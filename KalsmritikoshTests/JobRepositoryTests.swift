//
//  JobRepositoryTests.swift
//  KalsmritikoshTests
//
//  TBJ-FINAL — durable Job persistence. Proves that a Job is a planning ENVELOPE over the existing
//  task / deadline / workflow authorities and never a second task or deadline system: it stores an
//  objective + budget + references + append-only events, validates every reference against its
//  authority + workspace, binds a budget ONLY to a CONFIRMED deadline (a candidate is refused),
//  applies optimistic CAS on the job revision, records closing/abandoning as human acts, and
//  reconstructs the exact plan + history after a simulated relaunch. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("TBJ-FINAL — JobRepository", .serialized)
struct JobRepositoryTests {

    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    private struct Rig {
        let db: Database
        let jobs: JobRepository
        let tasks: ProfessionalTaskRepository
        let deadlines: DeadlineRepository
        let ws: UUID
    }

    private func rig() async throws -> Rig {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(ws), .text("WS"), .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
        return Rig(db: db, jobs: JobRepository(database: db), tasks: ProfessionalTaskRepository(database: db),
                   deadlines: DeadlineRepository(database: db), ws: ws)
    }

    private func openTask(_ r: Rig, ws: UUID? = nil, type: ProfessionalTaskType = .action) async throws -> ProfessionalTask {
        try await r.tasks.createConfirmed(workspaceID: ws ?? r.ws, primaryIssueID: nil, title: "T",
                                          detail: nil, type: type, priority: .normal, owner: nil,
                                          authority: .user(actor: "u"), at: t0)
    }

    private func confirmedDeadline(_ r: Rig, task: ProfessionalTask, at due: Date) async throws -> Deadline {
        try await r.deadlines.createConfirmedDeadline(
            taskID: task.id, value: DeadlineValue(date: due, precision: .day, timeZoneIdentifier: "UTC"),
            kind: .due, confirmation: DeadlineConfirmation(kind: .user, confirmedBy: "u", confirmedAt: t0,
                                                           reason: nil, ruleID: nil, ruleVersion: nil), at: t0)
    }

    // MARK: - Create

    @Test("Create persists the objective and a single created event")
    func createPersists() async throws {
        let r = try await rig()
        let rec = try await r.jobs.createJob(workspaceID: r.ws, title: "Prepare filing", detail: "for court",
                                             budget: .none, primaryWorkflowRunID: nil, actor: "u", at: t0)
        #expect(rec.objective.title == "Prepare filing")
        #expect(rec.objective.lifecycle == .active)
        #expect(rec.objective.revision == 1)
        #expect(rec.events.count == 1)
        #expect(rec.events.first?.action == .created)
        #expect(rec.events.first?.sequence == 1)
    }

