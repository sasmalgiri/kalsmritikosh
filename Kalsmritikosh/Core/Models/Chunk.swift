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
    /// Stage 1 ingestion quality gate — whether this chunk is admitted to the
    /// semantic vector index (see ChunkAdmissionGate). `false` for blanks,
    /// tiny fragments, bare page numbers, and lone navigation tokens: those are
    /// still STORED and FTS-/citation-searchable, just not embedded. Defaults
    /// true so pre-gate rows and every other code path treat chunks as
    /// embeddable unless explicitly gated.
    public let admitEmbedding: Bool
    /// v54 evidence-first chunking — the typed EvidenceBlock this chunk was
    /// derived from (exact block lineage), or nil for legacy chunks and chunks
    /// derived from flattened KnowledgeObject.content (formats with no
    /// structural parser). Lets retrieval prefer block-backed units and cite an
    /// exact block/locator.
    public let evidenceBlockID: UUID?
    /// The `EvidenceBlockKind.rawValue` of the source block (e.g. "paragraph",
    /// "tableCell", "emailBody"), or nil when not block-derived. A retrieval
    /// authority + display signal.
    public let blockKind: String?
    /// USF-002.1 — the EXACT source version this chunk belongs to (a retrieval projection field,
    /// not a source authority). New production chunks carry it so indexing readiness can be
    /// reconstructed per exact version; nil for legacy chunks whose ownership was unprovable.
    public let sourceVersionID: UUID?
    /// S2-U1 (D-17 Part B) — structural salience [0,1]: how strongly this
    /// chunk's position says "this is what the document is about" (subject
    /// line > quoted tail). Computed from SalienceTable at ingest; 0.6 is the
    /// neutral prior (also the v124 column default for legacy rows).
    /// Presentation-and-ranking only — never drops anything.
    public let salience: Double

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
        contextPrefixSource: String? = nil,
        admitEmbedding: Bool = true,
        evidenceBlockID: UUID? = nil,
        blockKind: String? = nil,
        sourceVersionID: UUID? = nil,
        salience: Double = SalienceTable.neutral
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
        self.admitEmbedding = admitEmbedding
        self.evidenceBlockID = evidenceBlockID
        self.blockKind = blockKind
        self.sourceVersionID = sourceVersionID
        self.salience = salience
    }

    /// Returns a copy with the structural salience set (S2-U1). Used by
    /// IngestCoordinator once the document class is known.
    public nonisolated func withSalience(_ s: Double) -> Chunk {
        Chunk(id: id, objectID: objectID, ordinal: ordinal, text: text, characterRange: characterRange,
              pageNumber: pageNumber, createdAt: createdAt, contextPrefix: contextPrefix,
              contextPrefixSource: contextPrefixSource, admitEmbedding: admitEmbedding,
              evidenceBlockID: evidenceBlockID, blockKind: blockKind, sourceVersionID: sourceVersionID,
              salience: s)
    }

    /// Returns a copy with the exact source-version id set (USF-002.1). Used by IngestCoordinator
    /// so every persisted chunk carries the version it belongs to.
    public nonisolated func withSourceVersion(_ versionID: UUID?) -> Chunk {
        Chunk(id: id, objectID: objectID, ordinal: ordinal, text: text, characterRange: characterRange,
              pageNumber: pageNumber, createdAt: createdAt, contextPrefix: contextPrefix,
              contextPrefixSource: contextPrefixSource, admitEmbedding: admitEmbedding,
              evidenceBlockID: evidenceBlockID, blockKind: blockKind, sourceVersionID: versionID,
              salience: salience)
    }

    /// Returns a new Chunk identical to `self` except `contextPrefix`
    /// + `contextPrefixSource` are replaced. Used by IngestCoordinator
    /// after the per-chunk context generator runs. Preserves `admitEmbedding`.
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
            contextPrefixSource: source,
            admitEmbedding: admitEmbedding,
            evidenceBlockID: evidenceBlockID,
            blockKind: blockKind,
            sourceVersionID: sourceVersionID,
            salience: salience
        )
    }

    /// Returns a copy with the embedding-admission flag set (Stage 1 gate).
    public nonisolated func withAdmitEmbedding(_ admit: Bool) -> Chunk {
        Chunk(
            id: id,
            objectID: objectID,
            ordinal: ordinal,
            text: text,
            characterRange: characterRange,
            pageNumber: pageNumber,
            createdAt: createdAt,
            contextPrefix: contextPrefix,
            contextPrefixSource: contextPrefixSource,
            admitEmbedding: admit,
            evidenceBlockID: evidenceBlockID,
            blockKind: blockKind,
            sourceVersionID: sourceVersionID,
            salience: salience
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, objectID, ordinal, text
        case characterRangeLower, characterRangeUpper
        case pageNumber, createdAt, contextPrefix, contextPrefixSource, admitEmbedding
        case evidenceBlockID, blockKind, sourceVersionID, salience
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
        self.admitEmbedding = try c.decodeIfPresent(Bool.self, forKey: .admitEmbedding) ?? true
        self.evidenceBlockID = try c.decodeIfPresent(UUID.self, forKey: .evidenceBlockID)
        self.blockKind = try c.decodeIfPresent(String.self, forKey: .blockKind)
        self.sourceVersionID = try c.decodeIfPresent(UUID.self, forKey: .sourceVersionID)
        self.salience = try c.decodeIfPresent(Double.self, forKey: .salience) ?? SalienceTable.neutral
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
        try c.encode(admitEmbedding, forKey: .admitEmbedding)
        try c.encodeIfPresent(evidenceBlockID, forKey: .evidenceBlockID)
        try c.encodeIfPresent(blockKind, forKey: .blockKind)
        try c.encodeIfPresent(sourceVersionID, forKey: .sourceVersionID)
        try c.encode(salience, forKey: .salience)
    }
}
