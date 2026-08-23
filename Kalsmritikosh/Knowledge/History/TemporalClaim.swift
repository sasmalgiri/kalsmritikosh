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
public nonisolated struct TemporalValue: Sendable, Codable, Hashable {
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
public nonisolated enum ClaimValue: Sendable, Codable, Hashable {
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

    // MARK: - Backward-compatible Codable (S0.5 item 2 C)

    private enum CodingKeys: String, CodingKey {
        case id, subjectID, predicate, object, validFrom, validTo, observedAt
        case assessment, status, confidence
        case sourceObjectIDs, sourceBlockIDs, assertionIDs, genericFactIDs
        case extractorID, extractorVersion, createdAt
    }

    public nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.subjectID = try c.decode(UUID.self, forKey: .subjectID)
        self.predicate = try c.decode(String.self, forKey: .predicate)
        self.object = try c.decode(ClaimValue.self, forKey: .object)
        self.validFrom = try c.decodeIfPresent(TemporalValue.self, forKey: .validFrom)
        self.validTo = try c.decodeIfPresent(TemporalValue.self, forKey: .validTo)
        self.observedAt = try c.decodeIfPresent(TemporalValue.self, forKey: .observedAt)
        self.confidence = try c.decode(Double.self, forKey: .confidence)
        self.sourceObjectIDs = try c.decodeIfPresent([UUID].self, forKey: .sourceObjectIDs) ?? []
        self.sourceBlockIDs = try c.decodeIfPresent([UUID].self, forKey: .sourceBlockIDs) ?? []
        self.assertionIDs = try c.decodeIfPresent([UUID].self, forKey: .assertionIDs) ?? []
        self.genericFactIDs = try c.decodeIfPresent([UUID].self, forKey: .genericFactIDs) ?? []
        self.extractorID = try c.decode(String.self, forKey: .extractorID)
        self.extractorVersion = try c.decode(String.self, forKey: .extractorVersion)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        if let a = try? c.decode(EvidenceAssessment.self, forKey: .assessment) {
            self.assessment = a
        } else if let s = try c.decodeIfPresent(EvidenceStatus.self, forKey: .status) {
            self.assessment = LegacyEvidenceStatusAdapter.decode(s)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "TemporalClaim: neither `assessment` nor legacy `status` present"))
        }
    }

    public nonisolated func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(subjectID, forKey: .subjectID)
        try c.encode(predicate, forKey: .predicate); try c.encode(object, forKey: .object)
        try c.encodeIfPresent(validFrom, forKey: .validFrom)
        try c.encodeIfPresent(validTo, forKey: .validTo)
        try c.encodeIfPresent(observedAt, forKey: .observedAt)
        try c.encode(assessment, forKey: .assessment)
        try c.encode(LegacyEvidenceStatusAdapter.encode(assessment), forKey: .status)   // compatibility
        try c.encode(confidence, forKey: .confidence)
        try c.encode(sourceObjectIDs, forKey: .sourceObjectIDs)
        try c.encode(sourceBlockIDs, forKey: .sourceBlockIDs)
        try c.encode(assertionIDs, forKey: .assertionIDs)
        try c.encode(genericFactIDs, forKey: .genericFactIDs)
        try c.encode(extractorID, forKey: .extractorID)
        try c.encode(extractorVersion, forKey: .extractorVersion)
        try c.encode(createdAt, forKey: .createdAt)
    }
}

/// HIST-024 — the domain-NEUTRAL predicate registry. Domain packs may add more, but
/// every predicate maps to this same temporal model. Kept as canonical strings so
/// the store and projector agree.
public nonisolated enum HistoryPredicate {
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
