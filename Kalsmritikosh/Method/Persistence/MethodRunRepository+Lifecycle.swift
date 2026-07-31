//
//  MethodRunRepository+Lifecycle.swift
//  Kalsmritikosh
//
//  PM-004 — the atomic lifecycle-plan primitive. MethodRunRepository remains the
//  ONE authoritative writer; there is no second lifecycle repository. One lifecycle
//  action executes in exactly one SAVEPOINT: revision CAS, optional content-revision
//  bump, run-status patch, optional review append, optional validation-batch append,
//  a lifecycle-event append, and exact aggregate reconstruction. A failure at any
//  stage leaves the run, its revisions, its status and its ledgers unchanged.
//

import Foundation

// MARK: - Plan types

/// The status patch a lifecycle action applies to the run row.
public nonisolated struct MethodLifecycleRunPatch: Sendable {
    public let toStatus: MethodRunStatus
    /// A content-epoch increment (reopen only) — invalidates stale gate decisions.
    public let contentChanged: Bool
    /// Set the completion timestamp to `now` (complete).
    public let setCompletedAt: Bool
    /// Clear the completion timestamp (reopen).
    public let clearCompletedAt: Bool
    /// The supersession successor (supersede only).
    public let supersededByRunID: UUID?

    public nonisolated init(
        toStatus: MethodRunStatus, contentChanged: Bool = false,
        setCompletedAt: Bool = false, clearCompletedAt: Bool = false,
        supersededByRunID: UUID? = nil
    ) {
        self.toStatus = toStatus
        self.contentChanged = contentChanged
        self.setCompletedAt = setCompletedAt
        self.clearCompletedAt = clearCompletedAt
        self.supersededByRunID = supersededByRunID
    }
}

/// One atomic lifecycle action: a run patch, an event, and optional review /
/// validation-batch appends — all in one savepoint.
public nonisolated struct MethodLifecyclePlan: Sendable {
    public let action: MethodLifecycleAction
    public let patch: MethodLifecycleRunPatch
    public let review: MethodReview?
    public let validationBatch: [MethodValidationResult]?
    public let actorKind: WorkflowDecisionActorKind
    public let actorIdentifier: String?
    public let reason: String?

    public nonisolated init(
        action: MethodLifecycleAction,
        patch: MethodLifecycleRunPatch,
        review: MethodReview? = nil,
        validationBatch: [MethodValidationResult]? = nil,
        actorKind: WorkflowDecisionActorKind,
        actorIdentifier: String? = nil,
        reason: String? = nil
    ) {
        self.action = action
        self.patch = patch
        self.review = review
        self.validationBatch = validationBatch
        self.actorKind = actorKind
        self.actorIdentifier = actorIdentifier
        self.reason = reason
    }
}

extension MethodRunRepository {

