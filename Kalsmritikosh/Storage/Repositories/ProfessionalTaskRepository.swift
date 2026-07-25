//
//  ProfessionalTaskRepository.swift
//  Kalsmritikosh
//
//  OPS-002 — persistence for shared professional Tasks (schema v69).
//
//  Guarantees:
//   • Origin safety: sourceExtraction / modelProposed / automationProposed (and importedLegacy)
//     tasks are created ONLY as `.candidate`; there is no overload that lets them start open.
//     `createConfirmed` requires an explicit user or deterministic-rule authority.
//   • Append-only audit: every lifecycle change writes a ProfessionalTaskReview in the SAME
//     SAVEPOINT — a failed ledger write rolls the state change back.
//   • Dependencies: no self-links (also a DB CHECK), same-workspace only, no duplicates, no
//     blocking cycles; a task cannot complete while a blocking predecessor is incomplete.
//   • Evidence links store canonical IDs only and are validated by the SHARED
//     WorkflowTargetValidator (same fail-closed rules as Issue links).
//   • Task completion is workflow completion — it never confirms linked evidence.
//

import Foundation

public enum ProfessionalTaskError: Error, Equatable {
    case blankTitle
    case blankAuthority
    case workspaceNotFound(UUID)
    case issueNotFound(UUID)
    case crossWorkspacePrimaryIssue(UUID)
    case taskNotFound(UUID)
    case invalidCandidateOrigin(ProfessionalTaskOrigin)
    case invalidTransition(from: ProfessionalTaskStatus, to: ProfessionalTaskStatus)
    case blockedByIncompleteDependency(UUID)
    case dependencyTaskNotFound(UUID)
    case selfDependency
    case crossWorkspaceDependency
    case duplicateDependency
    case dependencyCycle
    case dependencyNotFound(UUID)
    case linkNotFound(UUID)
    case duplicateLink
    case scopeObjectNotFound
    case scopeDoesNotBelongToTask
    case targetNotFound(kind: String, id: UUID)
    case crossWorkspaceLink(kind: String, id: UUID)
}

/// WHO may open a task (create confirmed / confirm a candidate). There is deliberately no
/// source-extraction or model-proposal authority.
public enum TaskCreationAuthority: Sendable, Equatable {
    case user(actor: String)
    case deterministicRule(ruleID: String, version: String, actor: String)

    nonisolated var actorName: String {
        switch self {
        case .user(let a): return a
        case .deterministicRule(_, _, let a): return a
        }
    }

    nonisolated var origin: ProfessionalTaskOrigin {
        switch self {
        case .user: return .userCreated
        case .deterministicRule: return .deterministicRule
        }
    }

    nonisolated var authorityKind: TaskAuthorityKind {
        switch self {
        case .user: return .user
        case .deterministicRule: return .deterministicRule
        }
    }

    /// The rule identity to PERSIST on the review row (v70) — validating it and then discarding
    /// it would leave the ledger unable to prove which rule confirmed the task.
    nonisolated var ruleIdentity: (id: String, version: String)? {
        switch self {
        case .user: return nil
        case .deterministicRule(let ruleID, let version, _): return (ruleID, version)
        }
    }

    nonisolated func validate() throws {
        switch self {
        case .user(let actor):
            guard !actor.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ProfessionalTaskError.blankAuthority
            }
        case .deterministicRule(let ruleID, let version, let actor):
            guard !ruleID.trimmingCharacters(in: .whitespaces).isEmpty,
                  !version.trimmingCharacters(in: .whitespaces).isEmpty,
                  !actor.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ProfessionalTaskError.blankAuthority
            }
        }
    }
}

