//
//  DeadlineRepository.swift
//  Kalsmritikosh
//
//  OPS-002 — persistence for deadline CANDIDATES (proposal layer) and confirmed DEADLINES.
//
//  THE truth rule: `DeadlineCandidate ≠ Deadline`. An extracted, rule-derived or model-proposed
//  date only ever becomes a `DeadlineCandidate`. Confirmation (`confirmCandidate`) atomically
//  inserts a SEPARATE `deadlines` row, marks the candidate `.promoted` (preserving it, its
//  origin, evidence and review history) and appends BOTH audit rows — a candidate row is never
//  reused as a confirmed deadline, and re-confirming a promoted candidate fails. A month/year/
//  unknown-precision candidate cannot be promoted; it must first be refined through an explicit
//  reviewed correction (never silently snapped to a month boundary). Overdue is calculated from
//  an active deadline and a comparison time — never a stored, autonomously-mutated status.
//

import Foundation

public enum DeadlineError: Error, Equatable {
    case taskNotFound(UUID)
    case candidateNotFound(UUID)
    case deadlineNotFound(UUID)
    case invalidCandidatePrecision(DatePrecision)
    case unpromotablePrecision(DatePrecision)
    case candidateNotPending(DeadlineCandidateStatus)
    case blankProposer
    case blankConfirmer
    case blankRule
    case ruleEvidenceRequired
    case ruleConfirmationRequiresCandidate
    case invalidStatusChange(from: DeadlineStatus, to: DeadlineStatus)
    case invalidCandidateStatusChange(from: DeadlineCandidateStatus, to: DeadlineCandidateStatus)
}

