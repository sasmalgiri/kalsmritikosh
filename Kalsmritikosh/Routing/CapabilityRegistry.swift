//
//  CapabilityRegistry.swift
//  Kalsmritikosh
//
//  The single front-door every caller uses to ask for a model. Callers
//  hand it a CapabilitySpec; the registry hands back a ModelProvider.
//  Providers and model identifiers never leak into experts, the brain,
//  the router, or any extractor.
//
//  Resolution order:
//      1. User pin for any required capability (always wins, modulo
//         availability + privacy gate).
//      2. AutoRecommendation default for the spec.
//      3. Best-fit ranking across registered providers using benchmarks,
//         tier matching, and stated capability coverage.
//      4. Throw `ModelProviderError.noProviderForSpec`.
//

import Foundation
import OSLog

public actor CapabilityRegistry {
    public let hardware: HardwareProfile

    private var providers: [String: any ModelProvider] = [:]
    private var manifestByID: [String: ModelManifest] = [:]
    private var recommendationByCapability: [ModelCapability: AutoRecommendation.Recommendation] = [:]

    private let benchmark: PerformanceBenchmark
    private let preferences: ModelUserPreferences
    private let privacyGate: PrivacyGate

    // MARK: Provider health / cooldown (in-memory)
    //
    // A provider that keeps timing out (e.g. an overloaded local Ollama
    // under ingest load) is put on a cooldown so `resolve` SKIPS it
    // instead of every caller blindly waiting the full per-call timeout
    // again — that blind retry-storm is what burned hours in the logs.
    // Cooldown is deliberately in-memory: it should reset on relaunch so
    // a fresh launch always re-probes rather than staying disabled after
    // a transient blip. Exponential backoff after N consecutive fails.
    private var consecutiveFailures: [String: Int] = [:]
    private var cooldownUntil: [String: Date] = [:]
    /// Consecutive failures before the first cooldown kicks in (so a
    /// single slow call doesn't sideline a provider).
    private let failuresBeforeCooldown = 3
    /// Base cooldown; doubles per extra failure, capped at `maxCooldown`.
    private let baseCooldown: TimeInterval = 20
    private let maxCooldown: TimeInterval = 120

    public init(
        hardware: HardwareProfile,
        benchmark: PerformanceBenchmark,
        preferences: ModelUserPreferences = .shared,
        privacyGate: PrivacyGate = .shared
    ) {
        self.hardware = hardware
        self.benchmark = benchmark
        self.preferences = preferences
        self.privacyGate = privacyGate
    }

    // MARK: - Registration

    public func register(_ provider: any ModelProvider) async {
        providers[provider.id] = provider
        manifestByID[provider.id] = provider.manifest
        await benchmark.benchmark(provider)
        await refreshRecommendations()
    }

    public func unregister(_ providerID: String) async {
        providers.removeValue(forKey: providerID)
        manifestByID.removeValue(forKey: providerID)
        await refreshRecommendations()
    }

    private func refreshRecommendations() async {
        var benchmarks: [String: BenchmarkResult] = [:]
        for id in providers.keys {
            if let r = await benchmark.result(for: id) { benchmarks[id] = r }
        }
        let recs = AutoRecommendation(hardware: hardware)
            .recommend(manifests: Array(manifestByID.values), benchmarks: benchmarks)
        recommendationByCapability = Dictionary(
            uniqueKeysWithValues: recs.map { ($0.capability, $0) }
        )
    }

    // MARK: - Resolution

    /// Resolve a CapabilitySpec to a concrete provider. Throws when nothing
    /// in the registry can fulfil the spec under the current privacy gate.
    public func resolve(_ spec: CapabilitySpec) async throws -> any ModelProvider {
        let candidates = try await rankedCandidates(for: spec)
        let now = Date()
        for candidate in candidates {
            // Skip providers currently cooling down after repeated
            // failures — don't pay their timeout again.
            if let until = cooldownUntil[candidate.id], until > now { continue }
            if await candidate.isAvailable() { return candidate }
        }
        throw ModelProviderError.noProviderForSpec(spec: spec)
    }

    // MARK: - Health reporting

    /// Callers that use a resolved provider report the outcome so the
    /// registry can cool down a failing provider (skip it in `resolve`)
    /// and recover it on the next success. Cheap to call; safe to spam.
    public func reportOutcome(providerID: String, success: Bool) {
        if success {
            consecutiveFailures[providerID] = 0
            cooldownUntil[providerID] = nil
            return
        }
        let fails = (consecutiveFailures[providerID] ?? 0) + 1
        consecutiveFailures[providerID] = fails
        guard fails >= failuresBeforeCooldown else { return }
        let over = fails - failuresBeforeCooldown        // 0,1,2,…
        let backoff = min(baseCooldown * pow(2, Double(over)), maxCooldown)
        cooldownUntil[providerID] = Date().addingTimeInterval(backoff)
        KalsmritikoshLog.routing.info("Provider \(providerID, privacy: .public) cooled down for \(Int(backoff), privacy: .public)s after \(fails, privacy: .public) consecutive failures")
    }

    /// True if the provider is currently on cooldown.
    public func isCooledDown(_ providerID: String) -> Bool {
        guard let until = cooldownUntil[providerID] else { return false }
        return until > Date()
    }

    /// Returns a list of providers that could fulfil the spec, in ranked
    /// order (best first). Used by the UI to surface fallback options.
    public func candidates(for spec: CapabilitySpec) async -> [any ModelProvider] {
        (try? await rankedCandidates(for: spec)) ?? []
    }

    /// Best provider for a single capability — most callers use this.
    public func resolve(_ capability: ModelCapability) async throws -> any ModelProvider {
        try await resolve(CapabilitySpec(requires: [capability]))
    }

    public func recommendation(for capability: ModelCapability) -> AutoRecommendation.Recommendation? {
        recommendationByCapability[capability]
    }

    public func allManifests() -> [ModelManifest] {
        Array(manifestByID.values)
    }

    public func allProviders() -> [any ModelProvider] {
        Array(providers.values)
    }

    // MARK: - Ranking

    private func rankedCandidates(for spec: CapabilitySpec) async throws -> [any ModelProvider] {
        // Fully-private / no-LLM stance: refuse any GENERATIVE spec so every
        // caller falls back to its deterministic rule/NL/extractive path.
        // Embedding specs (no `.textGeneration`) are untouched, so vector
        // retrieval still works entirely on-device. This is the master lever
        // for the "substitute the LLM" private facility.
        if privacyGate.offlineNoLLM && spec.requires.contains(.textGeneration) {
            throw ModelProviderError.noProviderForSpec(spec: spec)
        }
        // Filter by capability coverage + privacy.
        let eligible = providers.values.filter { provider -> Bool in
            let manifest = provider.manifest
            guard spec.requires.isSubset(of: manifest.capabilities) else { return false }
            guard isPrivacyEligible(manifest: manifest, spec: spec) else { return false }
            // STRICT device-fit gate. A GENERATIVE model whose estimated working
            // set exceeds 70% of device RAM only "runs" by swapping to disk
            // (a 26 GB model on a 16 GB Mac = unusably slow), so we never select
            // it — not even if the user pinned it (pins require eligibility).
            // minRAMBytes == 0 means unknown (e.g. Apple on-device) → allowed
            // (fail-open). Embedders (no .textGeneration) are never gated.
            if manifest.capabilities.contains(.textGeneration), manifest.minRAMBytes > 0 {
                let budget = Int64(Double(hardware.totalRAMBytes) * 0.7)
                if manifest.minRAMBytes > budget {
                    KalsmritikoshLog.app.info("Model-fit gate: excluding \(manifest.id, privacy: .public) — needs \(manifest.minRAMBytes / 1_073_741_824, privacy: .public)GB > budget \(budget / 1_073_741_824, privacy: .public)GB")
                    return false
                }
            }
            return true
        }

        if eligible.isEmpty {
            throw ModelProviderError.noProviderForSpec(spec: spec)
        }

        // User pin wins (when the pinned provider is in the eligible set).
        var pinned: [any ModelProvider] = []
        for capability in spec.requires {
            if let pinnedID = preferences.pinnedProvider(for: capability),
               let provider = providers[pinnedID],
               eligible.contains(where: { $0.id == provider.id }) {
                pinned.append(provider)
            }
        }

        var benchmarks: [String: BenchmarkResult] = [:]
        for p in eligible {
            if let r = await benchmark.result(for: p.id) { benchmarks[p.id] = r }
        }

        let scored = eligible
            .map { provider -> (any ModelProvider, Double) in
                (provider, score(provider: provider, spec: spec, benchmarks: benchmarks))
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)

        // Pinned providers first, then ranked, deduplicated.
        var seen = Set<String>()
        var out: [any ModelProvider] = []
        for p in pinned + scored where seen.insert(p.id).inserted {
            out.append(p)
        }
        return out
    }

    private func isPrivacyEligible(manifest: ModelManifest, spec: CapabilitySpec) -> Bool {
        switch spec.privacy {
        case .onDevice:
            return manifest.privacyLevel == .onDevice
        case .localNetwork:
            return manifest.privacyLevel == .onDevice || manifest.privacyLevel == .localNetwork
        case .cloud:
            if manifest.privacyLevel == .cloud {
                return privacyGate.allowCloudRouting
            }
            return true
        }
    }

    private func score(
        provider: any ModelProvider,
        spec: CapabilitySpec,
        benchmarks: [String: BenchmarkResult]
    ) -> Double {
        let manifest = provider.manifest
        var score: Double = 0

        // Preferred capabilities boost the score linearly.
        let preferMatches = spec.prefers.intersection(manifest.capabilities).count
        score += Double(preferMatches) * 10

        // Long context for big specs.
        if spec.estimatedContextTokens > 6_000 && manifest.capabilities.contains(.longContext) {
            score += 15
        }

        // Latency: if the spec is interactive but the measured latency isn't,
        // penalize. If it is, big bonus.
        if let result = benchmarks[provider.id] {
            if result.observedLatency <= spec.maxLatency {
                score += 20
            } else {
                score -= 10
            }
            score += min(result.tokensPerSecond, 100) * 0.2
        }

        // Hardware-tier match bonus.
        if manifest.tier == hardware.tier { score += 8 }

        // Privacy alignment.
        if manifest.privacyLevel == spec.privacy { score += 4 }

        return score
    }
}
