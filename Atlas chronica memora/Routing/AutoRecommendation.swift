//
//  AutoRecommendation.swift
//  Atlas chronica memora
//
//  Given the hardware profile and the manifests registered with the
//  CapabilityRegistry, decides which providers should be the default
//  fulfilment for each capability tier on this machine.
//
//  Pure function over (profile, manifests, benchmarks). The user can
//  override via UserPreferences; CapabilityRegistry consults the override
//  first and falls through to recommendation second.
//

import Foundation

public struct AutoRecommendation: Sendable {
    public struct Recommendation: Sendable, Hashable {
        public let capability: ModelCapability
        public let providerID: String
        public let rationale: String
    }

    public let hardware: HardwareProfile

    public init(hardware: HardwareProfile) {
        self.hardware = hardware
    }

    /// Returns one recommendation per capability the resolver wants a default
    /// for. Manifests whose `minRAMBytes` exceeds the hardware budget are
    /// dropped from candidacy.
    public func recommend(
        manifests: [ModelManifest],
        benchmarks: [String: BenchmarkResult]
    ) -> [Recommendation] {
        var recommendations: [Recommendation] = []
        let allTargets: Set<ModelCapability> = [
            .textGeneration, .reasoning, .summarization,
            .extraction, .classification, .routing,
            .embedding, .complexityAnalysis
        ]

        for capability in allTargets {
            guard let pick = pickProvider(
                for: capability,
                manifests: manifests,
                benchmarks: benchmarks
            ) else { continue }
            recommendations.append(pick)
        }
        return recommendations
    }

    private func pickProvider(
        for capability: ModelCapability,
        manifests: [ModelManifest],
        benchmarks: [String: BenchmarkResult]
    ) -> Recommendation? {
        let eligible = manifests
            .filter { $0.capabilities.contains(capability) }
            .filter { $0.minRAMBytes <= hardware.totalRAMBytes }

        guard !eligible.isEmpty else { return nil }

        // Routing-type capabilities prefer the smallest tier; reasoning /
        // summarization prefer the largest the hardware can carry.
        let preferLargest: Bool
        switch capability {
        case .routing, .classification, .complexityAnalysis: preferLargest = false
        default: preferLargest = true
        }

        let ranked = eligible.sorted { a, b in
            // Match against hardware tier first.
            let aMatch = a.tier == hardware.tier ? 0 : 1
            let bMatch = b.tier == hardware.tier ? 0 : 1
            if aMatch != bMatch { return aMatch < bMatch }

            // Then prefer faster benchmarks when measured.
            let aSpeed = benchmarks[a.id]?.tokensPerSecond ?? 0
            let bSpeed = benchmarks[b.id]?.tokensPerSecond ?? 0
            if aSpeed != bSpeed { return aSpeed > bSpeed }

            // Finally bias by tier preference.
            return preferLargest
                ? (a.tier.weight > b.tier.weight)
                : (a.tier.weight < b.tier.weight)
        }

        guard let best = ranked.first else { return nil }
        return Recommendation(
            capability: capability,
            providerID: best.id,
            rationale: "hardware \(hardware.tier.rawValue), provider tier \(best.tier.rawValue)"
        )
    }
}

private extension ModelManifest.Tier {
    var weight: Int {
        switch self {
        case .small: return 0
        case .medium: return 1
        case .large: return 2
        }
    }
}