    /// Apply one lifecycle action atomically and return the exact reconstructed
    /// aggregate. `expectedRevision` guards optimistic concurrency; a stale value
    /// writes nothing.
    public func applyLifecyclePlan(
        runID: UUID, expectedRevision: Int, plan: MethodLifecyclePlan, now: Date
    ) async throws -> MethodRunAggregate {
        let sp = "mrr_life_\(Self.spSuffix(runID))\(expectedRevision)"
        return try await database.withSavepoint(sp) { db -> MethodRunAggregate in
            guard let current = try Self.reconstruct(db, runID: runID) else {
                throw MethodPersistenceError.runNotFound(runID)
            }
            let run = current.run

            // Optional review append is a HUMAN act (validated) and must belong to the run.
            if let review = plan.review {
                try review.validate()
                if let nodeID = review.nodeID {
                    try Self.requireOwned(db, table: "method_nodes", id: nodeID, runID: runID, what: "review node")
                }
                if let findingID = review.findingID {
                    try Self.requireOwned(db, table: "method_findings", id: findingID, runID: runID, what: "review finding")
                }
            }

            // Revision CAS + status patch (+ optional content-revision bump).
            let newCompletedAt: Date? = plan.patch.setCompletedAt ? now
                : (plan.patch.clearCompletedAt ? nil : run.completedAt)
            let newSuperseded: UUID? = plan.patch.supersededByRunID ?? run.supersededByRunID
            let sql = plan.patch.contentChanged
                ? """
                  UPDATE method_runs SET revision = revision + 1, content_revision = content_revision + 1,
                      status = ?, updated_at = ?, completed_at = ?, superseded_by_run_id = ?
                    WHERE id = ? AND revision = ?;
                  """
                : """
                  UPDATE method_runs SET revision = revision + 1,
                      status = ?, updated_at = ?, completed_at = ?, superseded_by_run_id = ?
                    WHERE id = ? AND revision = ?;
                  """
            try db.exec(sql, [
                .text(plan.patch.toStatus.rawValue), .date(now),
                newCompletedAt.map(SQLValue.date) ?? .null,
                newSuperseded.map(SQLValue.uuid) ?? .null,
                .uuid(runID), .integer(Int64(expectedRevision))])
            guard Int(try db.query("SELECT changes();").first?.int(0) ?? 0) == 1 else {
                throw MethodPersistenceError.revisionConflict(runID: runID, expected: expectedRevision)
            }

            let newRevision = expectedRevision + 1
            let newContentRevision = plan.patch.contentChanged ? run.contentRevision + 1 : run.contentRevision

            // Append the review, if any.
            if let r = plan.review {
                try db.exec("""
                    INSERT INTO method_reviews
                        (id, method_run_id, node_id, finding_id, action, actor_kind, actor_identifier,
                         comment, reviewed_at, review_key, reviewed_content_revision)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?);
                    """, [
                        .uuid(r.id), .uuid(runID), r.nodeID.map(SQLValue.uuid) ?? .null,
                        r.findingID.map(SQLValue.uuid) ?? .null, .text(r.action.rawValue),
                        .text(r.actorKind.rawValue), .text(r.actorIdentifier),
                        .optionalText(r.comment), .date(r.reviewedAt),
                        .text(r.reviewKey), .integer(Int64(r.reviewedContentRevision))])
            }

            // Append the validation batch, if any (one batch id, one evaluated revision).
            if let batch = plan.validationBatch {
                for v in batch {
                    try db.exec("""
                        INSERT INTO method_validation_results
                            (id, method_run_id, validator_id, validator_version, severity, code, message,
                             subject_kind, subject_id, created_at, validation_batch_id, evaluated_content_revision)
                        VALUES (?,?,?,?,?,?,?,?,?,?,?,?);
                        """, [
                            .uuid(v.id), .uuid(runID), .text(v.validatorID), .text(v.validatorVersion),
                            .text(v.severity.rawValue), .text(v.code), .text(v.message),
                            .text(v.subjectKind.rawValue), v.subjectID.map(SQLValue.uuid) ?? .null,
                            .date(v.createdAt), .uuid(v.validationBatchID), .integer(Int64(v.evaluatedContentRevision))])
                }
            }

            // Append the lifecycle event (sequence resolved inside this savepoint).
            let seq = Int(try db.query(
                "SELECT COALESCE(MAX(sequence), 0) + 1 FROM method_run_events WHERE method_run_id = ?;",
                [.uuid(runID)]).first?.int(0) ?? 1)
            try db.exec("""
                INSERT INTO method_run_events
                    (id, method_run_id, sequence, run_revision, content_revision, action,
                     from_status, to_status, actor_kind, actor_identifier, reason, occurred_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?);
                """, [
                    .uuid(UUID()), .uuid(runID), .integer(Int64(seq)), .integer(Int64(newRevision)),
                    .integer(Int64(newContentRevision)), .text(plan.action.rawValue),
                    .text(run.status.rawValue), .text(plan.patch.toStatus.rawValue),
                    .text(plan.actorKind.rawValue), .optionalText(plan.actorIdentifier),
                    .optionalText(plan.reason), .date(now)])

            guard let reopened = try Self.reconstruct(db, runID: runID) else {
                throw MethodPersistenceError.runNotFound(runID)
            }
            return reopened
        }
    }

    // MARK: - Shared synchronous reconstruction (used by aggregate() and lifecycle)

    static func reconstruct(_ db: isolated Database, runID: UUID) throws -> MethodRunAggregate? {
        guard let run = try db.query(
            "SELECT \(runColumns) FROM method_runs WHERE id = ?;", [.uuid(runID)])
            .first.flatMap(decodeRun) else { return nil }
        let nodes = try db.query(
            "SELECT \(nodeColumns) FROM method_nodes WHERE method_run_id = ? ORDER BY ordinal, id;",
            [.uuid(runID)]).compactMap(decodeNode)
        let edges = try db.query(
            "SELECT \(edgeColumns) FROM method_edges WHERE method_run_id = ? ORDER BY ordinal, id;",
            [.uuid(runID)]).compactMap(decodeEdge)
        let links = try db.query(
            "SELECT \(linkColumns) FROM method_evidence_links WHERE method_run_id = ? ORDER BY ordinal, id;",
            [.uuid(runID)]).compactMap(decodeLink)
        let assumptions = try db.query(
            "SELECT \(assumptionColumns) FROM method_assumptions WHERE method_run_id = ? ORDER BY rowid;",
            [.uuid(runID)]).compactMap(decodeAssumption)
        let findings = try db.query(
            "SELECT \(findingColumns) FROM method_findings WHERE method_run_id = ? ORDER BY created_at, id;",
            [.uuid(runID)]).compactMap(decodeFinding)
        let reviews = try db.query(
            "SELECT \(reviewColumns) FROM method_reviews WHERE method_run_id = ? ORDER BY reviewed_at, id;",
            [.uuid(runID)]).compactMap(decodeReview)
        let validations = try db.query(
            "SELECT \(validationColumns) FROM method_validation_results WHERE method_run_id = ? ORDER BY created_at, id;",
            [.uuid(runID)]).compactMap(decodeValidation)
        let events = try db.query(
            "SELECT \(eventColumns) FROM method_run_events WHERE method_run_id = ? ORDER BY sequence;",
            [.uuid(runID)]).compactMap(decodeEvent)
        return MethodRunAggregate(
            run: run, nodes: nodes, edges: edges, evidenceLinks: links,
            assumptions: assumptions, findings: findings, reviews: reviews,
            validationResults: validations, lifecycleEvents: events)
    }
}
