//
//  Event.swift
//  Atlas chronica memora
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
        self.attributes = attributes
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
