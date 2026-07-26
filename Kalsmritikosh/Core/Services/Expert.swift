//
//  Expert.swift
//  Kalsmritikosh
//
//  Experts produce findings, not answers. The MasterBrain aggregates
//  findings from multiple experts in parallel and the Verifier folds
//  them into a final response with citations.
//
//  M6.1 contract change: ExpertContext no longer carries a specific
//  ModelProvider. Experts declare CapabilitySpec values and call the
//  CapabilityRegistry to obtain a model. No expert may name a provider
//  or model.
//

import Foundation

public protocol Expert: Sendable {
    /// Stable identifier the Router uses to address this expert.
    // G2-SWIFT6 — nonisolated so the registry / router can read these
    // declaratively without "main-actor-isolated property cannot be
    // referenced on a nonisolated actor instance" warnings.
    nonisolated var id: String { get }

    /// Capabilities + domains declared up front so the Router can match
    /// experts to intents deterministically.
    nonisolated var capabilities: Set<ExpertCapability> { get }
    nonisolated var domains: Set<ExpertDomain> { get }

    func analyze(
        intent: UserIntent,
        context: ExpertContext
    ) async throws -> ExpertFindings
}

public enum ExpertCapability: String, Codable, Sendable, Hashable {
    case threadAnalysis
    case relationshipAnalysis
    case revenueAnalysis
    case costAnalysis
    case contractAnalysis
    case obligationAnalysis
    case citationAnalysis
    case literatureAnalysis
    case tableUnderstanding
    case formUnderstanding
    case eventReconstruction
    case historyReconstruction
    case projectReconstruction
    case stakeholderMapping
    case generalReasoning
}

public enum ExpertDomain: String, Codable, Sendable, Hashable {
    case email
    case financial
    case legal
    case research
    case ocr
    case timeline
    case project
    /// Generalist: reasons across all retrieved evidence (chunks + entities
    /// + events), not one narrow domain. Always relevant.
    case reasoning
}

/// Read-only handles given to an expert so it can pull retrieved evidence
/// without ever touching the filesystem or naming a specific model.
public struct ExpertContext: Sendable {
    public let retriever: Retriever
    public let capabilities: CapabilityRegistry
    public let now: Date
    /// G2-0 — when MasterBrain has already run retrieval for this
    /// question, the result is shared across all experts (and the
    /// verifier) so a single question never costs more than ONE
    /// retrieval round-trip. nil = caller hasn't pre-fetched, fall
    /// back to a direct retriever call.
    public let sharedRetrieval: RetrievalResult?
    /// The shared request-scoped LLM budget/context for THIS question. An
    /// expert MUST pass it into `provider.generate(...purpose:context:)` so its
    /// call reserves from the one allowance every operation in the request
    /// shares. nil = unscoped (background / legacy) — no budget enforced.
    public let llmContext: LLMRequestContext?
    /// OPS-003B — the per-request sensitivity scope. When present, fresh
    /// retriever calls (i.e. not from sharedRetrieval) use the
    /// scope-aware retrieve(for:layers:access:) path so experts never
    /// bypass the SensitiveRetrievalPolicy. nil = legacy unscoped path.
    public let access: SensitiveAccessContext?
    /// OPS-003B — the policy actor injected by MasterBrain. Used by
    /// `promptAuthorizer` to re-filter at authorization time.
    public let sensitivePolicy: SensitiveRetrievalPolicy?

    public nonisolated init(
        retriever: Retriever,
        capabilities: CapabilityRegistry,
        sharedRetrieval: RetrievalResult? = nil,
        llmContext: LLMRequestContext? = nil,
        access: SensitiveAccessContext? = nil,
        sensitivePolicy: SensitiveRetrievalPolicy? = nil,
        now: Date = .init()
    ) {
        self.retriever = retriever
        self.capabilities = capabilities
        self.sharedRetrieval = sharedRetrieval
        self.llmContext = llmContext
        self.access = access
        self.sensitivePolicy = sensitivePolicy
        self.now = now
    }

    /// OPS-003B — authorizer that re-runs SensitiveRetrievalPolicy at
    /// prompt construction time so assignment changes since retrieval are caught.
    public var promptAuthorizer: PromptContextAuthorizer {
        PromptContextAuthorizer(policy: sensitivePolicy)
    }

    /// Returns the shared retrieval if MasterBrain pre-fetched it
    /// (G2-0); otherwise falls back to a fresh retriever call with the
    /// expert's requested layers. When an access context is present the
    /// call goes through the scope-aware retrieve(for:layers:access:) path
    /// so the SensitiveRetrievalPolicy is never bypassed on a fresh call.
    public func retrieve(
        for intent: UserIntent,
        layers: [RetrievalLayer]
    ) async throws -> RetrievalResult {
        if let cached = sharedRetrieval {
            return cached
        }
        if let access {
            let authorized = try await retriever.retrieve(for: intent, layers: layers, access: access)
            return authorized.result
        }
        return try await retriever.retrieve(for: intent, layers: layers)
    }

