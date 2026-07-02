//
//  AnswerLedgerRepository.swift
//  Kalsmritikosh
//
//  Ledger-AI v28 — persists answers as first-class objects, not
//  throwaway prose. The correct generation flow is:
//
//      Evidence → Claims → Verified answer → User-facing prose
//
//  ...NOT "LLM paragraph → hope it is correct". This repository stores
//  the answer, its atomic claims, and the claim→evidence contract so
//  the "Why this answer?" panel and future audits can reconstruct
//  exactly which files/chunks/events/entities supported each claim, and
//  which corpus snapshot the answer was produced against.
//

import Foundation

/// One persisted answer row (header). Claims + evidence hang off it via
/// the answer_claims / claim_evidence tables.
public struct StoredAnswer: Sendable, Identifiable, Hashable {
    public typealias ID = UUID

    public let id: ID
    public let question: String
    public let answerState: AnswerState
    public let corpusSnapshotID: UUID?
    public let body: String
    public let confidence: Double
    public let source: String?
    public let createdAt: Date

    public nonisolated init(
        id: ID = UUID(),
        question: String,
        answerState: AnswerState,
        corpusSnapshotID: UUID? = nil,
        body: String,
        confidence: Double,
        source: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.question = question
        self.answerState = answerState
        self.corpusSnapshotID = corpusSnapshotID
        self.body = body
        self.confidence = confidence
        self.source = source
        self.createdAt = createdAt
    }
}

public actor AnswerLedgerRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    /// Persist a VerifiedAnswer decomposed into the closed-corpus
    /// contract tables. Writes the answer header, one claim per
    /// contradiction-free answer body (support_status = answerState),
    /// and one claim_evidence row per citation. When the brain later
    /// produces true claim-level breakdowns, `persistClaims` can be
    /// used for the granular path.
    @discardableResult
    public func persist(
        question: String,
        answer: VerifiedAnswer,
        corpusSnapshotID: UUID?,
        at when: Date = Date()
    ) async throws -> UUID {
        let answerID = UUID()
        try await database.exec("""
        INSERT INTO answers
            (id, question, answer_state, corpus_snapshot_id, body, confidence, source, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """, [
            .uuid(answerID),
            .text(question),
            .text(answer.answerState.rawValue),
            corpusSnapshotID.map { .uuid($0) } ?? .null,
            .text(answer.body),
            .real(answer.confidence.value),
            .text(answer.source.rawValue),
            .real(when.timeIntervalSince1970)
        ])

        // One top-level claim representing the whole answer, tagged with
        // the answer's support state, plus its citations as evidence.
        let claimID = UUID()
        try await database.exec("""
        INSERT INTO answer_claims
            (id, answer_id, claim_text, support_status, confidence, ordinal, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """, [
            .uuid(claimID),
            .uuid(answerID),
            .text(answer.answerText ?? answer.body),
            .text(answer.answerState.rawValue),
            .real(answer.confidence.value),
            .integer(0),
            .real(when.timeIntervalSince1970)
        ])

        for citation in answer.citations {
            try await database.exec("""
            INSERT OR IGNORE INTO claim_evidence
                (claim_id, object_id, chunk_id, event_id, entity_id, evidence_role)
            VALUES (?, ?, ?, ?, ?, ?);
            """, [
                .uuid(claimID),
                .uuid(citation.objectID),
                citation.chunkID.map { .uuid($0) } ?? .null,
                citation.eventID.map { .uuid($0) } ?? .null,
                .null,
                .text("supports")
            ])
        }

        return answerID
    }

    public func recent(limit: Int = 100) async throws -> [StoredAnswer] {
        let rows = try await database.query("""
        SELECT id, question, answer_state, corpus_snapshot_id, body, confidence, source, created_at
        FROM answers
        ORDER BY created_at DESC
        LIMIT ?;
        """, [.integer(Int64(limit))])
        return rows.compactMap(decodeRow)
    }

    public func count() async throws -> Int {
        let rows = try await database.query("SELECT COUNT(*) FROM answers;", [])
        return Int(rows.first?.int(0) ?? 0)
    }

    // MARK: - Internals

    private func decodeRow(_ row: SQLRow) -> StoredAnswer? {
        guard
            let id = row.uuid(0),
            let question = row.string(1),
            let stateRaw = row.string(2),
            let body = row.string(4),
            let createdAtRaw = row.double(7)
        else { return nil }
        return StoredAnswer(
            id: id,
            question: question,
            answerState: AnswerState(rawValue: stateRaw) ?? .unknown,
            corpusSnapshotID: row.uuid(3),
            body: body,
            confidence: row.double(5) ?? 0,
            source: row.string(6),
            createdAt: Date(timeIntervalSince1970: createdAtRaw)
        )
    }
}
