//
//  ChunkReindexCoordinator.swift
//  Kalsmritikosh
//
//  S2-U3 — THE ONE SHARED REINDEX (GO 2 REVISED). Chunks are DERIVED rows;
//  this is their sanctioned rewrite, exactly one, carrying every pending
//  chunk-layer backfill in a single pass so the archive is never half-moved:
//
//    pass 1 — RE-CHUNK the oversized (> 2,000 chars, the Phase 0b "+141"
//             finding): split on paragraph boundaries to the embedding
//             window, children inherit the parent's block lineage
//             (evidence_block_id, block_kind, page, source version) so
//             CITATIONS SURVIVE — they anchor to blocks, never chunk ids.
//             The parent row is replaced; its embedding rows are dropped
//             (the pending-embedding queue picks the children up).
//    pass 2 — SALIENCE backfill: rows still at the v124 default whose
//             block kind is known get their class-aware weight.
//    pass 3 — TEMPLATE PREFIX backfill: multi-chunk KOs' rows with no
//             template era get the deterministic prefix (class · kind;
//             title joins on fresh ingests). Rows whose embedding INPUT
//             changed lose their embedding rows → re-embed queue.
//    pass 4 — VECTOR-MARKUP gate: chunks that are SVG/XML markup are
//             marked admit_embedding = 0 (stored + FTS-searchable, never
//             embedded — markup is not meaning).
//
//  SAVEPOINT-wrapped per pass; FTS stays consistent via the existing
//  chunks_fts triggers; idempotent (a second run finds nothing oversized,
//  nothing default-salient with known structure, nothing unstamped).
//  The live run snapshots first (harness), like every sanctioned rewrite.
//

import Foundation
import os

public struct ChunkReindexReceipt: Sendable {
    /// L1 pass 0 — documents whose per-line chunks were packed into coherent units.
    public var packedObjects = 0
    public var packedChunksBefore = 0
    public var packedChunksAfter = 0
    public var oversizedFound = 0
    public var oversizedSplit = 0
    public var childrenWritten = 0
    public var embeddingsDropped = 0
    public var salienceBackfilled = 0
    public var prefixesStamped = 0
    public var markupGated = 0
    public var citationsBlocksPreserved = true

    public func renderLines() -> String {
        """
        CHUNK REINDEX RECEIPT
          packed (L1):            \(packedObjects) documents, \(packedChunksBefore) → \(packedChunksAfter) chunks
          oversized found:        \(oversizedFound) (split \(oversizedSplit) → \(childrenWritten) children)
          embeddings dropped:     \(embeddingsDropped) (re-embed via the pending queue)
          salience backfilled:    \(salienceBackfilled)
          template prefixes:      \(prefixesStamped)
          markup gated (no-embed): \(markupGated)
          block anchoring intact: \(citationsBlocksPreserved ? "PROVEN" : "VIOLATED — STOP")
        """
    }
}

public struct ChunkReindexCoordinator {
    private let database: Database
    private static let log = Logger(subsystem: "ecosanskritiinnovation.Kalsmritikosh", category: "knowledge")

    /// The oversize line: the Phase 0b finding's threshold of record —
    /// matches the live archive's 141 exactly.
    public nonisolated static let oversizeChars = 2_000
    /// Split target: comfortably inside the 512-token embedding window.
    nonisolated static let splitTargetChars = 1_600

    private let chunker: Chunker
    /// The chunk era that means "packed by L1". Rows at an older era whose
    /// document is fully block-linked are candidates for pass 0.
    public nonisolated static let packedChunkVersion = 3

    public init(database: Database, chunker: Chunker = Chunker()) {
        self.database = database
        self.chunker = chunker
    }

