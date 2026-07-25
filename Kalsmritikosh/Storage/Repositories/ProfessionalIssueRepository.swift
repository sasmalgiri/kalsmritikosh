//
//  ProfessionalIssueRepository.swift
//  Kalsmritikosh
//
//  OPS-001 — persistence for the shared professional Issue Engine (schema v68).
//
//  Guarantees:
//   • Canonical isolation: an Issue stores canonical TARGET IDS only; creating / resolving /
//     dismissing / archiving an Issue never touches claims, contradictions, gap_nodes, events or
//     any source evidence.
//   • Append-only lifecycle: every status transition writes an IssueReview inside the SAME
//     SAVEPOINT as the status update — a failed ledger write rolls the status change back.
//   • Fail-closed link validation: a link target must EXIST in its canonical table, and when its
//     workspace/source boundary is determinable, it must not belong exclusively to another
//     workspace. An unresolvable target is rejected, never silently accepted.
//   • No hard deletion through the public API (workspace deletion cascades via FK; archiving
//     preserves links + reviews).
//

import Foundation

public enum ProfessionalIssueError: Error, Equatable {
    case blankTitle
    case workspaceNotFound(UUID)
    case issueNotFound(UUID)
    case linkNotFound(UUID)
    case targetNotFound(kind: String, id: UUID)
    case duplicateLink
    case crossWorkspaceLink(kind: String, id: UUID)
    case invalidTransition(from: IssueStatus, to: IssueStatus)
}

