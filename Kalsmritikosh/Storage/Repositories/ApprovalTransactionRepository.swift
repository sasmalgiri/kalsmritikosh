//
//  ApprovalTransactionRepository.swift
//  Kalsmritikosh
//
//  PHASE C (seventh audit) — the durable approval state machine. The strict-
//  mode approval act commits THREE writes in ONE savepoint, synchronously
//  isolated on the Database actor (no suspension points inside the barrier):
//
//    1. the findings-approval decision row  (investigation_findings_approvals)
//    2. the sealed conformance assessment   (conformance_assessments,
//                                            approval_state = 'approved')
//    3. the governance event                (governance_events)
//
//  Any failure rolls all three back: an approval STRUCTURALLY cannot exist
//  without its recorded assessment, and 'approved' on an assessment row can
//  only ever have been written together with its approval row. The
//  pending → assessed → sealed → approved states never persist individually
//  because the transition is a single transaction — compensation is gone.
//
//  Drift guard: tests read the composite's rows back through the ORIGINAL
//  repositories (InvestigationFindingsApprovalRepository /
//  ConformanceAssessmentRepository), proving column compatibility.
//

import Foundation

/// The approval decision the composite writes — same fields the
/// InvestigationFindingsApprovalRepository records.
public nonisolated struct AtomicApprovalWrite: Sendable {
    public let caseID: UUID
    public let workProductRunID: UUID
    public let receiptSeal: String
    public let scopeFingerprint: String
    public let rationale: String
    public let actor: String
    public init(caseID: UUID, workProductRunID: UUID, receiptSeal: String,
                scopeFingerprint: String, rationale: String, actor: String) {
        self.caseID = caseID; self.workProductRunID = workProductRunID
        self.receiptSeal = receiptSeal; self.scopeFingerprint = scopeFingerprint
        self.rationale = rationale; self.actor = actor
    }
}

public nonisolated enum ApprovalTransactionError: Error, Equatable {
    case caseNotFound(UUID)
    case blankField(String)
    /// The assessment was sealed for a different revision than the one the
    /// transaction would assign (a concurrent recording slipped in between).
    case revisionRace(sealed: Int, actual: Int)
}