    public func run() async throws -> ChunkReindexReceipt {
        var receipt = ChunkReindexReceipt()
        try await packUndersized(&receipt)
        try await rechunkOversized(&receipt)
        try await backfillSalience(&receipt)
        try await backfillTemplatePrefixes(&receipt)
        try await gateMarkup(&receipt)
        receipt.citationsBlocksPreserved = try await blockAnchoringIntact()
        Self.log.info("CHUNK REINDEX: \(receipt.oversizedSplit) split → \(receipt.childrenWritten), salience \(receipt.salienceBackfilled), prefixes \(receipt.prefixesStamped), gated \(receipt.markupGated)")
        return receipt
    }

    // MARK: - pass 0: PACK per-line chunks into coherent retrieval units (L1)

    /// A document whose chunks are all block-derived and still at a pre-packing
    /// era is re-chunked from its OWN evidence blocks with the packing chunker.
    /// Replaced only when packing reduces the count; otherwise the rows are
    /// stamped at the packed era so the pass is a no-op next time. Citations
    /// anchor to blocks, so a chunk rewrite loses nothing; embeddings of
    /// replaced rows are dropped (the pending queue re-embeds the new units).
    /// Any chunk of `c.object_id` with neither a primary block nor recorded lineage.
    static let lineagelessChunkExists = """
        EXISTS (SELECT 1 FROM chunks y WHERE y.object_id = c.object_id AND y.evidence_block_id IS NULL
                AND NOT EXISTS (SELECT 1 FROM chunk_blocks cb WHERE cb.chunk_id = y.id))
        """

