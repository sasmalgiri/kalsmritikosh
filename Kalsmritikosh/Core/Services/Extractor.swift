//
//  Extractor.swift
//  Kalsmritikosh
//
//  Two-layer extraction: entities (nouns) and events (verbs). Both
//  produce typed values plus confidence; both can be implemented by
//  deterministic rules, NaturalLanguage, or an LLM via ModelRegistry.
//

import Foundation

public protocol EntityExtractor: Sendable {
    func extractEntities(
        from object: KnowledgeObject,
        chunks: [Chunk]
    ) async throws -> [Entity]
}

public protocol EventExtractor: Sendable {
    func extractEvents(
        from object: KnowledgeObject,
        chunks: [Chunk],
        entities: [Entity]
    ) async throws -> [Event]
}

public protocol RelationshipExtractor: Sendable {
    func extractRelationships(
        from object: KnowledgeObject,
        entities: [Entity],
        events: [Event]
    ) async throws -> [Relationship]
}
