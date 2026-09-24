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
    @available(*, deprecated, message: "Use AssertabilityPolicy with a complete AssertabilityContext")
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

/// How a fact's value was recovered when it was not read verbatim from one
/// block. Deliberately a CLOSED set: a new derivation is a new producer, and
/// each one has to state what it reconstructed and at what confidence cost.
public enum FactDerivation: String, Codable, Sendable, Hashable, CaseIterable {
    /// C-4 — the label ended one block and the value began the next (a page
    /// break between a field name and its value). Both blocks are cited.
    case crossBlockAssembled = "CROSS_BLOCK_ASSEMBLED"
    /// The scanner read digits as letters ("7OO321"); the digits were restored.
    /// `rawMatch` keeps the mangled form as the receipt.
    case ocrCorrected = "OCR_CORRECTED"

    /// What the receipt says about this value, in the reader's words.
    public nonisolated var receiptNote: String {
        switch self {
        case .crossBlockAssembled:
            return "assembled across a page break (the label and the value are in different blocks)"
        case .ocrCorrected:
            return "digits restored from an OCR misread (see the raw match for the scanned form)"
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

    // MARK: - V2 capture-group provenance (C-1 + C-10) — the two-layer split
    //
    // `value` is the normalized ATOM (Element Calculus: "555489"); these carry
    // the presentation/corroboration layer. All optional — nil ≡ v0 (pre-V2),
    // which the composer renders via the legacy path (fused value as-is).
    /// The producer version that WROTE this row. nil ≡ 0 ≡ v0 (fused value,
    /// legacy render). v1 = normalized value + `rawMatch` display provenance.
    public let producerVersion: Int?
    /// The full matched text the fact was captured from ("Patent No. 555489")
    /// — display provenance for v1 rows, whose `value` is the bare atom.
    public let rawMatch: String?
    /// C-10 corroboration: distinct DOCUMENTS asserting this value. The merge
    /// maintains the invariant sourceCount == distinct source blocks.
    public let sourceCount: Int?
    /// V2 (C-10) gate-3 provenance: when the cross-field mislabel resolver
    /// reassigned this fact's evidence to its true home field, the origin field
    /// id it was mislabeled under. ADVISORY — never sealed, never gates
    /// surfacing; makes a reassignment auditable on the receipt. nil when the
    /// fact was never reassigned.
    public let reassignedFrom: String?
    /// How this value was obtained when it was NOT read cleanly off one block.
    /// `nil` is the ordinary case: captured verbatim from a single block, exactly
    /// as written.
    ///
    /// WHY THIS EXISTS AS A FIELD AND NOT MERELY AS A LOWER CONFIDENCE. Both
    /// producers that set it recover a value the strict reader could not see —
    /// one joins a label to its value across a page break, the other reads
    /// digits a scanner turned into letters. A confidence number cannot answer
    /// "which values did we repair, and how?", so a reader could not separate a
    /// verbatim capture from a reconstructed one. That is the same
    /// absence-as-verification defect in a different place. ADVISORY: never
    /// sealed, never gates surfacing, but QUERYABLE — a spike in either
    /// derivation is visible as the rule defect it would be.
    public let derivation: FactDerivation?

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
        sourceBlockIDs: [UUID],
        producerVersion: Int? = nil,
        rawMatch: String? = nil,
        sourceCount: Int? = nil,
        reassignedFrom: String? = nil,
        derivation: FactDerivation? = nil
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
        self.producerVersion = producerVersion
        self.rawMatch = rawMatch
        self.sourceCount = sourceCount
        self.reassignedFrom = reassignedFrom
        self.derivation = derivation
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
        sourceBlockIDs: [UUID],
        producerVersion: Int? = nil,
        rawMatch: String? = nil,
        sourceCount: Int? = nil,
        reassignedFrom: String? = nil,
        derivation: FactDerivation? = nil
    ) {
        self.init(id: id, subjectID: subjectID, subjectLabel: subjectLabel, field: field,
                  value: value, unit: unit, assessment: LegacyEvidenceStatusAdapter.decode(status),
                  confidence: confidence, sourceBlockIDs: sourceBlockIDs,
                  producerVersion: producerVersion, rawMatch: rawMatch, sourceCount: sourceCount,
                  reassignedFrom: reassignedFrom, derivation: derivation)
    }

    /// V3 3c — a copy with the canonical subject (identifier anchor) bound.
    /// Pure; keeps every other field (including the fact id and its producer
    /// version) intact. The writer binding sets this so a fact about
    /// "Patent No. 555489" points at the ONE anchor entity, not just a label.
    public nonisolated func withSubjectID(_ subjectID: UUID) -> GenericFact {
        GenericFact(
            id: id, subjectID: subjectID, subjectLabel: subjectLabel, field: field,
            value: value, unit: unit, assessment: assessment, confidence: confidence,
            sourceBlockIDs: sourceBlockIDs, producerVersion: producerVersion,
            rawMatch: rawMatch, sourceCount: sourceCount, reassignedFrom: reassignedFrom,
            derivation: derivation
        )
    }

    /// C-4 — a copy re-grounded on EVERY block the value was assembled from,
    /// at the stated derivation and a reduced confidence. Pure.
    ///
    /// The evidence list is the point: a reader who opens this fact's receipt
    /// must land on both the block holding the label and the block holding the
    /// value, because neither alone supports the claim.
    public nonisolated func assembled(
        from blockIDs: [UUID], derivation: FactDerivation, confidence: Double
    ) -> GenericFact {
        let blocks = Array(Set(blockIDs)).sorted { $0.uuidString < $1.uuidString }
        return GenericFact(
            id: id, subjectID: subjectID, subjectLabel: subjectLabel, field: field,
            value: value, unit: unit, assessment: assessment, confidence: confidence,
            sourceBlockIDs: blocks, producerVersion: producerVersion,
            rawMatch: rawMatch, sourceCount: blocks.count, reassignedFrom: reassignedFrom,
            derivation: derivation
        )
    }

    /// A material fact may appear in a final answer only if its assessment is assertable
    /// AND it carries at least one supporting evidence block.
    @available(*, deprecated, message: "Use ClaimEvaluation + AssertabilityPolicy")
    public var isMaterialAndSupported: Bool {
        let s = LegacyEvidenceStatusAdapter.encode(assessment)
        let assertable: Bool = {
            switch s {
            case .directlyObserved, .sourceAsserted, .deterministicallyDerived,
                 .humanConfirmed, .humanCorrected: return true
            default: return false
            }
        }()
        return assertable && !sourceBlockIDs.isEmpty
    }

    // MARK: - Backward-compatible Codable (S0.5 item 2 C)

    /// Includes BOTH the canonical `assessment` and the legacy `status` key so pre-change
    /// JSON (which had only `status`) still decodes, and new JSON dual-encodes both during
    /// the transition. Decode precedence: valid assessment → valid legacy status → throw.
    private enum CodingKeys: String, CodingKey {
        case id, subjectID, subjectLabel, field, value, unit, assessment, status, confidence, sourceBlockIDs
        case producerVersion, rawMatch, sourceCount, reassignedFrom, derivation
    }

    public nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.subjectID = try c.decodeIfPresent(UUID.self, forKey: .subjectID)
        self.subjectLabel = try c.decode(String.self, forKey: .subjectLabel)
        self.field = try c.decode(String.self, forKey: .field)
        self.value = try c.decode(String.self, forKey: .value)
        self.unit = try c.decodeIfPresent(String.self, forKey: .unit)
        self.confidence = try c.decode(Double.self, forKey: .confidence)
        self.sourceBlockIDs = try c.decodeIfPresent([UUID].self, forKey: .sourceBlockIDs) ?? []
        self.producerVersion = try c.decodeIfPresent(Int.self, forKey: .producerVersion)
        self.rawMatch = try c.decodeIfPresent(String.self, forKey: .rawMatch)
        self.sourceCount = try c.decodeIfPresent(Int.self, forKey: .sourceCount)
        self.reassignedFrom = try c.decodeIfPresent(String.self, forKey: .reassignedFrom)
        self.derivation = try c.decodeIfPresent(FactDerivation.self, forKey: .derivation)
        if let a = try? c.decode(EvidenceAssessment.self, forKey: .assessment) {
            self.assessment = a
        } else if let s = try c.decodeIfPresent(EvidenceStatus.self, forKey: .status) {
            self.assessment = LegacyEvidenceStatusAdapter.decode(s)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "GenericFact: neither `assessment` nor legacy `status` present"))
        }
    }

    public nonisolated func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(subjectID, forKey: .subjectID)
        try c.encode(subjectLabel, forKey: .subjectLabel)
        try c.encode(field, forKey: .field)
        try c.encode(value, forKey: .value)
        try c.encodeIfPresent(unit, forKey: .unit)
        try c.encode(assessment, forKey: .assessment)
        try c.encode(LegacyEvidenceStatusAdapter.encode(assessment), forKey: .status)   // compatibility
        try c.encode(confidence, forKey: .confidence)
        try c.encode(sourceBlockIDs, forKey: .sourceBlockIDs)
        try c.encodeIfPresent(producerVersion, forKey: .producerVersion)
        try c.encodeIfPresent(rawMatch, forKey: .rawMatch)
        try c.encodeIfPresent(sourceCount, forKey: .sourceCount)
        try c.encodeIfPresent(reassignedFrom, forKey: .reassignedFrom)
        try c.encodeIfPresent(derivation, forKey: .derivation)
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
        "status": "status", "email": "email", "phone": "phone", "location": "location",
        "applicant": "applicant", "owner": "applicant", "proprietor": "applicant",
        "patentholder": "applicant", "inventor": "inventor"
    ]

    /// Expected value shape for a canonical field (best-effort; defaults to text).
    /// D-11/D-12 — the domain-pack slot fields carry their real shapes so the
    /// comparator dedupes dates grain-aware and identifiers case-insensitively.
    nonisolated static let shapes: [String: ValueShape] = [
        "amount": .money, "date": .date, "employer": .text, "role": .text,
        "counterparty": .text, "status": .text, "email": .email, "phone": .phone,
        "applicant": .text, "inventor": .text,
        "location": .text,
        "grantdate": .date, "filingdate": .date,
        "patentnumber": .identifier, "applicationnumber": .identifier,
        "publicationnumber": .identifier, "invoicenumber": .identifier,
        "casenumber": .identifier, "pan": .identifier, "gstin": .identifier,
        "doi": .identifier,
        // Persona-coverage starter packs (medical / legal-case / vital /
        // financial / property / identity). Identifiers get display
        // constants in SlotAnswerComposer; dates use the precision canon;
        // money uses renderMoney; text renders its own atom.
        "accountnumber": .identifier, "idnumber": .identifier,
        "visitdate": .date, "hearingdate": .date, "birthdate": .date,
        "deathdate": .date, "marriagedate": .date, "deeddate": .date,
        "issuedate": .date, "expirydate": .date,
        "balance": .money, "consideration": .money,
        // HOST-8e — device identifiers. Declaring them `.identifier` is the whole
        // wiring: IngestCoordinator.bindIdentifierAnchors already resolves an
        // anchor for EVERY identifier-shaped fact, so device facts merge across
        // extractions through the existing gated door with no new call site.
        "deviceserialnumber": .identifier, "imei": .identifier, "meid": .identifier,
        "deviceudid": .identifier, "devicemacaddress": .identifier,
        "computername": .text, "deviceproducttype": .text,
    ]

    public nonisolated static func normalizeField(_ raw: String) -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return aliases[key] ?? key
    }

    public nonisolated static func expectedShape(of field: String) -> ValueShape {
        shapes[normalizeField(field)] ?? .text
    }
}
