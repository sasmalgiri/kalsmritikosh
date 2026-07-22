//
//  HistoryItem.swift
//  Kalsmritikosh
//
//  HIST-021 (Universal History program, Phase 3). The universal historical unit:
//  events, state changes, periods, relationships, decisions, communications and
//  document/legal/financial/research milestones all share ONE contract. Every item
//  carries an EvidenceStatus (the shared enum), a confidence, and evidence + lineage
//  references — no history item without provenance (trust rule 1).
//
//  Pure domain model, LLM-free.
//

import Foundation

public enum HistoryItemKind: String, Codable, Sendable, CaseIterable {
    case event
    case stateStart
    case stateEnd
    case stateChange
    case period
    case relationshipStart
    case relationshipEnd
    case decision
    case communication
    case documentMilestone
    case financialTransaction
    case legalMilestone
    case researchFinding
    case userAnnotation
}

/// History-local review state (kept self-contained; distinct from DerivedObject's).
public enum HistoryReviewStatus: String, Codable, Sendable {
    case unreviewed
    case accepted
    case rejected
    case corrected
}

/// A pointer from a history item to the EXACT evidence backing it. `role` records
/// whether this source supports, contradicts, or merely contextualises the item.
public struct EvidenceReference: Sendable, Codable, Hashable {
    public enum Role: String, Codable, Sendable { case supports, contradicts, context }
    public let objectID: KnowledgeObject.ID
    public let blockID: EvidenceBlock.ID?
    public let assertionID: Assertion.ID?
    public let genericFactID: GenericFact.ID?
    public let eventID: Event.ID?
    public let sourceVersionID: UUID?
    public let role: Role

    public nonisolated init(
        objectID: KnowledgeObject.ID, blockID: EvidenceBlock.ID? = nil,
        assertionID: Assertion.ID? = nil, genericFactID: GenericFact.ID? = nil,
        eventID: Event.ID? = nil, sourceVersionID: UUID? = nil, role: Role = .supports
    ) {
        self.objectID = objectID; self.blockID = blockID; self.assertionID = assertionID
        self.genericFactID = genericFactID; self.eventID = eventID
        self.sourceVersionID = sourceVersionID; self.role = role
    }
}

/// What a history item was projected FROM (lineage; §13 projection preserves refs).
public struct DerivedReference: Sendable, Codable, Hashable {
    public enum Kind: String, Codable, Sendable { case event, assertion, genericFact, temporalClaim, relationship }
    public let kind: Kind
    public let id: UUID
    public nonisolated init(kind: Kind, id: UUID) { self.kind = kind; self.id = id }
}

public struct HistoryItem: Sendable, Codable, Identifiable, Hashable {
    public let id: UUID
    public let subject: HistorySubject
    public let kind: HistoryItemKind
    public let title: String
    public let description: String?

    public let start: TemporalValue?
    public let end: TemporalValue?
    public let actors: [Entity.ID]
    public let relatedSubjects: [Entity.ID]

    public let evidenceStatus: EvidenceStatus
    public let confidence: Double
    public let evidence: [EvidenceReference]
    public let derivedFrom: [DerivedReference]

    public let contradictionGroupID: UUID?
    public let alternativeAccountID: UUID?
    public let reviewStatus: HistoryReviewStatus

    public nonisolated init(
        id: UUID = UUID(), subject: HistorySubject, kind: HistoryItemKind,
        title: String, description: String? = nil,
        start: TemporalValue? = nil, end: TemporalValue? = nil,
        actors: [Entity.ID] = [], relatedSubjects: [Entity.ID] = [],
        evidenceStatus: EvidenceStatus, confidence: Double,
        evidence: [EvidenceReference] = [], derivedFrom: [DerivedReference] = [],
        contradictionGroupID: UUID? = nil, alternativeAccountID: UUID? = nil,
        reviewStatus: HistoryReviewStatus = .unreviewed
    ) {
        self.id = id; self.subject = subject; self.kind = kind
        self.title = title; self.description = description
        self.start = start; self.end = end
        self.actors = actors; self.relatedSubjects = relatedSubjects
        self.evidenceStatus = evidenceStatus; self.confidence = confidence
        self.evidence = evidence; self.derivedFrom = derivedFrom
        self.contradictionGroupID = contradictionGroupID
        self.alternativeAccountID = alternativeAccountID
        self.reviewStatus = reviewStatus
    }

    /// A history item is undated when neither bound carries a concrete date — such
    /// items go to the "undated material" section, never onto the timeline at a
    /// guessed position (§13 rule 8).
    public var isUndated: Bool {
        (start?.start == nil && start?.end == nil) && (end?.start == nil && end?.end == nil)
    }
}
