//
//  Chunk.swift
//  Kalsmritikosh
//
//  Bounded slice of a KnowledgeObject's content, sized to fit through
//  embeddings and LLM context windows. Chunks are the granularity at
//  which we cite evidence and store vectors.
//
//  G2-SWIFT6 — Codable conformance is hand-written so the model can
//  carry a `Range<Int>` field without relying on the retroactive Range
//  conformance that used to live in SourceRange.swift. See the note
//  in SourceRange.swift for the rationale.
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
    /// G2-3 contextual retrieval — one-sentence summary of this chunk's
    /// role in the parent document. Used ONLY at embed time; never
    /// shown to the user, never indexed in FTS. Nil for chunks whose
    /// whole content IS the document and for chunks ingested before
    /// schema v16.
    public let contextPrefix: String?
    /// G2-3 provenance — which generator produced `contextPrefix`.
    /// One of `ContextPrefixResult.sourceLLM` /
    /// `ContextPrefixResult.sourceHeuristic` /
    /// `ContextPrefixResult.sourceHeuristicFallback`, or nil when no
    /// prefix was generated.
    public let contextPrefixSource: String?

    // G2-SWIFT6 — nonisolated so repository actors can construct Chunk
    // rows in synchronous context. Value type holding only Sendable
    // fields; main-actor isolation isn't needed.
    public nonisolated init(
        id: ID = UUID(),
        objectID: KnowledgeObject.ID,
        ordinal: Int,
        text: String,
        characterRange: Range<Int>,
        pageNumber: Int? = nil,
        createdAt: Date = .init(),
        contextPrefix: String? = nil,
        contextPrefixSource: String? = nil
    ) {
        self.id = id
        self.objectID = objectID
        self.ordinal = ordinal
        self.text = text
        self.characterRange = characterRange
        self.pageNumber = pageNumber
        self.createdAt = createdAt
        self.contextPrefix = contextPrefix
        self.contextPrefixSource = contextPrefixSource
    }

    /// Returns a new Chunk identical to `self` except `contextPrefix`
    /// + `contextPrefixSource` are replaced. Used by IngestCoordinator
    /// after the per-chunk context generator runs.
    public nonisolated func withContextPrefix(_ prefix: String?, source: String?) -> Chunk {
        Chunk(
            id: id,
            objectID: objectID,
            ordinal: ordinal,
            text: text,
            characterRange: characterRange,
            pageNumber: pageNumber,
            createdAt: createdAt,
            contextPrefix: prefix,
            contextPrefixSource: source
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, objectID, ordinal, text
        case characterRangeLower, characterRangeUpper
        case pageNumber, createdAt, contextPrefix, contextPrefixSource
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.objectID = try c.decode(UUID.self, forKey: .objectID)
        self.ordinal = try c.decode(Int.self, forKey: .ordinal)
        self.text = try c.decode(String.self, forKey: .text)
        let lower = try c.decode(Int.self, forKey: .characterRangeLower)
        let upper = try c.decode(Int.self, forKey: .characterRangeUpper)
        self.characterRange = lower..<max(lower, upper)
        self.pageNumber = try c.decodeIfPresent(Int.self, forKey: .pageNumber)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.contextPrefix = try c.decodeIfPresent(String.self, forKey: .contextPrefix)
        self.contextPrefixSource = try c.decodeIfPresent(String.self, forKey: .contextPrefixSource)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(objectID, forKey: .objectID)
        try c.encode(ordinal, forKey: .ordinal)
        try c.encode(text, forKey: .text)
        try c.encode(characterRange.lowerBound, forKey: .characterRangeLower)
        try c.encode(characterRange.upperBound, forKey: .characterRangeUpper)
        try c.encodeIfPresent(pageNumber, forKey: .pageNumber)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(contextPrefix, forKey: .contextPrefix)
        try c.encodeIfPresent(contextPrefixSource, forKey: .contextPrefixSource)
    }
}