public actor ProfessionalIssueRepository {
    private let database: Database

    public init(database: Database) { self.database = database }

    // MARK: - Test-only fault injection (mirrors ClaimRepository's precedent)

    /// Internal, settable only via `@testable` — forces the review INSERT inside `transition` to
    /// fail so tests can prove the status update rolls back. Never used in production.
    enum InjectedFailure { case beforeReviewInsert }
    private var injectFailure: InjectedFailure?
    func setInjectFailure(_ f: InjectedFailure?) { injectFailure = f }
    struct InjectedIssueFailure: Error {}

    // MARK: - Create

    public func create(workspaceID: UUID, title: String, detail: String?,
                       type: IssueType, priority: IssuePriority,
                       reviewer: String, at date: Date) async throws -> ProfessionalIssue {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProfessionalIssueError.blankTitle }
        guard try await rowExists("workspaces", id: workspaceID) else {
            throw ProfessionalIssueError.workspaceNotFound(workspaceID)
        }
        let issue = ProfessionalIssue(id: UUID(), workspaceID: workspaceID, title: trimmed,
                                      detail: detail, type: type, status: .open, priority: priority,
                                      createdAt: date, updatedAt: date, closedAt: nil)
        // Atomic: issue row + `created` ledger entry commit or roll back together.
        let savepoint = "issue_create_\(issue.id.uuidString.replacingOccurrences(of: "-", with: ""))"
        do {
            try await database.exec("SAVEPOINT \(savepoint);")
            try await database.exec("""
            INSERT INTO professional_issues (id, workspace_id, title, detail, issue_type, status, priority, created_at, updated_at, closed_at)
            VALUES (?,?,?,?,?,?,?,?,?,NULL);
            """, [.uuid(issue.id), .uuid(workspaceID), .text(trimmed), .optionalText(detail),
                  .text(type.rawValue), .text(IssueStatus.open.rawValue), .text(priority.rawValue),
                  .date(date), .date(date)])
            try await insertReview(issueID: issue.id, action: .created, prior: nil, new: .open,
                                   reviewer: reviewer, reason: nil, at: date)
            try await database.exec("RELEASE SAVEPOINT \(savepoint);")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(savepoint);")
            try? await database.exec("RELEASE SAVEPOINT \(savepoint);")
            throw error
        }
        return issue
    }

    // MARK: - Reads

    public func issue(id: UUID) async throws -> ProfessionalIssue? {
        let rows = try await database.query("\(selectColumns) WHERE id = ? LIMIT 1;", [.uuid(id)])
        return rows.first.flatMap(decode)
    }

    public func issues(workspaceID: UUID) async throws -> [ProfessionalIssue] {
        let rows = try await database.query(
            "\(selectColumns) WHERE workspace_id = ? ORDER BY created_at ASC, id ASC;", [.uuid(workspaceID)])
        return rows.compactMap(decode)
    }

    public func issues(workspaceID: UUID, statuses: Set<IssueStatus>,
                       types: Set<IssueType>) async throws -> [ProfessionalIssue] {
        // Empty filter set == no constraint on that dimension.
        var sql = "\(selectColumns) WHERE workspace_id = ?"
        var params: [SQLValue] = [.uuid(workspaceID)]
        if !statuses.isEmpty {
            sql += " AND status IN (\(statuses.map { _ in "?" }.joined(separator: ",")))"
            params += statuses.map { .text($0.rawValue) }.sorted { a, b in false }
        }
        if !types.isEmpty {
            sql += " AND issue_type IN (\(types.map { _ in "?" }.joined(separator: ",")))"
            params += types.map { .text($0.rawValue) }
        }
        sql += " ORDER BY created_at ASC, id ASC;"
        let rows = try await database.query(sql, params)
        return rows.compactMap(decode)
    }

    // MARK: - Links

    public func addLink(issueID: UUID, target: IssueLinkTarget, role: IssueLinkRole,
                        at date: Date) async throws -> IssueLink {
        guard let issue = try await issue(id: issueID) else {
            throw ProfessionalIssueError.issueNotFound(issueID)
        }
        try await validate(target: target, issueWorkspace: issue.workspaceID)
        // Duplicate = same (issue, kind, id, role); enforced by the UNIQUE constraint but checked
        // first for a typed error instead of a raw constraint failure.
        let dup = try await database.query("""
        SELECT COUNT(*) FROM professional_issue_links
        WHERE issue_id = ? AND target_kind = ? AND target_id = ? AND link_role = ?;
        """, [.uuid(issueID), .text(target.kind), .uuid(target.targetID), .text(role.rawValue)])
        guard Int(dup.first?.int(0) ?? 0) == 0 else { throw ProfessionalIssueError.duplicateLink }

        let link = IssueLink(id: UUID(), issueID: issueID, target: target, role: role, createdAt: date)
        try await database.exec("""
        INSERT INTO professional_issue_links (id, issue_id, target_kind, target_id, link_role, created_at)
        VALUES (?,?,?,?,?,?);
        """, [.uuid(link.id), .uuid(issueID), .text(target.kind), .uuid(target.targetID),
              .text(role.rawValue), .date(date)])
        return link
    }

    public func removeLink(id: UUID) async throws {
        let exists = try await database.query(
            "SELECT COUNT(*) FROM professional_issue_links WHERE id = ?;", [.uuid(id)])
        guard Int(exists.first?.int(0) ?? 0) == 1 else { throw ProfessionalIssueError.linkNotFound(id) }
        try await database.exec("DELETE FROM professional_issue_links WHERE id = ?;", [.uuid(id)])
    }

    public func links(issueID: UUID) async throws -> [IssueLink] {
        let rows = try await database.query("""
        SELECT id, issue_id, target_kind, target_id, link_role, created_at
        FROM professional_issue_links WHERE issue_id = ? ORDER BY created_at ASC, id ASC;
        """, [.uuid(issueID)])
        return rows.compactMap { r in
            guard let id = r.uuid(0), let iid = r.uuid(1), let kind = r.string(2), let tid = r.uuid(3),
                  let target = IssueLinkTarget(kind: kind, targetID: tid),
                  let role = r.string(4).flatMap(IssueLinkRole.init(rawValue:)),
                  let at = r.date(5) else { return nil }
            return IssueLink(id: id, issueID: iid, target: target, role: role, createdAt: at)
        }
    }

    // MARK: - Lifecycle

    @discardableResult
    public func transition(issueID: UUID, to status: IssueStatus, reviewer: String,
                           reason: String?, at date: Date) async throws -> ProfessionalIssue {
        guard var issue = try await issue(id: issueID) else {
            throw ProfessionalIssueError.issueNotFound(issueID)
        }
        let action = try Self.action(from: issue.status, to: status)

        let savepoint = "issue_tr_\(issueID.uuidString.replacingOccurrences(of: "-", with: ""))"
        let closesNow = [.resolved, .dismissed, .superseded, .archived].contains(status)
        do {
            try await database.exec("SAVEPOINT \(savepoint);")
            try await database.exec("""
            UPDATE professional_issues SET status = ?, updated_at = ?, closed_at = ? WHERE id = ?;
            """, [.text(status.rawValue), .date(date),
                  closesNow ? .date(date) : .null, .uuid(issueID)])
            if injectFailure == .beforeReviewInsert { throw InjectedIssueFailure() }
            try await insertReview(issueID: issueID, action: action, prior: issue.status,
                                   new: status, reviewer: reviewer, reason: reason, at: date)
            try await database.exec("RELEASE SAVEPOINT \(savepoint);")
        } catch {
            // A failed ledger write must roll the status change back — never a silent transition.
            try? await database.exec("ROLLBACK TO SAVEPOINT \(savepoint);")
            try? await database.exec("RELEASE SAVEPOINT \(savepoint);")
            throw error
        }
        issue.status = status
        issue.updatedAt = date
        issue.closedAt = closesNow ? date : nil
        return issue
    }

    public func reviews(issueID: UUID) async throws -> [IssueReview] {
        let rows = try await database.query("""
        SELECT id, issue_id, action, prior_status, new_status, reviewer, reason, reviewed_at
        FROM professional_issue_reviews WHERE issue_id = ? ORDER BY reviewed_at ASC, id ASC;
        """, [.uuid(issueID)])
        return rows.compactMap { r in
            guard let id = r.uuid(0), let iid = r.uuid(1),
                  let action = r.string(2).flatMap(IssueReviewAction.init(rawValue:)),
                  let reviewer = r.string(5), let at = r.date(7) else { return nil }
            return IssueReview(id: id, issueID: iid, action: action,
                               priorStatus: r.string(3).flatMap(IssueStatus.init(rawValue:)),
                               newStatus: r.string(4).flatMap(IssueStatus.init(rawValue:)),
                               reviewer: reviewer, reason: r.string(6), reviewedAt: at)
        }
    }

    public func archive(issueID: UUID, reviewer: String, reason: String?, at date: Date) async throws {
        _ = try await transition(issueID: issueID, to: .archived, reviewer: reviewer, reason: reason, at: date)
    }

    // MARK: - Transition matrix (workflow legality; never touches canonical truth)

    /// Legal transitions and their ledger action. `archived` is terminal; a dismissed Issue can
    /// only be explicitly REOPENED; resolved may reopen or archive; superseded may only archive.
    static func action(from prior: IssueStatus, to new: IssueStatus) throws -> IssueReviewAction {
        guard prior != new else { throw ProfessionalIssueError.invalidTransition(from: prior, to: new) }
        switch prior {
        case .archived:
            throw ProfessionalIssueError.invalidTransition(from: prior, to: new)   // terminal
        case .dismissed:
            guard new == .open else { throw ProfessionalIssueError.invalidTransition(from: prior, to: new) }
            return .reopened
        case .resolved:
            switch new {
            case .open:     return .reopened
            case .archived: return .archived
            default:        throw ProfessionalIssueError.invalidTransition(from: prior, to: new)
            }
        case .superseded:
            guard new == .archived else { throw ProfessionalIssueError.invalidTransition(from: prior, to: new) }
            return .archived
        case .open, .inReview, .blocked:
            switch new {
            case .resolved:   return .resolved
            case .dismissed:  return .dismissed
            case .superseded: return .superseded
            case .archived:   return .archived
            case .open, .inReview, .blocked: return .statusChanged
            }
        }
    }

    // MARK: - Link-target validation (fail-closed, shared)

    /// Delegates to the SHARED WorkflowTargetValidator (same rules as Task evidence links) and
    /// maps the shared failures onto this repository's error vocabulary.
    private func validate(target: IssueLinkTarget, issueWorkspace: UUID) async throws {
        do {
            try await WorkflowTargetValidator.validate(kind: target.kind, targetID: target.targetID,
                                                       workspaceID: issueWorkspace, database: database)
        } catch let e as WorkflowTargetValidationError {
            switch e {
            case .targetNotFound(let kind, let id):
                throw ProfessionalIssueError.targetNotFound(kind: kind, id: id)
            case .crossWorkspace(let kind, let id):
                throw ProfessionalIssueError.crossWorkspaceLink(kind: kind, id: id)
            }
        }
    }

    // MARK: - Internals

    private let selectColumns = """
    SELECT id, workspace_id, title, detail, issue_type, status, priority, created_at, updated_at, closed_at
    FROM professional_issues
    """

    private func decode(_ r: SQLRow) -> ProfessionalIssue? {
        guard let id = r.uuid(0), let ws = r.uuid(1), let title = r.string(2),
              let type = r.string(4).flatMap(IssueType.init(rawValue:)),
              let status = r.string(5).flatMap(IssueStatus.init(rawValue:)),
              let priority = r.string(6).flatMap(IssuePriority.init(rawValue:)),
              let created = r.date(7), let updated = r.date(8) else { return nil }
        return ProfessionalIssue(id: id, workspaceID: ws, title: title, detail: r.string(3),
                                 type: type, status: status, priority: priority,
                                 createdAt: created, updatedAt: updated, closedAt: r.date(9))
    }

    private func insertReview(issueID: UUID, action: IssueReviewAction, prior: IssueStatus?,
                              new: IssueStatus?, reviewer: String, reason: String?, at date: Date) async throws {
        try await database.exec("""
        INSERT INTO professional_issue_reviews (id, issue_id, action, prior_status, new_status, reviewer, reason, reviewed_at)
        VALUES (?,?,?,?,?,?,?,?);
        """, [.uuid(UUID()), .uuid(issueID), .text(action.rawValue),
              .optionalText(prior?.rawValue), .optionalText(new?.rawValue),
              .text(reviewer), .optionalText(reason), .date(date)])
    }

    private func rowExists(_ table: String, id: UUID) async throws -> Bool {
        let rows = try await database.query("SELECT COUNT(*) FROM \(table) WHERE id = ?;", [.uuid(id)])
        return Int(rows.first?.int(0) ?? 0) > 0
    }
}