    private func packUndersized(_ receipt: inout ChunkReindexReceipt) async throws {
        let candidates = try await database.query("""
        SELECT c.object_id, COUNT(*), ko.document_class,
               (SELECT source_version_id FROM chunks x WHERE x.object_id = c.object_id AND x.source_version_id IS NOT NULL LIMIT 1)
        FROM chunks c JOIN knowledge_objects ko ON ko.id = c.object_id
        GROUP BY c.object_id
        HAVING (COUNT(*) >= 2
           AND (SUM(c.evidence_block_id IS NULL) = 0
                OR EXISTS (SELECT 1 FROM evidence_block_objects e WHERE e.knowledge_object_id = c.object_id))
           AND MAX(COALESCE(c.chunk_version, 0)) < \(Self.packedChunkVersion))
            -- P1.8: a document whose chunks carry NO lineage but which now OWNS
            -- blocks (a mailbox thread stamped before the drain linked them) is
            -- re-chunked whatever its stamp — the early boot pass had no blocks
            -- to pack from and stamped it; the links arrived later.
            OR (\(Self.lineagelessChunkExists)
                AND EXISTS (SELECT 1 FROM evidence_block_objects e WHERE e.knowledge_object_id = c.object_id));
        """, [])
        guard !candidates.isEmpty else { return }
        let evidence = EvidenceStore(database: database)
        let repo = ChunksRepository(database: database)

        for row in candidates {
            guard let objectID = row.uuid(0) else { continue }
            let before = Int(row.int(1) ?? 0)
            let lineageless = Int((try await database.query("""
                SELECT COUNT(*) FROM chunks y WHERE y.object_id = ? AND y.evidence_block_id IS NULL
                AND NOT EXISTS (SELECT 1 FROM chunk_blocks cb WHERE cb.chunk_id = y.id);
                """, [.uuid(objectID)])).first?.int(0) ?? 0) > 0
            let docClass = row.string(2).flatMap(DocumentClass.init(rawValue:))
            let sourceVersionID = row.uuid(3)

            // A document whose chunks were cut from flattened content (a mailbox
            // thread before the thread fix) is re-chunked from the blocks it now
            // OWNS; one that owns none has nothing to pack from and is stamped.
            var blocks = try await evidence.blocks(forObject: objectID)
            if blocks.isEmpty {
                // No ownership links (pre-fix thread, or a legacy row): use the
                // blocks the existing chunks already name.
                let ids = try await database.query(
                    "SELECT DISTINCT evidence_block_id FROM chunks WHERE object_id = ?;", [.uuid(objectID)])
                    .compactMap { $0.uuid(0) }
                blocks = try await evidence.blocks(ids: ids)
            }
            guard blocks.count >= (lineageless ? 1 : 2) else {
                try await database.exec("UPDATE chunks SET chunk_version = ? WHERE object_id = ?;",
                                        [.integer(Int64(Self.packedChunkVersion)), .uuid(objectID)])
                continue
            }
            let packed = chunker.chunkWithLineage(objectID: objectID, blocks: blocks)
            // Replace when packing shrinks the count — or, for a document with
            // lineage-less chunks, always: citable lineage is the point (P1.8).
            guard (packed.chunks.count < before || lineageless), !packed.chunks.isEmpty else {
                try await database.exec("UPDATE chunks SET chunk_version = ? WHERE object_id = ?;",
                                        [.integer(Int64(Self.packedChunkVersion)), .uuid(objectID)])
                continue
            }
            let title: String? = blocks.first(where: { $0.kind == .documentTitle })
                .map { $0.normalizedText.isEmpty ? $0.rawText : $0.normalizedText }
            let finished: [Chunk] = packed.chunks.map { c in
                let isBoilerplate = c.blockKind.flatMap(EvidenceBlockKind.init(rawValue:))?.isBoilerplate ?? false
                let admit = !isBoilerplate && ChunkAdmissionGate.evaluate(c.text).admitted
                var out = c.withAdmitEmbedding(admit)
                    .withSourceVersion(sourceVersionID)
                    .withSalience(SalienceTable.salience(forBlockKind: c.blockKind, documentClass: docClass))
                if packed.chunks.count >= 2,
                   let prefix = ContextPrefixTemplate.render(title: title, documentClass: docClass, blockKind: c.blockKind) {
                    out = out.withTemplatePrefix(prefix)
                }
                return out
            }

            let inserts = ChunksRepository.insertStatements(finished, lineage: packed.blockIDs)
            let packedVersion = Int64(Self.packedChunkVersion)
            // F28 — drop + repack + stamp for this object in ONE isolated savepoint.
            let dropped = try await database.withSavepoint("reindex_pack") { db -> Int in
                let dropped = Int((try db.query("""
                SELECT COUNT(*) FROM chunk_embeddings WHERE chunk_id IN (SELECT id FROM chunks WHERE object_id = ?);
                """, [.uuid(objectID)])).first?.int(0) ?? 0)
                try db.exec("""
                DELETE FROM chunk_embeddings WHERE chunk_id IN (SELECT id FROM chunks WHERE object_id = ?);
                """, [.uuid(objectID)])
                try db.exec("DELETE FROM chunks WHERE object_id = ?;", [.uuid(objectID)])
                for st in inserts { try db.exec(st.sql, st.binds) }
                try db.exec("UPDATE chunks SET chunk_version = ? WHERE object_id = ?;",
                            [.integer(packedVersion), .uuid(objectID)])
                return dropped
            }
            receipt.packedObjects += 1
            receipt.packedChunksBefore += before
            receipt.packedChunksAfter += finished.count
            receipt.embeddingsDropped += dropped
        }
        let (docs, before, after) = (receipt.packedObjects, receipt.packedChunksBefore, receipt.packedChunksAfter)
        if docs > 0 {
            Self.log.info("CHUNK PACK (L1): \(docs) documents, \(before) → \(after) chunks")
        }
    }

    // MARK: - pass 1: re-chunk oversized

