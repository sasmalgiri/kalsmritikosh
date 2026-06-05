//
//  Expert.swift
//  Atlas chronica memora
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
    var id: String { get }

    /// Capabilities + domains declared up front so the Router can match
    /// experts to intents deterministically.
    var capabilities: Set<ExpertCapability> { get }
    var domains: Set<ExpertDomain> { get }

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
}

public enum ExpertDomain: String, Codable, Sendable, Hashable {
    case email
    case financial
    case legal
    case research
    case ocr
    case timeline
    case project
}

/// Read-only handles given to an expert so it can pull retrieved evidence
/// without ever touching the filesystem or naming a specific model.
public struct ExpertContext: Sendable {
    public let retriever: Retriever
    public let capabilities: CapabilityRegistry
    public let now: Date

    public init(retriever: Retriever, capabilities: CapabilityRegistry, now: Date = .init()) {
        self.retriever = retriever
        self.capabilities = capabilities
        self.now = now
    }
}

public struct ExpertFindings: Codable, Sendable {
    public let expertID: String
    public let claims: [Claim]
    public let confidence: Confidence
    public let notes: String?

    public init(expertID: String, claims: [Claim], confidence: Confidence, notes: String? = nil) {
        self.expertID = expertID
        self.claims = claims
        self.confidence = confidence
        self.notes = notes
    }

    public struct Claim: Codable, Sendable, Hashable {
        public let statement: String
        public let supportingObjectIDs: [KnowledgeObject.ID]
        public let supportingEventIDs: [Event.ID]
        public let supportingEntityIDs: [Entity.ID]
        public let confidence: Confidence

        public init(
            statement: String,
            supportingObjectIDs: [KnowledgeObject.ID] = [],
            supportingEventIDs: [Event.ID] = [],
            supportingEntityIDs: [Entity.ID] = [],
            confidence: Confidence
        ) {
            self.statement = statement
            self.supportingObjectIDs = supportingObjectIDs
            self.supportingEventIDs = supportingEventIDs
            self.supportingEntityIDs = supportingEntityIDs
            self.confidence = confidence
        }
    }
}
