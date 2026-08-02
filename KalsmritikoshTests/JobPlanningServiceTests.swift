//
//  JobPlanningServiceTests.swift
//  KalsmritikoshTests
//
//  TBJ-FINAL — the deterministic planner. Derives the honest, current time-bounded outcome from a
//  durable JobRecord + the LIVE task / deadline authorities: confirmed-only countdowns (a candidate
//  is surfaced as an advisory, never a countdown), expired-deadline overdue detection, explicit
//  budget remaining, dependency-aware blocking, deterministic priority bands (never a function of
//  evidence confidence), minimum-deliverable status, and an honest partial outcome that NEVER marks
//  the underlying job complete. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("TBJ-FINAL — JobPlanningService", .serialized)
struct JobPlanningServiceTests {

    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    private struct Rig {
        let db: Database
        let jobs: JobRepository
        let tasks: ProfessionalTaskRepository
        let deadlines: DeadlineRepository
        let service: JobPlanningService
        let ws: UUID
    }

    private func rig() async throws -> Rig {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(ws), .text("WS"), .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
        let tasks = ProfessionalTaskRepository(database: db)
        let deadlines = DeadlineRepository(database: db)
        let workflows = WorkflowRunRepository(database: db)
        return Rig(db: db, jobs: JobRepository(database: db), tasks: tasks, deadlines: deadlines,
                   service: JobPlanningService(tasks: tasks, deadlines: deadlines, workflows: workflows), ws: ws)
    }

    @discardableResult
    private func task(_ r: Rig, type: ProfessionalTaskType = .action) async throws -> ProfessionalTask {
        try await r.tasks.createConfirmed(workspaceID: r.ws, primaryIssueID: nil, title: "T", detail: nil,
                                          type: type, priority: .normal, owner: nil,
                                          authority: .user(actor: "u"), at: t0)
    }

    private func jobReferencingTasks(_ r: Rig, budget: TimeBudget = .none,
                                     _ refs: [(ProfessionalTask, JobPlanReferenceRole, Bool)]) async throws -> JobRecord {
        var rec = try await r.jobs.createJob(workspaceID: r.ws, title: "Job", detail: nil, budget: budget,
                                             primaryWorkflowRunID: nil, actor: "u", at: t0)
        var rev = rec.objective.revision
        for (t, role, mad) in refs {
            rec = try await r.jobs.addReference(jobID: rec.objective.id, kind: .professionalTask,
                                                referenceID: t.id.uuidString, workflowRunID: nil, role: role,
                                                isMinimumDeliverable: mad, note: nil, expectedRevision: rev, actor: "u", at: t0)
            rev = rec.objective.revision
        }
        return rec
    }

    // MARK: - Time budget

    @Test("A job with no bound is unbounded")
    func unbounded() async throws {
        let r = try await rig()
        let rec = try await r.jobs.createJob(workspaceID: r.ws, title: "J", detail: nil, budget: .none,
                                             primaryWorkflowRunID: nil, actor: "u", at: t0)
        let b = try await r.service.budgetStatus(for: rec, now: t0)
        #expect(b.basis == .none)
        #expect(b.isConfirmed == false)
        #expect(b.remaining == nil)
        #expect(b.advisory == nil)
    }

    @Test("A pending candidate deadline surfaces as an advisory, never a countdown")
    func candidateAdvisoryNotCountdown() async throws {
        let r = try await rig()
        let t = try await task(r)
        _ = try await r.deadlines.createCandidate(
            taskID: t.id, value: DeadlineValue(date: t0.addingTimeInterval(86_400), precision: .day, timeZoneIdentifier: "UTC"),
            kind: .due, origin: .userProposed, confidence: nil, proposedBy: "u", ruleID: nil, ruleVersion: nil, at: t0)
        let rec = try await jobReferencingTasks(r, [(t, .required, false)])
        let b = try await r.service.budgetStatus(for: rec, now: t0)
        #expect(b.basis == .none)
        #expect(b.isConfirmed == false)
        #expect(b.remaining == nil)                       // never a fabricated countdown
        #expect(b.advisory == "Possible deadline — needs confirmation.")
    }

