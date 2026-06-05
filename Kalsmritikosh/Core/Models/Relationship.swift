//
//  Relationship.swift
//  Kalsmritikosh
//
//  Edges of the knowledge graph. Stored separately so the Graph layer
//  can do traversal queries without touching entity / event tables.
//

import Foundation

public struct Relationship: Codable, Identifiable, Hashable, Sendable {
    public typealias ID = UUID

    public let id: ID
    public let kind: Kind
    public let fromEntityID: Entity.ID
    public let toEntityID: Entity.ID
    public let viaEventID: Event.ID?
    public let sourceObjectID: KnowledgeObject.ID
    public let confidence: Confidence
    public let attributes: [String: AnyCodable]

    public init(
        id: ID = UUID(),
        kind: Kind,
        fromEntityID: Entity.ID,
        toEntityID: Entity.ID,
        viaEventID: Event.ID? = nil,
        sourceObjectID: KnowledgeObject.ID,
        confidence: Confidence = .medium,
        attributes: [String: AnyCodable] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.fromEntityID = fromEntityID
        self.toEntityID = toEntityID
        self.viaEventID = viaEventID
        self.sourceObjectID = sourceObjectID
        self.confidence = confidence
        self.attributes = attributes
    }

    public enum Kind: String, Codable, CaseIterable, Sendable {
        case worksWith
        case sent
        case received
        case mentioned
        case paid
        case contracted
        case partOf
        case owns
        case manages
        case reportsTo
        case other
    }
}
