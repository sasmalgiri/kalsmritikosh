//
//  GenericFact.swift
//  Kalsmritikosh
//
//  SEM-003 — the domain-neutral fact layer that delivers the "any subject" contract
//  WITHOUT hard-coding every profession or topic. A GenericFact is a single
//  subject–field–value assertion carried by specific evidence blocks, with an evidence
//  status from the locked vocabulary. Domain packs (SEM-004…008) may refine extraction
//  for known fields, but their ABSENCE must never block structural search, cited answers
//  or honest unsupported-field reporting.
//
//  Never authoritative on its own: a GenericFact records WHO asserted WHAT with WHICH
//  evidence — it does not establish truth. Model-produced values are excluded here;
//  facts come from deterministic extraction or source assertions.
//

import Foundation

/// The trust classification of a fact — one vocabulary across storage/UI/exports.
public enum EvidenceStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case directlyObserved      = "DIRECTLY_OBSERVED"
    case sourceAsserted        = "SOURCE_ASSERTED"
    case deterministicallyDerived = "DETERMINISTICALLY_DERIVED"
    case inferred              = "INFERRED"
    case contradicted          = "CONTRADICTED"
    case unsupported           = "UNSUPPORTED"
    case missingEvidence       = "MISSING_EVIDENCE"
    case humanConfirmed        = "HUMAN_CONFIRMED"
    case humanCorrected        = "HUMAN_CORRECTED"
    case humanRejected         = "HUMAN_REJECTED"

    /// May this status back a MATERIAL claim in a final answer?
    public nonisolated var isAssertable: Bool {
        switch self {
        case .directlyObserved, .sourceAsserted, .deterministicallyDerived,
             .humanConfirmed, .humanCorrected:
            return true
        case .inferred, .contradicted, .unsupported, .missingEvidence, .humanRejected:
            return false
        }
    }
}

/// A single subject–field–value assertion grounded in evidence blocks.
public struct GenericFact: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    /// The entity/thing this fact is about (canonical entity id when known).
    public let subjectID: UUID?
    public let subjectLabel: String
    /// The field name — free-form but normalized (e.g. "employer", "amount", "date").
    public let field: String
    public let value: String
    /// Optional unit / currency / precision qualifier (e.g. "INR", "year").
    public let unit: String?
    /// The CANONICAL trust classification — the five separated dimensions (S0.5 item 2 C2).
    public let assessment: EvidenceAssessment
    public let confidence: Double
    /// Evidence blocks that support this fact (the claim–evidence contract).
    public let sourceBlockIDs: [UUID]

    /// Deprecated compatibility shim — derived from `assessment`. Kept so existing readers
    /// and the repository's legacy `status` column keep working during migration.
    @available(*, deprecated, message: "Use assessment (+ AssertabilityPolicy)")
    public var status: EvidenceStatus { LegacyEvidenceStatusAdapter.encode(assessment) }

    /// Canonical initializer.
    public nonisolated init(
        id: UUID = UUID(),
        subjectID: UUID? = nil,
        subjectLabel: String,
        field: String,
        value: String,
        unit: String? = nil,
        assessment: EvidenceAssessment,
        confidence: Double,
        sourceBlockIDs: [UUID]
    ) {
        self.id = id
        self.subjectID = subjectID
        self.subjectLabel = subjectLabel
        self.field = FactSchemaRegistry.normalizeField(field)
        self.value = value
        self.unit = unit
        self.assessment = assessment
        self.confidence = confidence
        self.sourceBlockIDs = sourceBlockIDs
    }

    /// Legacy initializer — decodes a single `EvidenceStatus` into the separated
    /// dimensions via the adapter. Retained so existing call sites compile unchanged.
    public nonisolated init(
        id: UUID = UUID(),
        subjectID: UUID? = nil,
        subjectLabel: String,
        field: String,
        value: String,
        unit: String? = nil,
        status: EvidenceStatus,
        confidence: Double,
        sourceBlockIDs: [UUID]
    ) {
        self.init(id: id, subjectID: subjectID, subjectLabel: subjectLabel, field: field,
                  value: value, unit: unit, assessment: LegacyEvidenceStatusAdapter.decode(status),
                  confidence: confidence, sourceBlockIDs: sourceBlockIDs)
    }

    /// A material fact may appear in a final answer only if its assessment is assertable
    /// AND it carries at least one supporting evidence block. (Kept for existing callers;
    /// the full decision is AssertabilityPolicy via the shared context builder.)
    public var isMaterialAndSupported: Bool {
        LegacyEvidenceStatusAdapter.encode(assessment).isAssertable && !sourceBlockIDs.isEmpty
    }
}

/// Maps free-form field names to a canonical field + expected value shape. Open — an
/// unknown field is represented as `.text`, never dropped ("any subject").
public enum FactSchemaRegistry {

    public enum ValueShape: String, Codable, Sendable {
        case text, number, money, date, duration, boolean, identifier, email, phone, url
    }

    /// Canonical field aliases → canonical name. Extend via domain packs, not by
    /// hard-coding professions here.
    nonisolated static let aliases: [String: String] = [
        "employer": "employer", "company": "employer", "organisation": "employer",
        "organization": "employer", "workplace": "employer",
        "amount": "amount", "sum": "amount", "total": "amount", "fee": "amount",
        "payee": "counterparty", "recipient": "counterparty", "paid to": "counterparty",
        "date": "date", "on": "date", "when": "date",
        "designation": "role", "position": "role", "title": "role", "job title": "role",
        "status": "status", "email": "email", "phone": "phone", "location": "location"
    ]

    /// Expected value shape for a canonical field (best-effort; defaults to text).
    nonisolated static let shapes: [String: ValueShape] = [
        "amount": .money, "date": .date, "employer": .text, "role": .text,
        "counterparty": .text, "status": .text, "email": .email, "phone": .phone,
        "location": .text
    ]

    public nonisolated static func normalizeField(_ raw: String) -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return aliases[key] ?? key
    }

    public nonisolated static func expectedShape(of field: String) -> ValueShape {
        shapes[normalizeField(field)] ?? .text
    }
}
