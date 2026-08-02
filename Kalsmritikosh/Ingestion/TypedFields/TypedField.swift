//
//  TypedField.swift
//  Kalsmritikosh
//
//  MMI-FINAL — a deterministic, source-backed typed field extracted from an ALREADY-ACCEPTED
//  EvidenceBlock. It is NOT a confirmed Claim: it is a located extraction (exact block +
//  source version + locator) carrying a confidence band. Conflicting values are preserved,
//  never silently resolved. Typed fields are the accepted producer for the USF-004 typedFields
//  content surface and the typedFieldExtraction readiness dimension.
//

import Foundation

/// The closed (but forward-tolerant) set of typed identity/document fields. An unknown
/// persisted value decodes to `.other` so future producers never break older readers.
public nonisolated enum TypedFieldType: String, Sendable, Codable, CaseIterable, Hashable {
    case personName
    case organizationName
    case documentNumber
    case dateOfBirth
    case issueDate
    case expiryDate
    case address
    case email
    case phone
    case amount
    case currency
    case invoiceNumber
    case referenceNumber
    case accountIdentifier
    case taxIdentifier
    case other

    /// Decode a stored value, tolerating unknown types (→ `.other`).
    public static func from(rawValue: String) -> TypedFieldType {
        TypedFieldType(rawValue: rawValue) ?? .other
    }

    /// Fields whose value is inherently sensitive (identity/financial) — the UI may mask them
    /// in Simple mode; the value still obeys the existing SensitiveScope authority.
    public var isSensitiveByNature: Bool {
        switch self {
        case .dateOfBirth, .accountIdentifier, .taxIdentifier, .documentNumber: return true
        default: return false
        }
    }
}

/// One extracted typed field with FULL provenance back to its exact source region.
public nonisolated struct TypedField: Sendable, Hashable, Identifiable, Codable {
    public let id: UUID
    public let sourceVersionID: UUID
    public let evidenceBlockID: UUID
    public let fieldType: TypedFieldType
    /// The verbatim matched text.
    public let rawValue: String
    /// The canonicalized value (trimmed / format-normalized) used for equality + conflict checks.
    public let normalizedValue: String
    public let confidence: Double
    /// How the underlying block's text was obtained (native/ocr/vision/…). OCR/vision → lower trust.
    public let extractionMethod: ExtractionMethod
    /// The exact locator (page / bounding box / character range) into the source version.
    public let locator: SourceLocator
    /// The block's OCR confidence, when the block came from OCR.
    public let ocrConfidence: Double?
    /// [x, y, w, h] in page/image units, when the block carried a region.
    public let boundingBox: [Double]?
    public let producerID: String
    public let producerVersion: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        sourceVersionID: UUID,
        evidenceBlockID: UUID,
        fieldType: TypedFieldType,
        rawValue: String,
        normalizedValue: String,
        confidence: Double,
        extractionMethod: ExtractionMethod,
        locator: SourceLocator,
        ocrConfidence: Double? = nil,
        boundingBox: [Double]? = nil,
        producerID: String,
        producerVersion: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sourceVersionID = sourceVersionID
        self.evidenceBlockID = evidenceBlockID
        self.fieldType = fieldType
        self.rawValue = rawValue
        self.normalizedValue = normalizedValue
        self.confidence = max(0, min(1, confidence))
        self.extractionMethod = extractionMethod
        self.locator = locator
        self.ocrConfidence = ocrConfidence
        self.boundingBox = boundingBox
        self.producerID = producerID
        self.producerVersion = producerVersion
        self.createdAt = createdAt
    }
}

/// A disagreement between two or more located values of the SAME field type. The system NEVER
/// silently picks a winner — the conflict is surfaced with all candidates + their regions.
public nonisolated struct TypedFieldConflict: Sendable, Hashable {
    public let fieldType: TypedFieldType
    /// The distinct candidate values, each backed by its own located TypedField(s).
    public let candidates: [TypedField]

    public init(fieldType: TypedFieldType, candidates: [TypedField]) {
        self.fieldType = fieldType
        self.candidates = candidates
    }

    /// The distinct normalized values in conflict.
    public var distinctValues: [String] {
        var seen = Set<String>(); var out: [String] = []
        for c in candidates where seen.insert(c.normalizedValue).inserted { out.append(c.normalizedValue) }
        return out
    }
}
