//
//  ChunksRepository.swift
//  Kalsmritikosh
//

import Foundation

public actor ChunksRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func insertBatch(_ chunks: [Chunk]) async throws {
        for chunk in chunks {
            try await database.exec("""
            INSERT INTO chunks (id, object_id, ordinal, text, char_start, char_end, page_number, created_at, context_prefix, context_prefix_source, admit_embedding, evidence_block_id, block_kind)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, [
                .uuid(chunk.id),
                .uuid(chunk.objectID),
                .integer(Int64(chunk.ordinal)),
                .text(chunk.text),
                .integer(Int64(chunk.characterRange.lowerBound)),
                .integer(Int64(chunk.characterRange.upperBound)),
                chunk.pageNumber.map { .integer(Int64($0)) } ?? .null,
                .date(chunk.createdAt),
                chunk.contextPrefix.map { .text($0) } ?? .null,
                chunk.contextPrefixSource.map { .text($0) } ?? .null,
                .integer(chunk.admitEmbedding ? 1 : 0),
                chunk.evidenceBlockID.map { .uuid($0) } ?? .null,
                chunk.blockKind.map { .text($0) } ?? .null
            ])
        }
    }

    /// G2-3 backfill — return chunks whose `context_prefix` is NULL
    /// AND that belong to a multi-chunk KO (single-chunk KOs are
    /// their own context — no prefix needed). Used by
    /// `ContextPrefixBackfiller` to fill in rows that timed out on
    /// the LLM during ingest.
    public func findChunksMissingContextPrefix(limit: Int = 100) async throws -> [Chunk] {
        let rows = try await database.query("""
        SELECT id, object_id, ordinal, text, char_start, char_end, page_number, created_at, context_prefix, context_prefix_source
        FROM chunks
        WHERE context_prefix IS NULL
          AND object_id IN (
            SELECT object_id FROM chunks GROUP BY object_id HAVING COUNT(*) >= 2
          )
        ORDER BY object_id ASC, ordinal ASC
        LIMIT ?;
        """, [.integer(Int64(limit))])
        return rows.compactMap(decode)
    }

    /// PERF.1 — chunks that have no vector yet (the embedding-pending set).
    /// A LEFT JOIN against `vectors` makes this the resumable work queue for the
    /// background embedding backfill: it survives restarts (a chunk with no
    /// vector is always re-found), so deferred embeddings can never be
    /// permanently lost — only delayed.
    /// v54 — model-aware: a chunk is "missing a vector" when it has no row in
    /// `chunk_embeddings` for the ACTIVE model. So when a second (quality) model
    /// is wired, its index backfills independently without disturbing the Apple
    /// index. `modelID` must match the active vector store's `embeddingModelID`.
    public func findChunksMissingVector(limit: Int = 128, modelID: String = "apple.nl.v1") async throws -> [Chunk] {
        let rows = try await database.query("""
        SELECT c.id, c.object_id, c.ordinal, c.text, c.char_start, c.char_end, c.page_number, c.created_at, c.context_prefix, c.context_prefix_source
        FROM chunks c
        LEFT JOIN chunk_embeddings ce ON ce.chunk_id = c.id AND ce.model_id = ?
        WHERE ce.chunk_id IS NULL
          AND c.admit_embedding = 1
        ORDER BY c.created_at DESC
        LIMIT ?;
        """, [.text(modelID), .integer(Int64(limit))])
        return rows.compactMap(decode)
    }

    /// PERF.1 — count of chunks awaiting embedding for the active model.
    public func countChunksMissingVector(modelID: String = "apple.nl.v1") async throws -> Int {
        let rows = try await database.query("""
        SELECT COUNT(*) FROM chunks c
        LEFT JOIN chunk_embeddings ce ON ce.chunk_id = c.id AND ce.model_id = ?
        WHERE ce.chunk_id IS NULL
          AND c.admit_embedding = 1;
        """, [.text(modelID)])
        return Int(rows.first?.int(0) ?? 0)
    }

    /// G2-3 backfill counter — fast count for the Settings panel to
    /// surface "N chunks awaiting context backfill".
    public func countChunksMissingContextPrefix() async throws -> Int {
        let rows = try await database.query("""
        SELECT COUNT(*) FROM chunks
        WHERE context_prefix IS NULL
          AND object_id IN (
            SELECT object_id FROM chunks GROUP BY object_id HAVING COUNT(*) >= 2
          );
        """, [])
        return Int(rows.first?.int(0) ?? 0)
    }

    /// G2-3 — update only the context_prefix + source for one chunk.
    /// Used when the per-chunk context generator runs AFTER insertBatch
    /// (e.g. async backfill) or to overwrite a generator's prior output.
    public func updateContextPrefix(_ chunkID: Chunk.ID, prefix: String?, source: String?) async throws {
        try await database.exec(
            "UPDATE chunks SET context_prefix = ?, context_prefix_source = ? WHERE id = ?;",
            [
                prefix.map { .text($0) } ?? .null,
                source.map { .text($0) } ?? .null,
                .uuid(chunkID)
            ]
        )
    }

    public func count(forObject id: KnowledgeObject.ID) async throws -> Int {
        let rows = try await database.query(
            "SELECT COUNT(*) FROM chunks WHERE object_id = ?;",
            [.uuid(id)]
        )
        return Int(rows.first?.int(0) ?? 0)
    }

    /// All chunks for a KO, in ordinal order. Used by the
    /// SyntheticQuestionsBackfill to re-run the heuristic generator
    /// over chunks ingested before G2 wired the synthetic-question
    /// writer.
    public func findByObjectID(_ id: KnowledgeObject.ID) async throws -> [Chunk] {
        let rows = try await database.query("""
        SELECT id, object_id, ordinal, text, char_start, char_end, page_number, created_at, context_prefix, context_prefix_source
        FROM chunks WHERE object_id = ? ORDER BY ordinal ASC;
        """, [.uuid(id)])
        return rows.compactMap(decode)
    }

    /// G2-QA-PAIRS retrieval helper. Returns the ordinal-0 chunk for
    /// an objectID — used by HybridRetriever when a qa_pair match
    /// hydrates the answer-side KO into a `RetrievedChunk`.
    public func firstChunk(forObjectID id: KnowledgeObject.ID) async throws -> Chunk? {
        let rows = try await database.query("""
        SELECT id, object_id, ordinal, text, char_start, char_end, page_number, created_at, context_prefix, context_prefix_source
        FROM chunks WHERE object_id = ? AND review_status IS NULL ORDER BY ordinal ASC LIMIT 1;
        """, [.uuid(id)])
        return rows.first.flatMap(decode)
    }

    public func findByIDs(_ ids: [Chunk.ID]) async throws -> [Chunk] {
        guard !ids.isEmpty else { return [] }
        var chunks: [Chunk] = []
        for id in ids {
            // Rejected chunks are excluded here too, so a passage a user
            // soft-excluded stops surfacing via vector-hit / synth hydration.
            let rows = try await database.query("""
            SELECT id, object_id, ordinal, text, char_start, char_end, page_number, created_at, context_prefix, context_prefix_source
            FROM chunks WHERE id = ? AND review_status IS NULL LIMIT 1;
            """, [.uuid(id)])
            if let row = rows.first, let chunk = decode(row) {
                chunks.append(chunk)
            }
        }
        return chunks
    }

    public func searchFTS(_ query: String, limit: Int = 50) async throws -> [Chunk] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let rows = try await database.query("""
        SELECT c.id, c.object_id, c.ordinal, c.text, c.char_start, c.char_end, c.page_number, c.created_at
        FROM chunks c
        JOIN chunks_fts ON chunks_fts.rowid = c.rowid
        WHERE chunks_fts.text MATCH ? AND c.review_status IS NULL
        ORDER BY rank
        LIMIT ?;
        """, [.text(query), .integer(Int64(limit))])
        return rows.compactMap(decode)
    }

    /// A deterministic sample of embeddable, non-rejected chunks (ordered by
    /// rowid, so the same DB yields the same sample). Used by the retrieval
    /// self-eval to measure recall@k on the user's OWN data.
    public func sample(limit: Int) async throws -> [Chunk] {
        let rows = try await database.query("""
        SELECT id, object_id, ordinal, text, char_start, char_end, page_number, created_at, context_prefix, context_prefix_source
        FROM chunks
        WHERE review_status IS NULL AND admit_embedding = 1 AND length(text) >= 40
        ORDER BY rowid
        LIMIT ?;
        """, [.integer(Int64(limit))])
        return rows.compactMap(decode)
    }

    // MARK: - Human-in-loop review status (v51)

    /// Soft-exclude ("reject") or restore a chunk. "rejected" excludes it from
    /// FTS, vector-hit hydration, and first-chunk lookups; nil restores it. The
    /// row and text are never deleted. Distinct from `admit_embedding` (the
    /// ingest-time noise gate) — this is an explicit human decision.
    public func setReviewStatus(_ id: Chunk.ID, _ status: String?) async throws {
        try await database.exec(
            "UPDATE chunks SET review_status = ? WHERE id = ?;",
            [status.map { .text($0) } ?? .null, .uuid(id)]
        )
    }

    private func decode(_ row: SQLRow) -> Chunk? {
        guard
            let id = row.uuid(0),
            let objectID = row.uuid(1),
            let ordinal = row.int(2),
            let text = row.string(3),
            let start = row.int(4),
            let end = row.int(5),
            let created = row.date(7)
        else { return nil }
        return Chunk(
            id: id,
            objectID: objectID,
            ordinal: Int(ordinal),
            text: text,
            characterRange: Int(start)..<Int(end),
            pageNumber: row.int(6).map(Int.init),
            createdAt: created,
            contextPrefix: row.string(8),
            contextPrefixSource: row.string(9)
        )
    }
}
