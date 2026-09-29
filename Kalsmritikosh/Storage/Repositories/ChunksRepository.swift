//
//  ChunksRepository.swift
//  Kalsmritikosh
//

import Foundation
import os

public actor ChunksRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func insertBatch(_ chunks: [Chunk]) async throws {
        try await insertBatch(chunks, lineage: [:])
    }

    /// L1 — insert chunks and record every block each was assembled from
    /// (`chunk_blocks`). A chunk with no lineage entry records its own
    /// `evidenceBlockID`, so single-block chunks are covered too.
    public func insertBatch(_ chunks: [Chunk], lineage: [Chunk.ID: [UUID]], blocks: [EvidenceBlock] = []) async throws {
        for statement in Self.insertStatements(chunks, lineage: lineage, blocks: blocks) {
            try await database.exec(statement.sql, statement.binds)
        }
    }

    /// The exact statements `insertBatch` runs, so a caller can compose them into its own isolated
    /// savepoint (F28) instead of awaiting this actor across a transaction.
    /// F15/F25 — `blocks` are the evidence blocks the chunks were derived from (their content binds each
    /// chunk's `derivation_digest`); a chunk whose lineage names a block not given here gets no digest
    /// (a later reconciliation records its baseline).
    nonisolated static func insertStatements(_ chunks: [Chunk], lineage: [Chunk.ID: [UUID]] = [:],
                                             blocks: [EvidenceBlock] = []) -> [(sql: String, binds: [SQLValue])] {
        var out: [(sql: String, binds: [SQLValue])] = []
        let content = Dictionary(blocks.map { ($0.id, ChunkDerivation.content(of: $0)) }, uniquingKeysWith: { a, _ in a })
        for chunk in chunks {
            let chunkLineage = lineage[chunk.id] ?? (chunk.evidenceBlockIDs.isEmpty ? chunk.allBlockIDs : chunk.evidenceBlockIDs)
            let digest = ChunkDerivation.digest(text: chunk.text, lineage: chunkLineage, content: content)
            out.append(("""
            INSERT INTO chunks (id, object_id, ordinal, text, char_start, char_end, page_number, created_at, context_prefix, context_prefix_source, admit_embedding, evidence_block_id, block_kind, source_version_id, salience, context_template_version, derivation_digest)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
                chunk.blockKind.map { .text($0) } ?? .null,
                chunk.sourceVersionID.map { .uuid($0) } ?? .null,
                .real(chunk.salience),
                chunk.contextTemplateVersion.map { .integer(Int64($0)) } ?? .null,
                digest.map { .text($0) } ?? .null
            ]))
            for (i, blockID) in chunkLineage.enumerated() {
                out.append(("INSERT OR IGNORE INTO chunk_blocks (chunk_id, evidence_block_id, ordinal) VALUES (?, ?, ?);",
                            [.uuid(chunk.id), .uuid(blockID), .integer(Int64(i))]))
            }
        }
        return out
    }

    /// L1 — every block a chunk was assembled from, in reading order; falls
    /// back to the chunk's primary block for rows written before v133.
    public func blockIDs(forChunk chunkID: Chunk.ID) async throws -> [UUID] {
        let rows = try await database.query(
            "SELECT evidence_block_id FROM chunk_blocks WHERE chunk_id = ? ORDER BY ordinal;", [.uuid(chunkID)])
        let ids = rows.compactMap { $0.uuid(0) }
        if !ids.isEmpty { return ids }
        let primary = try await database.query(
            "SELECT evidence_block_id FROM chunks WHERE id = ?;", [.uuid(chunkID)])
        return primary.first?.uuid(0).map { [$0] } ?? []
    }

    /// G2-3 backfill — return chunks whose `context_prefix` is NULL
    /// AND that belong to a multi-chunk KO (single-chunk KOs are
    /// their own context — no prefix needed). Used by
    /// `ContextPrefixBackfiller` to fill in rows that timed out on
    /// the LLM during ingest.
    public func findChunksMissingContextPrefix(limit: Int = 100) async throws -> [Chunk] {
        let rows = try await database.query("""
        SELECT id, object_id, ordinal, text, char_start, char_end, page_number, created_at, context_prefix, context_prefix_source, evidence_block_id, block_kind, salience, context_template_version
        FROM chunks
        WHERE context_prefix IS NULL
          AND object_id IN (
            SELECT object_id FROM chunks GROUP BY object_id HAVING COUNT(*) >= 2
          )
        ORDER BY object_id ASC, ordinal ASC
        LIMIT ?;
        """, [.integer(Int64(limit))])
        return try await hydrateLineage(rows.compactMap(decode))
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
        SELECT c.id, c.object_id, c.ordinal, c.text, c.char_start, c.char_end, c.page_number, c.created_at, c.context_prefix, c.context_prefix_source, c.evidence_block_id, c.block_kind
        FROM chunks c
        LEFT JOIN chunk_embeddings ce ON ce.chunk_id = c.id AND ce.model_id = ?
        WHERE ce.chunk_id IS NULL
          AND c.admit_embedding = 1 AND c.superseded_by_run IS NULL
        ORDER BY c.created_at DESC
        LIMIT ?;
        """, [.text(modelID), .integer(Int64(limit))])
        return try await hydrateLineage(rows.compactMap(decode))
    }

    /// F10 — one KEYSET page of chunks awaiting a vector for `modelID`, newest first by rowid,
    /// strictly older than `beforeRowID` (nil = from the newest). `lastRowID` is the cursor for the
    /// next page (nil when the page is empty). Paging past a page lets the drain move beyond chunks
    /// the embedder cannot vectorize instead of re-reading the same front page forever.
    public func findChunksMissingVectorPage(limit: Int, modelID: String,
                                            beforeRowID: Int64?) async throws -> (chunks: [Chunk], lastRowID: Int64?) {
        let rows = try await database.query("""
        SELECT c.id, c.object_id, c.ordinal, c.text, c.char_start, c.char_end, c.page_number, c.created_at, c.context_prefix, c.context_prefix_source, c.evidence_block_id, c.block_kind, c.rowid
        FROM chunks c
        LEFT JOIN chunk_embeddings ce ON ce.chunk_id = c.id AND ce.model_id = ?
        WHERE ce.chunk_id IS NULL
          AND c.admit_embedding = 1 AND c.superseded_by_run IS NULL
          AND (? IS NULL OR c.rowid < ?)
        ORDER BY c.rowid DESC
        LIMIT ?;
        """, [.text(modelID),
              beforeRowID.map { .integer($0) } ?? .null, beforeRowID.map { .integer($0) } ?? .null,
              .integer(Int64(limit))])
        let last = rows.last?.int(12)
        return (try await hydrateLineage(rows.compactMap(decode)), last)
    }

    /// PERF.1 — count of chunks awaiting embedding for the active model.
    public func countChunksMissingVector(modelID: String = "apple.nl.v1") async throws -> Int {
        let rows = try await database.query("""
        SELECT COUNT(*) FROM chunks c
        LEFT JOIN chunk_embeddings ce ON ce.chunk_id = c.id AND ce.model_id = ?
        WHERE ce.chunk_id IS NULL
          AND c.admit_embedding = 1 AND c.superseded_by_run IS NULL;
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
            "SELECT COUNT(*) FROM chunks WHERE object_id = ? AND superseded_by_run IS NULL;",
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
        SELECT id, object_id, ordinal, text, char_start, char_end, page_number, created_at, context_prefix, context_prefix_source, evidence_block_id, block_kind, salience, context_template_version
        FROM chunks WHERE object_id = ? AND superseded_by_run IS NULL ORDER BY ordinal ASC;
        """, [.uuid(id)])
        return try await hydrateLineage(rows.compactMap(decode))
    }

    /// G2-QA-PAIRS retrieval helper. Returns the ordinal-0 chunk for
    /// an objectID — used by HybridRetriever when a qa_pair match
    /// hydrates the answer-side KO into a `RetrievedChunk`.
    public func firstChunk(forObjectID id: KnowledgeObject.ID) async throws -> Chunk? {
        let rows = try await database.query("""
        SELECT id, object_id, ordinal, text, char_start, char_end, page_number, created_at, context_prefix, context_prefix_source, evidence_block_id, block_kind, salience, context_template_version
        FROM chunks WHERE object_id = ? AND review_status IS NULL AND superseded_by_run IS NULL ORDER BY ordinal ASC LIMIT 1;
        """, [.uuid(id)])
        return try await hydrateLineage(rows.compactMap(decode)).first
    }

    /// F08 — ids of the chunks belonging to `sourceVersionIDs`: the candidate set that restricts a
    /// vector scan to a case BEFORE its top-k cut. Capped; the cap is the caller's recall budget.
    public func chunkIDs(sourceVersionIDs: Set<UUID>, limit: Int) async throws -> [Chunk.ID] {
        guard !sourceVersionIDs.isEmpty else { return [] }
        let ids = sourceVersionIDs.sorted { $0.uuidString < $1.uuidString }
        return try await database.query("""
            SELECT id FROM chunks WHERE source_version_id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
               AND review_status IS NULL AND superseded_by_run IS NULL ORDER BY rowid LIMIT ?;
            """, ids.map { .uuid($0) } + [.integer(Int64(limit))]).compactMap { $0.uuid(0) }
    }

    /// F08 — chunks by id, restricted to `sourceVersionIDs` in the query, each carrying its version.
    public func findByIDs(_ ids: [Chunk.ID], sourceVersionIDs: Set<UUID>) async throws -> [Chunk] {
        guard !ids.isEmpty, !sourceVersionIDs.isEmpty else { return [] }
        let vs = sourceVersionIDs.sorted { $0.uuidString < $1.uuidString }
        var out: [Chunk] = []
        for id in ids {
            let rows = try await database.query("""
                SELECT id, object_id, ordinal, text, char_start, char_end, page_number, created_at, context_prefix, context_prefix_source, evidence_block_id, block_kind, salience, context_template_version, source_version_id
                FROM chunks WHERE id = ? AND review_status IS NULL
                  AND source_version_id IN (\(vs.map { _ in "?" }.joined(separator: ","))) LIMIT 1;
                """, [.uuid(id)] + vs.map { .uuid($0) })
            if let row = rows.first, let chunk = decode(row) { out.append(chunk) }
        }
        return out
    }

    public func findByIDs(_ ids: [Chunk.ID]) async throws -> [Chunk] {
        guard !ids.isEmpty else { return [] }
        var chunks: [Chunk] = []
        for id in ids {
            // Rejected chunks are excluded here too, so a passage a user
            // soft-excluded stops surfacing via vector-hit / synth hydration.
            let rows = try await database.query("""
            SELECT id, object_id, ordinal, text, char_start, char_end, page_number, created_at, context_prefix, context_prefix_source, evidence_block_id, block_kind, salience, context_template_version
            FROM chunks WHERE id = ? AND review_status IS NULL LIMIT 1;
            """, [.uuid(id)])
            if let row = rows.first, let chunk = decode(row) {
                chunks.append(chunk)
            }
        }
        return chunks
    }

    /// F08 — keyword search restricted to `sourceVersionIDs` INSIDE the query (before ranking/LIMIT),
    /// so a small authorized scope is not crowded out by higher-ranked chunks from elsewhere. Chunks
    /// come back stamped with their source version. Large scopes are queried in bounded batches.
    public func searchFTS(_ query: String, limit: Int, sourceVersionIDs: Set<UUID>) async throws -> [Chunk] {
        let match = FTSQuerySanitizer.sanitize(query)
        guard !match.isEmpty, !sourceVersionIDs.isEmpty else { return [] }
        let ids = sourceVersionIDs.sorted { $0.uuidString < $1.uuidString }
        var out: [Chunk] = []
        for start in stride(from: 0, to: ids.count, by: 400) {
            let slice = ids[start..<min(start + 400, ids.count)]
            let qs = slice.map { _ in "?" }.joined(separator: ",")
            let rows = try await database.query("""
            SELECT c.id, c.object_id, c.ordinal, c.text, c.char_start, c.char_end, c.page_number, c.created_at, c.context_prefix, c.context_prefix_source, c.evidence_block_id, c.block_kind, c.source_version_id
            FROM chunks c
            JOIN chunks_fts ON chunks_fts.rowid = c.rowid
            WHERE chunks_fts.text MATCH ? AND c.review_status IS NULL AND c.superseded_by_run IS NULL AND c.source_version_id IN (\(qs))
            ORDER BY rank
            LIMIT ?;
            """, [.text(match)] + slice.map { .uuid($0) } + [.integer(Int64(limit))])
            for r in rows {
                guard let c = decode(r) else { continue }
                out.append(r.uuid(12).map { c.withSourceVersion($0) } ?? c)
            }
            if out.count >= limit { break }
        }
        return try await hydrateLineage(Array(out.prefix(limit)))
    }

    public func searchFTS(_ query: String, limit: Int = 50) async throws -> [Chunk] {
        // V1.1 U2.5 — NEVER pass raw query text to FTS5 (task #40: it raised a
        // logic error on ordinary punctuation and the keyword layer went silently
        // dead). Sanitize to a quoted-term OR expression of INFORMATIVE tokens.
        let match = FTSQuerySanitizer.sanitize(query)
        guard !match.isEmpty else {
            // F4.1 — GRACEFUL, COUNTED abstention: no informative token remains
            // (all stopwords/noise). The keyword layer abstains and other layers
            // carry — same behavior as pre-F4 for this class, now VISIBLE.
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                KalsmritikoshLog.storage.info("FTS abstained (no informative token): \(String(query.prefix(60)), privacy: .private)")
            }
            return []
        }
        let rows = try await database.query("""
        SELECT c.id, c.object_id, c.ordinal, c.text, c.char_start, c.char_end, c.page_number, c.created_at, c.context_prefix, c.context_prefix_source, c.evidence_block_id, c.block_kind
        FROM chunks c
        JOIN chunks_fts ON chunks_fts.rowid = c.rowid
        WHERE chunks_fts.text MATCH ? AND c.review_status IS NULL AND c.superseded_by_run IS NULL
        ORDER BY rank
        LIMIT ?;
        """, [.text(match), .integer(Int64(limit))])
        return try await hydrateLineage(rows.compactMap(decode))
    }

    // MARK: - P2.2 · document-level FTS, so `knowledge_objects_fts` is READ
    //
    // `knowledge_objects_fts` has been trigger-maintained on EVERY
    // knowledge_objects write since v14 and queried by NOTHING. The obvious
    // conclusion — that it is redundant against `chunks_fts` — is wrong, and
    // the difference is structural rather than a matter of degree:
    //
    //   chunks_fts indexes each chunk SEPARATELY. A multi-word phrase whose
    //   words fall either side of a chunk boundary can never match it, because
    //   no single indexed row contains the whole phrase.
    //   knowledge_objects_fts indexes the WHOLE document, so the same phrase
    //   matches.
    //
    // That is exactly the class of query a chunked index is blind to, and it is
    // not a rare one: a name, a clause, or an address split across a boundary
    // is common. So the write was never waste — the READ was missing.
    //
    // Used as a FALLBACK, not a replacement: chunk-level hits are more precise
    // (they carry the passage) and stay the primary lane. This runs only when
    // the chunk lane found nothing, and hydrates the matched documents' chunks
    // so downstream code receives the same shape either way.

    /// Chunks belonging to documents whose FULL TEXT matches — the cross-chunk
    /// phrase lane. Deterministic order; bounded per document so one long
    /// document cannot crowd out the rest.
    public func searchDocumentFTS(_ query: String, documentLimit: Int = 8,
                                  chunksPerDocument: Int = 4) async throws -> [Chunk] {
        let match = FTSQuerySanitizer.sanitize(query)
        guard !match.isEmpty else { return [] }
        let docs = try await database.query("""
        SELECT k.id
        FROM knowledge_objects k
        JOIN knowledge_objects_fts ON knowledge_objects_fts.rowid = k.rowid
        WHERE knowledge_objects_fts.content MATCH ?
        ORDER BY rank
        LIMIT ?;
        """, [.text(match), .integer(Int64(documentLimit))])
        let ids = docs.compactMap { $0.uuid(0) }
        guard !ids.isEmpty else { return [] }

        var out: [Chunk] = []
        for id in ids {
            // Leading chunks of the document: without a per-chunk score there
            // is no honest ranking WITHIN the document, and pretending
            // otherwise would invent precision. Ordinal order is at least
            // truthful and stable.
            let rows = try await database.query("""
            SELECT id, object_id, ordinal, text, char_start, char_end, page_number, created_at, context_prefix, context_prefix_source, evidence_block_id, block_kind
            FROM chunks
            WHERE object_id = ? AND review_status IS NULL AND superseded_by_run IS NULL
            ORDER BY ordinal ASC LIMIT ?;
            """, [.uuid(id), .integer(Int64(chunksPerDocument))])
            out.append(contentsOf: try await hydrateLineage(rows.compactMap(decode)))
        }
        return out
    }

    /// A deterministic sample of embeddable, non-rejected chunks (ordered by
    /// rowid, so the same DB yields the same sample). Used by the retrieval
    /// self-eval to measure recall@k on the user's OWN data.
    public func sample(limit: Int) async throws -> [Chunk] {
        let rows = try await database.query("""
        SELECT id, object_id, ordinal, text, char_start, char_end, page_number, created_at, context_prefix, context_prefix_source, evidence_block_id, block_kind, salience, context_template_version
        FROM chunks
        WHERE review_status IS NULL AND superseded_by_run IS NULL AND admit_embedding = 1 AND length(text) >= 40
        ORDER BY rowid
        LIMIT ?;
        """, [.integer(Int64(limit))])
        return try await hydrateLineage(rows.compactMap(decode))
    }

    /// Chunks whose `evidence_block_id` is one of `blockIDs` (non-rejected).
    /// Slot-aware retrieval uses this to pull the block that CARRIES a
    /// requested fact value into the candidate set regardless of bm25 rank;
    /// the chunks still pass through the caller's scope filter downstream.
    public func chunksForEvidenceBlocks(_ blockIDs: [UUID], limit: Int = 60) async throws -> [Chunk] {
        let ids = Array(Set(blockIDs)).prefix(200)
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let rows = try await database.query("""
        SELECT id, object_id, ordinal, text, char_start, char_end, page_number, created_at, context_prefix, context_prefix_source, evidence_block_id, block_kind, salience, context_template_version
        FROM chunks
        WHERE (evidence_block_id IN (\(placeholders))
               OR id IN (SELECT chunk_id FROM chunk_blocks WHERE evidence_block_id IN (\(placeholders))))
          AND review_status IS NULL AND superseded_by_run IS NULL
        ORDER BY rowid
        LIMIT ?;
        """, ids.map { SQLValue.uuid($0) } + ids.map { SQLValue.uuid($0) } + [.integer(Int64(limit))])
        return try await hydrateLineage(rows.compactMap(decode))
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

    /// L1 — attach each chunk's full block lineage (`chunk_blocks`) in ONE
    /// batched query. Rows written before v133 have no lineage rows and keep
    /// their primary block via `allBlockIDs`.
    private func hydrateLineage(_ chunks: [Chunk]) async throws -> [Chunk] {
        guard !chunks.isEmpty else { return chunks }
        var lineage: [UUID: [UUID]] = [:]
        let ids = chunks.map(\.id)
        for slice in stride(from: 0, to: ids.count, by: 400).map({ Array(ids[$0..<min($0 + 400, ids.count)]) }) {
            let qs = slice.map { _ in "?" }.joined(separator: ",")
            let rows = try await database.query("""
            SELECT chunk_id, evidence_block_id FROM chunk_blocks WHERE chunk_id IN (\(qs)) ORDER BY chunk_id, ordinal;
            """, slice.map { .uuid($0) })
            for r in rows {
                guard let c = r.uuid(0), let b = r.uuid(1) else { continue }
                lineage[c, default: []].append(b)
            }
        }
        guard !lineage.isEmpty else { return chunks }
        return chunks.map { c in lineage[c.id].map { c.withBlockIDs($0) } ?? c }
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
            contextPrefixSource: row.string(9),
            // v54 — the evidence-first block link. Written by insertBatch but
            // omitted from every SELECT until now, so readers always saw nil and
            // the chunk→EvidenceBlock provenance was unusable at query time.
            // Optional row accessors return nil when a SELECT doesn't project
            // these columns, so this is safe for the (few) narrower queries.
            evidenceBlockID: row.uuid(10),
            blockKind: row.string(11),
            // S2-U1 — projected only by SELECTs that carry column 12; narrower
            // queries fall back to the neutral prior, same as legacy rows.
            // F08 — projected (column 14) only by the scoped readers; nil everywhere else.
            sourceVersionID: row.uuid(14),
            salience: row.double(12) ?? SalienceTable.neutral,
            contextTemplateVersion: row.int(13).map(Int.init)
        )
    }
}
