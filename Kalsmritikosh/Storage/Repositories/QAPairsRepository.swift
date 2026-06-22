//
//  QAPairsRepository.swift
//  Kalsmritikosh
//
//  G2-QA-PAIRS — persists mined Q-A turns and exposes FTS-based
//  retrieval against the answer-text surface so the HybridRetriever
//  can fuse question-shaped matches into the metadata layer.
//

import Foundation
import OSLog

public actor QAPairsRepository {
    public struct Row: Sendable, Hashable, Identifiable {
        public let id: UUID
        public let questionText: String
        public let answerText: String
        public let questionObjectID: KnowledgeObject.ID
        public let answerObjectID: KnowledgeObject.ID
        public let confidence: Double
        public let producedBy: String

        public nonisolated init(
            id: UUID = UUID(),
            questionText: String,
            answerText: String,
            questionObjectID: KnowledgeObject.ID,
            answerObjectID: KnowledgeObject.ID,
            confidence: Double,
            producedBy: String
        ) {
            self.id = id
            self.questionText = questionText
            self.answerText = answerText
            self.questionObjectID = questionObjectID
            self.answerObjectID = answerObjectID
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
                INSERT OR REPLACE INTO qa_pairs
                  (id, question_text, answer_text, question_object_id, answer_object_id,
                   confidence, produced_by, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """,
                [
                    .uuid(r.id),
                    .text(r.questionText),
                    .text(r.answerText),
                    .uuid(r.questionObjectID),
                    .uuid(r.answerObjectID),
                    .real(r.confidence),
                    .text(r.producedBy),
                    .real(now)
                ]
            )
            try await database.exec(
                "INSERT OR REPLACE INTO qa_pairs_fts(rowid, question_text, answer_text) VALUES ((SELECT rowid FROM qa_pairs WHERE id = ?), ?, ?);",
                [.uuid(r.id), .text(r.questionText), .text(r.answerText)]
            )
        }
    }

    public struct MatchRow: Sendable {
        public let pairID: UUID
        public let answerObjectID: KnowledgeObject.ID
        public let answerSnippet: String
        public let score: Double
    }

    public func search(_ query: String, limit: Int = 15) async throws -> [MatchRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let sanitized = trimmed
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
        let rows = try await database.query(
            """
            SELECT qa.id, qa.answer_object_id, qa.answer_text, bm25(qa_pairs_fts)
            FROM qa_pairs_fts
            JOIN qa_pairs qa ON qa.rowid = qa_pairs_fts.rowid
            WHERE qa_pairs_fts MATCH ?
            ORDER BY bm25(qa_pairs_fts)
            LIMIT ?;
            """,
            [.text(sanitized), .integer(Int64(limit))]
        )
        return rows.compactMap { row in
            guard let pid = row.uuid(0),
                  let aid = row.uuid(1),
                  let answer = row.string(2)
            else { return nil }
            let rawBm25 = row.double(3) ?? 0
            let normalized = max(0, min(1, 1.0 / (1.0 + max(0, rawBm25))))
            return MatchRow(
                pairID: pid,
                answerObjectID: aid,
                answerSnippet: String(answer.prefix(400)),
                score: normalized
            )
        }
    }

    public func count() async throws -> Int {
        let rows = try await database.query("SELECT COUNT(*) FROM qa_pairs;")
        return Int(rows.first?.int(0) ?? 0)
    }
}