public actor ProfessionalTaskRepository {
    private let database: Database

    public init(database: Database) { self.database = database }

    // Test-only fault injection (rollback proof) — same precedent as ClaimRepository/OPS-001.
    enum InjectedFailure { case beforeReviewInsert }
    private var injectFailure: InjectedFailure?
    func setInjectFailure(_ f: InjectedFailure?) { injectFailure = f }
    struct InjectedTaskFailure: Error {}

    /// Origins allowed to CREATE a candidate. userCreated / deterministicRule go through
    /// `createConfirmed` instead.
    private static let candidateOrigins: Set<ProfessionalTaskOrigin> =
        [.sourceExtraction, .modelProposed, .automationProposed, .importedLegacy]

    // MARK: - Create

    /// An automation / model / source / legacy-import proposal — ALWAYS starts `.candidate`.
    public func createCandidate(workspaceID: UUID, primaryIssueID: UUID?, title: String,
                                detail: String?, type: ProfessionalTaskType,
                                priority: ProfessionalTaskPriority, owner: String?,
                                origin: ProfessionalTaskOrigin, proposedBy: String,
                                at date: Date) async throws -> ProfessionalTask {
        guard Self.candidateOrigins.contains(origin) else {
            throw ProfessionalTaskError.invalidCandidateOrigin(origin)
        }
        return try await insertTask(workspaceID: workspaceID, primaryIssueID: primaryIssueID,
                                    title: title, detail: detail, type: type, priority: priority,
                                    owner: owner, origin: origin, status: .candidate,
                                    reviewer: proposedBy, authority: nil, at: date)
    }

    /// A user- or rule-authored task — starts `.open`. Authority is mandatory and validated.
    public func createConfirmed(workspaceID: UUID, primaryIssueID: UUID?, title: String,
                                detail: String?, type: ProfessionalTaskType,
                                priority: ProfessionalTaskPriority, owner: String?,
                                authority: TaskCreationAuthority,
                                at date: Date) async throws -> ProfessionalTask {
        try authority.validate()
        return try await insertTask(workspaceID: workspaceID, primaryIssueID: primaryIssueID,
                                    title: title, detail: detail, type: type, priority: priority,
                                    owner: owner, origin: authority.origin, status: .open,
                                    reviewer: authority.actorName, authority: authority, at: date)
    }

    /// Move a candidate task to `.open` — only a user or identified deterministic rule may.
    @discardableResult
    public func confirmCandidate(taskID: UUID, authority: TaskCreationAuthority,
                                 reason: String?, at date: Date) async throws -> ProfessionalTask {
        try authority.validate()
        guard let t = try await task(id: taskID) else { throw ProfessionalTaskError.taskNotFound(taskID) }
        guard t.status == .candidate else {
            throw ProfessionalTaskError.invalidTransition(from: t.status, to: .open)
        }
        return try await applyStatusChange(t, to: .open, action: .candidateConfirmed,
                                           reviewer: authority.actorName, reason: reason,
                                           authority: authority, at: date)
    }

    // MARK: - Reads

    public func task(id: UUID) async throws -> ProfessionalTask? {
        (try await database.query("\(selectColumns) WHERE id = ? LIMIT 1;", [.uuid(id)])).first.flatMap(decode)
    }

    public func tasks(workspaceID: UUID, statuses: Set<ProfessionalTaskStatus> = [],
                      types: Set<ProfessionalTaskType> = []) async throws -> [ProfessionalTask] {
        var sql = "\(selectColumns) WHERE workspace_id = ?"
        var params: [SQLValue] = [.uuid(workspaceID)]
        if !statuses.isEmpty {
            sql += " AND status IN (\(statuses.map { _ in "?" }.joined(separator: ",")))"
            params += statuses.map { .text($0.rawValue) }
        }
        if !types.isEmpty {
            sql += " AND task_type IN (\(types.map { _ in "?" }.joined(separator: ",")))"
            params += types.map { .text($0.rawValue) }
        }
        sql += " ORDER BY created_at ASC, id ASC;"
        return (try await database.query(sql, params)).compactMap(decode)
    }

    // MARK: - Lifecycle

    /// Non-terminal status movement. Completion goes through `complete`, reopening through
    /// `reopen`, archiving through `archive` — this handles open/inProgress/blocked/cancelled.
    @discardableResult
    public func transition(taskID: UUID, to status: ProfessionalTaskStatus, reviewer: String,
                           reason: String?, at date: Date) async throws -> ProfessionalTask {
        guard let t = try await task(id: taskID) else { throw ProfessionalTaskError.taskNotFound(taskID) }
        let action = try Self.transitionAction(from: t.status, to: status)
        return try await applyStatusChange(t, to: status, action: action,
                                           reviewer: reviewer, reason: reason, at: date)
    }

    /// Workflow completion (never evidence confirmation). Refused while a BLOCKING predecessor is
    /// incomplete; informational links never block.
    @discardableResult
    public func complete(taskID: UUID, reviewer: String, reason: String?,
                         at date: Date) async throws -> ProfessionalTask {
        guard let t = try await task(id: taskID) else { throw ProfessionalTaskError.taskNotFound(taskID) }
        guard [.open, .inProgress, .blocked].contains(t.status) else {
            throw ProfessionalTaskError.invalidTransition(from: t.status, to: .completed)
        }
        let blockers = try await database.query("""
        SELECT d.depends_on_task_id FROM professional_task_dependencies d
        JOIN professional_tasks p ON p.id = d.depends_on_task_id
        WHERE d.task_id = ? AND d.dependency_kind = 'blocking' AND p.status != 'completed';
        """, [.uuid(taskID)])
        if let blocker = blockers.first?.uuid(0) {
            throw ProfessionalTaskError.blockedByIncompleteDependency(blocker)
        }
        return try await applyStatusChange(t, to: .completed, action: .completed,
                                           reviewer: reviewer, reason: reason, at: date)
    }

    @discardableResult
    public func reopen(taskID: UUID, reviewer: String, reason: String?,
                       at date: Date) async throws -> ProfessionalTask {
        guard let t = try await task(id: taskID) else { throw ProfessionalTaskError.taskNotFound(taskID) }
        guard [.completed, .cancelled].contains(t.status) else {
            throw ProfessionalTaskError.invalidTransition(from: t.status, to: .open)
        }
        return try await applyStatusChange(t, to: .open, action: .reopened,
                                           reviewer: reviewer, reason: reason, at: date)
    }

    public func archive(taskID: UUID, reviewer: String, reason: String?, at date: Date) async throws {
        guard let t = try await task(id: taskID) else { throw ProfessionalTaskError.taskNotFound(taskID) }
        guard t.status != .archived else {
            throw ProfessionalTaskError.invalidTransition(from: .archived, to: .archived)
        }
        _ = try await applyStatusChange(t, to: .archived, action: .archived,
                                        reviewer: reviewer, reason: reason, at: date)
    }

    public func reviews(taskID: UUID) async throws -> [ProfessionalTaskReview] {
        let rows = try await database.query("""
        SELECT id, task_id, action, prior_status, new_status, reviewer, reason, reviewed_at,
               authority_kind, rule_id, rule_version
        FROM professional_task_reviews WHERE task_id = ? ORDER BY reviewed_at ASC, id ASC;
        """, [.uuid(taskID)])
        return rows.compactMap { r in
            guard let id = r.uuid(0), let tid = r.uuid(1),
                  let action = r.string(2).flatMap(ProfessionalTaskReviewAction.init(rawValue:)),
                  let reviewer = r.string(5), let at = r.date(7) else { return nil }
            return ProfessionalTaskReview(id: id, taskID: tid, action: action,
                                          priorStatus: r.string(3).flatMap(ProfessionalTaskStatus.init(rawValue:)),
                                          newStatus: r.string(4).flatMap(ProfessionalTaskStatus.init(rawValue:)),
                                          reviewer: reviewer, reason: r.string(6), reviewedAt: at,
                                          authorityKind: r.string(8).flatMap(TaskAuthorityKind.init(rawValue:)),
                                          ruleID: r.string(9), ruleVersion: r.string(10))
        }
    }

    // MARK: - Dependencies

    @discardableResult
    public func addDependency(taskID: UUID, dependsOn dependsOnTaskID: UUID,
                              kind: TaskDependencyKind, at date: Date) async throws -> TaskDependency {
        guard taskID != dependsOnTaskID else { throw ProfessionalTaskError.selfDependency }
        guard let a = try await task(id: taskID) else { throw ProfessionalTaskError.taskNotFound(taskID) }
        guard let b = try await task(id: dependsOnTaskID) else {
            throw ProfessionalTaskError.dependencyTaskNotFound(dependsOnTaskID)
        }
        guard a.workspaceID == b.workspaceID else { throw ProfessionalTaskError.crossWorkspaceDependency }
        let dup = try await database.query("""
        SELECT COUNT(*) FROM professional_task_dependencies
        WHERE task_id = ? AND depends_on_task_id = ? AND dependency_kind = ?;
        """, [.uuid(taskID), .uuid(dependsOnTaskID), .text(kind.rawValue)])
        guard Int(dup.first?.int(0) ?? 0) == 0 else { throw ProfessionalTaskError.duplicateDependency }
        // A blocking edge task→dependsOn creates a cycle iff taskID is already (transitively)
        // a blocking prerequisite of dependsOnTaskID.
        if kind == .blocking, try await blockingReaches(from: dependsOnTaskID, target: taskID) {
            throw ProfessionalTaskError.dependencyCycle
        }
        let dep = TaskDependency(id: UUID(), taskID: taskID, dependsOnTaskID: dependsOnTaskID,
                                 kind: kind, createdAt: date)
        try await database.exec("""
        INSERT INTO professional_task_dependencies (id, task_id, depends_on_task_id, dependency_kind, created_at)
        VALUES (?,?,?,?,?);
        """, [.uuid(dep.id), .uuid(taskID), .uuid(dependsOnTaskID), .text(kind.rawValue), .date(date)])
        return dep
    }

    public func removeDependency(id: UUID) async throws {
        let n = Int(try await database.query(
            "SELECT COUNT(*) FROM professional_task_dependencies WHERE id = ?;", [.uuid(id)]).first?.int(0) ?? 0)
        guard n == 1 else { throw ProfessionalTaskError.dependencyNotFound(id) }
        try await database.exec("DELETE FROM professional_task_dependencies WHERE id = ?;", [.uuid(id)])
    }

    public func dependencies(taskID: UUID) async throws -> [TaskDependency] {
        let rows = try await database.query("""
        SELECT id, task_id, depends_on_task_id, dependency_kind, created_at
        FROM professional_task_dependencies WHERE task_id = ? ORDER BY created_at ASC, id ASC;
        """, [.uuid(taskID)])
        return rows.compactMap { r in
            guard let id = r.uuid(0), let t = r.uuid(1), let on = r.uuid(2),
                  let kind = r.string(3).flatMap(TaskDependencyKind.init(rawValue:)),
                  let at = r.date(4) else { return nil }
            return TaskDependency(id: id, taskID: t, dependsOnTaskID: on, kind: kind, createdAt: at)
        }
    }

    // MARK: - Evidence links (IDs only; shared fail-closed validation)

    @discardableResult
    public func addEvidenceLink(taskID: UUID, scope: TaskEvidenceLinkScope,
                                target: TaskEvidenceTarget, role: TaskEvidenceLinkRole,
                                at date: Date) async throws -> TaskEvidenceLink {
        guard let t = try await task(id: taskID) else { throw ProfessionalTaskError.taskNotFound(taskID) }
        // A candidate/deadline scope must exist AND belong to this task.
        switch scope {
        case .task: break
        case .deadlineCandidate(let cid):
            let rows = try await database.query("SELECT task_id FROM deadline_candidates WHERE id = ?;", [.uuid(cid)])
            guard let owner = rows.first?.uuid(0) else { throw ProfessionalTaskError.scopeObjectNotFound }
            guard owner == taskID else { throw ProfessionalTaskError.scopeDoesNotBelongToTask }
        case .deadline(let did):
            let rows = try await database.query("SELECT task_id FROM deadlines WHERE id = ?;", [.uuid(did)])
            guard let owner = rows.first?.uuid(0) else { throw ProfessionalTaskError.scopeObjectNotFound }
            guard owner == taskID else { throw ProfessionalTaskError.scopeDoesNotBelongToTask }
        }
        do {
            try await WorkflowTargetValidator.validate(kind: target.kind, targetID: target.targetID,
                                                       workspaceID: t.workspaceID, database: database)
        } catch let e as WorkflowTargetValidationError {
            switch e {
            case .targetNotFound(let kind, let id): throw ProfessionalTaskError.targetNotFound(kind: kind, id: id)
            case .crossWorkspace(let kind, let id): throw ProfessionalTaskError.crossWorkspaceLink(kind: kind, id: id)
            }
        }
        let scopeID = scope.scopeID?.uuidString ?? ""
        let dup = try await database.query("""
        SELECT COUNT(*) FROM professional_task_evidence_links
        WHERE task_id = ? AND scope_kind = ? AND scope_id = ? AND target_kind = ? AND target_id = ? AND link_role = ?;
        """, [.uuid(taskID), .text(scope.kind), .text(scopeID), .text(target.kind),
              .uuid(target.targetID), .text(role.rawValue)])
        guard Int(dup.first?.int(0) ?? 0) == 0 else { throw ProfessionalTaskError.duplicateLink }
        let link = TaskEvidenceLink(id: UUID(), taskID: taskID, scope: scope, target: target,
                                    role: role, createdAt: date)
        try await database.exec("""
        INSERT INTO professional_task_evidence_links (id, task_id, scope_kind, scope_id, target_kind, target_id, link_role, created_at)
        VALUES (?,?,?,?,?,?,?,?);
        """, [.uuid(link.id), .uuid(taskID), .text(scope.kind), .text(scopeID),
              .text(target.kind), .uuid(target.targetID), .text(role.rawValue), .date(date)])
        return link
    }

    public func removeEvidenceLink(id: UUID) async throws {
        let n = Int(try await database.query(
            "SELECT COUNT(*) FROM professional_task_evidence_links WHERE id = ?;", [.uuid(id)]).first?.int(0) ?? 0)
        guard n == 1 else { throw ProfessionalTaskError.linkNotFound(id) }
        try await database.exec("DELETE FROM professional_task_evidence_links WHERE id = ?;", [.uuid(id)])
    }

    public func evidenceLinks(taskID: UUID) async throws -> [TaskEvidenceLink] {
        let rows = try await database.query("""
        SELECT id, task_id, scope_kind, scope_id, target_kind, target_id, link_role, created_at
        FROM professional_task_evidence_links WHERE task_id = ? ORDER BY created_at ASC, id ASC;
        """, [.uuid(taskID)])
        return rows.compactMap { r in
            guard let id = r.uuid(0), let tid = r.uuid(1), let scopeKind = r.string(2),
                  let scope = TaskEvidenceLinkScope(kind: scopeKind,
                                                    scopeID: (r.string(3)?.isEmpty == false) ? r.uuid(3) : nil),
                  let targetKind = r.string(4), let targetID = r.uuid(5),
                  let target = TaskEvidenceTarget(kind: targetKind, targetID: targetID),
                  let role = r.string(6).flatMap(TaskEvidenceLinkRole.init(rawValue:)),
                  let at = r.date(7) else { return nil }
            return TaskEvidenceLink(id: id, taskID: tid, scope: scope, target: target, role: role, createdAt: at)
        }
    }

    // MARK: - Transition matrix

    /// Legal `transition()` movements. Candidate active-work moves, completion, reopening and
    /// archiving are handled by their dedicated methods (confirmCandidate / complete / reopen /
    /// archive) so their audit actions are explicit.
    static func transitionAction(from prior: ProfessionalTaskStatus,
                                 to new: ProfessionalTaskStatus) throws -> ProfessionalTaskReviewAction {
        guard prior != new else { throw ProfessionalTaskError.invalidTransition(from: prior, to: new) }
        switch (prior, new) {
        case (.candidate, .cancelled):
            return .cancelled                                   // rejecting a proposal
        case (.open, .inProgress), (.open, .blocked),
             (.inProgress, .open), (.inProgress, .blocked),
             (.blocked, .open), (.blocked, .inProgress):
            return .statusChanged
        case (.open, .cancelled), (.inProgress, .cancelled), (.blocked, .cancelled):
            return .cancelled
        default:
            // candidate→open only via confirmCandidate; →completed only via complete();
            // completed/cancelled→open only via reopen(); →archived only via archive();
            // archived is terminal.
            throw ProfessionalTaskError.invalidTransition(from: prior, to: new)
        }
    }

    // MARK: - Internals

    private func insertTask(workspaceID: UUID, primaryIssueID: UUID?, title: String, detail: String?,
                            type: ProfessionalTaskType, priority: ProfessionalTaskPriority,
                            owner: String?, origin: ProfessionalTaskOrigin,
                            status: ProfessionalTaskStatus, reviewer: String,
                            authority: TaskCreationAuthority?,
                            at date: Date) async throws -> ProfessionalTask {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProfessionalTaskError.blankTitle }
        guard try await rowExists("workspaces", id: workspaceID) else {
            throw ProfessionalTaskError.workspaceNotFound(workspaceID)
        }
        if let issue = primaryIssueID {
            // The Issue must exist AND live in the SAME workspace — a task must never anchor to
            // another workspace's issue.
            let rows = try await database.query(
                "SELECT workspace_id FROM professional_issues WHERE id = ?;", [.uuid(issue)])
            guard let issueWorkspace = rows.first?.uuid(0) else {
                throw ProfessionalTaskError.issueNotFound(issue)
            }
            guard issueWorkspace == workspaceID else {
                throw ProfessionalTaskError.crossWorkspacePrimaryIssue(issue)
            }
        }
        let t = ProfessionalTask(id: UUID(), workspaceID: workspaceID, primaryIssueID: primaryIssueID,
                                 title: trimmed, detail: detail, type: type, status: status,
                                 priority: priority, owner: owner, origin: origin,
                                 createdAt: date, updatedAt: date, completedAt: nil, archivedAt: nil)
        let savepoint = "task_create_\(t.id.uuidString.replacingOccurrences(of: "-", with: ""))"
        do {
            try await database.exec("SAVEPOINT \(savepoint);")
            try await database.exec("""
            INSERT INTO professional_tasks (id, workspace_id, primary_issue_id, title, detail, task_type,
                                            status, priority, owner, origin, created_at, updated_at, completed_at, archived_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,NULL,NULL);
            """, [.uuid(t.id), .uuid(workspaceID), primaryIssueID.map { SQLValue.uuid($0) } ?? .null,
                  .text(trimmed), .optionalText(detail), .text(type.rawValue), .text(status.rawValue),
                  .text(priority.rawValue), .optionalText(owner), .text(origin.rawValue),
                  .date(date), .date(date)])
            try await insertReview(taskID: t.id, action: .created, prior: nil, new: status,
                                   reviewer: reviewer, reason: nil, authority: authority, at: date)
            try await database.exec("RELEASE SAVEPOINT \(savepoint);")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(savepoint);")
            try? await database.exec("RELEASE SAVEPOINT \(savepoint);")
            throw error
        }
        return t
    }

    private func applyStatusChange(_ t: ProfessionalTask, to status: ProfessionalTaskStatus,
                                   action: ProfessionalTaskReviewAction, reviewer: String,
                                   reason: String?, authority: TaskCreationAuthority? = nil,
                                   at date: Date) async throws -> ProfessionalTask {
        var updated = t
        updated.status = status
        updated.updatedAt = date
        updated.completedAt = status == .completed ? date : (action == .reopened ? nil : t.completedAt)
        updated.archivedAt = status == .archived ? date : t.archivedAt
        let savepoint = "task_tr_\(t.id.uuidString.replacingOccurrences(of: "-", with: ""))"
        do {
            try await database.exec("SAVEPOINT \(savepoint);")
            try await database.exec("""
            UPDATE professional_tasks SET status = ?, updated_at = ?, completed_at = ?, archived_at = ? WHERE id = ?;
            """, [.text(status.rawValue), .date(date),
                  updated.completedAt.map { SQLValue.date($0) } ?? .null,
                  updated.archivedAt.map { SQLValue.date($0) } ?? .null, .uuid(t.id)])
            if injectFailure == .beforeReviewInsert { throw InjectedTaskFailure() }
            try await insertReview(taskID: t.id, action: action, prior: t.status, new: status,
                                   reviewer: reviewer, reason: reason, authority: authority, at: date)
            try await database.exec("RELEASE SAVEPOINT \(savepoint);")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(savepoint);")
            try? await database.exec("RELEASE SAVEPOINT \(savepoint);")
            throw error
        }
        return updated
    }

    /// True when `target` is transitively reachable from `from` along BLOCKING dependencies.
    private func blockingReaches(from: UUID, target: UUID) async throws -> Bool {
        var frontier: [UUID] = [from]
        var seen: Set<UUID> = [from]
        while let current = frontier.popLast() {
            if current == target { return true }
            let next = try await database.query("""
            SELECT depends_on_task_id FROM professional_task_dependencies
            WHERE task_id = ? AND dependency_kind = 'blocking';
            """, [.uuid(current)]).compactMap { $0.uuid(0) }
            for n in next where seen.insert(n).inserted { frontier.append(n) }
        }
        return false
    }

    private let selectColumns = """
    SELECT id, workspace_id, primary_issue_id, title, detail, task_type, status, priority, owner,
           origin, created_at, updated_at, completed_at, archived_at
    FROM professional_tasks
    """

    private func decode(_ r: SQLRow) -> ProfessionalTask? {
        guard let id = r.uuid(0), let ws = r.uuid(1), let title = r.string(3),
              let type = r.string(5).flatMap(ProfessionalTaskType.init(rawValue:)),
              let status = r.string(6).flatMap(ProfessionalTaskStatus.init(rawValue:)),
              let priority = r.string(7).flatMap(ProfessionalTaskPriority.init(rawValue:)),
              let origin = r.string(9).flatMap(ProfessionalTaskOrigin.init(rawValue:)),
              let created = r.date(10), let updated = r.date(11) else { return nil }
        return ProfessionalTask(id: id, workspaceID: ws, primaryIssueID: r.uuid(2), title: title,
                                detail: r.string(4), type: type, status: status, priority: priority,
                                owner: r.string(8), origin: origin, createdAt: created,
                                updatedAt: updated, completedAt: r.date(12), archivedAt: r.date(13))
    }

    private func insertReview(taskID: UUID, action: ProfessionalTaskReviewAction,
                              prior: ProfessionalTaskStatus?, new: ProfessionalTaskStatus?,
                              reviewer: String, reason: String?,
                              authority: TaskCreationAuthority?, at date: Date) async throws {
        try await database.exec("""
        INSERT INTO professional_task_reviews (id, task_id, action, prior_status, new_status, reviewer, reason,
                                               reviewed_at, authority_kind, rule_id, rule_version)
        VALUES (?,?,?,?,?,?,?,?,?,?,?);
        """, [.uuid(UUID()), .uuid(taskID), .text(action.rawValue),
              .optionalText(prior?.rawValue), .optionalText(new?.rawValue),
              .text(reviewer), .optionalText(reason), .date(date),
              .optionalText(authority?.authorityKind.rawValue),
              .optionalText(authority?.ruleIdentity?.id),
              .optionalText(authority?.ruleIdentity?.version)])
    }

    private func rowExists(_ table: String, id: UUID) async throws -> Bool {
        Int(try await database.query("SELECT COUNT(*) FROM \(table) WHERE id = ?;", [.uuid(id)]).first?.int(0) ?? 0) > 0
    }
}
