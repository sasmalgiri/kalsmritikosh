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

public actor CapabilityRegistry {
    public let hardware: HardwareProfile

    private var providers: [String: any ModelProvider] = [:]
    private var manifestByID: [String: ModelManifest] = [:]
    private var recommendationByCapability: [ModelCapability: AutoRecommendation.Recommendation] = [:]

    private let benchmark: PerformanceBenchmark
    private let preferences: ModelUserPreferences
    private let privacyGate: PrivacyGate

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
        for candidate in candidates {
            if await candidate.isAvailable() { return candidate }
        }
        throw ModelProviderError.noProviderForSpec(spec: spec)
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
        // Filter by capability coverage + privacy.
        let eligible = providers.values.filter { provider -> Bool in
            let manifest = provider.manifest
            guard spec.requires.isSubset(of: manifest.capabilities) else { return false }
            return isPrivacyEligible(manifest: manifest, spec: spec)
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
