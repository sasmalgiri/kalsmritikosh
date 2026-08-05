//
//  InvestigationClosureRepository.swift
//  Kalsmritikosh
//
//  INV-20 — the durable authority for case closure (schema v101 investigation_case_closures). Recording a
//  closure/reopen is ATOMIC with the case's status transition (one SAVEPOINT), so the case status and its
//  closure decision can never desync. The log is append-only: a reopen is a new row, never a rewrite of the
//  closure it follows, so the decision genealogy survives. This actor is the ONLY path that sets a case to
//  'closed' — there is no auto-close.
//

import Foundation

public actor InvestigationClosureRepository {
    private let database: Database

    public init(database: Database) { self.database = database }

    /// Close a case by a recorded human decision. Atomic: appends the closure row AND transitions the case
    /// to 'closed' (revision CAS). Fails if the case is missing, already closed, or the revision is stale.
    @discardableResult
    public func close(caseID: UUID, expectedRevision: Int, rationale: String, workProductRunID: UUID?,
                      scopeFingerprint: CaseScopeFingerprint, unresolvedItems: [String], receiptSeal: String?,
                      actor: String, at date: Date) async throws -> InvestigationClosureDecision {
        try await record(caseID: caseID, expectedRevision: expectedRevision, decision: .closed, newStatus: .closed,
                         requiredCurrentStatus: nil, rationale: rationale, workProductRunID: workProductRunID,
                         scopeFingerprint: scopeFingerprint, unresolvedItems: unresolvedItems, receiptSeal: receiptSeal,
                         actor: actor, at: date)
    }

    /// Reopen a closed case by a recorded human decision. Atomic: appends the reopen row AND transitions the
    /// case back to 'open'. The prior closure row is untouched (genealogy preserved). Fails if not closed.
    @discardableResult
    public func reopen(caseID: UUID, expectedRevision: Int, rationale: String,
                       scopeFingerprint: CaseScopeFingerprint, actor: String, at date: Date) async throws -> InvestigationClosureDecision {
        try await record(caseID: caseID, expectedRevision: expectedRevision, decision: .reopened, newStatus: .open,
                         requiredCurrentStatus: .closed, rationale: rationale, workProductRunID: nil,
                         scopeFingerprint: scopeFingerprint, unresolvedItems: [], receiptSeal: nil, actor: actor, at: date)
    }

    public func closures(caseID: UUID) async throws -> [InvestigationClosureDecision] {
        (try await database.query("\(selectAll) WHERE case_id = ? ORDER BY sequence ASC;", [.uuid(caseID)])).compactMap(decode)
    }
    public func latest(caseID: UUID) async throws -> InvestigationClosureDecision? {
        (try await database.query("\(selectAll) WHERE case_id = ? ORDER BY sequence DESC LIMIT 1;", [.uuid(caseID)])).first.flatMap(decode)
    }

    // MARK: - Internals

    private func record(caseID: UUID, expectedRevision: Int, decision: ClosureDecisionKind, newStatus: InvestigationCaseStatus,
                        requiredCurrentStatus: InvestigationCaseStatus?, rationale: String, workProductRunID: UUID?,
                        scopeFingerprint: CaseScopeFingerprint, unresolvedItems: [String], receiptSeal: String?,
                        actor: String, at date: Date) async throws -> InvestigationClosureDecision {
        let cleanRationale = rationale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanRationale.isEmpty else { throw InvestigationClosureError.blankRationale }
        let cleanActor = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanActor.isEmpty else { throw InvestigationClosureError.blankActor }
        let id = UUID()
        var sequence = 0
        let sp = "invclose_\(id.uuidString.replacingOccurrences(of: "-", with: ""))"
        do {
            try await database.exec("SAVEPOINT \(sp);")
            let header = try await database.query("SELECT status, revision FROM investigation_cases WHERE id = ? LIMIT 1;", [.uuid(caseID)]).first
            guard let header, let statusRaw = header.string(0), let revision = header.int(1),
                  let status = InvestigationCaseStatus(rawValue: statusRaw) else {
                throw InvestigationClosureError.caseNotFound(caseID)
            }
            if let requiredCurrentStatus {
                guard status == requiredCurrentStatus else { throw InvestigationClosureError.caseNotClosed(caseID) }
            } else if status == .closed {
                throw InvestigationClosureError.caseAlreadyClosed(caseID)
            }
            guard Int(revision) == expectedRevision else {
                throw InvestigationClosureError.revisionConflict(expected: expectedRevision, actual: Int(revision))
            }
            sequence = Int(try await database.query(
                "SELECT COALESCE(MAX(sequence), 0) FROM investigation_case_closures WHERE case_id = ?;", [.uuid(caseID)]).first?.int(0) ?? 0) + 1
            let unresolvedJSON = encodeUnresolved(unresolvedItems)
            try await database.exec("""
                INSERT INTO investigation_case_closures (id, case_id, sequence, decision, rationale, work_product_run_id,
                    scope_fingerprint, unresolved_json, receipt_seal, actor, created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .integer(Int64(sequence)), .text(decision.rawValue), .text(cleanRationale),
                      workProductRunID.map { SQLValue.uuid($0) } ?? .null, .text(scopeFingerprint.value), .text(unresolvedJSON),
                      receiptSeal.flatMap { $0.isEmpty ? nil : .text($0) } ?? .null, .text(cleanActor), .date(date)])
            try await database.exec("UPDATE investigation_cases SET status = ?, revision = ?, actor = ?, updated_at = ? WHERE id = ? AND revision = ?;",
                                    [.text(newStatus.rawValue), .integer(Int64(Int(revision) + 1)), .text(cleanActor), .date(date), .uuid(caseID), .integer(revision)])
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(sp);")
            try? await database.exec("RELEASE SAVEPOINT \(sp);")
            throw error
        }
        return InvestigationClosureDecision(id: id, caseID: caseID, sequence: sequence, decision: decision, rationale: cleanRationale,
                                            workProductRunID: workProductRunID, scopeFingerprint: scopeFingerprint,
                                            unresolvedItems: unresolvedItems, receiptSeal: receiptSeal?.isEmpty == true ? nil : receiptSeal,
                                            actor: cleanActor, createdAt: date)
    }

    private let selectAll = """
        SELECT id, case_id, sequence, decision, rationale, work_product_run_id, scope_fingerprint, unresolved_json, receipt_seal, actor, created_at
        FROM investigation_case_closures
        """

    private nonisolated func decode(_ r: SQLRow) -> InvestigationClosureDecision? {
        guard let id = r.uuid(0), let caseID = r.uuid(1), let seq = r.int(2),
              let decision = r.string(3).flatMap(ClosureDecisionKind.init(rawValue:)), let rationale = r.string(4),
              let fp = r.string(6), let actor = r.string(9), let created = r.date(10) else { return nil }
        return InvestigationClosureDecision(id: id, caseID: caseID, sequence: Int(seq), decision: decision, rationale: rationale,
                                            workProductRunID: r.uuid(5), scopeFingerprint: CaseScopeFingerprint(value: fp),
                                            unresolvedItems: decodeUnresolved(r.string(7)), receiptSeal: r.string(8),
                                            actor: actor, createdAt: created)
    }

    private nonisolated func encodeUnresolved(_ items: [String]) -> String {
        let clean = items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard let data = try? JSONEncoder().encode(clean), let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }
    private nonisolated func decodeUnresolved(_ raw: String?) -> [String] {
        guard let raw, let data = raw.data(using: .utf8), let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return arr
    }
}
