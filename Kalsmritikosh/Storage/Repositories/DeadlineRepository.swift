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
    case taskNotOperational(ProfessionalTaskStatus)
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
        (try await database.query("\(Self.candidateColumns) WHERE id = ? LIMIT 1;", [.uuid(id)])).first.flatMap(Self.decodeCandidate)
    }

    public func candidates(taskID: UUID, statuses: Set<DeadlineCandidateStatus> = []) async throws -> [DeadlineCandidate] {
        var sql = "\(Self.candidateColumns) WHERE task_id = ?"
        var params: [SQLValue] = [.uuid(taskID)]
        if !statuses.isEmpty {
            sql += " AND status IN (\(statuses.map { _ in "?" }.joined(separator: ",")))"
            params += statuses.map { .text($0.rawValue) }
        }
        sql += " ORDER BY created_at ASC, id ASC;"
        return (try await database.query(sql, params)).compactMap(Self.decodeCandidate)
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

    /// The ONLY path from a proposal to a confirmed deadline. EVERY state validation and every
    /// write executes inside ONE non-interleavable `Database.withSavepoint` operation (the
    /// closure is synchronous and isolated to the database actor — no suspension point exists
    /// between "the task is operational / the candidate is pending / the evidence is exact" and
    /// the inserts, so no other writer can invalidate a check before the commit; OPS-002.2).
    /// Sequence: load pending candidate → operational task → authority → precision → (rule)
    /// exact evidence → no existing Deadline → insert NEW Deadline → mark candidate promoted →
    /// append both audit rows. Any failure rolls the entire savepoint back.
    @discardableResult
    public func confirmCandidate(id: UUID, confirmation: DeadlineConfirmation,
                                 at date: Date) async throws -> Deadline {
        try validateAuthority(confirmation)          // pure input validation — no DB state read
        let injected = injectFailure
        let savepoint = "dl_conf_\(id.uuidString.replacingOccurrences(of: "-", with: ""))"
        return try await database.withSavepoint(savepoint) { (db: isolated Database) -> Deadline in
            guard let c = try Self.fetchCandidate(db, id: id) else {
                throw DeadlineError.candidateNotFound(id)
            }
            guard c.status == .pending else { throw DeadlineError.candidateNotPending(c.status) }
            // A candidate may be PROPOSED against a candidate task, but it can only become an
            // OPERATIONAL Deadline once the task itself is confirmed and still live.
            try Self.requireOperationalTask(db, c.taskID)
            guard DeadlineValue.confirmablePrecisions.contains(c.value.precision) else {
                throw DeadlineError.unpromotablePrecision(c.value.precision)   // refine first
            }
            if confirmation.kind == .deterministicRule {
                guard try Self.hasExactRuleEvidence(db, candidateID: id) else {
                    throw DeadlineError.ruleEvidenceRequired
                }
            }
            // One candidate → at most one Deadline (UNIQUE(source_candidate_id) backstops this;
            // the explicit check yields the domain error instead of a raw constraint failure).
            let existing = Int(try db.query(
                "SELECT COUNT(*) FROM deadlines WHERE source_candidate_id = ?;", [.uuid(id)]
            ).first?.int(0) ?? 0)
            guard existing == 0 else { throw DeadlineError.candidateNotPending(.promoted) }

            let d = Deadline(id: UUID(), taskID: c.taskID, sourceCandidateID: c.id, value: c.value,
                             kind: c.kind, status: .active, confirmation: confirmation,
                             createdAt: date, updatedAt: date, satisfiedAt: nil, archivedAt: nil)
            try Self.insertDeadline(db, d)
            try db.exec("UPDATE deadline_candidates SET status = ?, reviewed_at = ? WHERE id = ?;",
                        [.text(DeadlineCandidateStatus.promoted.rawValue), .date(date), .uuid(id)])
            try Self.insertCandidateReview(db, candidateID: id, action: .promoted,
                                           reviewer: confirmation.confirmedBy,
                                           reason: confirmation.reason, at: date)
            if injected == .beforeDeadlineReview { throw InjectedDeadlineFailure() }
            try Self.insertDeadlineReview(db, deadlineID: d.id, action: .confirmed,
                                          reviewer: confirmation.confirmedBy,
                                          reason: confirmation.reason, at: date)
            return d
        }
    }

    /// Direct creation of a confirmed deadline — USER authority only. A deterministic rule must
    /// go through a candidate (exact inputs + rule version recorded) per the truth rule.
    /// Like `confirmCandidate`, the operational-task validation executes INSIDE the same
    /// non-interleavable savepoint as the writes (OPS-002.2).
    @discardableResult
    public func createConfirmedDeadline(taskID: UUID, value: DeadlineValue, kind: DeadlineKind,
                                        confirmation: DeadlineConfirmation,
                                        at date: Date) async throws -> Deadline {
        guard confirmation.kind == .user else { throw DeadlineError.ruleConfirmationRequiresCandidate }
        try validateAuthority(confirmation)
        guard DeadlineValue.confirmablePrecisions.contains(value.precision) else {
            throw DeadlineError.unpromotablePrecision(value.precision)
        }
        let d = Deadline(id: UUID(), taskID: taskID, sourceCandidateID: nil, value: value,
                         kind: kind, status: .active, confirmation: confirmation,
                         createdAt: date, updatedAt: date, satisfiedAt: nil, archivedAt: nil)
        let savepoint = "dl_new_\(d.id.uuidString.replacingOccurrences(of: "-", with: ""))"
        return try await database.withSavepoint(savepoint) { (db: isolated Database) -> Deadline in
            try Self.requireOperationalTask(db, taskID)   // also proves the task exists
            try Self.insertDeadline(db, d)
            try Self.insertDeadlineReview(db, deadlineID: d.id, action: .confirmed,
                                          reviewer: confirmation.confirmedBy,
                                          reason: confirmation.reason, at: date)
            return d
        }
    }

    // MARK: - Deadline reads + lifecycle

    public func deadline(id: UUID) async throws -> Deadline? {
        (try await database.query("\(Self.deadlineColumns) WHERE id = ? LIMIT 1;", [.uuid(id)])).first.flatMap(Self.decodeDeadline)
    }

    public func deadlines(taskID: UUID, statuses: Set<DeadlineStatus> = []) async throws -> [Deadline] {
        var sql = "\(Self.deadlineColumns) WHERE task_id = ?"
        var params: [SQLValue] = [.uuid(taskID)]
        if !statuses.isEmpty {
            sql += " AND status IN (\(statuses.map { _ in "?" }.joined(separator: ",")))"
            params += statuses.map { .text($0.rawValue) }
        }
        sql += " ORDER BY due_date ASC, id ASC;"
        return (try await database.query(sql, params)).compactMap(Self.decodeDeadline)
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

    // MARK: - Internals (transactional validators — synchronous, isolated to the Database)

    /// A confirmed, live task: open / inProgress / blocked. Candidate tasks have not been
    /// confirmed by any authority; completed / cancelled / archived tasks are closed — none of
    /// them may carry an ACTIVE operational deadline. Runs INSIDE the confirmation savepoint.
    private static func requireOperationalTask(_ db: isolated Database, _ taskID: UUID) throws {
        let rows = try db.query("SELECT status FROM professional_tasks WHERE id = ?;", [.uuid(taskID)])
        guard let status = rows.first?.string(0).flatMap(ProfessionalTaskStatus.init(rawValue:)) else {
            throw DeadlineError.taskNotFound(taskID)
        }
        guard [.open, .inProgress, .blocked].contains(status) else {
            throw DeadlineError.taskNotOperational(status)
        }
    }

    /// EXACT evidence for deterministic-rule confirmation: a link that is (a) scoped to THIS
    /// candidate, (b) role `deadlineBasis`, and (c) resolves to exact cited evidence — either an
    /// EvidenceBlock tied to a resolvable source version, or a Claim with at least one evidence
    /// reference whose exact EvidenceBlock BELONGS TO the reference's own source version
    /// (`b.source_version_id = r.source_version_id` — a reference pairing a real block from
    /// version A with a real version-B id is malformed and never qualifies; OPS-002.2). Entity /
    /// Event / Gap / Contradiction / bare-KnowledgeObject targets and context-role links never
    /// qualify. Runs INSIDE the confirmation savepoint.
    private static func hasExactRuleEvidence(_ db: isolated Database, candidateID: UUID) throws -> Bool {
        let blockLinks = Int(try db.query("""
        SELECT COUNT(*) FROM professional_task_evidence_links l
        JOIN evidence_blocks b   ON b.id  = l.target_id
        JOIN source_versions sv  ON sv.id = b.source_version_id
        WHERE l.scope_kind = 'deadlineCandidate' AND l.scope_id = ?
          AND l.link_role = 'deadlineBasis' AND l.target_kind = 'evidenceBlock';
        """, [.text(candidateID.uuidString)]).first?.int(0) ?? 0)
        if blockLinks >= 1 { return true }
        let claimLinks = Int(try db.query("""
        SELECT COUNT(*) FROM professional_task_evidence_links l
        JOIN claim_evidence_ref r ON r.claim_id = l.target_id
        JOIN evidence_blocks b    ON b.id  = r.evidence_block_id
        JOIN source_versions sv   ON sv.id = b.source_version_id
                                 AND sv.id = r.source_version_id
        WHERE l.scope_kind = 'deadlineCandidate' AND l.scope_id = ?
          AND l.link_role = 'deadlineBasis' AND l.target_kind = 'claim';
        """, [.text(candidateID.uuidString)]).first?.int(0) ?? 0)
        return claimLinks >= 1
    }

    private static func fetchCandidate(_ db: isolated Database, id: UUID) throws -> DeadlineCandidate? {
        (try db.query("\(candidateColumns) WHERE id = ? LIMIT 1;", [.uuid(id)])).first.flatMap(Self.decodeCandidate)
    }

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

    // MARK: - Internals (shared statement builders — ONE source of SQL for both the async
    // instance paths and the synchronous transactional paths, so they can never drift)

    private nonisolated static func deadlineInsertStatement(_ d: Deadline) -> (sql: String, params: [SQLValue]) {
        ("""
        INSERT INTO deadlines (id, task_id, source_candidate_id, due_date, precision, time_zone,
                               deadline_kind, status, confirmation_kind, confirmed_by, confirmed_at,
                               confirm_reason, rule_id, rule_version, created_at, updated_at,
                               satisfied_at, archived_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,NULL,NULL);
        """,
        [.uuid(d.id), .uuid(d.taskID), d.sourceCandidateID.map { SQLValue.uuid($0) } ?? .null,
         .date(d.value.date), .integer(Int64(d.value.precision.rawValue)),
         .text(d.value.timeZoneIdentifier), .text(d.kind.rawValue), .text(d.status.rawValue),
         .text(d.confirmation.kind.rawValue), .text(d.confirmation.confirmedBy),
         .date(d.confirmation.confirmedAt), .optionalText(d.confirmation.reason),
         .optionalText(d.confirmation.ruleID), .optionalText(d.confirmation.ruleVersion),
         .date(d.createdAt), .date(d.updatedAt)])
    }

    private nonisolated static func candidateReviewStatement(
        candidateID: UUID, action: DeadlineCandidateReviewAction,
        reviewer: String, reason: String?, at date: Date) -> (sql: String, params: [SQLValue]) {
        ("""
        INSERT INTO deadline_candidate_reviews (id, candidate_id, action, reviewer, reason, reviewed_at)
        VALUES (?,?,?,?,?,?);
        """,
        [.uuid(UUID()), .uuid(candidateID), .text(action.rawValue),
         .text(reviewer), .optionalText(reason), .date(date)])
    }

    private nonisolated static func deadlineReviewStatement(
        deadlineID: UUID, action: DeadlineReviewAction,
        reviewer: String, reason: String?, at date: Date) -> (sql: String, params: [SQLValue]) {
        ("""
        INSERT INTO deadline_reviews (id, deadline_id, action, reviewer, reason, reviewed_at)
        VALUES (?,?,?,?,?,?);
        """,
        [.uuid(UUID()), .uuid(deadlineID), .text(action.rawValue),
         .text(reviewer), .optionalText(reason), .date(date)])
    }

    private static func insertDeadline(_ db: isolated Database, _ d: Deadline) throws {
        let s = deadlineInsertStatement(d)
        try db.exec(s.sql, s.params)
    }

    private static func insertCandidateReview(
        _ db: isolated Database, candidateID: UUID, action: DeadlineCandidateReviewAction,
        reviewer: String, reason: String?, at date: Date) throws {
        let s = candidateReviewStatement(candidateID: candidateID, action: action,
                                         reviewer: reviewer, reason: reason, at: date)
        try db.exec(s.sql, s.params)
    }

    private static func insertDeadlineReview(
        _ db: isolated Database, deadlineID: UUID, action: DeadlineReviewAction,
        reviewer: String, reason: String?, at date: Date) throws {
        let s = deadlineReviewStatement(deadlineID: deadlineID, action: action,
                                        reviewer: reviewer, reason: reason, at: date)
        try db.exec(s.sql, s.params)
    }

    private nonisolated static let candidateColumns = """
    SELECT id, task_id, due_date, precision, time_zone, deadline_kind, origin, confidence,
           proposed_by, rule_id, rule_version, status, created_at, reviewed_at
    FROM deadline_candidates
    """

    private nonisolated static func decodeCandidate(_ r: SQLRow) -> DeadlineCandidate? {
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

    private nonisolated static let deadlineColumns = """
    SELECT id, task_id, source_candidate_id, due_date, precision, time_zone, deadline_kind, status,
           confirmation_kind, confirmed_by, confirmed_at, confirm_reason, rule_id, rule_version,
           created_at, updated_at, satisfied_at, archived_at
    FROM deadlines
    """

    private nonisolated static func decodeDeadline(_ r: SQLRow) -> Deadline? {
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
        let s = Self.candidateReviewStatement(candidateID: candidateID, action: action,
                                              reviewer: reviewer, reason: reason, at: date)
        try await database.exec(s.sql, s.params)
    }

    private func insertDeadlineReview(deadlineID: UUID, action: DeadlineReviewAction,
                                      reviewer: String, reason: String?, at date: Date) async throws {
        let s = Self.deadlineReviewStatement(deadlineID: deadlineID, action: action,
                                             reviewer: reviewer, reason: reason, at: date)
        try await database.exec(s.sql, s.params)
    }

    private func rowExists(_ table: String, id: UUID) async throws -> Bool {
        Int(try await database.query("SELECT COUNT(*) FROM \(table) WHERE id = ?;", [.uuid(id)]).first?.int(0) ?? 0) > 0
    }
}
