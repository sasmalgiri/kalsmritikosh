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

    /// The CANONICAL trust classification. Its `review` is always reconciled to the
    /// authoritative `reviewStatus` (history vocabulary), so the two never disagree.
    public let assessment: EvidenceAssessment
    public let confidence: Double
    public let evidence: [EvidenceReference]
    public let derivedFrom: [DerivedReference]

    public let contradictionGroupID: UUID?
    public let alternativeAccountID: UUID?
    public let reviewStatus: HistoryReviewStatus

    /// Deprecated compatibility shim — derived from `assessment`.
    @available(*, deprecated, message: "Use assessment (+ AssertabilityPolicy)")
    public var evidenceStatus: EvidenceStatus { LegacyEvidenceStatusAdapter.encode(assessment) }

    /// The shared ReviewDisposition for a history review status (authoritative here).
    public nonisolated static func reviewDisposition(for s: HistoryReviewStatus) -> ReviewDisposition {
        switch s {
        case .unreviewed: return .unreviewed
        case .accepted:   return .confirmed
        case .corrected:  return .corrected
        case .rejected:   return .rejected
        }
    }

    /// Canonical initializer. The assessment's review is RECONCILED to `reviewStatus` so
    /// in-memory and persisted review can never diverge.
    public nonisolated init(
        id: UUID = UUID(), subject: HistorySubject, kind: HistoryItemKind,
        title: String, description: String? = nil,
        start: TemporalValue? = nil, end: TemporalValue? = nil,
        actors: [Entity.ID] = [], relatedSubjects: [Entity.ID] = [],
        assessment: EvidenceAssessment, confidence: Double,
        evidence: [EvidenceReference] = [], derivedFrom: [DerivedReference] = [],
        contradictionGroupID: UUID? = nil, alternativeAccountID: UUID? = nil,
        reviewStatus: HistoryReviewStatus = .unreviewed
    ) {
        self.id = id; self.subject = subject; self.kind = kind
        self.title = title; self.description = description
        self.start = start; self.end = end
        self.actors = actors; self.relatedSubjects = relatedSubjects
        self.assessment = assessment.with(review: Self.reviewDisposition(for: reviewStatus))
        self.confidence = confidence
        self.evidence = evidence; self.derivedFrom = derivedFrom
        self.contradictionGroupID = contradictionGroupID
        self.alternativeAccountID = alternativeAccountID
        self.reviewStatus = reviewStatus
    }

    /// Legacy initializer — decodes `evidenceStatus`, then reconciles the review dimension
    /// with the mapped `reviewStatus` (so an item built with evidenceStatus .sourceAsserted
    /// + reviewStatus .accepted carries review == .confirmed, matching what the repo writes).
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
        self.init(id: id, subject: subject, kind: kind, title: title, description: description,
                  start: start, end: end, actors: actors, relatedSubjects: relatedSubjects,
                  assessment: LegacyEvidenceStatusAdapter.decode(evidenceStatus), confidence: confidence,
                  evidence: evidence, derivedFrom: derivedFrom,
                  contradictionGroupID: contradictionGroupID, alternativeAccountID: alternativeAccountID,
                  reviewStatus: reviewStatus)
    }

    /// A history item is undated when neither bound carries a concrete date — such
    /// items go to the "undated material" section, never onto the timeline at a
    /// guessed position (§13 rule 8).
    public var isUndated: Bool {
        (start?.start == nil && start?.end == nil) && (end?.start == nil && end?.end == nil)
    }

    // MARK: - Backward-compatible Codable (S0.5 item 2 C)

    /// Includes BOTH `assessment` and the legacy `evidenceStatus` key. Decode precedence:
    /// valid assessment → valid legacy evidenceStatus → throw; then the review dimension is
    /// RECONCILED to `reviewStatus` so decoded items match freshly-constructed ones.
    private enum CodingKeys: String, CodingKey {
        case id, subject, kind, title, description, start, end, actors, relatedSubjects
        case assessment, evidenceStatus, confidence, evidence, derivedFrom
        case contradictionGroupID, alternativeAccountID, reviewStatus
    }

    public nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.subject = try c.decode(HistorySubject.self, forKey: .subject)
        self.kind = try c.decode(HistoryItemKind.self, forKey: .kind)
        self.title = try c.decode(String.self, forKey: .title)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.start = try c.decodeIfPresent(TemporalValue.self, forKey: .start)
        self.end = try c.decodeIfPresent(TemporalValue.self, forKey: .end)
        self.actors = try c.decodeIfPresent([Entity.ID].self, forKey: .actors) ?? []
        self.relatedSubjects = try c.decodeIfPresent([Entity.ID].self, forKey: .relatedSubjects) ?? []
        self.confidence = try c.decode(Double.self, forKey: .confidence)
        self.evidence = try c.decodeIfPresent([EvidenceReference].self, forKey: .evidence) ?? []
        self.derivedFrom = try c.decodeIfPresent([DerivedReference].self, forKey: .derivedFrom) ?? []
        self.contradictionGroupID = try c.decodeIfPresent(UUID.self, forKey: .contradictionGroupID)
        self.alternativeAccountID = try c.decodeIfPresent(UUID.self, forKey: .alternativeAccountID)
        let review = try c.decodeIfPresent(HistoryReviewStatus.self, forKey: .reviewStatus) ?? .unreviewed
        self.reviewStatus = review
        let decoded: EvidenceAssessment
        if let a = try? c.decode(EvidenceAssessment.self, forKey: .assessment) {
            decoded = a
        } else if let s = try c.decodeIfPresent(EvidenceStatus.self, forKey: .evidenceStatus) {
            decoded = LegacyEvidenceStatusAdapter.decode(s)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "HistoryItem: neither `assessment` nor legacy `evidenceStatus` present"))
        }
        // Reconcile review with the authoritative reviewStatus (matches the initializers).
        self.assessment = decoded.with(review: Self.reviewDisposition(for: review))
    }

    public nonisolated func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(subject, forKey: .subject)
        try c.encode(kind, forKey: .kind); try c.encode(title, forKey: .title)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(start, forKey: .start); try c.encodeIfPresent(end, forKey: .end)
        try c.encode(actors, forKey: .actors); try c.encode(relatedSubjects, forKey: .relatedSubjects)
        try c.encode(assessment, forKey: .assessment)
        try c.encode(LegacyEvidenceStatusAdapter.encode(assessment), forKey: .evidenceStatus)  // compatibility
        try c.encode(confidence, forKey: .confidence)
        try c.encode(evidence, forKey: .evidence); try c.encode(derivedFrom, forKey: .derivedFrom)
        try c.encodeIfPresent(contradictionGroupID, forKey: .contradictionGroupID)
        try c.encodeIfPresent(alternativeAccountID, forKey: .alternativeAccountID)
        try c.encode(reviewStatus, forKey: .reviewStatus)
    }
}
