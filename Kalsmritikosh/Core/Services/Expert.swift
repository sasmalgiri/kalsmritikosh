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

    public nonisolated init(
        retriever: Retriever,
        capabilities: CapabilityRegistry,
        sharedRetrieval: RetrievalResult? = nil,
        now: Date = .init()
    ) {
        self.retriever = retriever
        self.capabilities = capabilities
        self.sharedRetrieval = sharedRetrieval
        self.now = now
    }

    /// Returns the shared retrieval if MasterBrain pre-fetched it
    /// (G2-0); otherwise falls back to a fresh retriever call with the
    /// expert's requested layers. Either way the expert sees the same
    /// `RetrievalResult` shape — it can keep filtering chunks/events
    /// to its domain without caring whether the result was shared. The
    /// shared result always covers the union of layers any expert
    /// might want (the priority order), so per-expert layer filtering
    /// happens on the consumer side, not at retrieval time.
    public func retrieve(
        for intent: UserIntent,
        layers: [RetrievalLayer]
    ) async throws -> RetrievalResult {
        if let cached = sharedRetrieval {
            return cached
        }
        return try await retriever.retrieve(for: intent, layers: layers)
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

        public nonisolated init(
            statement: String,
            supportingObjectIDs: [KnowledgeObject.ID] = [],
            supportingEventIDs: [Event.ID] = [],
            supportingEntityIDs: [Entity.ID] = [],
            confidence: Confidence,
            evidenceGranularity: EvidenceGranularity = .specific
        ) {
            self.statement = statement
            self.supportingObjectIDs = supportingObjectIDs
            self.supportingEventIDs = supportingEventIDs
            self.supportingEntityIDs = supportingEntityIDs
            self.confidence = confidence
            self.evidenceGranularity = evidenceGranularity
        }

        private enum CodingKeys: String, CodingKey {
            case statement, supportingObjectIDs, supportingEventIDs,
                 supportingEntityIDs, confidence, evidenceGranularity
        }

        public nonisolated init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.statement = try c.decode(String.self, forKey: .statement)
            self.supportingObjectIDs = try c.decodeIfPresent([KnowledgeObject.ID].self, forKey: .supportingObjectIDs) ?? []
            self.supportingEventIDs = try c.decodeIfPresent([Event.ID].self, forKey: .supportingEventIDs) ?? []
            self.supportingEntityIDs = try c.decodeIfPresent([Entity.ID].self, forKey: .supportingEntityIDs) ?? []
            self.confidence = try c.decode(Confidence.self, forKey: .confidence)
            self.evidenceGranularity = try c.decodeIfPresent(EvidenceGranularity.self, forKey: .evidenceGranularity) ?? .specific
        }
    }
}
