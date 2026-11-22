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
    /// Fully private by default: the release app never proposes or performs a
    /// model download — every shipped model (reasoning + BGE embedder/reranker)
    /// travels inside the app bundle. Zero network connections.
    public let optionalModelDownloadEnabled: Bool

    /// The locked v1 profile. All generative-ingest levers OFF; no cloud, no
    /// user-facing Ollama/BYO-model; bundled reasoning provider required.
    public nonisolated static let v1 = ReleaseCapabilityProfile(
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
        bundledReasoningProviderRequired: true,
        optionalModelDownloadEnabled: false
    )

    /// Unified path AI-34 (owner 2026-11-22) — not tested yet. The release profile when the person has AI ON
    /// (the evidence-only release is not enforced and the AI regime allows a model): the generative levers are
    /// on — chunk context labels (context-prefix backfill), the first-passage card, memory distillation at
    /// import, background AI upkeep, AI re-ranking and AI during import. Everything privacy-related is
    /// unchanged: no cloud routing, no model setup UI, no downloads (Online stays the person's choice).
    public nonisolated static let v1AIOn = ReleaseCapabilityProfile(
        engine: .ledgerEventDriven,
        cloudRoutingEnabled: false,
        ollamaUserSetupVisible: false,
        byoModelUIVisible: false,
        ingestGenerativeLLMEnabled: true,
        contextPrefixBackfillEnabled: true,
        firstChunkCardEnabled: true,
        memoryDistillationOnIngestEnabled: true,
        silentLLMBackgroundMaintenanceEnabled: true,
        promptedLLMRerankerEnabled: true,
        bundledReasoningProviderRequired: true,
        optionalModelDownloadEnabled: false
    )

    /// Unified path AI-34 (owner 2026-11-22) — not tested yet. Whether AI is ON for the release levers: the
    /// regime allows a model (Fully private / the evidence-only release forces it off) and the engine is at
    /// full power (Lightning reads every AI lever off).
    public nonisolated static func aiOn() -> Bool {
        FeatureFlags.aiRegimeValue().allowsAI && FeatureFlags.fullPowerModeValue()
    }

    /// Unified path AI-34 (owner 2026-11-22) — not tested yet. The profile in force now: `.v1AIOn` with AI on,
    /// the locked `.v1` (zero generative AI at import) otherwise. Read at launch for the import levers.
    public nonisolated static func current() -> ReleaseCapabilityProfile { aiOn() ? .v1AIOn : .v1 }

    /// Unified path AI-34 (owner 2026-11-22) — not tested yet. The import policy the app runs: the engine's own
    /// policy with the profile's generative levers added (with AI off this is exactly the engine's policy).
    public nonisolated static func effectiveIngestPolicy(_ base: SystemMode.EnrichmentPolicy,
                                                         profile: ReleaseCapabilityProfile = current()) -> SystemMode.EnrichmentPolicy {
        SystemMode.EnrichmentPolicy(
            eagerMemoryDistillation: base.eagerMemoryDistillation || profile.memoryDistillationOnIngestEnabled,
            contextPrefixBackfill: base.contextPrefixBackfill || profile.contextPrefixBackfillEnabled,
            firstChunkCard: base.firstChunkCard || profile.firstChunkCardEnabled)
    }

    /// Verify the live configuration matches the release profile in force (`current()`: AI-aware, AI-34).
    /// Returns the list of violations (empty = compliant). ReleaseReadiness
    /// asserts this so a drifted build fails the gate instead of shipping.
    public static func violations(against profile: ReleaseCapabilityProfile = current()) -> [String] {
        var out: [String] = []
        if FeatureFlags.systemModeValue() != profile.engine {
            out.append("engine is \(FeatureFlags.systemModeValue().rawValue), expected \(profile.engine.rawValue)")
        }
        // AI-34 — the policy AppState actually runs (the engine's, plus the profile's levers when AI is on).
        let policy = effectiveIngestPolicy(SystemEngineFactory.make(profile.engine).ingestPolicy, profile: profile)
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