public actor ApprovalTransactionRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    /// The revision the NEXT recorded assessment will get — sealed into the
    /// envelope BEFORE the transaction; the transaction re-derives it inside
    /// the barrier and refuses on mismatch.
    public func nextRevision(caseID: UUID) async throws -> Int {
        let rows = try await database.query(
            "SELECT COALESCE(MAX(run_revision), 0) FROM conformance_assessments WHERE case_id = ?;",
            [.uuid(caseID)])
        return Int(rows.first?.int(0) ?? 0) + 1
    }

    /// Approve atomically: approval decision + sealed assessment + governance
    /// event, one savepoint. `seal` may be nil ONLY when the caller explicitly
    /// accepts an unsealed record (the strict-mode caller refuses first).
    public func approveAtomically(write: AtomicApprovalWrite,
                                  assessment: ConformanceAssessment,
                                  seal: SealedConformance?,
                                  sealedForRevision: Int,
                                  governanceDetail: String,
                                  at now: Date) async throws -> StoredConformanceAssessment {
        let rationale = write.rationale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rationale.isEmpty else { throw ApprovalTransactionError.blankField("rationale") }
        let actor = write.actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !actor.isEmpty else { throw ApprovalTransactionError.blankField("actor") }
        let receiptSeal = write.receiptSeal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !receiptSeal.isEmpty else { throw ApprovalTransactionError.blankField("receiptSeal") }

        // Serialize OUTSIDE the barrier (pure CPU).
        let evaluationsJSON = String(data: try ConformanceCanonical.data(of: assessment.evaluations), encoding: .utf8) ?? "[]"
        let sealJSON = try seal.map { String(data: try ConformanceCanonical.data(of: $0), encoding: .utf8) ?? "" }
        let factsJSON = try assessment.facts.map { String(data: try ConformanceCanonical.data(of: $0), encoding: .utf8) ?? "" }
        let manifestJSON = try assessment.evidenceManifest.map { String(data: try ConformanceCanonical.data(of: $0), encoding: .utf8) ?? "" }
        let approvalID = UUID()
        let assessmentID = UUID()
        let governanceID = UUID()
        let caseID = write.caseID
        let runID = write.workProductRunID
        let fingerprint = write.scopeFingerprint
        let spName = "approvecomposite_\(assessmentID.uuidString.replacingOccurrences(of: "-", with: ""))"

        let stored: StoredConformanceAssessment = try await database.withSavepoint(spName) { db in
            // Case must exist (same guard the approval repository applies).
            let caseRow = try db.query("SELECT id FROM investigation_cases WHERE id = ? LIMIT 1;", [.uuid(caseID)])
            guard caseRow.first != nil else { throw ApprovalTransactionError.caseNotFound(caseID) }

            // 1 — the approval decision row (next sequence, re-derived inside).
            let seq = Int(try db.query(
                "SELECT COALESCE(MAX(sequence), 0) FROM investigation_findings_approvals WHERE case_id = ?;",
                [.uuid(caseID)]).first?.int(0) ?? 0) + 1
            try db.exec("""
                INSERT INTO investigation_findings_approvals (id, case_id, sequence, decision, work_product_run_id,
                    receipt_seal, scope_fingerprint, rationale, actor, created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(approvalID), .uuid(caseID), .integer(Int64(seq)), .text("approved"), .uuid(runID),
                      .text(receiptSeal), .text(fingerprint), .text(rationale), .text(actor), .date(now)])

            // 2 — the assessment row, 'approved' state. The revision the seal
            // signed must be the revision the barrier derives — refuse a race.
            let revision = Int(try db.query(
                "SELECT COALESCE(MAX(run_revision), 0) FROM conformance_assessments WHERE case_id = ?;",
                [.uuid(caseID)]).first?.int(0) ?? 0) + 1
            guard revision == sealedForRevision else {
                throw ApprovalTransactionError.revisionRace(sealed: sealedForRevision, actual: revision)
            }
            try db.exec("""
            INSERT INTO conformance_assessments
                (id, case_id, run_revision, sutra_citation, sutra_sha256, sutra_snapshot_json,
                 evaluations_json, status, seal_json, assessed_at, created_at,
                 run_id, run_state_sha256, facts_json, evidence_manifest_json, approval_state)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'approved');
            """, [
                .uuid(assessmentID), .uuid(caseID), .integer(Int64(revision)),
                .text(assessment.sutraCitation), .text(assessment.sutraSHA256),
                .text(assessment.sutraSnapshotJSON), .text(evaluationsJSON),
                .text(assessment.status.rawValue), .optionalText(sealJSON),
                .date(assessment.assessedAt), .date(now),
                assessment.runID.map { SQLValue.uuid($0) } ?? .null,
                .optionalText(assessment.runStateSHA256),
                .optionalText(factsJSON), .optionalText(manifestJSON)
            ])

            // 3 — the governance event, in the SAME atom (no longer best-effort
            // for the approval act).
            try db.exec("""
            INSERT INTO governance_events (id, kind, case_id, actor, detail, occurred_at)
            VALUES (?, 'findings.approved', ?, ?, ?, ?);
            """, [.uuid(governanceID), .uuid(caseID), .text(actor), .text(governanceDetail),
                  .real(now.timeIntervalSince1970)])

            return StoredConformanceAssessment(id: assessmentID, caseID: caseID, runRevision: revision,
                                               assessment: assessment, seal: seal, createdAt: now)
        }
        return stored
    }

    /// Withdraw atomically: the withdrawal decision row and its governance
    /// event in one savepoint.
    public func withdrawAtomically(write: AtomicApprovalWrite,
                                   governanceDetail: String,
                                   at now: Date) async throws {
        let rationale = write.rationale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rationale.isEmpty else { throw ApprovalTransactionError.blankField("rationale") }
        let actor = write.actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !actor.isEmpty else { throw ApprovalTransactionError.blankField("actor") }
        let approvalID = UUID()
        let governanceID = UUID()
        let caseID = write.caseID
        let runID = write.workProductRunID
        let receiptSeal = write.receiptSeal
        let fingerprint = write.scopeFingerprint
        let spName = "withdrawcomposite_\(approvalID.uuidString.replacingOccurrences(of: "-", with: ""))"

        try await database.withSavepoint(spName) { db in
            let caseRow = try db.query("SELECT id FROM investigation_cases WHERE id = ? LIMIT 1;", [.uuid(caseID)])
            guard caseRow.first != nil else { throw ApprovalTransactionError.caseNotFound(caseID) }
            let seq = Int(try db.query(
                "SELECT COALESCE(MAX(sequence), 0) FROM investigation_findings_approvals WHERE case_id = ?;",
                [.uuid(caseID)]).first?.int(0) ?? 0) + 1
            try db.exec("""
                INSERT INTO investigation_findings_approvals (id, case_id, sequence, decision, work_product_run_id,
                    receipt_seal, scope_fingerprint, rationale, actor, created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(approvalID), .uuid(caseID), .integer(Int64(seq)), .text("withdrawn"), .uuid(runID),
                      .text(receiptSeal), .text(fingerprint), .text(rationale), .text(actor), .date(now)])
            try db.exec("""
            INSERT INTO governance_events (id, kind, case_id, actor, detail, occurred_at)
            VALUES (?, 'approval.withdrawn', ?, ?, ?, ?);
            """, [.uuid(governanceID), .uuid(caseID), .text(actor), .text(governanceDetail),
                  .real(now.timeIntervalSince1970)])
        }
    }
}
