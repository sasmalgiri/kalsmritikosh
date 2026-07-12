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
    /// A5.3 — `blocks` are the source's structural EvidenceBlocks (empty when
    /// the structural layer isn't wired). When present, the extractor links each
    /// event to the specific block(s) that evidence it, so events carry
    /// event-specific source provenance rather than the whole document.
    func extractEvents(
        from object: KnowledgeObject,
        chunks: [Chunk],
        entities: [Entity],
        blocks: [EvidenceBlock]
    ) async throws -> [Event]
}

public extension EventExtractor {
    /// Backward-compatible overload for call sites that have no structural
    /// blocks (smoke tests, legacy paths). Forwards with an empty block set.
    func extractEvents(
        from object: KnowledgeObject,
        chunks: [Chunk],
        entities: [Entity]
    ) async throws -> [Event] {
        try await extractEvents(from: object, chunks: chunks, entities: entities, blocks: [])
    }
}

public protocol RelationshipExtractor: Sendable {
    func extractRelationships(
        from object: KnowledgeObject,
        entities: [Entity],
        events: [Event]
    ) async throws -> [Relationship]
}