    @Test("Blank title / actor / unknown workspace are rejected")
    func createValidation() async throws {
        let r = try await rig()
        await #expect(throws: JobError.self) {
            _ = try await r.jobs.createJob(workspaceID: r.ws, title: "   ", detail: nil, budget: .none,
                                           primaryWorkflowRunID: nil, actor: "u", at: t0)
        }
        await #expect(throws: JobError.self) {
            _ = try await r.jobs.createJob(workspaceID: r.ws, title: "T", detail: nil, budget: .none,
                                           primaryWorkflowRunID: nil, actor: " ", at: t0)
        }
        await #expect(throws: JobError.self) {
            _ = try await r.jobs.createJob(workspaceID: UUID(), title: "T", detail: nil, budget: .none,
                                           primaryWorkflowRunID: nil, actor: "u", at: t0)
        }
    }

    @Test("An explicit-duration budget round-trips")
    func explicitBudgetRoundTrips() async throws {
        let r = try await rig()
        let rec = try await r.jobs.createJob(workspaceID: r.ws, title: "T", detail: nil,
                                             budget: .explicit(seconds: 7200), primaryWorkflowRunID: nil,
                                             actor: "u", at: t0)
        #expect(rec.objective.budget.basis == .explicitDuration)
        #expect(rec.objective.budget.explicitDuration == 7200)
    }

    // MARK: - Budget = CONFIRMED deadline only (candidate never authoritative)

    @Test("A budget may bind a CONFIRMED deadline but never a candidate")
    func budgetRequiresConfirmedDeadline() async throws {
        let r = try await rig()
        let task = try await openTask(r)
        let d = try await confirmedDeadline(r, task: task, at: t0.addingTimeInterval(86_400))
        // Confirmed deadline binds.
        let rec = try await r.jobs.createJob(workspaceID: r.ws, title: "T", detail: nil,
                                             budget: .confirmedDeadline(d.id), primaryWorkflowRunID: nil,
                                             actor: "u", at: t0)
        #expect(rec.objective.budget.deadlineID == d.id)
        // A pending CANDIDATE deadline id is NOT confirmed — refused.
        let candidate = try await r.deadlines.createCandidate(
            taskID: task.id, value: DeadlineValue(date: t0.addingTimeInterval(172_800), precision: .day, timeZoneIdentifier: "UTC"),
            kind: .due, origin: .userProposed, confidence: nil, proposedBy: "u", ruleID: nil, ruleVersion: nil, at: t0)
        await #expect(throws: JobError.self) {
            _ = try await r.jobs.createJob(workspaceID: r.ws, title: "T2", detail: nil,
                                           budget: .confirmedDeadline(candidate.id), primaryWorkflowRunID: nil,
                                           actor: "u", at: t0)
        }
    }

    @Test("A confirmed deadline from another workspace is refused")
    func crossWorkspaceDeadlineRefused() async throws {
        let r = try await rig()
        let otherWS = UUID()
        try await r.db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                            [.uuid(otherWS), .text("B"), .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
        let foreignTask = try await openTask(r, ws: otherWS)
        let d = try await confirmedDeadline(r, task: foreignTask, at: t0.addingTimeInterval(86_400))
        await #expect(throws: JobError.self) {
            _ = try await r.jobs.createJob(workspaceID: r.ws, title: "T", detail: nil,
                                           budget: .confirmedDeadline(d.id), primaryWorkflowRunID: nil,
                                           actor: "u", at: t0)
        }
    }

    // MARK: - References (not a second task system)

    @Test("Adding a task reference stores a pointer, never a new task; ordinal + revision advance")
    func addReferenceIsAPointer() async throws {
        let r = try await rig()
        let task = try await openTask(r)
        let rec0 = try await r.jobs.createJob(workspaceID: r.ws, title: "T", detail: nil, budget: .none,
                                              primaryWorkflowRunID: nil, actor: "u", at: t0)
        let taskCountBefore = Int(try await r.db.query("SELECT COUNT(*) FROM professional_tasks;", []).first?.int(0) ?? -1)
        let rec1 = try await r.jobs.addReference(jobID: rec0.objective.id, kind: .professionalTask,
                                                 referenceID: task.id.uuidString, workflowRunID: nil,
                                                 role: .required, isMinimumDeliverable: true, note: nil,
                                                 expectedRevision: 1, actor: "u", at: t0)
        #expect(rec1.references.count == 1)
        #expect(rec1.references.first?.ordinal == 0)
        #expect(rec1.objective.revision == 2)
        // No new task row was created — the job only points at the existing one.
        let taskCountAfter = Int(try await r.db.query("SELECT COUNT(*) FROM professional_tasks;", []).first?.int(0) ?? -1)
        #expect(taskCountAfter == taskCountBefore)
        #expect(rec1.events.last?.action == .referenceAdded)
    }

    @Test("A task reference must resolve and belong to the job's workspace")
    func referenceValidation() async throws {
        let r = try await rig()
        let rec = try await r.jobs.createJob(workspaceID: r.ws, title: "T", detail: nil, budget: .none,
                                             primaryWorkflowRunID: nil, actor: "u", at: t0)
        // Nonexistent task.
        await #expect(throws: JobError.self) {
            _ = try await r.jobs.addReference(jobID: rec.objective.id, kind: .professionalTask,
                                              referenceID: UUID().uuidString, workflowRunID: nil, role: .required,
                                              isMinimumDeliverable: false, note: nil, expectedRevision: 1, actor: "u", at: t0)
        }
        // Cross-workspace task.
        let otherWS = UUID()
        try await r.db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                            [.uuid(otherWS), .text("B"), .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
        let foreign = try await openTask(r, ws: otherWS)
        await #expect(throws: JobError.self) {
            _ = try await r.jobs.addReference(jobID: rec.objective.id, kind: .professionalTask,
                                              referenceID: foreign.id.uuidString, workflowRunID: nil, role: .required,
                                              isMinimumDeliverable: false, note: nil, expectedRevision: 1, actor: "u", at: t0)
        }
    }

    @Test("The same reference cannot be added twice")
    func duplicateReferenceRejected() async throws {
        let r = try await rig()
        let task = try await openTask(r)
        let rec = try await r.jobs.createJob(workspaceID: r.ws, title: "T", detail: nil, budget: .none,
                                             primaryWorkflowRunID: nil, actor: "u", at: t0)
        _ = try await r.jobs.addReference(jobID: rec.objective.id, kind: .professionalTask,
                                          referenceID: task.id.uuidString, workflowRunID: nil, role: .required,
                                          isMinimumDeliverable: false, note: nil, expectedRevision: 1, actor: "u", at: t0)
        await #expect(throws: JobError.self) {
            _ = try await r.jobs.addReference(jobID: rec.objective.id, kind: .professionalTask,
                                              referenceID: task.id.uuidString, workflowRunID: nil, role: .required,
                                              isMinimumDeliverable: false, note: nil, expectedRevision: 2, actor: "u", at: t0)
        }
    }

    @Test("A stale expected revision is a CAS conflict")
    func casConflict() async throws {
        let r = try await rig()
        let task = try await openTask(r)
        let rec = try await r.jobs.createJob(workspaceID: r.ws, title: "T", detail: nil, budget: .none,
                                             primaryWorkflowRunID: nil, actor: "u", at: t0)
        await #expect(throws: JobError.self) {
            _ = try await r.jobs.addReference(jobID: rec.objective.id, kind: .professionalTask,
                                              referenceID: task.id.uuidString, workflowRunID: nil, role: .required,
                                              isMinimumDeliverable: false, note: nil, expectedRevision: 99, actor: "u", at: t0)
        }
    }

    @Test("A reference's role and minimum-deliverable flag can be updated, then removed")
    func updateAndRemoveReference() async throws {
        let r = try await rig()
        let task = try await openTask(r)
        var rec = try await r.jobs.createJob(workspaceID: r.ws, title: "T", detail: nil, budget: .none,
                                             primaryWorkflowRunID: nil, actor: "u", at: t0)
        rec = try await r.jobs.addReference(jobID: rec.objective.id, kind: .professionalTask,
                                            referenceID: task.id.uuidString, workflowRunID: nil, role: .optional,
                                            isMinimumDeliverable: false, note: nil, expectedRevision: 1, actor: "u", at: t0)
        let refID = try #require(rec.references.first?.id)
        rec = try await r.jobs.updateReference(referenceID: refID, role: .required, isMinimumDeliverable: true,
                                               expectedRevision: 2, actor: "u", at: t0)
        #expect(rec.references.first?.role == .required)
        #expect(rec.references.first?.isMinimumDeliverable == true)
        rec = try await r.jobs.removeReference(referenceID: refID, expectedRevision: 3, actor: "u", at: t0)
        #expect(rec.references.isEmpty)
        #expect(rec.events.last?.action == .referenceRemoved)
    }

    // MARK: - Lifecycle (human acts)

    @Test("Closing is a human act; a closed job rejects further plan edits until reopened")
    func closeIsHumanAct() async throws {
        let r = try await rig()
        let task = try await openTask(r)
        var rec = try await r.jobs.createJob(workspaceID: r.ws, title: "T", detail: nil, budget: .none,
                                             primaryWorkflowRunID: nil, actor: "u", at: t0)
        rec = try await r.jobs.close(jobID: rec.objective.id, reason: "delivered", expectedRevision: 1,
                                     actor: "counsel", at: t0.addingTimeInterval(10))
        #expect(rec.objective.lifecycle == .closed)
        #expect(rec.objective.closedAt != nil)
        #expect(rec.events.last?.action == .closed)
        // Cannot mutate a closed job's plan.
        await #expect(throws: JobError.self) {
            _ = try await r.jobs.addReference(jobID: rec.objective.id, kind: .professionalTask,
                                              referenceID: task.id.uuidString, workflowRunID: nil, role: .required,
                                              isMinimumDeliverable: false, note: nil, expectedRevision: 2, actor: "u", at: t0)
        }
        // Reopen reactivates and clears closure.
        rec = try await r.jobs.reopen(jobID: rec.objective.id, expectedRevision: 2, actor: "counsel", at: t0.addingTimeInterval(20))
        #expect(rec.objective.lifecycle == .active)
        #expect(rec.objective.closedAt == nil)
        #expect(rec.events.last?.action == .reopened)
    }

    @Test("Abandoning preserves the plan and its history")
    func abandonPreservesPlan() async throws {
        let r = try await rig()
        let task = try await openTask(r)
        var rec = try await r.jobs.createJob(workspaceID: r.ws, title: "T", detail: nil, budget: .none,
                                             primaryWorkflowRunID: nil, actor: "u", at: t0)
        rec = try await r.jobs.addReference(jobID: rec.objective.id, kind: .professionalTask,
                                            referenceID: task.id.uuidString, workflowRunID: nil, role: .required,
                                            isMinimumDeliverable: false, note: nil, expectedRevision: 1, actor: "u", at: t0)
        rec = try await r.jobs.abandon(jobID: rec.objective.id, reason: "superseded", expectedRevision: 2, actor: "u", at: t0)
        #expect(rec.objective.lifecycle == .abandoned)
        #expect(rec.references.count == 1)   // plan preserved
        #expect(rec.events.contains { $0.action == .abandoned })
    }

    // MARK: - Durable resume (plan reconstruction, no LLM memory)

    @Test("A job's full plan + history reconstruct exactly after a simulated relaunch")
    func resumeAfterRelaunch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tbj-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("db.sqlite")

        let db1 = try Database(url: url)
        try await SchemaMigrations.migrate(db1)
        let ws = UUID()
        try await db1.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                           [.uuid(ws), .text("WS"), .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
        let tasks1 = ProfessionalTaskRepository(database: db1)
        let task = try await tasks1.createConfirmed(workspaceID: ws, primaryIssueID: nil, title: "T", detail: nil,
                                                    type: .action, priority: .normal, owner: nil,
                                                    authority: .user(actor: "u"), at: t0)
        let jobs1 = JobRepository(database: db1)
        var rec = try await jobs1.createJob(workspaceID: ws, title: "Investigate delay", detail: "root cause",
                                            budget: .explicit(seconds: 3600), primaryWorkflowRunID: nil, actor: "u", at: t0)
        let jobID = rec.objective.id
        rec = try await jobs1.addReference(jobID: jobID, kind: .professionalTask, referenceID: task.id.uuidString,
                                           workflowRunID: nil, role: .required, isMinimumDeliverable: true,
                                           note: "the deliverable", expectedRevision: 1, actor: "u", at: t0)

        // Simulate relaunch: a brand-new Database + repository over the SAME file. No reconstruction
        // from prose — the durable rows are the source of truth.
        let db2 = try Database(url: url)
        try await SchemaMigrations.migrate(db2)
        let jobs2 = JobRepository(database: db2)
        let reopened = try #require(try await jobs2.fetch(jobID: jobID))
        #expect(reopened.objective.title == "Investigate delay")
        #expect(reopened.objective.budget.explicitDuration == 3600)
        #expect(reopened.references.count == 1)
        #expect(reopened.references.first?.referenceID == task.id.uuidString)
        #expect(reopened.references.first?.isMinimumDeliverable == true)
        #expect(reopened.plan.minimumAcceptableDeliverable.references.count == 1)
        // Contiguous event history survived.
        #expect(reopened.events.map(\.sequence) == Array(1...reopened.events.count))
    }

    @Test("Jobs list by workspace and lifecycle")
    func jobIDsFilter() async throws {
        let r = try await rig()
        let a = try await r.jobs.createJob(workspaceID: r.ws, title: "A", detail: nil, budget: .none,
                                           primaryWorkflowRunID: nil, actor: "u", at: t0)
        _ = try await r.jobs.createJob(workspaceID: r.ws, title: "B", detail: nil, budget: .none,
                                       primaryWorkflowRunID: nil, actor: "u", at: t0)
        _ = try await r.jobs.close(jobID: a.objective.id, reason: nil, expectedRevision: 1, actor: "u", at: t0)
        #expect(try await r.jobs.jobIDs(workspaceID: r.ws).count == 2)
        #expect(try await r.jobs.jobIDs(workspaceID: r.ws, lifecycles: [.active]).count == 1)
        #expect(try await r.jobs.jobIDs(workspaceID: r.ws, lifecycles: [.closed]).count == 1)
    }
}
