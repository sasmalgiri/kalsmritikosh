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
        var sequence = 0
        let sp = "invapprove_\(id.uuidString.replacingOccurrences(of: "-", with: ""))"
        do {
            try await database.exec("SAVEPOINT \(sp);")
            let header = try await database.query("SELECT id FROM investigation_cases WHERE id = ? LIMIT 1;", [.uuid(caseID)]).first
            guard header != nil else { throw InvestigationFindingsError.caseNotFound(caseID) }
            sequence = Int(try await database.query(
                "SELECT COALESCE(MAX(sequence), 0) FROM investigation_findings_approvals WHERE case_id = ?;", [.uuid(caseID)]).first?.int(0) ?? 0) + 1
            try await database.exec("""
                INSERT INTO investigation_findings_approvals (id, case_id, sequence, decision, work_product_run_id,
                    receipt_seal, scope_fingerprint, rationale, actor, created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .integer(Int64(sequence)), .text(decision.rawValue), .uuid(workProductRunID),
                      .text(cleanSeal), .text(scopeFingerprint.value), .text(cleanRationale), .text(cleanActor), .date(date)])
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(sp);")
            try? await database.exec("RELEASE SAVEPOINT \(sp);")
            throw error
        }
        return InvestigationFindingsApproval(id: id, caseID: caseID, sequence: sequence, decision: decision,
                                             workProductRunID: workProductRunID, receiptSeal: cleanSeal,
                                             scopeFingerprint: scopeFingerprint, rationale: cleanRationale,
                                             actor: cleanActor, createdAt: date)
    }

    private let selectAll = """
        SELECT id, case_id, sequence, decision, work_product_run_id, receipt_seal, scope_fingerprint, rationale, actor, created_at
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
                                             actor: actor, createdAt: created)
    }
}
