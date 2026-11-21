//
//  AnswerLedgerRepository+ReviewFlags.swift
//  Kalsmritikosh
//
//  Unified path AI-26 (owner 2026-11-22) — not tested yet. A shipped answer is terminal and is
//  never rewritten; when an independent AI reading of the same evidence (ComposeTwin) gives a
//  different value, a "Needs review" flag is recorded BESIDE the answer (v200
//  answer_review_flags, fixed once written) and the Answer Journal shows it.
//

import Foundation

public struct AnswerReviewFlag: Sendable, Hashable {
    public let answerID: UUID
    public let origin: String
    public let detail: String
    public let createdAt: Date
}

extension AnswerLedgerRepository {

    /// Mark a committed answer "Needs review". `origin` names what raised it ("composeTwin").
    public func flagNeedsReview(answerID: UUID, origin: String, detail: String, at when: Date = Date()) async throws {
        try await database.exec("""
        INSERT INTO answer_review_flags (id, answer_id, flag, origin, detail, created_at)
        VALUES (?, ?, 'needsReview', ?, ?, ?);
        """, [.uuid(UUID()), .uuid(answerID), .text(origin), .text(detail), .real(when.timeIntervalSince1970)])
    }

    /// The review flags on one answer, oldest first.
    public func reviewFlags(answerID: UUID) async throws -> [AnswerReviewFlag] {
        try await database.query("""
        SELECT answer_id, origin, detail, created_at FROM answer_review_flags
        WHERE answer_id = ? ORDER BY created_at ASC;
        """, [.uuid(answerID)]).compactMap { row in
            guard let id = row.uuid(0), let origin = row.string(1), let detail = row.string(2) else { return nil }
            return AnswerReviewFlag(answerID: id, origin: origin, detail: detail,
                                    createdAt: Date(timeIntervalSince1970: row.double(3) ?? 0))
        }
    }
}