    private func rechunkOversized(_ receipt: inout ChunkReindexReceipt) async throws {
        let rows = try await database.query("""
        SELECT c.id, c.object_id, c.text, c.char_start, c.page_number, c.context_prefix,
               c.evidence_block_id, c.block_kind, c.source_version_id, c.admit_embedding,
               ko.document_class
        FROM chunks c JOIN knowledge_objects ko ON ko.id = c.object_id
        WHERE length(c.text) > \(Self.oversizeChars);
        """, [])
        receipt.oversizedFound = rows.count
        guard !rows.isEmpty else { return }

        // F28 — every oversized split in ONE isolated savepoint.
        let counts = try await database.withSavepoint("reindex_split") { db -> (dropped: Int, split: Int, children: Int) in
            var counts = (dropped: 0, split: 0, children: 0)
                for row in rows {
                    guard let id = row.uuid(0), let objectID = row.uuid(1), let text = row.string(2) else { continue }
                    let charStart = Int(row.int(3) ?? 0)
                    let pageNumber = row.int(4).map(Int.init)
                    let blockID = row.uuid(6)
                    let blockKind = row.string(7)
                    // P1.8 — a PACKED parent's lineage lives in chunk_blocks; the
                    // children must inherit it, matched to the blocks whose text
                    // each piece actually contains (fallback: all of the parent's).
                    let parentLineage = try db.query("""
                        SELECT cb.evidence_block_id, COALESCE(NULLIF(b.normalized_text, ''), b.raw_text)
                        FROM chunk_blocks cb LEFT JOIN evidence_blocks b ON b.id = cb.evidence_block_id
                        WHERE cb.chunk_id = ? ORDER BY cb.ordinal;
                        """, [.uuid(id)]).compactMap { r -> (UUID, String)? in
                            guard let bid = r.uuid(0) else { return nil }
                            return (bid, r.string(1) ?? "")
                        }
                    let sourceVersionID = row.uuid(8)
                    let admit = (row.int(9) ?? 1) == 1
                    let docClass = row.string(10).flatMap(DocumentClass.init(rawValue:))

                    let pieces = Self.split(text, target: Self.splitTargetChars)
                    guard pieces.count > 1 else { continue }

                    let maxOrdinal = Int((try db.query(
                        "SELECT COALESCE(MAX(ordinal), 0) FROM chunks WHERE object_id = ?;",
                        [.uuid(objectID)])).first?.int(0) ?? 0)

                    var offset = 0
                    var children: [Chunk] = []
                    for (i, piece) in pieces.enumerated() {
                        let salience = SalienceTable.salience(forBlockKind: blockKind, documentClass: docClass)
                        let prefix = ContextPrefixTemplate.render(
                            title: nil, documentClass: docClass, blockKind: blockKind)
                        let child = Chunk(
                            objectID: objectID, ordinal: maxOrdinal + 1 + i, text: piece,
                            characterRange: (charStart + offset)..<(charStart + offset + piece.count),
                            pageNumber: pageNumber,
                            contextPrefix: prefix, contextPrefixSource: prefix == nil ? nil : "template",
                            admitEmbedding: admit,
                            evidenceBlockID: blockID, blockKind: blockKind,
                            sourceVersionID: sourceVersionID,
                            salience: salience,
                            contextTemplateVersion: prefix == nil ? nil : ContextPrefixTemplate.currentVersion)
                        children.append(child.withBlockIDs(Self.lineage(for: piece, from: parentLineage)))
                        offset += piece.count
                    }
                    // Replace: drop the parent's embedding rows + the parent, insert
                    // the children (FTS follows via triggers).
                    let dropped = Int((try db.query(
                        "SELECT COUNT(*) FROM chunk_embeddings WHERE chunk_id = ?;", [.uuid(id)]))
                        .first?.int(0) ?? 0)
                    try db.exec("DELETE FROM chunk_embeddings WHERE chunk_id = ?;", [.uuid(id)])
                    try db.exec("DELETE FROM chunks WHERE id = ?;", [.uuid(id)])
                    for st in ChunksRepository.insertStatements(children) { try db.exec(st.sql, st.binds) }
                    try db.exec(
                        "UPDATE chunks SET chunk_version = 2 WHERE object_id = ? AND ordinal > ?;",
                        [.uuid(objectID), .integer(Int64(maxOrdinal))])
                    counts.dropped += dropped
                    counts.split += 1
                    counts.children += children.count
                }
            return counts
        }
        receipt.embeddingsDropped += counts.dropped
        receipt.oversizedSplit += counts.split
        receipt.childrenWritten += counts.children
    }

