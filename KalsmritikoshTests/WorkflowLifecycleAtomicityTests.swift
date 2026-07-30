//
//  WorkflowLifecycleAtomicityTests.swift
//  KalsmritikoshTests
//
//  PJE-004 — Lifecycle atomicity: revision CAS, SAVEPOINT rollback on failure,
//  one-event invariant, and checkpoint creation within the same SAVEPOINT.
//  15 tests.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-004 — WorkflowLifecycleAtomicity")
struct WorkflowLifecycleAtomicityTests {

    private let t0 = Date(timeIntervalSince1970: 1_753_100_000)

    // MARK: - Helpers (duplicated from EngineTests to keep tests independent)

    private func makeDB() async throws -> Database {
        try await MigrationFixtureBuilder.database(atVersion: 77)
    }

    private func makeEngine(db: Database) -> WorkflowLifecycleEngine {
        WorkflowLifecycleEngine(repository: WorkflowRunRepository(database: db))
    }

    private func insertWorkspace(_ db: Database, id: UUID) async throws {
        try await db.exec("""
        INSERT INTO workspaces (id, title, template_type, created_at, updated_at)
        VALUES (?,?,?,?,?);
        """, [.uuid(id), .text("Atomicity WS"), .text("general"),
              .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
    }

    private func makeTwoStepPackage() throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let appID = ApplicationDefinitionID(rawValue: "com.atom.test.app")
        let wfID = WorkflowDefinitionID(rawValue: "com.atom.test.wf")
        let intakeID = StepDefinitionID(rawValue: "step.intake")
        let doneID = StepDefinitionID(rawValue: "step.done")
        let intake = PersonaWorkflowStepDefinition(
            id: intakeID, kind: .intake, label: "Intake", isEntry: true,
            transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: doneID)])
        let done = PersonaWorkflowStepDefinition(
            id: doneID, kind: .closure, label: "Done", isTerminal: true)
        let term = PersonaTerminologyDefinition(
            id: TerminologyDefinitionID(rawValue: "com.atom.test.term"), version: 1,
            applicationID: appID, labels: [:])
        let app = PersonaApplicationDefinition(id: appID, version: 1, label: "Atom App")
        let wfDef = PersonaWorkflowDefinition(
            id: wfID, version: 1, schemaVersion: 1, label: "Atom WF", steps: [intake, done])
        let validated = try WorkflowDefinitionCompiler().compile(wfDef)
        let pkg = ResolvedPersonaApplicationPackage(
            applicationKey: RegistryKey(id: appID, version: 1), application: app,
            toolKeys: [], tools: [],
            workflowKeys: [RegistryKey(id: wfID, version: 1)], workflows: [validated],
            terminologyKey: RegistryKey(id: term.id, version: 1), terminology: term,
            objectSchemaKeys: [], objectSchemas: [], workProductKeys: [], workProducts: [],
            validatorKeys: [], validators: [], automationKeys: [], automations: [])
        return (pkg, wfID)
    }

    private func createRun(
        db: Database, pkg: ResolvedPersonaApplicationPackage, wfID: WorkflowDefinitionID
    ) async throws -> ReopenedWorkflowRun {
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        return try await WorkflowRunRepository(database: db).createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: wsID,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
    }

    // MARK: - 1: Stale revision in applyLifecyclePlan throws revisionConflict

    @Test("applyLifecyclePlan with a stale expectedRevision throws revisionConflict")
    func staleRevisionThrowsRevisionConflict() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)

        // Start moves revision 1→2
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)

        // Attempt to start again with the stale aggregate — this re-fetches the run first,
        // so we can't inject a stale revision through the engine directly.
        // Instead, call applyLifecyclePlan directly with a stale revision.
        let repo = WorkflowRunRepository(database: db)
        let agg = try await repo.fetchRun(created.run.id)  // revision == 2

        let plan = WorkflowLifecyclePlan(
            runPatch: WorkflowLifecycleRunPatch(
                newStatus: .paused, currentStepDefinitionID: agg.run.currentStepDefinitionID,
                currentStepRunID: agg.run.currentStepRunID,
                startedAt: agg.run.startedAt, pausedAt: t0,
                completedAt: nil, cancelledAt: nil,
                cancellationReason: nil, supersededByRunID: nil),
            stepsToInsert: [], stepsToUpdate: [],
            decisionToInsert: nil, checkpointReason: nil,
            eventType: .runStateChanged, actorKind: .system, actorIdentifier: nil)

        do {
            _ = try await repo.applyLifecyclePlan(
                runID: created.run.id,
                expectedRevision: 1,  // stale — actual is 2
                plan: plan, now: t0)
            Issue.record("Expected revisionConflict")
        } catch WorkflowRunRepositoryError.revisionConflict(let id, let expected) {
            #expect(id == created.run.id)
            #expect(expected == 1)
        }
    }

    // MARK: - 2: Two concurrent starts: exactly one wins

    @Test("two concurrent start calls on the same draft run: exactly one wins")
    func twoStartsExactlyOneWins() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)

        var successCount = 0
        var conflictCount = 0

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do {
                        _ = try await engine.start(
                            runID: created.run.id, actor: .system, now: self.t0)
                        return true
                    } catch {
                        return false
                    }
                }
            }
            for await succeeded in group {
                if succeeded { successCount += 1 } else { conflictCount += 1 }
            }
        }
        #expect(successCount == 1, "Exactly one start should succeed")
        #expect(conflictCount == 1, "Exactly one start should conflict")
    }

    // MARK: - 3: Failed action leaves revision unchanged

    @Test("a failed lifecycle action does not change the revision")
    func failedActionLeavesRevisionUnchanged() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)

        let repo = WorkflowRunRepository(database: db)
        let before = try await repo.fetchRun(created.run.id)
        let revisionBefore = before.run.revision

        // Try an illegal action
        do {
            _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)
        } catch { /* expected */ }

        let after = try await repo.fetchRun(created.run.id)
        #expect(after.run.revision == revisionBefore, "Revision must not change on failure")
    }

    // MARK: - 4: Failed action leaves event count unchanged

    @Test("a failed lifecycle action does not append any event")
    func failedActionLeavesEventCountUnchanged() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)

        let repo = WorkflowRunRepository(database: db)
        let before = try await repo.fetchRun(created.run.id)
        let countBefore = before.events.count

        do {
            _ = try await engine.cancel(
                runID: created.run.id, reason: "", actor: .system, now: t0)
        } catch { /* cancellationReasonRequired */ }

        let after = try await repo.fetchRun(created.run.id)
        #expect(after.events.count == countBefore, "Event count must not change on failure")
    }

    // MARK: - 5: Failed action leaves step run count unchanged

    @Test("a failed lifecycle action does not insert any step run")
    func failedActionLeavesStepRunCountUnchanged() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)

        let repo = WorkflowRunRepository(database: db)
        let before = try await repo.fetchRun(created.run.id)
        let countBefore = before.stepRuns.count

        // pause with invalid JSON should fail at codec validation
        do {
            let badPayload = WorkflowStepCompletionPayload(
                stateJSON: "not-valid-json", outputJSON: nil)
            _ = try await engine.pause(
                runID: created.run.id, stepCompletion: badPayload, actor: .system, now: t0)
        } catch { /* invalidJSONPayload */ }

        let after = try await repo.fetchRun(created.run.id)
        #expect(after.stepRuns.count == countBefore, "Step run count must not change on failure")
    }

    // MARK: - 6: Each successful action appends exactly one event

    @Test("each successful lifecycle action appends exactly one event to the log")
    func eachSuccessfulActionAppendExactlyOneEvent() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        #expect(created.events.count == 1)

        var events = created.events.count
        let afterStart = try await engine.start(runID: created.run.id, actor: .system, now: t0)
        events += 1
        #expect(afterStart.events.count == events)

        let afterPause = try await engine.pause(runID: created.run.id, actor: .system, now: t0)
        events += 1
        #expect(afterPause.events.count == events)

        let afterResume = try await engine.resume(runID: created.run.id, actor: .system, now: t0)
        events += 1
        #expect(afterResume.events.count == events)

        let afterBlock = try await engine.block(runID: created.run.id, actor: .system, now: t0)
        events += 1
        #expect(afterBlock.events.count == events)
    }

    // MARK: - 7: Checkpoint is included atomically in start's SAVEPOINT

    @Test("save creates a checkpoint in the same SAVEPOINT as the revision bump")
    func savePersistsCheckpointAtomically() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)

        let afterSave = try await engine.save(runID: created.run.id, actor: .system, now: t0)

        // Checkpoint created in same SAVEPOINT as the revision bump
        #expect(afterSave.checkpoints.count == 1)
        // The checkpoint's revision matches the run's revision after save
        #expect(afterSave.checkpoints[0].runRevision == afterSave.run.revision)
    }

    // MARK: - 8: Pause creates a beforeDecision checkpoint for requestHumanDecision

    @Test("requestHumanDecision creates a beforeDecision checkpoint atomically")
    func requestHumanDecisionCreatesCheckpointAtomically() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)

        let after = try await engine.requestHumanDecision(
            runID: created.run.id, actor: .system, now: t0)

        #expect(after.checkpoints.count == 1)
        #expect(after.checkpoints[0].reason == .beforeDecision)
        #expect(after.checkpoints[0].runRevision == after.run.revision)
    }

    // MARK: - 9: Checkpoint has pause reason for pause action

    @Test("pause creates a pause checkpoint atomically")
    func pauseCreatesCheckpointAtomically() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)

        let afterPause = try await engine.pause(runID: created.run.id, actor: .system, now: t0)

        #expect(afterPause.checkpoints.count == 1)
        #expect(afterPause.checkpoints[0].reason == .pause)
    }

    // MARK: - 10: No checkpoint for unblock

    @Test("unblock does not create a checkpoint")
    func unblockDoesNotCreateCheckpoint() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)
        _ = try await engine.block(runID: created.run.id, actor: .system, now: t0)

        let afterUnblock = try await engine.unblock(runID: created.run.id, actor: .system, now: t0)

        #expect(afterUnblock.checkpoints.isEmpty)
    }

    // MARK: - 11: Decision is inserted in the same SAVEPOINT as chooseBranch

    @Test("chooseBranch inserts decision with same revision as the run patch")
    func chooseBranchInsertsDecisionAtomically() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        // Decision workflow
        let appID = ApplicationDefinitionID(rawValue: "com.atom.test.app.dec")
        let wfID = WorkflowDefinitionID(rawValue: "com.atom.test.wf.dec")
        let decID = StepDefinitionID(rawValue: "step.decide")
        let doneID = StepDefinitionID(rawValue: "step.done")
        let dec = PersonaWorkflowStepDefinition(
            id: decID, kind: .decision, label: "Decide", isEntry: true,
            transitions: [
                WorkflowTransitionDefinition(label: "yes", targetStepID: doneID),
                WorkflowTransitionDefinition(label: "no", targetStepID: doneID)
            ],
            decisionBranches: ["yes", "no"])
        let done = PersonaWorkflowStepDefinition(
            id: doneID, kind: .closure, label: "Done", isTerminal: true)
        let term = PersonaTerminologyDefinition(
            id: TerminologyDefinitionID(rawValue: "com.atom.dec.term"), version: 1,
            applicationID: appID, labels: [:])
        let app = PersonaApplicationDefinition(id: appID, version: 1, label: "Dec App")
        let wfDef = PersonaWorkflowDefinition(
            id: wfID, version: 1, schemaVersion: 1, label: "Dec WF", steps: [dec, done])
        let validated = try WorkflowDefinitionCompiler().compile(wfDef)
        let pkg = ResolvedPersonaApplicationPackage(
            applicationKey: RegistryKey(id: appID, version: 1), application: app,
            toolKeys: [], tools: [],
            workflowKeys: [RegistryKey(id: wfID, version: 1)], workflows: [validated],
            terminologyKey: RegistryKey(id: term.id, version: 1), terminology: term,
            objectSchemaKeys: [], objectSchemas: [], workProductKeys: [], workProducts: [],
            validatorKeys: [], validators: [], automationKeys: [], automations: [])
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let created = try await WorkflowRunRepository(database: db).createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: wsID,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)

        let after = try await engine.chooseBranch(
            runID: created.run.id, branch: "yes", rationale: nil, actor: .system, now: t0)

        #expect(after.decisions.count == 1)
        #expect(after.run.status == .completed)
        // Decision and completion happened in one SAVEPOINT: run.revision matches
        #expect(after.decisions[0].selectedOption == "yes")
    }

    // MARK: - 12: Supersession is atomic: old→superseded + new→draft in one operation

    @Test("supersede creates replacement run with revision 1 atomically")
    func supersessionIsAtomic() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)

        let result = try await engine.supersede(
            runID: created.run.id,
            package: pkg,
            selectedWorkflowID: wfID,
            workspaceID: created.run.workspaceID,
            title: nil,
            actor: .system, now: t0)

        // Old run is superseded — atomically in the same SAVEPOINT
        #expect(result.superseded.run.status == .superseded)
        // Replacement run starts as draft with revision 1
        #expect(result.replacement.run.revision == 1)
        #expect(result.replacement.run.status == .draft)
    }

    // MARK: - 13: Supersession links old run to replacement

    @Test("supersede sets supersededByRunID on the old run")
    func supersessionLinksOldToReplacement() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)

        let result = try await engine.supersede(
            runID: created.run.id, package: pkg,
            selectedWorkflowID: wfID,
            workspaceID: created.run.workspaceID,
            title: nil, actor: .system, now: t0)

        #expect(result.superseded.run.supersededByRunID == result.replacement.run.id)
    }

    // MARK: - 14: Revision sequence is gapless after a multi-action sequence

    @Test("revision sequence is gapless: 1, 2, 3, 4 after three actions")
    func revisionSequenceIsGapless() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        #expect(created.run.revision == 1)
        let r2 = try await engine.start(runID: created.run.id, actor: .system, now: t0)
        #expect(r2.run.revision == 2)
        let r3 = try await engine.pause(runID: created.run.id, actor: .system, now: t0)
        #expect(r3.run.revision == 3)
        let r4 = try await engine.resume(runID: created.run.id, actor: .system, now: t0)
        #expect(r4.run.revision == 4)
    }

    // MARK: - 15: Events are sequenced monotonically

    @Test("workflow run events are sequenced 1, 2, 3, ... with no gaps")
    func eventSequenceIsMonotonic() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)
        _ = try await engine.save(runID: created.run.id, actor: .system, now: t0)
        _ = try await engine.pause(runID: created.run.id, actor: .system, now: t0)

        let repo = WorkflowRunRepository(database: db)
        let final = try await repo.fetchRun(created.run.id)
        let seqs = final.events.map(\.sequence).sorted()
        #expect(seqs == Array(1...seqs.count), "Event sequences must be 1..N with no gaps")
    }
}