    @Test("A confirmed future deadline yields a real countdown; precision is carried")
    func confirmedCountdown() async throws {
        let r = try await rig()
        let t = try await task(r)
        let due = t0.addingTimeInterval(10 * 24 * 3600)
        let d = try await r.deadlines.createConfirmedDeadline(
            taskID: t.id, value: DeadlineValue(date: due, precision: .day, timeZoneIdentifier: "UTC"),
            kind: .due, confirmation: DeadlineConfirmation(kind: .user, confirmedBy: "u", confirmedAt: t0,
                                                           reason: nil, ruleID: nil, ruleVersion: nil), at: t0)
        let rec = try await r.jobs.createJob(workspaceID: r.ws, title: "J", detail: nil,
                                             budget: .confirmedDeadline(d.id), primaryWorkflowRunID: nil, actor: "u", at: t0)
        let b = try await r.service.budgetStatus(for: rec, now: t0)
        #expect(b.isConfirmed)
        #expect(b.precision == .day)
        #expect((b.remaining ?? 0) > 0)
        #expect(b.risk == .onTrack)
    }

    @Test("A confirmed deadline already past is overdue")
    func expiredIsOverdue() async throws {
        let r = try await rig()
        let t = try await task(r)
        let due = t0.addingTimeInterval(5 * 24 * 3600)
        let d = try await r.deadlines.createConfirmedDeadline(
            taskID: t.id, value: DeadlineValue(date: due, precision: .day, timeZoneIdentifier: "UTC"),
            kind: .due, confirmation: DeadlineConfirmation(kind: .user, confirmedBy: "u", confirmedAt: t0,
                                                           reason: nil, ruleID: nil, ruleVersion: nil), at: t0)
        let rec = try await r.jobs.createJob(workspaceID: r.ws, title: "J", detail: nil,
                                             budget: .confirmedDeadline(d.id), primaryWorkflowRunID: nil, actor: "u", at: t0)
        // "now" is well past the due date.
        let b = try await r.service.budgetStatus(for: rec, now: due.addingTimeInterval(3600))
        #expect(b.isConfirmed)
        #expect((b.remaining ?? 0) < 0)
        #expect(b.risk == .overdue)
    }

    @Test("An explicit duration counts down from the job start")
    func explicitRemaining() async throws {
        let r = try await rig()
        let rec = try await r.jobs.createJob(workspaceID: r.ws, title: "J", detail: nil,
                                             budget: .explicit(seconds: 48 * 3600), primaryWorkflowRunID: nil, actor: "u", at: t0)
        let onTrack = try await r.service.budgetStatus(for: rec, now: t0)
        #expect(onTrack.isConfirmed)
        #expect(onTrack.risk == .onTrack)                 // 48h remaining, outside the 24h at-risk window
        let over = try await r.service.budgetStatus(for: rec, now: t0.addingTimeInterval(50 * 3600))
        #expect(over.risk == .overdue)                    // past the allotment
    }

    // MARK: - Reference state resolution

    @Test("Task references resolve to honest states by status and type")
    func taskStates() async throws {
        let r = try await rig()
        let completed = try await task(r)
        _ = try await r.tasks.complete(taskID: completed.id, reviewer: "u", reason: nil, at: t0)
        let open = try await task(r)
        let blocked = try await task(r)
        _ = try await r.tasks.transition(taskID: blocked.id, to: .blocked, reviewer: "u", reason: nil, at: t0)
        let evidence = try await task(r, type: .evidenceRequest)
        let review = try await task(r, type: .review)

        let rec = try await jobReferencingTasks(r, [
            (completed, .required, false), (open, .required, false), (blocked, .required, false),
            (evidence, .required, false), (review, .required, false)])
        let states = try await r.service.resolveStates(rec.references)
        func state(_ t: ProfessionalTask) -> JobReferenceState? {
            states.first { $0.reference.referenceID == t.id.uuidString }?.state
        }
        #expect(state(completed) == .complete)
        #expect(state(open) == .notStarted)
        #expect(state(blocked) == .blocked)
        #expect(state(evidence) == .missingEvidence)
        #expect(state(review) == .waitingReview)
    }

