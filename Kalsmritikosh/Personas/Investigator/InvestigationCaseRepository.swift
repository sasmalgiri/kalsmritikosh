//
//  InvestigationCaseRepository.swift
//  Kalsmritikosh
//
//  INV-01-A — the durable authority for Investigator case intake & scope (schema v96). Every mutation is
//  one SAVEPOINT with optimistic revision CAS and an append-only event, so a case (its scope statement,
//  time window, the in-scope source set, scope confirmation, and any bound deadline) survives relaunch
//  and is provable. This actor REFERENCES canonical identities by id only — a workspace id, a source
//  reference, a confirmed `deadlines` row — and never copies, mutates, or forks any canonical evidence,
//  task, deadline, workflow or SensitiveScope authority.
//
//  Two truth boundaries are enforced here, not merely documented:
//    • available-in-workspace ≠ authorized-for-this-case — only sources added in-scope are authorized.
//    • possible deadline ≠ confirmed deadline — `bindConfirmedDeadline` refuses an id that is not present
//      in the canonical confirmed `deadlines` table (a `deadline_candidates` row can never bind).
//

import Foundation

public actor InvestigationCaseRepository {
    private let database: Database

    public init(database: Database) { self.database = database }

    // MARK: - Intake

    /// Create a new case anchored to an existing workspace. Fails if the workspace does not exist or the
    /// title/actor is blank. The case starts `open`, revision 1, with a `created` audit event.
    public func createCase(workspaceID: UUID, title: String, purpose: String? = nil,
                           scopeStatement: String? = nil, outOfScopeStatement: String? = nil,
                           timeWindowStart: Date? = nil, timeWindowEnd: Date? = nil,
                           possibleDeadlineNote: String? = nil, actor: String, at date: Date) async throws -> InvestigationCase {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { throw InvestigationCaseError.blankTitle }
        let cleanActor = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanActor.isEmpty else { throw InvestigationCaseError.blankActor }
        let workspaceExists = try await database.query(
            "SELECT 1 FROM workspaces WHERE id = ? LIMIT 1;", [.uuid(workspaceID)]).first != nil
        guard workspaceExists else { throw InvestigationCaseError.workspaceNotFound(workspaceID) }

        let id = UUID()
        let sp = savepoint("invcase", id)
        do {
            try await database.exec("SAVEPOINT \(sp);")
            try await database.exec("""
                INSERT INTO investigation_cases (id, workspace_id, title, purpose, scope_statement, out_of_scope_statement,
                    time_window_start, time_window_end, status, confirmed_deadline_id, possible_deadline_note, revision, actor, created_at, updated_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(workspaceID), .text(cleanTitle), opt(purpose), opt(scopeStatement), opt(outOfScopeStatement),
                      optDate(timeWindowStart), optDate(timeWindowEnd), .text(InvestigationCaseStatus.open.rawValue), .null,
                      opt(possibleDeadlineNote), .integer(1), .text(cleanActor), .date(date), .date(date)])
            try await appendEvent(caseID: id, revision: 1, action: .created, actor: cleanActor, detail: cleanTitle, at: date)
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(sp);")
            try? await database.exec("RELEASE SAVEPOINT \(sp);")
            throw error
        }
        return try await requireHeader(id)
    }

    // MARK: - Scope

    /// Revise the scope framing (scope / out-of-scope statements, time window, advisory possible-deadline
    /// note). Optimistic CAS on `expectedRevision`; bumps revision and records a `scopeSet` event.
    public func updateScope(caseID: UUID, expectedRevision: Int, scopeStatement: String?, outOfScopeStatement: String?,
                            timeWindowStart: Date?, timeWindowEnd: Date?, possibleDeadlineNote: String? = nil,
                            actor: String, at date: Date) async throws -> InvestigationCase {
        let cleanActor = try validatedActor(actor)
        let sp = savepoint("invscope", caseID)
        do {
            try await database.exec("SAVEPOINT \(sp);")
            let header = try await requireMutableHeader(caseID, expectedRevision: expectedRevision)
            let newRevision = header.revision + 1
            try await database.exec("""
                UPDATE investigation_cases SET scope_statement = ?, out_of_scope_statement = ?, time_window_start = ?,
                    time_window_end = ?, possible_deadline_note = ?, revision = ?, actor = ?, updated_at = ?
                WHERE id = ? AND revision = ?;
                """, [opt(scopeStatement), opt(outOfScopeStatement), optDate(timeWindowStart), optDate(timeWindowEnd),
                      opt(possibleDeadlineNote), .integer(Int64(newRevision)), .text(cleanActor), .date(date),
                      .uuid(caseID), .integer(Int64(header.revision))])
            try await appendEvent(caseID: caseID, revision: newRevision, action: .scopeSet, actor: cleanActor, detail: nil, at: date)
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(sp);")
            try? await database.exec("RELEASE SAVEPOINT \(sp);")
            throw error
        }
        return try await requireHeader(caseID)
    }

    /// Add (or re-include) a canonical source in-scope — this is what authorizes it for the investigation.
    public func includeSource(caseID: UUID, expectedRevision: Int, sourceRef: String, sourceKind: InvestigationSourceKind,
                              note: String? = nil, actor: String, at date: Date) async throws -> InvestigationCase {
        try await setSourceDisposition(caseID: caseID, expectedRevision: expectedRevision, sourceRef: sourceRef,
                                       sourceKind: sourceKind, inScope: true, note: note, actor: actor, at: date)
    }

    /// Explicitly exclude a canonical source from the investigation (recorded, not silently dropped).
    public func excludeSource(caseID: UUID, expectedRevision: Int, sourceRef: String, sourceKind: InvestigationSourceKind,
                              note: String? = nil, actor: String, at date: Date) async throws -> InvestigationCase {
        try await setSourceDisposition(caseID: caseID, expectedRevision: expectedRevision, sourceRef: sourceRef,
                                       sourceKind: sourceKind, inScope: false, note: note, actor: actor, at: date)
    }

    private func setSourceDisposition(caseID: UUID, expectedRevision: Int, sourceRef: String,
                                      sourceKind: InvestigationSourceKind, inScope: Bool, note: String?,
                                      actor: String, at date: Date) async throws -> InvestigationCase {
        let cleanActor = try validatedActor(actor)
        let cleanRef = sourceRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanRef.isEmpty else { throw InvestigationCaseError.blankSourceRef }
        let sp = savepoint("invsrc", caseID)
        do {
            try await database.exec("SAVEPOINT \(sp);")
            let header = try await requireMutableHeader(caseID, expectedRevision: expectedRevision)
            let newRevision = header.revision + 1
            // One disposition per (case, source): replace any prior binding for this reference.
            try await database.exec("DELETE FROM investigation_case_sources WHERE case_id = ? AND source_ref = ?;",
                                    [.uuid(caseID), .text(cleanRef)])
            try await database.exec("""
                INSERT INTO investigation_case_sources (id, case_id, source_ref, source_kind, in_scope, note, created_at)
                VALUES (?,?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(caseID), .text(cleanRef), .text(sourceKind.rawValue),
                      .integer(inScope ? 1 : 0), opt(note), .date(date)])
            try await database.exec("UPDATE investigation_cases SET revision = ?, actor = ?, updated_at = ? WHERE id = ? AND revision = ?;",
                                    [.integer(Int64(newRevision)), .text(cleanActor), .date(date), .uuid(caseID), .integer(Int64(header.revision))])
            try await appendEvent(caseID: caseID, revision: newRevision,
                                  action: inScope ? .sourceIncluded : .sourceExcluded, actor: cleanActor, detail: cleanRef, at: date)
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(sp);")
            try? await database.exec("RELEASE SAVEPOINT \(sp);")
            throw error
        }
        return try await requireHeader(caseID)
    }

    /// Confirm the scope: the human has decided the case boundary is settled (open → scopeConfirmed).
    /// This is a human decision the engine records; it never decides case merits itself.
    public func confirmScope(caseID: UUID, expectedRevision: Int, actor: String, at date: Date) async throws -> InvestigationCase {
        try await setStatus(caseID: caseID, expectedRevision: expectedRevision, to: .scopeConfirmed,
                            action: .scopeConfirmed, actor: actor, at: date)
    }

    /// Reopen a confirmed scope for further intake (scopeConfirmed → open).
    public func reopenScope(caseID: UUID, expectedRevision: Int, actor: String, at date: Date) async throws -> InvestigationCase {
        try await setStatus(caseID: caseID, expectedRevision: expectedRevision, to: .open,
                            action: .reopened, actor: actor, at: date)
    }

    private func setStatus(caseID: UUID, expectedRevision: Int, to status: InvestigationCaseStatus,
                           action: InvestigationCaseEventAction, actor: String, at date: Date) async throws -> InvestigationCase {
        let cleanActor = try validatedActor(actor)
        let sp = savepoint("invstat", caseID)
        do {
            try await database.exec("SAVEPOINT \(sp);")
            let header = try await requireMutableHeader(caseID, expectedRevision: expectedRevision)
            let newRevision = header.revision + 1
            try await database.exec("UPDATE investigation_cases SET status = ?, revision = ?, actor = ?, updated_at = ? WHERE id = ? AND revision = ?;",
                                    [.text(status.rawValue), .integer(Int64(newRevision)), .text(cleanActor), .date(date),
                                     .uuid(caseID), .integer(Int64(header.revision))])
            try await appendEvent(caseID: caseID, revision: newRevision, action: action, actor: cleanActor, detail: status.rawValue, at: date)
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(sp);")
            try? await database.exec("RELEASE SAVEPOINT \(sp);")
            throw error
        }
        return try await requireHeader(caseID)
    }

    // MARK: - Deadline (possible ≠ confirmed)

    /// Bind a CONFIRMED deadline to the case. The id MUST exist in the canonical `deadlines` table; a
    /// possible/candidate deadline can never bind here. Records a `deadlineBound` event.
    public func bindConfirmedDeadline(caseID: UUID, expectedRevision: Int, deadlineID: UUID,
                                      actor: String, at date: Date) async throws -> InvestigationCase {
        let cleanActor = try validatedActor(actor)
        let sp = savepoint("invddl", caseID)
        do {
            try await database.exec("SAVEPOINT \(sp);")
            let header = try await requireMutableHeader(caseID, expectedRevision: expectedRevision)
            // Reference check against the canonical confirmed deadlines table — read-only, no fork.
            let confirmed = try await database.query("SELECT 1 FROM deadlines WHERE id = ? LIMIT 1;", [.uuid(deadlineID)]).first != nil
            guard confirmed else { throw InvestigationCaseError.deadlineNotConfirmed(deadlineID) }
            let newRevision = header.revision + 1
            try await database.exec("UPDATE investigation_cases SET confirmed_deadline_id = ?, revision = ?, actor = ?, updated_at = ? WHERE id = ? AND revision = ?;",
                                    [.uuid(deadlineID), .integer(Int64(newRevision)), .text(cleanActor), .date(date),
                                     .uuid(caseID), .integer(Int64(header.revision))])
            try await appendEvent(caseID: caseID, revision: newRevision, action: .deadlineBound, actor: cleanActor, detail: deadlineID.uuidString, at: date)
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(sp);")
            try? await database.exec("RELEASE SAVEPOINT \(sp);")
            throw error
        }
        return try await requireHeader(caseID)
    }

    // MARK: - Read / resume

    /// Reconstruct the full durable case (header + source dispositions + audit) — the reopen anchor.
    public func fetch(caseID: UUID) async throws -> InvestigationCaseRecord? {
        guard let header = try await loadHeader(caseID) else { return nil }
        let sources = try await loadSources(caseID)
        let events = try await loadEvents(caseID)
        return InvestigationCaseRecord(caseHeader: header, sources: sources, events: events)
    }

    /// The HARD evidence boundary as a convenience: the in-scope source references for a case, sorted.
    public func authorizedSourceRefs(caseID: UUID) async throws -> [String] {
        (try await fetch(caseID: caseID))?.authorizedSourceRefs ?? []
    }

    /// All cases in a workspace, oldest first.
    public func listCases(workspaceID: UUID) async throws -> [InvestigationCase] {
        let rows = try await database.query(
            "\(headerSelect) WHERE workspace_id = ? ORDER BY created_at ASC, id ASC;", [.uuid(workspaceID)])
        return rows.compactMap { decodeHeader($0) }
    }

    // MARK: - Internals

    private let headerSelect = """
        SELECT id, workspace_id, title, purpose, scope_statement, out_of_scope_statement, time_window_start,
               time_window_end, status, confirmed_deadline_id, possible_deadline_note, revision, actor, created_at, updated_at
        FROM investigation_cases
        """

    private func loadHeader(_ caseID: UUID) async throws -> InvestigationCase? {
        let rows = try await database.query("\(headerSelect) WHERE id = ? LIMIT 1;", [.uuid(caseID)])
        return rows.first.flatMap { decodeHeader($0) }
    }

    private func requireHeader(_ caseID: UUID) async throws -> InvestigationCase {
        guard let header = try await loadHeader(caseID) else { throw InvestigationCaseError.caseNotFound(caseID) }
        return header
    }

    /// A mutation precondition: the case exists, is not closed, and matches the expected revision.
    private func requireMutableHeader(_ caseID: UUID, expectedRevision: Int) async throws -> InvestigationCase {
        let header = try await requireHeader(caseID)
        guard header.status != .closed else { throw InvestigationCaseError.caseClosed(caseID) }
        guard header.revision == expectedRevision else {
            throw InvestigationCaseError.revisionConflict(expected: expectedRevision, actual: header.revision)
        }
        return header
    }

    private func loadSources(_ caseID: UUID) async throws -> [InvestigationScopeSource] {
        let rows = try await database.query("""
            SELECT id, case_id, source_ref, source_kind, in_scope, note, created_at
            FROM investigation_case_sources WHERE case_id = ? ORDER BY source_ref ASC;
            """, [.uuid(caseID)])
        return rows.compactMap { r in
            guard let id = r.uuid(0), let cid = r.uuid(1), let ref = r.string(2),
                  let kind = r.string(3).flatMap(InvestigationSourceKind.init(rawValue:)),
                  let inScope = r.int(4), let createdAt = r.date(6) else { return nil }
            return InvestigationScopeSource(id: id, caseID: cid, sourceRef: ref, sourceKind: kind,
                                            inScope: inScope != 0, note: r.string(5), createdAt: createdAt)
        }
    }

    private func loadEvents(_ caseID: UUID) async throws -> [InvestigationCaseEvent] {
        let rows = try await database.query("""
            SELECT id, case_id, sequence, case_revision, action, actor, detail, occurred_at
            FROM investigation_case_events WHERE case_id = ? ORDER BY sequence ASC;
            """, [.uuid(caseID)])
        return rows.compactMap { r in
            guard let id = r.uuid(0), let cid = r.uuid(1), let seq = r.int(2), let rev = r.int(3),
                  let action = r.string(4).flatMap(InvestigationCaseEventAction.init(rawValue:)),
                  let actor = r.string(5), let occurredAt = r.date(7) else { return nil }
            return InvestigationCaseEvent(id: id, caseID: cid, sequence: Int(seq), caseRevision: Int(rev),
                                          action: action, actor: actor, detail: r.string(6), occurredAt: occurredAt)
        }
    }

    private func appendEvent(caseID: UUID, revision: Int, action: InvestigationCaseEventAction,
                             actor: String, detail: String?, at date: Date) async throws {
        let maxSeq = try await database.query(
            "SELECT COALESCE(MAX(sequence), 0) FROM investigation_case_events WHERE case_id = ?;", [.uuid(caseID)]).first?.int(0) ?? 0
        try await database.exec("""
            INSERT INTO investigation_case_events (id, case_id, sequence, case_revision, action, actor, detail, occurred_at)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(caseID), .integer(maxSeq + 1), .integer(Int64(revision)),
                  .text(action.rawValue), .text(actor), opt(detail), .date(date)])
    }

    private nonisolated func decodeHeader(_ r: SQLRow) -> InvestigationCase? {
        guard let id = r.uuid(0), let ws = r.uuid(1), let title = r.string(2),
              let status = r.string(8).flatMap(InvestigationCaseStatus.init(rawValue:)),
              let revision = r.int(11), let actor = r.string(12),
              let createdAt = r.date(13), let updatedAt = r.date(14) else { return nil }
        return InvestigationCase(id: id, workspaceID: ws, title: title, purpose: r.string(3), scopeStatement: r.string(4),
                                 outOfScopeStatement: r.string(5), timeWindowStart: r.date(6), timeWindowEnd: r.date(7),
                                 status: status, confirmedDeadlineID: r.uuid(9), possibleDeadlineNote: r.string(10),
                                 revision: Int(revision), actor: actor, createdAt: createdAt, updatedAt: updatedAt)
    }

    private nonisolated func validatedActor(_ actor: String) throws -> String {
        let clean = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw InvestigationCaseError.blankActor }
        return clean
    }

    private nonisolated func opt(_ s: String?) -> SQLValue {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .null }
        return .text(s)
    }

    private nonisolated func optDate(_ d: Date?) -> SQLValue { d.map { SQLValue.date($0) } ?? .null }

    private nonisolated func savepoint(_ prefix: String, _ id: UUID) -> String {
        "\(prefix)_\(id.uuidString.replacingOccurrences(of: "-", with: ""))"
    }
}
