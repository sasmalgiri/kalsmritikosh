//
//  Event.swift
//  Kalsmritikosh
//
//  Events are the verb layer. They drive the Timeline Engine — the
//  product's core moat. Each event ties a date to a set of entity
//  participants and an originating KnowledgeObject.
//

import Foundation

public struct Event: Codable, Identifiable, Hashable, Sendable {
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

    public init(
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
        attributes: [String: AnyCodable] = [:]
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
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, date, endDate, title, summary, entityIDs,
             sourceObjectID, sourceRange, confidence, dateConfidence, attributes
    }

    public init(from decoder: Decoder) throws {
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