    @Test("A required incomplete blocking dependency makes the dependent item blocked")
    func blockingDependency() async throws {
        let r = try await rig()
        let predecessor = try await task(r)
        let dependent = try await task(r)
        _ = try await r.tasks.addDependency(taskID: dependent.id, dependsOn: predecessor.id, kind: .blocking, at: t0)
        let rec = try await jobReferencingTasks(r, [(dependent, .required, false)])
        var states = try await r.service.resolveStates(rec.references)
        #expect(states.first?.state == .blocked)          // predecessor not complete
        // Completing the predecessor unblocks the dependent.
        _ = try await r.tasks.complete(taskID: predecessor.id, reviewer: "u", reason: nil, at: t0)
        states = try await r.service.resolveStates(rec.references)
        #expect(states.first?.state == .notStarted)
    }

    // MARK: - Deterministic priority

    @Test("Priority order is deterministic: blocker → required → evidence → review → optional")
    func deterministicPriority() async throws {
        let r = try await rig()
        let blocked = try await task(r)
        _ = try await r.tasks.transition(taskID: blocked.id, to: .blocked, reviewer: "u", reason: nil, at: t0)
        let required = try await task(r)
        let evidence = try await task(r, type: .evidenceRequest)
        let review = try await task(r, type: .review)
        let optional = try await task(r)

        let rec = try await jobReferencingTasks(r, [
            (blocked, .required, false), (required, .required, false), (evidence, .supporting, false),
            (review, .supporting, false), (optional, .optional, false)])
        let outcome = try await r.service.outcome(for: rec, now: t0)
        let bands = outcome.prioritizedItems.map(\.band)
        #expect(bands == [.hardBlocker, .requiredDeliverableDependency, .decisiveEvidence, .requiredReview, .optionalEnrichment])
        #expect(outcome.recommendedNextAction?.reference.referenceID == blocked.id.uuidString)
        #expect(outcome.marksJobComplete == false)
    }

    @Test("Confirmed-deadline pressure elevates a required item above ordinary required work")
    func deadlinePressureElevatesRequired() async throws {
        let r = try await rig()
        let t = try await task(r)
        let due = t0.addingTimeInterval(5 * 24 * 3600)
        let d = try await r.deadlines.createConfirmedDeadline(
            taskID: t.id, value: DeadlineValue(date: due, precision: .day, timeZoneIdentifier: "UTC"),
            kind: .due, confirmation: DeadlineConfirmation(kind: .user, confirmedBy: "u", confirmedAt: t0,
                                                           reason: nil, ruleID: nil, ruleVersion: nil), at: t0)
        let required = try await task(r)
        var rec = try await r.jobs.createJob(workspaceID: r.ws, title: "J", detail: nil,
                                             budget: .confirmedDeadline(d.id), primaryWorkflowRunID: nil, actor: "u", at: t0)
        rec = try await r.jobs.addReference(jobID: rec.objective.id, kind: .professionalTask,
                                            referenceID: required.id.uuidString, workflowRunID: nil, role: .required,
                                            isMinimumDeliverable: false, note: nil, expectedRevision: 1, actor: "u", at: t0)
        // now is past the deadline → overdue pressure.
        let outcome = try await r.service.outcome(for: rec, now: due.addingTimeInterval(3600))
        #expect(outcome.prioritizedItems.first?.band == .confirmedDeadlineCritical)
    }

    // MARK: - Progress + minimum deliverable + honest partial outcome