public actor DeadlineRepository {
    private let database: Database

    public init(database: Database) { self.database = database }

    // Test-only fault injection (promotion/status rollback proof).
    enum InjectedFailure { case beforeDeadlineReview }
    private var injectFailure: InjectedFailure?
    func setInjectFailure(_ f: InjectedFailure?) { injectFailure = f }
    struct InjectedDeadlineFailure: Error {}

    // MARK: - Candidates

    /// Any origin may CREATE a candidate — that is the whole point of the proposal layer.
    public func createCandidate(taskID: UUID, value: DeadlineValue, kind: DeadlineKind,
                                origin: DeadlineCandidateOrigin, confidence: Double?,
                                proposedBy: String, ruleID: String?, ruleVersion: String?,
                                at date: Date) async throws -> DeadlineCandidate {
        guard try await rowExists("professional_tasks", id: taskID) else {
            throw DeadlineError.taskNotFound(taskID)
        }
        guard DeadlineValue.candidatePrecisions.contains(value.precision) else {
            throw DeadlineError.invalidCandidatePrecision(value.precision)
        }
        guard !proposedBy.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw DeadlineError.blankProposer
        }
        if origin == .deterministicRule {
            guard let r = ruleID, let v = ruleVersion,
                  !r.trimmingCharacters(in: .whitespaces).isEmpty,
                  !v.trimmingCharacters(in: .whitespaces).isEmpty else { throw DeadlineError.blankRule }
        }
        let c = DeadlineCandidate(id: UUID(), taskID: taskID, value: value, kind: kind,
                                  origin: origin, confidence: confidence, proposedBy: proposedBy,
                                  ruleID: ruleID, ruleVersion: ruleVersion, status: .pending,
                                  createdAt: date, reviewedAt: nil)
        let savepoint = "dc_create_\(c.id.uuidString.replacingOccurrences(of: "-", with: ""))"
        do {
            try await database.exec("SAVEPOINT \(savepoint);")
            try await database.exec("""
            INSERT INTO deadline_candidates (id, task_id, due_date, precision, time_zone, deadline_kind,
                                             origin, confidence, proposed_by, rule_id, rule_version,
                                             status, created_at, reviewed_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,NULL);
            """, [.uuid(c.id), .uuid(taskID), .date(value.date), .integer(Int64(value.precision.rawValue)),
                  .text(value.timeZoneIdentifier), .text(kind.rawValue), .text(origin.rawValue),
                  confidence.map { SQLValue.real($0) } ?? .null, .text(proposedBy),
                  .optionalText(ruleID), .optionalText(ruleVersion),
                  .text(DeadlineCandidateStatus.pending.rawValue), .date(date)])
            try await insertCandidateReview(candidateID: c.id, action: .created,
                                            reviewer: proposedBy, reason: nil, at: date)
            try await database.exec("RELEASE SAVEPOINT \(savepoint);")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(savepoint);")
            try? await database.exec("RELEASE SAVEPOINT \(savepoint);")
            throw error
        }
        return c
    }

    public func candidate(id: UUID) async throws -> DeadlineCandidate? {
        (try await database.query("\(candidateColumns) WHERE id = ? LIMIT 1;", [.uuid(id)])).first.flatMap(decodeCandidate)
    }

    public func candidates(taskID: UUID, statuses: Set<DeadlineCandidateStatus> = []) async throws -> [DeadlineCandidate] {
        var sql = "\(candidateColumns) WHERE task_id = ?"
        var params: [SQLValue] = [.uuid(taskID)]
        if !statuses.isEmpty {
            sql += " AND status IN (\(statuses.map { _ in "?" }.joined(separator: ",")))"
            params += statuses.map { .text($0.rawValue) }
        }
        sql += " ORDER BY created_at ASC, id ASC;"
        return (try await database.query(sql, params)).compactMap(decodeCandidate)
    }

    /// Explicit reviewed refinement (e.g. .month → .day before promotion). Never a silent
    /// month-boundary snap — the corrected value is whatever the reviewer explicitly supplies.
    @discardableResult
    public func correctCandidate(id: UUID, to newValue: DeadlineValue, reviewer: String,
                                 reason: String?, at date: Date) async throws -> DeadlineCandidate {
        guard let c = try await candidate(id: id) else { throw DeadlineError.candidateNotFound(id) }
        guard c.status == .pending else { throw DeadlineError.candidateNotPending(c.status) }
        guard DeadlineValue.candidatePrecisions.contains(newValue.precision) else {
            throw DeadlineError.invalidCandidatePrecision(newValue.precision)
        }
        let savepoint = "dc_corr_\(id.uuidString.replacingOccurrences(of: "-", with: ""))"
        do {
            try await database.exec("SAVEPOINT \(savepoint);")
            try await database.exec("""
            UPDATE deadline_candidates SET due_date = ?, precision = ?, time_zone = ?, reviewed_at = ? WHERE id = ?;
            """, [.date(newValue.date), .integer(Int64(newValue.precision.rawValue)),
                  .text(newValue.timeZoneIdentifier), .date(date), .uuid(id)])
            try await insertCandidateReview(candidateID: id, action: .corrected,
                                            reviewer: reviewer, reason: reason, at: date)
            try await database.exec("RELEASE SAVEPOINT \(savepoint);")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(savepoint);")
            try? await database.exec("RELEASE SAVEPOINT \(savepoint);")
            throw error
        }
        return try await candidate(id: id) ?? c
    }

    public func rejectCandidate(id: UUID, reviewer: String, reason: String?, at date: Date) async throws {
        try await changeCandidateStatus(id: id, to: .rejected, action: .rejected,
                                        reviewer: reviewer, reason: reason, at: date)
    }

    public func supersedeCandidate(id: UUID, reviewer: String, reason: String?, at date: Date) async throws {
        try await changeCandidateStatus(id: id, to: .superseded, action: .superseded,
                                        reviewer: reviewer, reason: reason, at: date)
    }

    public func archiveCandidate(id: UUID, reviewer: String, reason: String?, at date: Date) async throws {
        try await changeCandidateStatus(id: id, to: .archived, action: .archived,
                                        reviewer: reviewer, reason: reason, at: date)
    }

    // MARK: - Confirmation (candidate → SEPARATE Deadline; atomic)

    /// The ONLY path from a proposal to a confirmed deadline. Atomically: validate the pending
    /// candidate → validate confirmation authority → validate precision → (rule) validate exact
    /// evidence → insert the NEW Deadline → mark the candidate promoted → append the candidate
    /// review → append the Deadline confirmation review. Any failure rolls everything back.
    @discardableResult
    public func confirmCandidate(id: UUID, confirmation: DeadlineConfirmation,
                                 at date: Date) async throws -> Deadline {
        guard let c = try await candidate(id: id) else { throw DeadlineError.candidateNotFound(id) }
        guard c.status == .pending else { throw DeadlineError.candidateNotPending(c.status) }   // re-confirm fails
        try validateAuthority(confirmation)
        guard DeadlineValue.confirmablePrecisions.contains(c.value.precision) else {
            throw DeadlineError.unpromotablePrecision(c.value.precision)   // refine via correction first
        }
        if confirmation.kind == .deterministicRule {
            // A rule confirmation must cite at least one exact evidence link on the candidate.
            let n = Int(try await database.query("""
            SELECT COUNT(*) FROM professional_task_evidence_links
            WHERE scope_kind = 'deadlineCandidate' AND scope_id = ?;
            """, [.text(id.uuidString)]).first?.int(0) ?? 0)
            guard n >= 1 else { throw DeadlineError.ruleEvidenceRequired }
        }

        let d = Deadline(id: UUID(), taskID: c.taskID, sourceCandidateID: c.id, value: c.value,
                         kind: c.kind, status: .active, confirmation: confirmation,
                         createdAt: date, updatedAt: date, satisfiedAt: nil, archivedAt: nil)
        let savepoint = "dl_conf_\(id.uuidString.replacingOccurrences(of: "-", with: ""))"
        do {
            try await database.exec("SAVEPOINT \(savepoint);")
            try await insertDeadline(d)
            try await database.exec(
                "UPDATE deadline_candidates SET status = ?, reviewed_at = ? WHERE id = ?;",
                [.text(DeadlineCandidateStatus.promoted.rawValue), .date(date), .uuid(id)])
            try await insertCandidateReview(candidateID: id, action: .promoted,
                                            reviewer: confirmation.confirmedBy,
                                            reason: confirmation.reason, at: date)
            if injectFailure == .beforeDeadlineReview { throw InjectedDeadlineFailure() }
            try await insertDeadlineReview(deadlineID: d.id, action: .confirmed,
                                           reviewer: confirmation.confirmedBy,
                                           reason: confirmation.reason, at: date)
            try await database.exec("RELEASE SAVEPOINT \(savepoint);")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(savepoint);")
            try? await database.exec("RELEASE SAVEPOINT \(savepoint);")
            throw error
        }
        return d
    }

    /// Direct creation of a confirmed deadline — USER authority only. A deterministic rule must
    /// go through a candidate (exact inputs + rule version recorded) per the truth rule.
    @discardableResult
    public func createConfirmedDeadline(taskID: UUID, value: DeadlineValue, kind: DeadlineKind,
                                        confirmation: DeadlineConfirmation,
                                        at date: Date) async throws -> Deadline {
        guard confirmation.kind == .user else { throw DeadlineError.ruleConfirmationRequiresCandidate }
        try validateAuthority(confirmation)
        guard try await rowExists("professional_tasks", id: taskID) else {
            throw DeadlineError.taskNotFound(taskID)
        }
        guard DeadlineValue.confirmablePrecisions.contains(value.precision) else {
            throw DeadlineError.unpromotablePrecision(value.precision)
        }
        let d = Deadline(id: UUID(), taskID: taskID, sourceCandidateID: nil, value: value,
                         kind: kind, status: .active, confirmation: confirmation,
                         createdAt: date, updatedAt: date, satisfiedAt: nil, archivedAt: nil)
        let savepoint = "dl_new_\(d.id.uuidString.replacingOccurrences(of: "-", with: ""))"
        do {
            try await database.exec("SAVEPOINT \(savepoint);")
            try await insertDeadline(d)
            try await insertDeadlineReview(deadlineID: d.id, action: .confirmed,
                                           reviewer: confirmation.confirmedBy,
                                           reason: confirmation.reason, at: date)
            try await database.exec("RELEASE SAVEPOINT \(savepoint);")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(savepoint);")
            try? await database.exec("RELEASE SAVEPOINT \(savepoint);")
            throw error
        }
        return d
    }

    // MARK: - Deadline reads + lifecycle

    public func deadline(id: UUID) async throws -> Deadline? {
        (try await database.query("\(deadlineColumns) WHERE id = ? LIMIT 1;", [.uuid(id)])).first.flatMap(decodeDeadline)
    }

    public func deadlines(taskID: UUID, statuses: Set<DeadlineStatus> = []) async throws -> [Deadline] {
        var sql = "\(deadlineColumns) WHERE task_id = ?"
        var params: [SQLValue] = [.uuid(taskID)]
        if !statuses.isEmpty {
            sql += " AND status IN (\(statuses.map { _ in "?" }.joined(separator: ",")))"
            params += statuses.map { .text($0.rawValue) }
        }
        sql += " ORDER BY due_date ASC, id ASC;"
        return (try await database.query(sql, params)).compactMap(decodeDeadline)
    }

    public func satisfy(id: UUID, reviewer: String, reason: String?, at date: Date) async throws {
        try await changeDeadlineStatus(id: id, to: .satisfied, action: .satisfied,
                                       reviewer: reviewer, reason: reason, at: date)
    }

    public func cancel(id: UUID, reviewer: String, reason: String?, at date: Date) async throws {
        try await changeDeadlineStatus(id: id, to: .cancelled, action: .cancelled,
                                       reviewer: reviewer, reason: reason, at: date)
    }

    public func supersede(id: UUID, reviewer: String, reason: String?, at date: Date) async throws {
        try await changeDeadlineStatus(id: id, to: .superseded, action: .superseded,
                                       reviewer: reviewer, reason: reason, at: date)
    }

    public func archive(id: UUID, reviewer: String, reason: String?, at date: Date) async throws {
        try await changeDeadlineStatus(id: id, to: .archived, action: .archived,
                                       reviewer: reviewer, reason: reason, at: date)
    }

    // MARK: - Audits

    public func candidateReviews(candidateID: UUID) async throws -> [DeadlineCandidateReview] {
        let rows = try await database.query("""
        SELECT id, candidate_id, action, reviewer, reason, reviewed_at
        FROM deadline_candidate_reviews WHERE candidate_id = ? ORDER BY reviewed_at ASC, id ASC;
        """, [.uuid(candidateID)])
        return rows.compactMap { r in
            guard let id = r.uuid(0), let cid = r.uuid(1),
                  let action = r.string(2).flatMap(DeadlineCandidateReviewAction.init(rawValue:)),
                  let reviewer = r.string(3), let at = r.date(5) else { return nil }
            return DeadlineCandidateReview(id: id, candidateID: cid, action: action,
                                           reviewer: reviewer, reason: r.string(4), reviewedAt: at)
        }
    }

    public func deadlineReviews(deadlineID: UUID) async throws -> [DeadlineReview] {
        let rows = try await database.query("""
        SELECT id, deadline_id, action, reviewer, reason, reviewed_at
        FROM deadline_reviews WHERE deadline_id = ? ORDER BY reviewed_at ASC, id ASC;
        """, [.uuid(deadlineID)])
        return rows.compactMap { r in
            guard let id = r.uuid(0), let did = r.uuid(1),
                  let action = r.string(2).flatMap(DeadlineReviewAction.init(rawValue:)),
                  let reviewer = r.string(3), let at = r.date(5) else { return nil }
            return DeadlineReview(id: id, deadlineID: did, action: action,
                                  reviewer: reviewer, reason: r.string(4), reviewedAt: at)
        }
    }

    // MARK: - Internals

    private func validateAuthority(_ confirmation: DeadlineConfirmation) throws {
        guard !confirmation.confirmedBy.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw DeadlineError.blankConfirmer
        }
        if confirmation.kind == .deterministicRule {
            guard let r = confirmation.ruleID, let v = confirmation.ruleVersion,
                  !r.trimmingCharacters(in: .whitespaces).isEmpty,
                  !v.trimmingCharacters(in: .whitespaces).isEmpty else { throw DeadlineError.blankRule }
        }
    }

    private func changeCandidateStatus(id: UUID, to status: DeadlineCandidateStatus,
                                       action: DeadlineCandidateReviewAction, reviewer: String,
                                       reason: String?, at date: Date) async throws {
        guard let c = try await candidate(id: id) else { throw DeadlineError.candidateNotFound(id) }
        // Pending may reject/supersede/archive; rejected/superseded may archive; promoted and
        // archived are terminal for the candidate's own lifecycle.
        let legal: Bool
        switch (c.status, status) {
        case (.pending, .rejected), (.pending, .superseded), (.pending, .archived),
             (.rejected, .archived), (.superseded, .archived):
            legal = true
        default:
            legal = false
        }
        guard legal else { throw DeadlineError.invalidCandidateStatusChange(from: c.status, to: status) }
        let savepoint = "dc_st_\(id.uuidString.replacingOccurrences(of: "-", with: ""))"
        do {
            try await database.exec("SAVEPOINT \(savepoint);")
            try await database.exec("UPDATE deadline_candidates SET status = ?, reviewed_at = ? WHERE id = ?;",
                                    [.text(status.rawValue), .date(date), .uuid(id)])
            try await insertCandidateReview(candidateID: id, action: action,
                                            reviewer: reviewer, reason: reason, at: date)
            try await database.exec("RELEASE SAVEPOINT \(savepoint);")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(savepoint);")
            try? await database.exec("RELEASE SAVEPOINT \(savepoint);")
            throw error
        }
    }

    private func changeDeadlineStatus(id: UUID, to status: DeadlineStatus,
                                      action: DeadlineReviewAction, reviewer: String,
                                      reason: String?, at date: Date) async throws {
        guard let d = try await deadline(id: id) else { throw DeadlineError.deadlineNotFound(id) }
        let legal: Bool
        switch (d.status, status) {
        case (.active, .satisfied), (.active, .cancelled), (.active, .superseded), (.active, .archived),
             (.satisfied, .archived), (.cancelled, .archived), (.superseded, .archived):
            legal = true
        default:
            legal = false
        }
        guard legal else { throw DeadlineError.invalidStatusChange(from: d.status, to: status) }
        let savepoint = "dl_st_\(id.uuidString.replacingOccurrences(of: "-", with: ""))"
        do {
            try await database.exec("SAVEPOINT \(savepoint);")
            try await database.exec("""
            UPDATE deadlines SET status = ?, updated_at = ?, satisfied_at = ?, archived_at = ? WHERE id = ?;
            """, [.text(status.rawValue), .date(date),
                  status == .satisfied ? .date(date) : (d.satisfiedAt.map { SQLValue.date($0) } ?? .null),
                  status == .archived ? .date(date) : (d.archivedAt.map { SQLValue.date($0) } ?? .null),
                  .uuid(id)])
            if injectFailure == .beforeDeadlineReview { throw InjectedDeadlineFailure() }
            try await insertDeadlineReview(deadlineID: id, action: action,
                                           reviewer: reviewer, reason: reason, at: date)
            try await database.exec("RELEASE SAVEPOINT \(savepoint);")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(savepoint);")
            try? await database.exec("RELEASE SAVEPOINT \(savepoint);")
            throw error
        }
    }

    private func insertDeadline(_ d: Deadline) async throws {
        try await database.exec("""
        INSERT INTO deadlines (id, task_id, source_candidate_id, due_date, precision, time_zone,
                               deadline_kind, status, confirmation_kind, confirmed_by, confirmed_at,
                               confirm_reason, rule_id, rule_version, created_at, updated_at,
                               satisfied_at, archived_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,NULL,NULL);
        """, [.uuid(d.id), .uuid(d.taskID), d.sourceCandidateID.map { SQLValue.uuid($0) } ?? .null,
              .date(d.value.date), .integer(Int64(d.value.precision.rawValue)),
              .text(d.value.timeZoneIdentifier), .text(d.kind.rawValue), .text(d.status.rawValue),
              .text(d.confirmation.kind.rawValue), .text(d.confirmation.confirmedBy),
              .date(d.confirmation.confirmedAt), .optionalText(d.confirmation.reason),
              .optionalText(d.confirmation.ruleID), .optionalText(d.confirmation.ruleVersion),
              .date(d.createdAt), .date(d.updatedAt)])
    }

    private let candidateColumns = """
    SELECT id, task_id, due_date, precision, time_zone, deadline_kind, origin, confidence,
           proposed_by, rule_id, rule_version, status, created_at, reviewed_at
    FROM deadline_candidates
    """

    private func decodeCandidate(_ r: SQLRow) -> DeadlineCandidate? {
        guard let id = r.uuid(0), let task = r.uuid(1), let due = r.date(2),
              let precision = r.int(3).flatMap({ DatePrecision(rawValue: Int($0)) }),
              let tz = r.string(4),
              let kind = r.string(5).flatMap(DeadlineKind.init(rawValue:)),
              let origin = r.string(6).flatMap(DeadlineCandidateOrigin.init(rawValue:)),
              let proposedBy = r.string(8),
              let status = r.string(11).flatMap(DeadlineCandidateStatus.init(rawValue:)),
              let created = r.date(12) else { return nil }
        return DeadlineCandidate(id: id, taskID: task,
                                 value: DeadlineValue(date: due, precision: precision, timeZoneIdentifier: tz),
                                 kind: kind, origin: origin, confidence: r.double(7),
                                 proposedBy: proposedBy, ruleID: r.string(9), ruleVersion: r.string(10),
                                 status: status, createdAt: created, reviewedAt: r.date(13))
    }

    private let deadlineColumns = """
    SELECT id, task_id, source_candidate_id, due_date, precision, time_zone, deadline_kind, status,
           confirmation_kind, confirmed_by, confirmed_at, confirm_reason, rule_id, rule_version,
           created_at, updated_at, satisfied_at, archived_at
    FROM deadlines
    """

    private func decodeDeadline(_ r: SQLRow) -> Deadline? {
        guard let id = r.uuid(0), let task = r.uuid(1), let due = r.date(3),
              let precision = r.int(4).flatMap({ DatePrecision(rawValue: Int($0)) }),
              let tz = r.string(5),
              let kind = r.string(6).flatMap(DeadlineKind.init(rawValue:)),
              let status = r.string(7).flatMap(DeadlineStatus.init(rawValue:)),
              let confKind = r.string(8).flatMap(DeadlineConfirmationKind.init(rawValue:)),
              let confirmedBy = r.string(9), let confirmedAt = r.date(10),
              let created = r.date(14), let updated = r.date(15) else { return nil }
        return Deadline(id: id, taskID: task, sourceCandidateID: r.uuid(2),
                        value: DeadlineValue(date: due, precision: precision, timeZoneIdentifier: tz),
                        kind: kind, status: status,
                        confirmation: DeadlineConfirmation(kind: confKind, confirmedBy: confirmedBy,
                                                           confirmedAt: confirmedAt, reason: r.string(11),
                                                           ruleID: r.string(12), ruleVersion: r.string(13)),
                        createdAt: created, updatedAt: updated,
                        satisfiedAt: r.date(16), archivedAt: r.date(17))
    }

    private func insertCandidateReview(candidateID: UUID, action: DeadlineCandidateReviewAction,
                                       reviewer: String, reason: String?, at date: Date) async throws {
        try await database.exec("""
        INSERT INTO deadline_candidate_reviews (id, candidate_id, action, reviewer, reason, reviewed_at)
        VALUES (?,?,?,?,?,?);
        """, [.uuid(UUID()), .uuid(candidateID), .text(action.rawValue),
              .text(reviewer), .optionalText(reason), .date(date)])
    }

    private func insertDeadlineReview(deadlineID: UUID, action: DeadlineReviewAction,
                                      reviewer: String, reason: String?, at date: Date) async throws {
        try await database.exec("""
        INSERT INTO deadline_reviews (id, deadline_id, action, reviewer, reason, reviewed_at)
        VALUES (?,?,?,?,?,?);
        """, [.uuid(UUID()), .uuid(deadlineID), .text(action.rawValue),
              .text(reviewer), .optionalText(reason), .date(date)])
    }

    private func rowExists(_ table: String, id: UUID) async throws -> Bool {
        Int(try await database.query("SELECT COUNT(*) FROM \(table) WHERE id = ?;", [.uuid(id)]).first?.int(0) ?? 0) > 0
    }
}
