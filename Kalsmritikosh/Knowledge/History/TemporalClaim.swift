//
//  TemporalClaim.swift
//  Kalsmritikosh
//
//  HIST-020/024 (Universal History program, Phase 3). Events alone cannot express
//  employment, education, ownership, residence, roles, membership or status that
//  hold TRUE OVER TIME. A TemporalClaim is subject–predicate–object with validity
//  and observation intervals, evidence-linked and status-graded. It reuses the ONE
//  shared EvidenceStatus (Core/Models/GenericFact.swift) — no fork.
//
//  Pure domain model, LLM-free (capability discipline).
//

import Foundation

/// A date with preserved precision and original text. Never widen precision for
/// display (a year-only date is NOT 1 January) — the renderer honours `precision`.
public struct TemporalValue: Sendable, Codable, Hashable {
    public let start: Date?
    public let end: Date?
    public let precision: DatePrecision
    public let originalText: String?
    public let confidence: Double

    public nonisolated init(start: Date?, end: Date? = nil, precision: DatePrecision,
                            originalText: String? = nil, confidence: Double) {
        self.start = start; self.end = end; self.precision = precision
        self.originalText = originalText; self.confidence = confidence
    }
    public var isUnknown: Bool { start == nil && end == nil }
}

/// The object of a temporal claim: a literal string, another entity, or a quantity.
public enum ClaimValue: Sendable, Codable, Hashable {
    case literal(String)
    case entity(Entity.ID)
    case quantity(Double, unit: String?)

    public var displayText: String {
        switch self {
        case .literal(let s): return s
        case .entity(let id): return id.uuidString
        case .quantity(let n, let u): return u.map { "\(n) \($0)" } ?? "\(n)"
        }
    }
}

public struct TemporalClaim: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let subjectID: Entity.ID
    public let predicate: String
    public let object: ClaimValue

    public let validFrom: TemporalValue?
    public let validTo: TemporalValue?
    public let observedAt: TemporalValue?

    /// The CANONICAL trust classification — the five separated dimensions (S0.5 item 2 C2).
    public let assessment: EvidenceAssessment
    public let confidence: Double
    public let sourceObjectIDs: [KnowledgeObject.ID]
    public let sourceBlockIDs: [EvidenceBlock.ID]
    public let assertionIDs: [Assertion.ID]
    public let genericFactIDs: [GenericFact.ID]

    public let extractorID: String
    public let extractorVersion: String
    public let createdAt: Date

    /// Deprecated compatibility shim — derived from `assessment`.
    @available(*, deprecated, message: "Use assessment (+ AssertabilityPolicy)")
    public var status: EvidenceStatus { LegacyEvidenceStatusAdapter.encode(assessment) }

    /// Canonical initializer.
    public nonisolated init(
        id: UUID = UUID(), subjectID: Entity.ID, predicate: String, object: ClaimValue,
        validFrom: TemporalValue? = nil, validTo: TemporalValue? = nil, observedAt: TemporalValue? = nil,
        assessment: EvidenceAssessment, confidence: Double,
        sourceObjectIDs: [KnowledgeObject.ID] = [], sourceBlockIDs: [EvidenceBlock.ID] = [],
        assertionIDs: [Assertion.ID] = [], genericFactIDs: [GenericFact.ID] = [],
        extractorID: String, extractorVersion: String, createdAt: Date
    ) {
        self.id = id; self.subjectID = subjectID; self.predicate = predicate; self.object = object
        self.validFrom = validFrom; self.validTo = validTo; self.observedAt = observedAt
        self.assessment = assessment; self.confidence = confidence
        self.sourceObjectIDs = sourceObjectIDs; self.sourceBlockIDs = sourceBlockIDs
        self.assertionIDs = assertionIDs; self.genericFactIDs = genericFactIDs
        self.extractorID = extractorID; self.extractorVersion = extractorVersion; self.createdAt = createdAt
    }

    /// Legacy initializer — decodes a single `EvidenceStatus` into the dimensions.
    public nonisolated init(
        id: UUID = UUID(), subjectID: Entity.ID, predicate: String, object: ClaimValue,
        validFrom: TemporalValue? = nil, validTo: TemporalValue? = nil, observedAt: TemporalValue? = nil,
        status: EvidenceStatus, confidence: Double,
        sourceObjectIDs: [KnowledgeObject.ID] = [], sourceBlockIDs: [EvidenceBlock.ID] = [],
        assertionIDs: [Assertion.ID] = [], genericFactIDs: [GenericFact.ID] = [],
        extractorID: String, extractorVersion: String, createdAt: Date
    ) {
        self.init(id: id, subjectID: subjectID, predicate: predicate, object: object,
                  validFrom: validFrom, validTo: validTo, observedAt: observedAt,
                  assessment: LegacyEvidenceStatusAdapter.decode(status), confidence: confidence,
                  sourceObjectIDs: sourceObjectIDs, sourceBlockIDs: sourceBlockIDs,
                  assertionIDs: assertionIDs, genericFactIDs: genericFactIDs,
                  extractorID: extractorID, extractorVersion: extractorVersion, createdAt: createdAt)
    }
}

/// HIST-024 — the domain-NEUTRAL predicate registry. Domain packs may add more, but
/// every predicate maps to this same temporal model. Kept as canonical strings so
/// the store and projector agree.
public enum HistoryPredicate {
    public static let hasName = "has_name"
    public static let hasAlias = "has_alias"
    public static let bornOn = "born_on"
    public static let diedOn = "died_on"
    public static let educatedAt = "educated_at"
    public static let completedDegree = "completed_degree"
    public static let workedFor = "worked_for"
    public static let heldRole = "held_role"
    public static let founded = "founded"
    public static let directed = "directed"
    public static let owned = "owned"
    public static let residedAt = "resided_at"
    public static let locatedAt = "located_at"
    public static let memberOf = "member_of"
    public static let associatedWith = "associated_with"
    public static let communicatedWith = "communicated_with"
    public static let representedBy = "represented_by"
    public static let signed = "signed"
    public static let filed = "filed"
    public static let published = "published"
    public static let granted = "granted"
    public static let paid = "paid"
    public static let received = "received"
    public static let delivered = "delivered"
    public static let approved = "approved"
    public static let rejected = "rejected"
    public static let status = "status"
    public static let assignedTo = "assigned_to"
    public static let responsibleFor = "responsible_for"
    public static let relatedTo = "related_to"

    /// The full neutral registry (order-stable for deterministic iteration).
    public static let registry: [String] = [
        hasName, hasAlias, bornOn, diedOn, educatedAt, completedDegree, workedFor,
        heldRole, founded, directed, owned, residedAt, locatedAt, memberOf,
        associatedWith, communicatedWith, representedBy, signed, filed, published,
        granted, paid, received, delivered, approved, rejected, status, assignedTo,
        responsibleFor, relatedTo
    ]
    public static let registrySet = Set(registry)

    /// Normalise a free-form predicate to the registry form (lowercase, spaces→_).
    public static func normalize(_ raw: String) -> String {
        raw.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "_")
    }
}
