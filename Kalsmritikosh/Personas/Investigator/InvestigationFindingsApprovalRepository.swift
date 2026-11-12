//
//  InvestigationFindingsApprovalRepository.swift
//  Kalsmritikosh
//
//  INV-19 — the durable authority for FINDINGS approval (schema v102 investigation_findings_approvals). The
//  findings work product itself is the SHARED WorkProductRun; this actor records only the explicit human
//  decision that a specific immutable findings run is APPROVED as the case's findings. The log is append-only:
//  a withdrawal is a new row, never a rewrite of the approval it follows, so the decision genealogy survives.
//  Approval NEVER changes case status — closing a case is a separate human decision (INV-20). Approval is
//  never inferred (build / workflow / method completion / confidence / no-contradiction do not approve).
//

import Foundation

public actor InvestigationFindingsApprovalRepository {
    private let database: Database

    public init(database: Database) { self.database = database }

    /// Approve a specific findings run as the case's findings, by a recorded human decision. Appends an
    /// `approved` row pinned to the run, its sealed receipt, and the case scope fingerprint the findings were
    /// built under. Fails if the case is missing or rationale / actor / receipt seal is blank.
    @discardableResult
    public func approve(caseID: UUID, workProductRunID: UUID, receiptSeal: String,
                        scopeFingerprint: CaseScopeFingerprint, rationale: String, actor: String,
                        at date: Date) async throws -> InvestigationFindingsApproval {
        try await record(caseID: caseID, decision: .approved, workProductRunID: workProductRunID,
                         receiptSeal: receiptSeal, scopeFingerprint: scopeFingerprint, rationale: rationale,
                         actor: actor, at: date)
    }

    /// Withdraw approval of a findings run, by a recorded human decision. Appends a `withdrawn` row; the prior
    /// approval row is untouched (genealogy preserved).
    @discardableResult
    public func withdraw(caseID: UUID, workProductRunID: UUID, receiptSeal: String,
                         scopeFingerprint: CaseScopeFingerprint, rationale: String, actor: String,
                         at date: Date) async throws -> InvestigationFindingsApproval {
        try await record(caseID: caseID, decision: .withdrawn, workProductRunID: workProductRunID,
                         receiptSeal: receiptSeal, scopeFingerprint: scopeFingerprint, rationale: rationale,
                         actor: actor, at: date)
    }

    public func approvals(caseID: UUID) async throws -> [InvestigationFindingsApproval] {
        (try await database.query("\(selectAll) WHERE case_id = ? ORDER BY sequence ASC;", [.uuid(caseID)])).compactMap(decode)
    }
    public func latest(caseID: UUID) async throws -> InvestigationFindingsApproval? {
        (try await database.query("\(selectAll) WHERE case_id = ? ORDER BY sequence DESC LIMIT 1;", [.uuid(caseID)])).first.flatMap(decode)
    }

    // MARK: - Internals

    private func record(caseID: UUID, decision: FindingsApprovalKind, workProductRunID: UUID, receiptSeal: String,
                        scopeFingerprint: CaseScopeFingerprint, rationale: String, actor: String,
                        at date: Date) async throws -> InvestigationFindingsApproval {
        let cleanRationale = rationale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanRationale.isEmpty else { throw InvestigationFindingsError.blankRationale }
        let cleanActor = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanActor.isEmpty else { throw InvestigationFindingsError.blankActor }
        let cleanSeal = receiptSeal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSeal.isEmpty else { throw InvestigationFindingsError.blankReceiptSeal }
        let id = UUID()
        let sp = "invapprove_\(id.uuidString.replacingOccurrences(of: "-", with: ""))"
        let fingerprint = scopeFingerprint.value
        // F28 — case check, sequence allocation and insert in ONE isolated savepoint.
        let sequence = try await database.withSavepoint(sp) { db -> (Int, CaseReviewKind?) in
            let header = try db.query("SELECT id FROM investigation_cases WHERE id = ? LIMIT 1;", [.uuid(caseID)]).first
            guard header != nil else { throw InvestigationFindingsError.caseNotFound(caseID) }
            // S9 (ACCESS-09) — approving or withdrawing the case's findings is a review decision: in a team case only a
            // person holding the owner or reviewer role may record it (checked here, inside the decision's savepoint).
            try CaseAccessPolicy.require(db, caseID: caseID, actor: cleanActor, .review)
            // S14 (ACCESS-10) — was the run built by the approver? Refused when the case requires an independent reviewer.
            let kind = decision == .approved
                ? try FindingsBuilds.reviewKind(db, caseID: caseID, runID: workProductRunID, approver: cleanActor) : nil
            let next = Int(try db.query(
                "SELECT COALESCE(MAX(sequence), 0) FROM investigation_findings_approvals WHERE case_id = ?;", [.uuid(caseID)]).first?.int(0) ?? 0) + 1
            try db.exec("""
                INSERT INTO investigation_findings_approvals (id, case_id, sequence, decision, work_product_run_id,
                    receipt_seal, scope_fingerprint, rationale, actor, created_at, review_kind)
                VALUES (?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .integer(Int64(next)), .text(decision.rawValue), .uuid(workProductRunID),
                      .text(cleanSeal), .text(fingerprint), .text(cleanRationale), .text(cleanActor), .date(date),
                      .optionalText(kind?.rawValue)])
            return (next, kind)
        }
        return InvestigationFindingsApproval(id: id, caseID: caseID, sequence: sequence.0, decision: decision,
                                             workProductRunID: workProductRunID, receiptSeal: cleanSeal,
                                             scopeFingerprint: scopeFingerprint, rationale: cleanRationale,
                                             actor: cleanActor, createdAt: date, reviewKind: sequence.1)
    }

    private let selectAll = """
        SELECT id, case_id, sequence, decision, work_product_run_id, receipt_seal, scope_fingerprint, rationale, actor, created_at,
               review_kind
        FROM investigation_findings_approvals
        """

    private nonisolated func decode(_ r: SQLRow) -> InvestigationFindingsApproval? {
        guard let id = r.uuid(0), let caseID = r.uuid(1), let seq = r.int(2),
              let decision = r.string(3).flatMap(FindingsApprovalKind.init(rawValue:)),
              let runID = r.uuid(4), let seal = r.string(5), let fp = r.string(6),
              let rationale = r.string(7), let actor = r.string(8), let created = r.date(9) else { return nil }
        return InvestigationFindingsApproval(id: id, caseID: caseID, sequence: Int(seq), decision: decision,
                                             workProductRunID: runID, receiptSeal: seal,
                                             scopeFingerprint: CaseScopeFingerprint(value: fp), rationale: rationale,
                                             actor: actor, createdAt: created,
                                             reviewKind: r.string(10).flatMap(CaseReviewKind.init(rawValue:)))
    }

    // MARK: - Audit chain (implementation brief §5)

    /// Every findings approval and withdrawal, pinned to its run, receipt seal and scope fingerprint.
    public func auditChainEvents() async throws -> [AuditChainEvent] {
        try await database.query("""
            SELECT id, case_id, sequence, decision, work_product_run_id, receipt_seal, scope_fingerprint, rationale, actor, created_at
            FROM investigation_findings_approvals ORDER BY created_at ASC, case_id ASC, sequence ASC;
            """, []).compactMap { r in
            guard let id = r.uuid(0), let c = r.uuid(1), let seq = r.int(2), let decision = r.string(3), let run = r.string(4),
                  let seal = r.string(5), let fp = r.string(6), let actor = r.string(8), let at = r.date(9) else { return nil }
            let payload = "actor=\(actor);at=\(at.timeIntervalSince1970);caseID=\(c.uuidString);decision=\(decision);"
                + "rationaleDigest=\(CaseFileHash.sha256(r.string(7) ?? ""));receiptSeal=\(seal);run=\(run);scope=\(fp);sequence=\(seq)"
            return AuditChainEvent(source: .findingsApproval, eventID: id, occurredAt: at, canonicalPayload: payload)
        }
    }
}

/// S14 (ACCESS-10) — who built each findings run (schema v189 investigation_findings_builds), and whether an approval of the
/// run is by its builder. Written inside the run's own savepoint; read inside the approval's savepoint.
public nonisolated enum FindingsBuilds {
    /// Record that `builtBy` built `runID` for `caseID`. A blank name records nothing (the builder stays "not recorded").
    static func record(_ db: isolated Database, runID: UUID, caseID: UUID, builtBy: String, at date: Date) throws {
        let who = builtBy.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !who.isEmpty else { return }
        try db.exec("INSERT INTO investigation_findings_builds (run_id, case_id, built_by, built_at) VALUES (?,?,?,?);",
                    [.uuid(runID), .uuid(caseID), .text(who), .date(date)])
    }

    /// The recorded builder of `runID`, or nil when none was recorded.
    static func builder(_ db: isolated Database, runID: UUID) throws -> String? {
        try db.query("SELECT built_by FROM investigation_findings_builds WHERE run_id = ? LIMIT 1;", [.uuid(runID)]).first?.string(0)
    }

    /// `.selfReview` when `approver` built the run, `.independent` when someone else did, nil when the builder is not
    /// recorded. Throws `CaseActionWorkError.independentReviewRequired` when the approver built it and the case's policy
    /// requires an independent reviewer — the requirement stays unmet; no approval is fabricated.
    static func reviewKind(_ db: isolated Database, caseID: UUID, runID: UUID, approver: String) throws -> CaseReviewKind? {
        guard let builder = try builder(db, runID: runID) else { return nil }
        let same = CaseConflictMatcher.normalise(builder) == CaseConflictMatcher.normalise(approver)
        if same, try CaseAutomationPolicyStore.requiresIndependentReview(db, caseID: caseID) {
            throw CaseActionWorkError.independentReviewRequired
        }
        return same ? .selfReview : .independent
    }
}