    @Test("Progress is honest counts, not a percentage")
    func progressCounts() async throws {
        let r = try await rig()
        let done = try await task(r); _ = try await r.tasks.complete(taskID: done.id, reviewer: "u", reason: nil, at: t0)
        let open = try await task(r)
        let rec = try await jobReferencingTasks(r, [(done, .required, false), (open, .required, false)])
        let outcome = try await r.service.outcome(for: rec, now: t0)
        #expect(outcome.progress.total == 2)
        #expect(outcome.progress.completeCount == 1)
        #expect(outcome.progress.remainingCount == 1)
    }

    @Test("Minimum deliverable is met only when every MAD item is complete")
    func minimumDeliverable() async throws {
        let r = try await rig()
        let madDone = try await task(r); _ = try await r.tasks.complete(taskID: madDone.id, reviewer: "u", reason: nil, at: t0)
        let madOpen = try await task(r)
        let extra = try await task(r)

        // MAD = {madDone} only → met.
        var rec = try await jobReferencingTasks(r, [(madDone, .required, true), (extra, .optional, false)])
        var outcome = try await r.service.outcome(for: rec, now: t0)
        #expect(outcome.minimumDeliverable == .met)

        // Add an incomplete MAD item → notMet.
        rec = try await r.jobs.addReference(jobID: rec.objective.id, kind: .professionalTask,
                                            referenceID: madOpen.id.uuidString, workflowRunID: nil, role: .required,
                                            isMinimumDeliverable: true, note: nil,
                                            expectedRevision: rec.objective.revision, actor: "u", at: t0)
        outcome = try await r.service.outcome(for: rec, now: t0)
        #expect(outcome.minimumDeliverable == .notMet)
    }

    @Test("No minimum deliverable defined reports undefined, not met")
    func minimumDeliverableUndefined() async throws {
        let r = try await rig()
        let t = try await task(r)
        let rec = try await jobReferencingTasks(r, [(t, .required, false)])
        let outcome = try await r.service.outcome(for: rec, now: t0)
        #expect(outcome.minimumDeliverable == .undefined)
    }

    @Test("An honest partial outcome delivers what is done and never marks the job complete")
    func honestPartialOutcome() async throws {
        let r = try await rig()
        let done = try await task(r); _ = try await r.tasks.complete(taskID: done.id, reviewer: "u", reason: nil, at: t0)
        let evidence = try await task(r, type: .evidenceRequest)
        let blocked = try await task(r)
        _ = try await r.tasks.transition(taskID: blocked.id, to: .blocked, reviewer: "u", reason: nil, at: t0)

        let rec = try await jobReferencingTasks(r, [
            (done, .required, true), (evidence, .required, true), (blocked, .required, false)])
        let outcome = try await r.service.outcome(for: rec, now: t0)

        #expect(outcome.completedNow.contains { $0.reference.referenceID == done.id.uuidString })
        #expect(outcome.remainingWork.count == 2)
        #expect(outcome.missingEvidence.contains { $0.referenceID == evidence.id.uuidString })
        #expect(outcome.blockedActions.contains { $0.referenceID == blocked.id.uuidString })
        #expect(outcome.minimumDeliverable == .notMet)     // evidence MAD item still outstanding
        #expect(outcome.recommendedNextAction != nil)
        #expect(outcome.marksJobComplete == false)
        // The service never closed the job — that is a human act.
        let reopened = try #require(try await r.jobs.fetch(jobID: rec.objective.id))
        #expect(reopened.objective.lifecycle == .active)
    }

    @Test("Even with all items complete and MAD met, the service never marks the job complete")
    func neverAutoCompletes() async throws {
        let r = try await rig()
        let a = try await task(r); _ = try await r.tasks.complete(taskID: a.id, reviewer: "u", reason: nil, at: t0)
        let rec = try await jobReferencingTasks(r, [(a, .required, true)])
        let outcome = try await r.service.outcome(for: rec, now: t0)
        #expect(outcome.minimumDeliverable == .met)
        #expect(outcome.progress.remainingCount == 0)
        #expect(outcome.marksJobComplete == false)
        let reopened = try #require(try await r.jobs.fetch(jobID: rec.objective.id))
        #expect(reopened.objective.lifecycle == .active)   // still open until a human closes it
    }
}
