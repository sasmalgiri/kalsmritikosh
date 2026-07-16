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
            (id, subject_kind, subject_id, action, prior_value, new_value, reviewer, reason, reviewed_at, reversal_of)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, [
            .uuid(review.id),
            .text(review.subjectKind.rawValue),
            .uuid(review.subjectID),
            .text(review.action.rawValue),
            review.priorValue.map { .text($0) } ?? .null,
            review.newValue.map { .text($0) } ?? .null,
            .text(review.reviewer),
            review.reason.map { .text($0) } ?? .null,
            .real(review.reviewedAt.timeIntervalSince1970),
            review.reversalOf.map { .uuid($0) } ?? .null
        ])
        return review.id
    }

    /// A5.8 — undo a prior review by appending a `.reverse` row that points at
    /// it. Nothing is deleted; the reversed review and its undo both remain in
    /// the history, and `latestBySubject` stops counting the reversed verdict.
    @discardableResult
    public func reverse(
        _ reviewID: UUID,
        subjectKind: FactSourceKind,
        subjectID: UUID,
        reviewer: String = "user",
        reason: String? = nil
    ) async throws -> UUID {
        try await record(FactReview(
            subjectKind: subjectKind,
            subjectID: subjectID,
            action: .reverse,
            reviewer: reviewer,
            reason: reason,
            reversalOf: reviewID
        ))
    }

    /// Latest verdict per subject id (max reviewed_at). Used as the overlay
    /// input to FactStatusClassifier.
    public func latestBySubject() async throws -> [UUID: FactReview] {
        let rows = try await database.query("""
        SELECT id, subject_kind, subject_id, action, prior_value, new_value, reviewer, reason, reviewed_at, reversal_of
        FROM fact_reviews
        ORDER BY reviewed_at ASC;
        """)
        return Self.effectiveVerdicts(rows.compactMap(decode))
    }

    /// A5.8 — the effective verdict per subject from an append-only review log.
    /// A `.reverse` row undoes the review it targets; the effective verdict is
    /// the latest review that is neither a reversal itself nor the target of
    /// one. Pure (testable without a database). `reviews` MUST be time-ascending.
    nonisolated static func effectiveVerdicts(_ reviews: [FactReview]) -> [UUID: FactReview] {
        let reversed = Set(reviews.compactMap { $0.action == .reverse ? $0.reversalOf : nil })
        var out: [UUID: FactReview] = [:]
        for r in reviews {   // ascending => last active write wins
            guard r.action != .reverse, !reversed.contains(r.id) else { continue }
            out[r.subjectID] = r
        }
        return out
    }

    /// Global review feed across ALL subjects, newest first — the human-
    /// decision half of the unified Audit view.
    public func recent(limit: Int = 300) async throws -> [FactReview] {
        let rows = try await database.query("""
        SELECT id, subject_kind, subject_id, action, prior_value, new_value, reviewer, reason, reviewed_at, reversal_of
        FROM fact_reviews ORDER BY reviewed_at DESC LIMIT ?;
        """, [.integer(Int64(limit))])
        return rows.compactMap(decode)
    }

    /// Full append-only history for one subject, newest first.
    public func history(forSubject id: UUID) async throws -> [FactReview] {
        let rows = try await database.query("""
        SELECT id, subject_kind, subject_id, action, prior_value, new_value, reviewer, reason, reviewed_at, reversal_of
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
            reversalOf: row.uuid(9),
            reviewedAt: Date(timeIntervalSince1970: at)
        )
    }
}
