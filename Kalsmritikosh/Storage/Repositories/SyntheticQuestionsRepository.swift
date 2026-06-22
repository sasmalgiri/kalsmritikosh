//
//  SyntheticQuestionsRepository.swift
//  Kalsmritikosh
//
//  G2-SYNTHETIC-QUESTIONS — persists hypothetical-question rows
//  generated at ingest time. Sidecar to the chunks table; the FTS
//  view `synthetic_questions_fts` is what HybridRetriever queries to
//  match question-shaped projections of the corpus.
//

import Foundation
import OSLog

public actor SyntheticQuestionsRepository {
    public struct Row: Sendable, Hashable, Identifiable {
        public let id: UUID
        public let chunkID: Chunk.ID
        public let objectID: KnowledgeObject.ID
        public let text: String
        public let confidence: Double
        public let producedBy: String

        public nonisolated init(
            id: UUID = UUID(),
            chunkID: Chunk.ID,
            objectID: KnowledgeObject.ID,
            text: String,
            confidence: Double,
            producedBy: String
        ) {
            self.id = id
            self.chunkID = chunkID
            self.objectID = objectID
            self.text = text
            self.confidence = max(0, min(1, confidence))
            self.producedBy = producedBy
        }
    }

    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func insertBatch(_ rows: [Row]) async throws {
        guard !rows.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        for r in rows {
            try await database.exec(
                """
                INSERT OR REPLACE INTO synthetic_questions
                  (id, chunk_id, object_id, text, confidence, produced_by, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """,
                [
                    .uuid(r.id),
                    .uuid(r.chunkID),
                    .uuid(r.objectID),
                    .text(r.text),
                    .real(r.confidence),
                    .text(r.producedBy),
                    .real(now)
                ]
            )
            // Keep FTS in sync with the parent row.
            try await database.exec(
                "INSERT OR REPLACE INTO synthetic_questions_fts(rowid, text) VALUES ((SELECT rowid FROM synthetic_questions WHERE id = ?), ?);",
                [.uuid(r.id), .text(r.text)]
            )
        }
    }

    /// FTS5 lookup against synthetic-question text. Returns matching
    /// chunk/object IDs the retriever can union with chunk-text hits.
    public struct MatchRow: Sendable {
        public let questionID: UUID
        public let chunkID: Chunk.ID
        public let objectID: KnowledgeObject.ID
        public let questionText: String
        public let score: Double
    }

    public func search(_ query: String, limit: Int = 25) async throws -> [MatchRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let sanitized = trimmed
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
        let rows = try await database.query(
            """
            SELECT sq.id, sq.chunk_id, sq.object_id, sq.text, bm25(synthetic_questions_fts)
            FROM synthetic_questions_fts
            JOIN synthetic_questions sq ON sq.rowid = synthetic_questions_fts.rowid
            WHERE synthetic_questions_fts MATCH ?
            ORDER BY bm25(synthetic_questions_fts)
            LIMIT ?;
            """,
            [.text(sanitized), .integer(Int64(limit))]
        )
        return rows.compactMap { row in
            guard let id = row.uuid(0),
                  let cid = row.uuid(1),
                  let oid = row.uuid(2),
                  let text = row.string(3)
            else { return nil }
            // bm25 scores are negative-good in SQLite FTS5. Invert
            // and clamp to [0,1] so the retriever's downstream sort
            // matches the rest of the vector/scoreByObject contract.
            let rawBm25 = row.double(4) ?? 0
            let normalized = max(0, min(1, 1.0 / (1.0 + max(0, rawBm25))))
            return MatchRow(
                questionID: id,
                chunkID: cid,
                objectID: oid,
                questionText: text,
                score: normalized
            )
        }
    }

    public func count() async throws -> Int {
        let rows = try await database.query("SELECT COUNT(*) FROM synthetic_questions;")
        return Int(rows.first?.int(0) ?? 0)
    }
}
