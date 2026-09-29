//
//  ChunkDerivation.swift
//  Kalsmritikosh
//
//  F15/F25 — the dependency contract of a derived chunk, and its check. A chunk is derived from:
//    • the chunker (its `version` here — bump it when chunking output changes);
//    • its own text;
//    • in lineage order, each evidence block it was assembled from: the block's id, kind, raw text and
//      normalized text.
//  The block's LOCATOR is deliberately not a dependency: a citation resolves the block by id and reads
//  its locator live, so a locator-only correction needs no text rebuild. Attributes, language and
//  confidence do not change chunk text either; they move the evidence revision (v141) so dependent
//  proofs are re-verified, but they do not invalidate the chunk.
//
//  The digest is recorded when the chunk is written (`chunks.derivation_digest`, v141) and recomputed
//  from the LIVE chunk, lineage and blocks when readiness is reconciled. A mismatch means the derived
//  output no longer matches the evidence it claims to come from — the object's index is rebuilt from
//  its committed blocks, never re-stamped as current.
//

import Foundation
import CryptoKit

public nonisolated enum ChunkDerivation {

    /// Chunker output version folded into every digest.
    public static let version = 1

    struct BlockContent: Sendable, Equatable {
        let kind: String
        let rawText: String
        let normalizedText: String
    }

    /// Digest of one chunk's derivation. Nil when a lineage block's content is unknown (the chunk
    /// cannot be bound to what it came from; a reconciliation records its baseline later).
    static func digest(text: String, lineage: [UUID], content: [UUID: BlockContent]) -> String? {
        var h = SHA256()
        func put(_ s: String) {
            h.update(data: Data(String(s.utf8.count).utf8)); h.update(data: Data([0x1F])); h.update(data: Data(s.utf8))
        }
        put("chunk-derivation-\(version)")
        put(text)
        for id in lineage {
            guard let c = content[id] else { return nil }
            put(id.uuidString); put(c.kind); put(c.rawText); put(c.normalizedText)
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func content(of block: EvidenceBlock) -> BlockContent {
        BlockContent(kind: block.kind.rawValue, rawText: block.rawText, normalizedText: block.normalizedText)
    }

    /// The outcome of checking a version's (or one object's) active chunks against their evidence.
    public struct Verification: Sendable, Equatable {
        /// Objects with at least one chunk whose derivation no longer matches its evidence.
        public var mismatchedObjects: Set<UUID> = []
        public var mismatchedChunks = 0
        /// Chunks written before v141 whose baseline digest was recorded by this check.
        public var baselined = 0
        public var checked = 0
    }

    /// Recompute every active chunk's digest from the live chunk, lineage and blocks and compare it
    /// with the recorded one; record a baseline where none was recorded. Paged by rowid, one isolated
    /// savepoint per page (a writer between pages is caught by the caller's revision compare-and-set).
    static func verify(_ db: Database, sourceVersionID svid: UUID, object: UUID? = nil, pageSize: Int = 500) async throws -> Verification {
        var result = Verification()
        var after: Int64 = -1
        while true {
            let (page, last) = try await db.withSavepoint("chunk_verify_\(svid.uuidString.prefix(8))") { db -> (Verification, Int64?) in
                try verifyPage(db, svid: svid, object: object, after: after, limit: pageSize)
            }
            result.mismatchedObjects.formUnion(page.mismatchedObjects)
            result.mismatchedChunks += page.mismatchedChunks
            result.baselined += page.baselined
            result.checked += page.checked
            guard let last else { break }
            after = last
        }
        return result
    }

    private static func verifyPage(_ db: isolated Database, svid: UUID, object: UUID?, after: Int64, limit: Int) throws -> (Verification, Int64?) {
        var out = Verification()
        var binds: [SQLValue] = [.uuid(svid), .integer(after)]
        if let object { binds.append(.uuid(object)) }
        binds.append(.integer(Int64(limit)))
        let rows = try db.query("""
            SELECT rowid, id, object_id, text, derivation_digest FROM chunks
             WHERE source_version_id = ? AND superseded_by_run IS NULL AND rowid > ?\(object == nil ? "" : " AND object_id = ?")
             ORDER BY rowid LIMIT ?;
            """, binds)
        guard let lastRow = rows.last?.int(0) else { return (out, nil) }
        let ids = rows.compactMap { $0.uuid(1) }
        var lineage: [UUID: [UUID]] = [:]
        for slice in stride(from: 0, to: ids.count, by: 400).map({ Array(ids[$0..<min($0 + 400, ids.count)]) }) {
            let marks = slice.map { _ in "?" }.joined(separator: ",")
            for r in try db.query("SELECT chunk_id, evidence_block_id FROM chunk_blocks WHERE chunk_id IN (\(marks)) ORDER BY chunk_id, ordinal;",
                                  slice.map { .uuid($0) }) {
                if let c = r.uuid(0), let b = r.uuid(1) { lineage[c, default: []].append(b) }
            }
        }
        let blockIDs = Array(Set(lineage.values.flatMap { $0 }))
        var content: [UUID: BlockContent] = [:]
        for slice in stride(from: 0, to: blockIDs.count, by: 400).map({ Array(blockIDs[$0..<min($0 + 400, blockIDs.count)]) }) {
            let marks = slice.map { _ in "?" }.joined(separator: ",")
            for r in try db.query("SELECT id, kind, raw_text, normalized_text FROM evidence_blocks WHERE id IN (\(marks));",
                                  slice.map { .uuid($0) }) {
                if let id = r.uuid(0) {
                    content[id] = BlockContent(kind: r.string(1) ?? "", rawText: r.string(2) ?? "", normalizedText: r.string(3) ?? "")
                }
            }
        }
        for r in rows {
            guard let id = r.uuid(1), let ko = r.uuid(2) else { continue }
            out.checked += 1
            let live = digest(text: r.string(3) ?? "", lineage: lineage[id] ?? [], content: content)
            if let recorded = r.string(4) {
                if live != recorded { out.mismatchedChunks += 1; out.mismatchedObjects.insert(ko) }
            } else if let live {
                // Written before v141: nothing to compare against — record today's state as the baseline.
                try db.exec("UPDATE chunks SET derivation_digest = ? WHERE id = ?;", [.text(live), .uuid(id)])
                out.baselined += 1
            }
        }
        return (out, lastRow)
    }
}
