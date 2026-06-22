//
//  KnowledgeObject.swift
//  Kalsmritikosh
//
//  The normalized unit every downstream system works with. After ingestion,
//  no layer of the app should ever touch raw files again — they work with
//  KnowledgeObjects.
//
//  Schema locked per Phase 4 instructions:
//      id, sourceFile, sourceType, content, metadata, entities, events,
//      relationships, summaries, confidence.
//

import Foundation

public struct KnowledgeObject: Codable, Identifiable, Hashable, Sendable {
    public typealias ID = UUID

    public let id: ID
    public let sourceFile: URL
    public let sourceType: SourceType
    public let content: String
    public let metadata: [String: AnyCodable]
    public let entities: [Entity.ID]
    public let events: [Event.ID]
    public let relationships: [Relationship.ID]
    public let summaries: [Summary.ID]
    public let confidence: Confidence
    public let createdAt: Date
    public let updatedAt: Date

    public nonisolated init(
        id: ID = UUID(),
        sourceFile: URL,
        sourceType: SourceType,
        content: String,
        metadata: [String: AnyCodable] = [:],
        entities: [Entity.ID] = [],
        events: [Event.ID] = [],
        relationships: [Relationship.ID] = [],
        summaries: [Summary.ID] = [],
        confidence: Confidence = .high,
        createdAt: Date = .init(),
        updatedAt: Date = .init()
    ) {
        self.id = id
        self.sourceFile = sourceFile
        self.sourceType = sourceType
        self.content = content
        self.metadata = metadata
        self.entities = entities
        self.events = events
        self.relationships = relationships
        self.summaries = summaries
        self.confidence = confidence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