    /// OPS-003B — scope-aware retrieval that returns the full
    /// AuthorizedRetrievalResult so the caller can pass it directly to
    /// `promptAuthorizer.authorize(_:)`. Throws `SensitiveRetrievalError.unscopedRetrieval`
    /// when no access context is present — fail-closed, no globalPermissive bypass.
    public func retrieveAuthorized(
        for intent: UserIntent,
        layers: [RetrievalLayer]
    ) async throws -> AuthorizedRetrievalResult {
        guard let access else {
            throw SensitiveRetrievalError.unscopedRetrieval
        }
        if let cached = sharedRetrieval {
            return AuthorizedRetrievalResult(result: cached, accessContext: access)
        }
        return try await retriever.retrieve(for: intent, layers: layers, access: access)
    }
}

public struct ExpertFindings: Codable, Sendable {
    public let expertID: String
    public let claims: [Claim]
    public let confidence: Confidence
    public let notes: String?
    /// Count of LLM-generated claims dropped because their cited evidence
    /// didn't resolve to anything in the retrieval set. Surfaced via the
    /// ConfidenceReport so the UI can show "N unverifiable claims dropped".
    public let droppedUnverifiable: Int

    public nonisolated init(
        expertID: String,
        claims: [Claim],
        confidence: Confidence,
        notes: String? = nil,
        droppedUnverifiable: Int = 0
    ) {
        self.expertID = expertID
        self.claims = claims
        self.confidence = confidence
        self.notes = notes
        self.droppedUnverifiable = droppedUnverifiable
    }

    private enum CodingKeys: String, CodingKey {
        case expertID, claims, confidence, notes, droppedUnverifiable
    }

    public nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.expertID = try c.decode(String.self, forKey: .expertID)
        self.claims = try c.decode([Claim].self, forKey: .claims)
        self.confidence = try c.decode(Confidence.self, forKey: .confidence)
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes)
        self.droppedUnverifiable = try c.decodeIfPresent(Int.self, forKey: .droppedUnverifiable) ?? 0
    }

    /// Whether a claim's supporting IDs are per-claim LLM-cited evidence
    /// (`.specific`) or come from a deterministic per-item heuristic path
    /// (`.coarse`). UI surfaces this so users can distinguish the two.
    public enum EvidenceGranularity: String, Codable, Sendable, Hashable {
        case specific
        case coarse
    }

    public struct Claim: Codable, Sendable, Hashable {
        public let statement: String
        public let supportingObjectIDs: [KnowledgeObject.ID]
        public let supportingEventIDs: [Event.ID]
        public let supportingEntityIDs: [Entity.ID]
        public let confidence: Confidence
        public let evidenceGranularity: EvidenceGranularity
        /// S0.5 item 2 C2 — the canonical assertability evaluation this claim was derived
        /// from (present for GenericFact-derived deterministic claims; nil for LLM claims
        /// still under the evidence-verification contract). Carried UNCHANGED from retrieval
        /// so the brain/validator cannot strengthen it.
        public let evaluation: ClaimEvaluation?

        public nonisolated init(
            statement: String,
            supportingObjectIDs: [KnowledgeObject.ID] = [],
            supportingEventIDs: [Event.ID] = [],
            supportingEntityIDs: [Entity.ID] = [],
            confidence: Confidence,
            evidenceGranularity: EvidenceGranularity = .specific,
            evaluation: ClaimEvaluation? = nil
        ) {
            self.statement = statement
            self.supportingObjectIDs = supportingObjectIDs
            self.supportingEventIDs = supportingEventIDs
            self.supportingEntityIDs = supportingEntityIDs
            self.confidence = confidence
            self.evidenceGranularity = evidenceGranularity
            self.evaluation = evaluation
        }

        private enum CodingKeys: String, CodingKey {
            case statement, supportingObjectIDs, supportingEventIDs,
                 supportingEntityIDs, confidence, evidenceGranularity, evaluation
        }

        public nonisolated init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.statement = try c.decode(String.self, forKey: .statement)
            self.supportingObjectIDs = try c.decodeIfPresent([KnowledgeObject.ID].self, forKey: .supportingObjectIDs) ?? []
            self.supportingEventIDs = try c.decodeIfPresent([Event.ID].self, forKey: .supportingEventIDs) ?? []
            self.supportingEntityIDs = try c.decodeIfPresent([Entity.ID].self, forKey: .supportingEntityIDs) ?? []
            self.confidence = try c.decode(Confidence.self, forKey: .confidence)
            self.evidenceGranularity = try c.decodeIfPresent(EvidenceGranularity.self, forKey: .evidenceGranularity) ?? .specific
            self.evaluation = try c.decodeIfPresent(ClaimEvaluation.self, forKey: .evaluation)
        }
    }
}
