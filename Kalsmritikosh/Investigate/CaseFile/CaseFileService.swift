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
    public nonisolated let file: CaseFileRepository
    private let tasks: ProfessionalTaskRepository
    private let deadlines: DeadlineRepository
    private let cases: InvestigationCaseRepository
    private let workspaces: WorkspaceRepository
    /// §2 — the one verifier for case evidence (allegation links, chronology, report items, ACH
    /// citations, handoffs). Built over the same ledger with the same access policy the studios use.
    public nonisolated let verifier: CaseEvidenceVerifier
    /// §3 — the snapshot reads job-result revisions to flag superseded origins.
    nonisolated let results: JobResultRepository

    public init(database: Database, cases: InvestigationCaseRepository, workspaces: WorkspaceRepository) {
        let file = CaseFileRepository(database: database)
        self.file = file
        self.results = JobResultRepository(database: database)
        self.tasks = ProfessionalTaskRepository(database: database)
        self.deadlines = DeadlineRepository(database: database)
        self.cases = cases
        self.workspaces = workspaces
        self.verifier = Self.makeVerifier(database: database, cases: cases, file: file)
    }

    /// The verifier's dependencies: the case's eligible source versions under the export policy
    /// (`InvestigationDataLabService.eligibleSourceVersions`, as every studio and export uses), the
    /// case's documents and their text, the version's blocks, and the live exhibit register.
    nonisolated static func makeVerifier(database: Database, cases: InvestigationCaseRepository, file: CaseFileRepository) -> CaseEvidenceVerifier {
        let evidence = EvidenceStore(database: database)
        let objects = KnowledgeObjectRepository(database: database)
        let dataLab = InvestigationDataLabService(cases: cases, resolver: CaseRetrievalScopeResolver(evidence: evidence),
                                                  datasets: WorkbenchDatasetRepository(database: database), scopes: SensitiveScopeRepository(database: database))
        return CaseEvidenceVerifier(
            context: { caseID in
                guard let record = try? await cases.fetch(caseID: caseID) else { return nil }
                let access = SensitiveAccessContext(scope: SensitiveScope(workspaceID: record.caseHeader.workspaceID, maximumSensitivity: .restricted,
                                                                          permitsPrivilegedMaterial: false, purpose: .export))
                guard let (included, _) = try? await dataLab.eligibleSourceVersions(caseID: caseID, access: access) else { return nil }
                let versions = Set(included)
                guard let objectIDs = try? await objects.objectIDs(inSourceVersionIDs: versions),
                      let names = try? await objects.sourceFilenames(for: objectIDs),
                      let objectVersions = try? await objects.sourceVersionsByObject(inSourceVersionIDs: versions) else { return nil }
                return StudioEvidenceContext(
                    eligibleSourceVersions: versions, caseObjects: objectIDs, documentNames: names, objectVersions: objectVersions,
                    blockText: { id in
                        guard let r = try? await database.query("SELECT source_version_id, raw_text FROM evidence_blocks WHERE id = ? LIMIT 1;", [.uuid(id)]).first,
                              let text = r.string(1) else { return nil }
                        return (r.uuid(0), text)
                    },
                    objectText: { id in (try? await objects.fetchContent(id: id)) ?? nil })
            },
            exhibitLive: { caseID, number in
                ((try? await file.exhibits(caseID: caseID, includeWithdrawn: false)) ?? []).contains { $0.number == number }
            },
            blocksForVersion: { version in
                let rows = (try? await database.query("""
                    SELECT b.id, b.raw_text, (SELECT o.knowledge_object_id FROM evidence_block_objects o WHERE o.evidence_block_id = b.id LIMIT 1)
                    FROM evidence_blocks b WHERE b.source_version_id = ? ORDER BY b.ordinal;
                    """, [.uuid(version)])) ?? []
                return rows.compactMap { r in r.uuid(0).map { (id: $0, object: r.uuid(2), text: r.string(1) ?? "") } }
            })
    }

    // MARK: - §2 — verified evidence

    /// Verify a reference and passage in the case (no write).
    public func verify(reference: String, passage: StudioEvidenceRef?, caseID: UUID) async -> CaseEvidenceVerification {
        await verifier.verify(reference: reference, passage: passage, caseID: caseID)
    }

    /// Link evidence to an allegation THROUGH verification: the passage is checked against the source
    /// text in this case under the current policy, the result is stored with the link, and a quote
    /// found in exactly one block is pinned to it. An unverified link is still recorded — labelled
    /// unverified — because the person may fix or reject it; it is never documentary support.
    @discardableResult
    public func linkEvidence(caseID: UUID, allegationID: UUID, evidenceRef: String, label: String?, stance: GridStance, note: String?,
                             passage: StudioEvidenceRef? = nil, origin: String? = nil, reviewState: String? = nil, originDigest: String? = nil,
                             allowDuplicate: Bool = false, actor: String, at date: Date = Date()) async throws -> (id: UUID, verification: CaseEvidenceVerification) {
        let result = await verifier.verify(reference: evidenceRef, passage: passage, caseID: caseID)
        let id = try await file.addAllegationEvidence(caseID: caseID, allegationID: allegationID, evidenceRef: evidenceRef, label: label, stance: stance, note: note,
                                                      passage: result.passage ?? passage, origin: origin, support: result.support,
                                                      reviewState: reviewState, originDigest: originDigest, allowDuplicate: allowDuplicate, actor: actor, at: date)
        return (id, result)
    }

    /// Re-verify every live link of a case against the ledger as it is NOW (a source removed from the
    /// case, a withdrawn exhibit, a changed access label or a re-ingested version changes the stored
    /// state). Returns the links with their fresh verification.
    @discardableResult
    public func reverifyLinks(caseID: UUID, at date: Date = Date()) async throws -> [(link: AllegationEvidence, verification: CaseEvidenceVerification)] {
        var out: [(AllegationEvidence, CaseEvidenceVerification)] = []
        for link in try await file.allegationEvidence(caseID: caseID) {
            let v = await verifier.verify(reference: link.evidenceRef, passage: link.passage, caseID: caseID)
            try await file.recordVerification(linkID: link.id, caseID: caseID, v, at: date)
            out.append((link, v))
        }
        return out
    }

    /// Re-verify the chronology entries and report items that carry citations.
    public func reverifyCarriedItems(caseID: UUID, at date: Date = Date()) async throws {
        for e in try await file.journal(caseID: caseID) where e.evidenceRef != nil || !e.citations.isEmpty {
            let primary = e.citations.first ?? StudioEvidenceRef(sourceVersionID: e.evidenceRef.flatMap(UUID.init(uuidString:)), quote: e.quote)
            let ref = e.evidenceRef ?? primary.sourceVersionID?.uuidString ?? ""
            let v = await verifier.verify(reference: ref, passage: primary, caseID: caseID)
            try await file.recordVerification(journalID: e.id, caseID: caseID, v, at: date)
        }
        for i in try await file.reportItems(caseID: caseID) where i.evidenceRef != nil || !i.citations.isEmpty {
            let primary = i.citations.first ?? StudioEvidenceRef(sourceVersionID: i.evidenceRef.flatMap(UUID.init(uuidString:)), quote: i.quote)
            let ref = i.evidenceRef ?? primary.sourceVersionID?.uuidString ?? ""
            let v = await verifier.verify(reference: ref, passage: primary, caseID: caseID)
            try await file.recordVerification(reportItemID: i.id, caseID: caseID, v, at: date)
        }
    }

    /// Record a disposition. An adverse finding (substantiated) first RE-VERIFIES every link of the
    /// allegation against the ledger as it is now, so the repository's gate reads fresh states: a
    /// passage that no longer verifies, a withdrawn exhibit or a source that left the case is not
    /// documentary support at the moment of decision. An exception waives only the respondent's
    /// response, never this verification.
    public func decide(allegationID: UUID, caseID: UUID, disposition: AllegationDisposition, rationale: String?,
                       exception: String? = nil, actor: String, at date: Date = Date()) async throws {
        if disposition == .substantiated { try await reverifyLinks(caseID: caseID, at: date) }
        try await file.decide(allegationID: allegationID, caseID: caseID, disposition: disposition, rationale: rationale,
                              exception: exception, actor: actor, at: date)
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
