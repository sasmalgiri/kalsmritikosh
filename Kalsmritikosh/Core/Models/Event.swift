//
//  Event.swift
//  Kalsmritikosh
//
//  Events are the verb layer. They drive the Timeline Engine — the
//  product's core moat. Each event ties a date to a set of entity
//  participants and an originating KnowledgeObject.
//

import Foundation

public nonisolated struct Event: Codable, Identifiable, Hashable, Sendable {
    public typealias ID = UUID

    public let id: ID
    public let kind: Kind
    public let date: Date
    public let endDate: Date?
    public let title: String
    public let summary: String?
    public let entityIDs: [Entity.ID]
    public let sourceObjectID: KnowledgeObject.ID
    public let sourceRange: SourceRange?
    public let confidence: Confidence
    /// Confidence in the event's date specifically: 0.95 for email
    /// headers, 0.7 for content-extracted, 0.3 for mtime-fallback,
    /// 0.5 for "unknown source" backfills.
    public let dateConfidence: Double
    public let attributes: [String: AnyCodable]
    /// HISTORY Phase A — set by QualityTierClassifier at extraction
    /// time. Same semantics as Entity.qualityTier.
    public let qualityTier: QualityTier
    /// HISTORY Phase G.1 — temporal precision (Wikidata-style integer
    /// scale, EDTF-inspired). Lets the composer say "in March 2025"
    /// for month-precision events vs "On Mar 14, 2025 at 09:00" for
    /// instants. Email-header events ship as .instant; forensic PDF
    /// events with day-only dates ship as .day; events extracted from
    /// "Q1 2025" or "early 2025" body text downgrade to .quarter /
    /// .year. Critical anti-pattern note from the design research:
    /// NEVER pad a low-precision date to midnight and forget the
    /// precision flag — that's how you get false "08:00 AM" claims
    /// in prose and a permanently corrupted ledger. Precision MUST
    /// travel with the timestamp; never reconstruct from "the time
    /// is exactly midnight, must be month-only".
    public let datePrecision: DatePrecision
    /// T16 — persisted evidentiary status (§13 vocabulary). Set at
    /// extraction/insert time (see EventStatus.derive) and read back by the
    /// Fact Status Matrix. Orthogonal to `kind` (the event TYPE): an
    /// `emailSent` event can be OBSERVED, a `meetingHeld` INFERRED, etc.
    /// CONTRADICTED is relational (derived from the contradictions table),
    /// so it is NOT stored here — FactStatusClassifier overlays it.
    public let status: EventStatus

    public nonisolated init(
        id: ID = UUID(),
        kind: Kind,
        date: Date,
        endDate: Date? = nil,
        title: String,
        summary: String? = nil,
        entityIDs: [Entity.ID] = [],
        sourceObjectID: KnowledgeObject.ID,
        sourceRange: SourceRange? = nil,
        confidence: Confidence = .medium,
        dateConfidence: Double = 0.5,
        attributes: [String: AnyCodable] = [:],
        qualityTier: QualityTier = .t2,
        datePrecision: DatePrecision = .day,
        status: EventStatus = .inferred
    ) {
        self.id = id
        self.kind = kind
        self.date = date
        self.endDate = endDate
        self.title = title
        self.summary = summary
        self.entityIDs = entityIDs
        self.sourceObjectID = sourceObjectID
        self.sourceRange = sourceRange
        self.confidence = confidence
        self.dateConfidence = dateConfidence
        self.attributes = attributes
        self.qualityTier = qualityTier
        self.datePrecision = datePrecision
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, date, endDate, title, summary, entityIDs,
             sourceObjectID, sourceRange, confidence, dateConfidence, attributes,
             qualityTier, datePrecision, status
    }

    public nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.kind = try c.decode(Kind.self, forKey: .kind)
        self.date = try c.decode(Date.self, forKey: .date)
        self.endDate = try c.decodeIfPresent(Date.self, forKey: .endDate)
        self.title = try c.decode(String.self, forKey: .title)
        self.summary = try c.decodeIfPresent(String.self, forKey: .summary)
        self.entityIDs = try c.decodeIfPresent([Entity.ID].self, forKey: .entityIDs) ?? []
        self.sourceObjectID = try c.decode(KnowledgeObject.ID.self, forKey: .sourceObjectID)
        self.sourceRange = try c.decodeIfPresent(SourceRange.self, forKey: .sourceRange)
        self.confidence = try c.decode(Confidence.self, forKey: .confidence)
        self.dateConfidence = try c.decodeIfPresent(Double.self, forKey: .dateConfidence) ?? 0.5
        self.attributes = try c.decodeIfPresent([String: AnyCodable].self, forKey: .attributes) ?? [:]
        self.qualityTier = try c.decodeIfPresent(QualityTier.self, forKey: .qualityTier) ?? .t2
        self.datePrecision = try c.decodeIfPresent(DatePrecision.self, forKey: .datePrecision) ?? .day
        self.status = try c.decodeIfPresent(EventStatus.self, forKey: .status) ?? .inferred
    }

    /// The 10 event kinds from Phase 6 of the roadmap, plus an
    /// `other` escape hatch for events the extractor isn't sure about.
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case emailSent
        case emailReceived
        case contractSigned
        case contractModified
        case invoiceIssued
        case invoicePaid
        case meetingHeld
        case taskAssigned
        case deliveryDelayed
        case deliveryCompleted
        case other
    }
}

/// T16 — the §13 evidentiary-status vocabulary for a reconstructed event.
/// Persisted on `events.status`. CONTRADICTED is derived relationally from
/// the contradictions table (never stored); REVIEWED / REJECTED are written
/// by the human-review workflow (T17).
public nonisolated enum EventStatus: String, Codable, Sendable, CaseIterable, Hashable {
    /// Directly visible in reliable structured evidence (email header, log).
    case observed
    /// Stated by a person/document/source — not automatically true.
    case asserted
    /// Deterministically calculated from evidence (invoice date + 30d).
    case derived
    /// Likely event reconstructed from multiple evidence units.
    case inferred
    /// Conflicts with other evidence (relational — set by the overlay).
    case contradicted
    /// No supporting evidence found.
    case unsupported
    /// A human reviewer accepted/corrected it.
    case reviewed
    /// A human reviewer rejected it (kept, never deleted).
    case rejected

    /// Derive the at-extraction status from an event's own signals. Pure.
    /// OBSERVED for high-confidence structured (T1) facts with a trusted
    /// date; DERIVED when the date is computed (low date-confidence but the
    /// content is solid); UNSUPPORTED at the trust floor; else INFERRED.
    /// CONTRADICTED / REVIEWED / REJECTED are never produced here — they are
    /// applied later (overlay / human review).
    public static func derive(
        qualityTier: QualityTier,
        dateConfidence: Double,
        contentConfidence: Double,
        kind: Event.Kind
    ) -> EventStatus {
        if contentConfidence < 0.33 { return .unsupported }
        if qualityTier == .t1 && contentConfidence >= 0.75 && dateConfidence >= 0.60 {
            return .observed
        }
        if dateConfidence < 0.60 && contentConfidence >= 0.60 {
            return .derived
        }
        return .inferred
    }
}
