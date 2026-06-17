//
//  CapabilitySpec.swift
//  Kalsmritikosh
//
//  Declarative description of what a caller needs from a model. Experts,
//  the router, summarizers, and extractors compose CapabilitySpec values
//  and hand them to CapabilityRegistry.resolve(_:).
//
//  Callers never name a provider or model. They name what the call has to
//  achieve.
//

import Foundation

public struct CapabilitySpec: Codable, Sendable, Hashable {
    /// Capabilities a fulfilling model MUST possess. Resolution fails if no
    /// provider in the registry covers all of them.
    public let requires: Set<ModelCapability>

    /// Capabilities that are nice-to-have. Used as tiebreakers when several
    /// providers match `requires` — more matches wins.
    public let prefers: Set<ModelCapability>

    /// Acceptable latency tier. Providers that benchmarked slower than this
    /// tier are deprioritized but still eligible if nothing better is loaded.
    public let maxLatency: LatencyHint

    /// Strictest privacy tier the call can tolerate. `cloud` providers are
    /// filtered out unless the spec is `.cloud` AND the user-level PrivacyGate
    /// allows cloud routing.
    public let privacy: PrivacyLevel

    /// Hint for the resolver about how much input context is coming. Drives
    /// long-context capability selection and KV-cache budgeting.
    public let estimatedContextTokens: Int

    /// Free-form human description, surfaced in debugging traces. Never
    /// parsed by the resolver.
    public let purpose: String

    public init(
        requires: Set<ModelCapability>,
        prefers: Set<ModelCapability> = [],
        maxLatency: LatencyHint = .background,
        privacy: PrivacyLevel = .onDevice,
        estimatedContextTokens: Int = 2_000,
        purpose: String = ""
    ) {
        self.requires = requires
        self.prefers = prefers
        self.maxLatency = maxLatency
        self.privacy = privacy
        self.estimatedContextTokens = estimatedContextTokens
        self.purpose = purpose
    }
}

extension CapabilitySpec {
    /// Convenience for callers that only need raw text generation.
    public static func textGeneration(purpose: String = "") -> CapabilitySpec {
        .init(requires: [.textGeneration], purpose: purpose)
    }

    /// Convenience for the common "I want structured reasoning over a body
    /// of evidence" call experts make.
    ///
    /// Privacy is `.localNetwork` (not `.onDevice`) so a localhost-only
    /// model server (e.g. Ollama on http://localhost:11434) can resolve
    /// when no on-device reasoning model is available — most notably on
    /// macOS 15.6 where FoundationModelsProvider's
    /// `#available(macOS 26.0,*)` gate fails. The privacy ladder in
    /// CapabilityRegistry.isPrivacyEligible still accepts
    /// `.onDevice` manifests under a `.localNetwork` spec, so
    /// FoundationModels continues to win on macOS 26+ where it is
    /// strictly higher-privacy and scored ahead by the resolver.
    /// Cloud providers stay filtered via PrivacyGate independent of
    /// this tier. UPDATE_15 Step 2 — without this relax, Ollama
    /// could never resolve regardless of whether the server was
    /// running, and every expert would silently fall back to
    /// heuristic.
    public static func reasoning(
        contextTokens: Int = 4_000,
        purpose: String = ""
    ) -> CapabilitySpec {
        .init(
            requires: [.textGeneration, .reasoning],
            prefers: [.structuredOutput, .longContext],
            maxLatency: .background,
            privacy: .localNetwork,
            estimatedContextTokens: contextTokens,
            purpose: purpose
        )
    }

    /// Convenience for the Summarizer. Same `.localNetwork` rationale
    /// as `reasoning` — keep on-device-or-localhost open so the
    /// summarizer doesn't silently dead-end on macOS 15.6 when no
    /// reasoning model is otherwise reachable.
    public static func summarization(
        contextTokens: Int = 8_000,
        purpose: String = ""
    ) -> CapabilitySpec {
        .init(
            requires: [.textGeneration, .summarization],
            prefers: [.longContext, .reasoning],
            maxLatency: .background,
            privacy: .localNetwork,
            estimatedContextTokens: contextTokens,
            purpose: purpose
        )
    }

    /// Convenience for embedding calls.
    public static func embedding(purpose: String = "") -> CapabilitySpec {
        .init(
            requires: [.embedding],
            maxLatency: .interactive,
            privacy: .onDevice,
            purpose: purpose
        )
    }

    /// Convenience for the routing / intent / complexity small-model role.
    public static func router(purpose: String = "") -> CapabilitySpec {
        .init(
            requires: [.textGeneration, .routing],
            prefers: [.routerSmall, .structuredOutput],
            maxLatency: .interactive,
            privacy: .onDevice,
            purpose: purpose
        )
    }
}