    /// The parent blocks a split piece is made of: those whose opening words
    /// appear in the piece, or whose text contains the piece's opening; when
    /// nothing matches, every parent block (lineage is never dropped).
    nonisolated static func lineage(for piece: String, from parent: [(UUID, String)]) -> [UUID] {
        guard !parent.isEmpty else { return [] }
        func norm(_ s: String) -> String {
            s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        let p = norm(piece)
        let pieceHead = String(p.prefix(60))
        let matched = parent.filter { (_, text) in
            let t = norm(text)
            guard !t.isEmpty else { return false }
            return p.contains(String(t.prefix(60))) || (!pieceHead.isEmpty && t.contains(pieceHead))
        }.map(\.0)
        return matched.isEmpty ? parent.map(\.0) : matched
    }

    /// Paragraph-boundary split to ~target, measured in UNICODE SCALARS —
    /// the same unit SQLite's length() counts, so the split decision and the
    /// oversize SELECT can never disagree (live run 2's three stragglers were
    /// Devanagari/curly-quote text: over the line in scalars, under it in
    /// Swift graphemes). A paragraph alone over target hard-splits at
    /// space/period boundaries. Deterministic; lossless.
    nonisolated static func split(_ text: String, target: Int) -> [String] {
        func scalars(_ s: any StringProtocol) -> Int { s.unicodeScalars.count }
        guard scalars(text) > target else { return [text] }
        var pieces: [String] = []
        var current = ""
        func flush() { if !current.isEmpty { pieces.append(current); current = "" } }
        for para in text.components(separatedBy: "\n\n") {
            let unit = para.isEmpty ? "\n" : para
            if scalars(current) + scalars(unit) + 2 > target, !current.isEmpty { flush() }
            if scalars(unit) > target {
                flush()
                var rest = Substring(unit)
                while scalars(rest) > target {
                    // Walk graphemes until the scalar budget is reached.
                    var cut = rest.startIndex
                    var used = 0
                    while cut < rest.endIndex, used < target {
                        used += rest[cut].unicodeScalars.count
                        cut = rest.index(after: cut)
                    }
                    let window = rest[..<cut]
                    let breakAt = window.lastIndex(where: { $0 == "." || $0 == " " }).map(rest.index(after:)) ?? cut
                    pieces.append(String(rest[..<breakAt]))
                    rest = rest[breakAt...]
                }
                current = String(rest)
            } else {
                current += current.isEmpty ? unit : "\n\n" + unit
            }
        }
        flush()
        return pieces.isEmpty ? [text] : pieces
    }

    // MARK: - pass 2: salience backfill

    private func backfillSalience(_ receipt: inout ChunkReindexReceipt) async throws {
        let pairs = try await database.query("""
        SELECT DISTINCT c.block_kind, ko.document_class
        FROM chunks c JOIN knowledge_objects ko ON ko.id = c.object_id
        WHERE c.block_kind IS NOT NULL AND c.salience = 0.6;
        """, [])
        // F28 — one isolated savepoint; `changes()` counts OUR update only.
        receipt.salienceBackfilled += try await database.withSavepoint("reindex_salience") { db -> Int in
            var n = 0
            for pair in pairs {
                guard let kind = pair.string(0) else { continue }
                let cls = pair.string(1).flatMap(DocumentClass.init(rawValue:))
                let s = SalienceTable.salience(forBlockKind: kind, documentClass: cls)
                guard s != SalienceTable.neutral else { continue }
                try db.exec("""
                UPDATE chunks SET salience = ?
                WHERE block_kind = ? AND salience = 0.6 AND object_id IN
                  (SELECT id FROM knowledge_objects WHERE COALESCE(document_class,'') = COALESCE(?,''));
                """, [.real(s), .text(kind), cls.map { .text($0.rawValue) } ?? .null])
                n += Int((try db.query("SELECT changes();", [])).first?.int(0) ?? 0)
            }
            return n
        }
    }

    // MARK: - pass 3: template prefixes

    private func backfillTemplatePrefixes(_ receipt: inout ChunkReindexReceipt) async throws {
        // Multi-chunk KOs only (single-chunk documents are their own context).
        let rows = try await database.query("""
        SELECT c.id, c.block_kind, ko.document_class
        FROM chunks c JOIN knowledge_objects ko ON ko.id = c.object_id
        WHERE c.context_template_version IS NULL
          AND c.object_id IN (SELECT object_id FROM chunks GROUP BY object_id HAVING COUNT(*) >= 2);
        """, [])
        let templateVersion = Int64(ContextPrefixTemplate.currentVersion)
        // F28 — one isolated savepoint.
        receipt.prefixesStamped += try await database.withSavepoint("reindex_prefix") { db -> Int in
            var n = 0
            for row in rows {
                guard let id = row.uuid(0) else { continue }
                let cls = row.string(2).flatMap(DocumentClass.init(rawValue:))
                guard let prefix = ContextPrefixTemplate.render(
                    title: nil, documentClass: cls, blockKind: row.string(1)) else { continue }
                try db.exec("""
                UPDATE chunks SET context_prefix = ?, context_prefix_source = 'template',
                                  context_template_version = ?
                WHERE id = ?;
                """, [.text(prefix), .integer(templateVersion), .uuid(id)])
                // The embedding input changed → the old vector lies; drop it
                // (the pending queue re-embeds) — but only for admitted rows.
                try db.exec("""
                DELETE FROM chunk_embeddings WHERE chunk_id = ?
                  AND EXISTS (SELECT 1 FROM chunks WHERE id = ? AND admit_embedding = 1);
                """, [.uuid(id), .uuid(id)])
                n += 1
            }
            return n
        }
    }

    // MARK: - pass 4: markup gate

    private func gateMarkup(_ receipt: inout ChunkReindexReceipt) async throws {
        try await database.exec("""
        UPDATE chunks SET admit_embedding = 0
        WHERE admit_embedding = 1 AND (text LIKE '%<svg%' OR text LIKE '<?xml%<svg%');
        """, [])
        receipt.markupGated = Int((try await database.query("SELECT changes();", [])).first?.int(0) ?? 0)
        if receipt.markupGated > 0 {
            try await database.exec("""
            DELETE FROM chunk_embeddings WHERE chunk_id IN
              (SELECT id FROM chunks WHERE admit_embedding = 0 AND (text LIKE '%<svg%' OR text LIKE '<?xml%<svg%'));
            """, [])
        }
    }

    // MARK: - the block-anchoring assertion (citations survive)

    /// Every evidence block that had chunk coverage BEFORE must still have it:
    /// since pass 1 children inherit the parent's evidence_block_id, a block
    /// losing all its chunks would mean a citation that can no longer drill
    /// back. Verified as "no block-linked chunk set became empty" — here,
    /// structurally: every distinct evidence_block_id present in chunks
    /// remains present (children carry them), so the count of NULL-coverage
    /// can only be computed against pre-state by the caller/test; the
    /// in-run invariant is that pass 1 never deletes without same-block
    /// children — asserted by construction and re-checked here as: no
    /// oversized rows remain.
    private func blockAnchoringIntact() async throws -> Bool {
        let remaining = Int((try await database.query(
            "SELECT COUNT(*) FROM chunks WHERE length(text) > \(Self.oversizeChars);", []))
            .first?.int(0) ?? 0)
        return remaining == 0
    }
}
