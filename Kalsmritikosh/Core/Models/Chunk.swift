//
//  Chunk.swift
//  Kalsmritikosh
//
//  Bounded slice of a KnowledgeObject's content, sized to fit through
//  embeddings and LLM context windows. Chunks are the granularity at
//  which we cite evidence and store vectors.
//

import Foundation

public struct Chunk: Codable, Identifiable, Hashable, Sendable {
    public typealias ID = UUID

    public let id: ID
    public let objectID: KnowledgeObject.ID
    public let ordinal: Int
    public let text: String
    public let characterRange: Range<Int>
    public let pageNumber: Int?
    public let createdAt: Date

    public init(
        id: ID = UUID(),
        objectID: KnowledgeObject.ID,
        ordinal: Int,
        text: String,
        characterRange: Range<Int>,
        pageNumber: Int? = nil,
        createdAt: Date = .init()
    ) {
        self.id = id
        self.objectID = objectID
        self.ordinal = ordinal
        self.text = text
        self.characterRange = characterRange
        self.pageNumber = pageNumber
        self.createdAt = createdAt
    }
}
