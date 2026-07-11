//
//  ReleaseCapabilityProfile.swift
//  Kalsmritikosh
//
//  The single immutable source of truth for the v1 consumer-release
//  configuration (spec P0.3). Every value is a locked decision from
//  SHIP_DECISIONS.md; release code reads THIS, not scattered flags, so the
//  shipped binary can never drift from the locked promise. Debug/internal
//  builds may expose experimental controls; the release profile must not.
//

import Foundation

public struct ReleaseCapabilityProfile: Sendable, Equatable {
    public let engine: SystemMode
    public let cloudRoutingEnabled: Bool
    public let ollamaUserSetupVisible: Bool
    public let byoModelUIVisible: Bool
    public let ingestGenerativeLLMEnabled: Bool
    public let contextPrefixBackfillEnabled: Bool
    public let firstChunkCardEnabled: Bool
    public let memoryDistillationOnIngestEnabled: Bool
    public let silentLLMBackgroundMaintenanceEnabled: Bool
    public let promptedLLMRerankerEnabled: Bool
    public let bundledReasoningProviderRequired: Bool

    /// The locked v1 profile. All generative-ingest levers OFF; no cloud, no
    /// user-facing Ollama/BYO-model; bundled reasoning provider required.
    public static let v1 = ReleaseCapabilityProfile(
        engine: .ledgerEventDriven,
        cloudRoutingEnabled: false,
        ollamaUserSetupVisible: false,
        byoModelUIVisible: false,
        ingestGenerativeLLMEnabled: false,
        contextPrefixBackfillEnabled: false,
        firstChunkCardEnabled: false,
        memoryDistillationOnIngestEnabled: false,
        silentLLMBackgroundMaintenanceEnabled: false,
        promptedLLMRerankerEnabled: false,
        bundledReasoningProviderRequired: true
    )

    /// Verify the live configuration matches the locked release profile.
    /// Returns the list of violations (empty = compliant). ReleaseReadiness
    /// asserts this so a drifted build fails the gate instead of shipping.
    public static func violations(against profile: ReleaseCapabilityProfile = .v1) -> [String] {
        var out: [String] = []
        if FeatureFlags.systemModeValue() != profile.engine {
            out.append("engine is \(FeatureFlags.systemModeValue().rawValue), expected \(profile.engine.rawValue)")
        }
        let policy = SystemEngineFactory.make(profile.engine).ingestPolicy
        if policy.eagerMemoryDistillation != profile.memoryDistillationOnIngestEnabled {
            out.append("ingest eagerMemoryDistillation=\(policy.eagerMemoryDistillation), expected \(profile.memoryDistillationOnIngestEnabled)")
        }
        if policy.contextPrefixBackfill != profile.contextPrefixBackfillEnabled {
            out.append("ingest contextPrefixBackfill=\(policy.contextPrefixBackfill), expected \(profile.contextPrefixBackfillEnabled)")
        }
        if policy.firstChunkCard != profile.firstChunkCardEnabled {
            out.append("ingest firstChunkCard=\(policy.firstChunkCard), expected \(profile.firstChunkCardEnabled)")
        }
        return out
    }
}
