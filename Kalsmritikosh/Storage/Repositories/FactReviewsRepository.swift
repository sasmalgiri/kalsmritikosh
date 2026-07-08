//
//  FactReviewsRepository.swift
//  Kalsmritikosh
//
//  T17 — append-only human-review ledger (schema v33). Every accept/reject/
//  correct is a new row; nothing is UPDATEd or DELETEd, so the full review
//  history of any fact survives (§12.9). `latestBySubject` returns the most
//  recent verdict per subject for the Fact Status Matrix overlay.
//

import Foundation

public actor FactReviewsRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    /// Append a review. Returns the new row id. Never overwrites history.
    @discardableResult
    public func record(_ review: FactReview) async throws -> UUID {
        try await database.exec("""
        INSERT INTO fact_reviews
            (id, subject_kind, subject_id, action, prior_value, new_value, reviewer, reason, reviewed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, [
            .uuid(review.id),
            .text(review.subjectKind.rawValue),
            .uuid(review.subjectID),
            .text(review.action.rawValue),
            review.priorValue.map { .text($0) } ?? .null,
            review.newValue.map { .text($0) } ?? .null,
            .text(review.reviewer),
            review.reason.map { .text($0) } ?? .null,
            .real(review.reviewedAt.timeIntervalSince1970)
        ])
        return review.id
    }

    /// Latest verdict per subject id (max reviewed_at). Used as the overlay
    /// input to FactStatusClassifier.
    public func latestBySubject() async throws -> [UUID: FactReview] {
        let rows = try await database.query("""
        SELECT id, subject_kind, subject_id, action, prior_value, new_value, reviewer, reason, reviewed_at
        FROM fact_reviews
        ORDER BY reviewed_at ASC;
        """)
        // Ascending order + last-write-wins in the dictionary => latest kept.
        var out: [UUID: FactReview] = [:]
        for row in rows {
            guard let r = decode(row) else { continue }
            out[r.subjectID] = r
        }
        return out
    }

    /// Full append-only history for one subject, newest first.
    public func history(forSubject id: UUID) async throws -> [FactReview] {
        let rows = try await database.query("""
        SELECT id, subject_kind, subject_id, action, prior_value, new_value, reviewer, reason, reviewed_at
        FROM fact_reviews WHERE subject_id = ? ORDER BY reviewed_at DESC;
        """, [.uuid(id)])
        return rows.compactMap(decode)
    }

    public func count() async throws -> Int {
        let rows = try await database.query("SELECT COUNT(*) FROM fact_reviews;", [])
        return Int(rows.first?.int(0) ?? 0)
    }

    // MARK: - Internals

    private func decode(_ row: SQLRow) -> FactReview? {
        guard
            let id = row.uuid(0),
            let kindRaw = row.string(1),
            let kind = FactSourceKind(rawValue: kindRaw),
            let subjectID = row.uuid(2),
            let actionRaw = row.string(3),
            let action = FactReview.Action(rawValue: actionRaw),
            let reviewer = row.string(6),
            let at = row.double(8)
        else { return nil }
        return FactReview(
            id: id,
            subjectKind: kind,
            subjectID: subjectID,
            action: action,
            priorValue: row.string(4),
            newValue: row.string(5),
            reviewer: reviewer,
            reason: row.string(7),
            reviewedAt: Date(timeIntervalSince1970: at)
        )
    }
}
