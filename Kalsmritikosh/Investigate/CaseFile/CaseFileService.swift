//
//  CaseFileService.swift
//  Kalsmritikosh
//
//  Case tasks and deadlines (C-6/C-7) over the ONE task engine: a case task is a ProfessionalTask
//  opened with user authority, its due date a confirmed Deadline (DeadlineRepository), and the case
//  holds only the link. Plus templates (C-10) and the caseload over cases (C-8).
//

import Foundation
import os

/// One row of the caseload (C-8).
public nonisolated struct CaseloadRow: Identifiable, Sendable, Equatable {
    public let caseID: UUID
    public let workspaceID: UUID
    public let title: String
    public let stage: CaseStage
    public let severity: CaseSeverity?
    public let owner: String?
    public let kind: String?
    public let openedAt: Date
    public let openTasks: Int
    public let overdueTasks: Int
    public let nextDue: Date?
    public let nextTask: String?
    public let outstandingHolds: Int
    public let retainUntil: Date?
    public let archived: Bool
    public var id: UUID { caseID }
    public func ageDays(at date: Date) -> Int { max(0, Calendar.current.dateComponents([.day], from: openedAt, to: date).day ?? 0) }
}

public actor CaseFileService {
    public let file: CaseFileRepository
    private let tasks: ProfessionalTaskRepository
    private let deadlines: DeadlineRepository
    private let cases: InvestigationCaseRepository
    private let workspaces: WorkspaceRepository

    public init(database: Database, cases: InvestigationCaseRepository, workspaces: WorkspaceRepository) {
        self.file = CaseFileRepository(database: database)
        self.tasks = ProfessionalTaskRepository(database: database)
        self.deadlines = DeadlineRepository(database: database)
        self.cases = cases
        self.workspaces = workspaces
    }

    public func caseHeader(_ id: UUID) async throws -> InvestigationCase? { try await cases.fetch(caseID: id)?.caseHeader }

    // MARK: - Tasks + deadlines

    /// Add a case task; with `due`, a confirmed deadline the person sets.
    @discardableResult
    public func addTask(caseID: UUID, workspaceID: UUID, title: String, detail: String? = nil, type: ProfessionalTaskType = .action,
                        priority: ProfessionalTaskPriority = .normal, assignee: String?, due: Date?, actor: String,
                        at date: Date = Date()) async throws -> UUID {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw CaseFileError.blank("The task") }
        let task = try await tasks.createConfirmed(workspaceID: workspaceID, primaryIssueID: nil, title: clean, detail: detail, type: type,
                                                   priority: priority, owner: assignee?.isEmpty == true ? nil : assignee,
                                                   authority: .user(actor: actor), at: date)
        try await file.linkTask(caseID: caseID, taskID: task.id, title: clean, actor: actor, at: date)
        if let due { try await setDue(caseID: caseID, taskID: task.id, due: due, actor: actor, at: date) }
        return task.id
    }

    /// Set or move a task's due date: the old deadline is superseded (kept), a new one confirmed.
    public func setDue(caseID: UUID, taskID: UUID, due: Date, actor: String, at date: Date = Date()) async throws {
        for d in try await deadlines.deadlines(taskID: taskID, statuses: [.active]) {
            try await deadlines.supersede(id: d.id, reviewer: actor, reason: "Due date changed", at: date)
        }
        let value = DeadlineValue(date: Calendar.current.startOfDay(for: due).addingTimeInterval(17 * 3600),
                                  precision: .day, timeZoneIdentifier: TimeZone.current.identifier)
        _ = try await deadlines.createConfirmedDeadline(
            taskID: taskID, value: value, kind: .due,
            confirmation: DeadlineConfirmation(kind: .user, confirmedBy: actor, confirmedAt: date, reason: "Set in the case file",
                                               ruleID: nil, ruleVersion: nil), at: date)
        try await file.logAction(caseID: caseID, action: "dueSet", detail: ISO8601DateFormatter().string(from: due), actor: actor, at: date)
    }

    public func caseTasks(caseID: UUID) async throws -> [CaseTaskItem] {
        var out: [CaseTaskItem] = []
        for id in try await file.linkedTaskIDs(caseID: caseID) {
            guard let t = try await tasks.task(id: id), t.status != .archived else { continue }
            let d = try await deadlines.deadlines(taskID: id, statuses: [.active, .satisfied]).sorted { $0.createdAt > $1.createdAt }.first
            out.append(CaseTaskItem(task: t, deadline: d))
        }
        return out.sorted { a, b in
            switch (a.deadline?.value.date, b.deadline?.value.date) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.task.createdAt < b.task.createdAt
            }
        }
    }

    public func completeTask(caseID: UUID, taskID: UUID, actor: String, at date: Date = Date()) async throws {
        _ = try await tasks.complete(taskID: taskID, reviewer: actor, reason: nil, at: date)
        for d in try await deadlines.deadlines(taskID: taskID, statuses: [.active]) {
            try await deadlines.satisfy(id: d.id, reviewer: actor, reason: "Task completed", at: date)
        }
        try await file.logAction(caseID: caseID, action: "taskCompleted", detail: nil, actor: actor, at: date)
    }

    public func reopenTask(caseID: UUID, taskID: UUID, actor: String, at date: Date = Date()) async throws {
        _ = try await tasks.reopen(taskID: taskID, reviewer: actor, reason: nil, at: date)
        try await file.logAction(caseID: caseID, action: "taskReopened", detail: nil, actor: actor, at: date)
    }

    public func setTaskStatus(caseID: UUID, taskID: UUID, to status: ProfessionalTaskStatus, actor: String, at date: Date = Date()) async throws {
        _ = try await tasks.transition(taskID: taskID, to: status, reviewer: actor, reason: nil, at: date)
        try await file.logAction(caseID: caseID, action: "taskStatus", detail: status.rawValue, actor: actor, at: date)
    }

    // MARK: - Templates

    /// Apply a template: plan (only where the plan is still empty), retention, tasks with due dates,
    /// and starter allegations (only when the case has none).
    public func applyTemplate(_ template: CaseTemplate, caseID: UUID, workspaceID: UUID, actor: String, at date: Date = Date()) async throws {
        var p = try await file.profile(caseID: caseID)
        p.kind = template.id
        if p.plan.isEmpty { p.plan = template.plan }
        if p.retentionPolicy == nil { p.retentionPolicy = template.retentionPolicy }
        if p.owner == nil { p.owner = actor }
        try await file.saveProfile(p, actor: actor, at: date)
        let cal = Calendar.current
        for t in template.tasks {
            let due = t.dueInDays.flatMap { cal.date(byAdding: .day, value: $0, to: date) }
            try await addTask(caseID: caseID, workspaceID: workspaceID, title: t.title, type: t.type, priority: t.priority,
                              assignee: actor, due: due, actor: actor, at: date)
        }
        if try await file.allegations(caseID: caseID).isEmpty {
            for a in template.allegationPrompts { try await file.addAllegation(caseID: caseID, text: a, actor: actor, at: date) }
        }
        try await file.logAction(caseID: caseID, action: "templateApplied", detail: template.title, actor: actor, at: date)
    }

    // MARK: - Caseload (C-8)

    public func caseload(includeArchived: Bool = false, at now: Date = Date()) async throws -> [CaseloadRow] {
        let profiles = Dictionary(uniqueKeysWithValues: try await file.allProfiles().map { ($0.caseID, $0) })
        var rows: [CaseloadRow] = []
        for ws in try await workspaces.all(includeArchived: false) {
            for c in try await cases.listCases(workspaceID: ws.id) {
                let p = profiles[c.id] ?? CaseProfile(caseID: c.id, stage: c.status == .closed ? .closed : .open, updatedAt: c.updatedAt)
                if p.archivedAt != nil && !includeArchived { continue }
                let stage: CaseStage = c.status == .closed ? .closed : p.stage
                let items = try await caseTasks(caseID: c.id)
                let open = items.filter { [.open, .inProgress, .blocked].contains($0.task.status) }
                let next = open.compactMap { i in i.deadline.map { (i, $0.value.date) } }.min { $0.1 < $1.1 }
                let holds = try await file.holdNotices(caseID: c.id).filter(\.isOutstanding).count
                rows.append(CaseloadRow(caseID: c.id, workspaceID: ws.id, title: c.title, stage: stage, severity: p.triage.severity,
                                        owner: p.owner, kind: p.kind, openedAt: c.createdAt, openTasks: open.count,
                                        overdueTasks: open.filter { $0.isOverdue(at: now) }.count, nextDue: next?.1,
                                        nextTask: next?.0.task.title, outstandingHolds: holds, retainUntil: p.retainUntil,
                                        archived: p.archivedAt != nil))
            }
        }
        return rows.sorted {
            if $0.stage.isActive != $1.stage.isActive { return $0.stage.isActive }
            if $0.overdueTasks != $1.overdueTasks { return $0.overdueTasks > $1.overdueTasks }
            if ($0.severity?.rank ?? -1) != ($1.severity?.rank ?? -1) { return ($0.severity?.rank ?? -1) > ($1.severity?.rank ?? -1) }
            return ($0.nextDue ?? .distantFuture) < ($1.nextDue ?? .distantFuture)
        }
    }

    /// Cases whose retention date has passed (S-1). Retention never deletes: the person reviews each
    /// case and chooses to keep it longer, archive it, or erase its sources through the confirmed path.
    public func dueForRetentionReview(at now: Date = Date()) async throws -> [CaseloadRow] {
        try await caseload(includeArchived: true, at: now).filter { ($0.retainUntil ?? .distantFuture) <= now }
    }
}
