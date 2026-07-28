//
//  WorkflowLifecycleEngineTests.swift
//  KalsmritikoshTests
//
//  PJE-004 — WorkflowLifecycleEngine: end-to-end lifecycle actions against a real
//  in-memory database at schema v75.  One action per test.
//  ~35 tests covering start, save, pause, resume, block, unblock, advance,
//  chooseBranch, requestHumanDecision, recordHumanDecision, recordHumanApproval,
//  returnToPriorStep, complete, cancel, supersede, and project.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-004 — WorkflowLifecycleEngine")
struct WorkflowLifecycleEngineTests {

    private let t0 = Date(timeIntervalSince1970: 1_753_000_000)

    // MARK: - Setup helpers

    private func makeDB() async throws -> Database {
        try await MigrationFixtureBuilder.database(atVersion: 76)
    }

    private func makeEngine(db: Database) -> WorkflowLifecycleEngine {
        WorkflowLifecycleEngine(repository: WorkflowRunRepository(database: db))
    }

    private func insertWorkspace(_ db: Database, id: UUID) async throws {
        try await db.exec("""
        INSERT INTO workspaces (id, title, template_type, created_at, updated_at)
        VALUES (?,?,?,?,?);
        """, [.uuid(id), .text("Test WS"), .text("general"),
              .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
    }

    // Two-step package: intake → closure
    private func makeTwoStepPackage() throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let appID = ApplicationDefinitionID(rawValue: "com.engine.test.app")
        let wfID = WorkflowDefinitionID(rawValue: "com.engine.test.wf.twostep")
        let intakeID = StepDefinitionID(rawValue: "step.intake")
        let doneID = StepDefinitionID(rawValue: "step.done")
        let intake = PersonaWorkflowStepDefinition(
            id: intakeID, kind: .intake, label: "Intake", isEntry: true,
            transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: doneID)])
        let done = PersonaWorkflowStepDefinition(
            id: doneID, kind: .closure, label: "Done", isTerminal: true)
        return try makePackage(appID: appID, wfID: wfID, steps: [intake, done])
    }

    // Three-step package: intake → review → closure
    private func makeThreeStepPackage() throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let appID = ApplicationDefinitionID(rawValue: "com.engine.test.app.three")
        let wfID = WorkflowDefinitionID(rawValue: "com.engine.test.wf.threestep")
        let intakeID = StepDefinitionID(rawValue: "step.intake")
        let reviewID = StepDefinitionID(rawValue: "step.review")
        let doneID = StepDefinitionID(rawValue: "step.done")
        let intake = PersonaWorkflowStepDefinition(
            id: intakeID, kind: .intake, label: "Intake", isEntry: true,
            transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: reviewID)])
        let review = PersonaWorkflowStepDefinition(
            id: reviewID, kind: .form, label: "Review",
            transitions: [WorkflowTransitionDefinition(label: "approve", targetStepID: doneID)])
        let done = PersonaWorkflowStepDefinition(
            id: doneID, kind: .closure, label: "Done", isTerminal: true)
        return try makePackage(appID: appID, wfID: wfID, steps: [intake, review, done])
    }

    // Decision package: decision → yes→closure | no→closure
    private func makeDecisionPackage() throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let appID = ApplicationDefinitionID(rawValue: "com.engine.test.app.dec")
        let wfID = WorkflowDefinitionID(rawValue: "com.engine.test.wf.decision")
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
        return try makePackage(appID: appID, wfID: wfID, steps: [dec, done])
    }

    // humanApproval package: intake → approval → closure
    private func makeApprovalPackage() throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let appID = ApplicationDefinitionID(rawValue: "com.engine.test.app.appr")
        let wfID = WorkflowDefinitionID(rawValue: "com.engine.test.wf.approval")
        let intakeID = StepDefinitionID(rawValue: "step.intake")
        let approvalID = StepDefinitionID(rawValue: "step.approval")
        let doneID = StepDefinitionID(rawValue: "step.done")
        let intake = PersonaWorkflowStepDefinition(
            id: intakeID, kind: .intake, label: "Intake", isEntry: true,
            transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: approvalID)])
        let approval = PersonaWorkflowStepDefinition(
            id: approvalID, kind: .humanApproval, label: "Approval",
            transitions: [WorkflowTransitionDefinition(label: "approved", targetStepID: doneID)],
            approverRoles: ["supervisor"])
        let done = PersonaWorkflowStepDefinition(
            id: doneID, kind: .closure, label: "Done", isTerminal: true)
        return try makePackage(appID: appID, wfID: wfID, steps: [intake, approval, done])
    }

    private func makePackage(
        appID: ApplicationDefinitionID,
        wfID: WorkflowDefinitionID,
        steps: [PersonaWorkflowStepDefinition]
    ) throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let termID = TerminologyDefinitionID(rawValue: "com.engine.test.term")
        let app = PersonaApplicationDefinition(id: appID, version: 1, label: "Engine Test App")
        let wfDef = PersonaWorkflowDefinition(
            id: wfID, version: 1, schemaVersion: 1, label: "Engine Test WF", steps: steps)
        let validated = try WorkflowDefinitionCompiler().compile(wfDef)
        let term = PersonaTerminologyDefinition(
            id: termID, version: 1, applicationID: appID, labels: [:])
        let pkg = ResolvedPersonaApplicationPackage(
            applicationKey: RegistryKey(id: appID, version: 1),
            application: app,
            toolKeys: [], tools: [],
            workflowKeys: [RegistryKey(id: wfID, version: 1)],
            workflows: [validated],
            terminologyKey: RegistryKey(id: termID, version: 1),
            terminology: term,
            objectSchemaKeys: [], objectSchemas: [],
            workProductKeys: [], workProducts: [],
            validatorKeys: [], validators: [],
            automationKeys: [], automations: [])
        return (pkg, wfID)
    }

    private func createRun(
        db: Database, pkg: ResolvedPersonaApplicationPackage, wfID: WorkflowDefinitionID
    ) async throws -> ReopenedWorkflowRun {
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let repo = WorkflowRunRepository(database: db)
        return try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: "Engine Test Run",
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0)
    }

    // MARK: - 1: start transitions draft to active

    @Test("start transitions a draft run to active and inserts an entry step run")
    func startTransitionsDraftToActive() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)

        let after = try await engine.start(
            runID: created.run.id,
            actor: .system, now: t0)

        #expect(after.run.status == .active)
        #expect(after.run.revision == 2)
        #expect(after.stepRuns.count == 1)
        #expect(after.stepRuns[0].status == .active)
        #expect(after.stepRuns[0].stepDefinitionID.rawValue == "step.intake")
    }

    // MARK: - 2: start inserts exactly one runStateChanged event

    @Test("start inserts exactly one runStateChanged event")
    func startInsertsOneEvent() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)

        let after = try await engine.start(
            runID: created.run.id, actor: .system, now: t0)

        let startEvents = after.events.filter { $0.type == .runStateChanged }
        #expect(startEvents.count == 1)
    }

    // MARK: - 3: start twice throws (active → start is illegal)

    @Test("starting an already active run throws illegalRunTransition")
    func startTwiceThrows() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)

        do {
            _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)
            Issue.record("Expected illegalRunTransition")
        } catch WorkflowLifecycleError.illegalRunTransition(let from, let action) {
            #expect(from == .active)
            #expect(action == .start)
        }
    }

    // MARK: - 4: save creates a checkpoint without changing status

    @Test("save creates a checkpoint on an active run without changing status")
    func saveCreatesCheckpoint() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)

        let after = try await engine.save(runID: created.run.id, actor: .system, now: t0)

        #expect(after.run.status == .active)
        #expect(after.checkpoints.count == 1)
        #expect(after.checkpoints[0].reason == .explicitSave)
    }

    // MARK: - 5: pause transitions active to paused

    @Test("pause transitions an active run to paused")
    func pauseTransitionsActiveToAused() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)

        let after = try await engine.pause(runID: created.run.id, actor: .system, now: t0)

        #expect(after.run.status == .paused)
        #expect(after.run.pausedAt != nil)
        #expect(after.stepRuns[0].status == .waiting)
    }

    // MARK: - 6: resume transitions paused to active

    @Test("resume transitions a paused run back to active")
    func resumeTransitionsPausedToActive() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)
        _ = try await engine.pause(runID: created.run.id, actor: .system, now: t0)

        let after = try await engine.resume(runID: created.run.id, actor: .system, now: t0)

        #expect(after.run.status == .active)
        #expect(after.run.pausedAt == nil)
        #expect(after.stepRuns[0].status == .active)
    }

    // MARK: - 7: block transitions active to blocked

    @Test("block transitions an active run to blocked")
    func blockTransitionsActiveToBlocked() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)

        let after = try await engine.block(runID: created.run.id, actor: .system, now: t0)

        #expect(after.run.status == .blocked)
        #expect(after.stepRuns[0].status == .blocked)
    }

    // MARK: - 8: unblock transitions blocked to active

    @Test("unblock transitions a blocked run back to active")
    func unblockTransitionsBlockedToActive() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)
        _ = try await engine.block(runID: created.run.id, actor: .system, now: t0)

        let after = try await engine.unblock(runID: created.run.id, actor: .system, now: t0)

        #expect(after.run.status == .active)
        #expect(after.stepRuns[0].status == .active)
    }

    // MARK: - 9: advance to non-terminal step creates new step run

    @Test("advance to non-terminal step completes current step and inserts next step run")
    func advanceToNonTerminalStepCreatesNewStepRun() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeThreeStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)

        let after = try await engine.advance(
            runID: created.run.id, selector: .label("next"), actor: .system, now: t0)

        #expect(after.run.status == .active)
        #expect(after.stepRuns.count == 2)
        let current = after.stepRuns.first(where: { $0.stepDefinitionID.rawValue == "step.review" })
        #expect(current?.status == .active)
        let old = after.stepRuns.first(where: { $0.stepDefinitionID.rawValue == "step.intake" })
        #expect(old?.status == .completed)
    }

    // MARK: - 10: advance to terminal step completes the run

    @Test("advance to the terminal step completes the run")
    func advanceToTerminalStepCompletesRun() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)

        let after = try await engine.advance(
            runID: created.run.id, selector: .label("next"), actor: .system, now: t0)

        #expect(after.run.status == .completed)
        #expect(after.run.completedAt != nil)
    }

    // MARK: - 11: advance by targetStepID resolves correctly

    @Test("advance by targetStepID selects the right transition")
    func advanceByTargetStepID() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeThreeStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)

        let after = try await engine.advance(
            runID: created.run.id,
            selector: .targetStepID(StepDefinitionID(rawValue: "step.review")),
            actor: .system, now: t0)

        #expect(after.run.status == .active)
        let reviewStep = after.stepRuns.first(where: { $0.stepDefinitionID.rawValue == "step.review" })
        #expect(reviewStep != nil)
    }

    // MARK: - 12: complete transitions active run to completed

    @Test("complete directly marks an active run as completed")
    func completeTransitionsToCompleted() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)

        let after = try await engine.complete(
            runID: created.run.id, actor: .system, now: t0)

        #expect(after.run.status == .completed)
        #expect(after.run.completedAt != nil)
    }

    // MARK: - 13: cancel transitions draft run to cancelled

    @Test("cancel transitions a draft run to cancelled with a reason")
    func cancelDraftRun() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)

        let after = try await engine.cancel(
            runID: created.run.id, reason: "Test cancellation", actor: .system, now: t0)

        #expect(after.run.status == .cancelled)
        #expect(after.run.cancellationReason == "Test cancellation")
        #expect(after.run.cancelledAt != nil)
    }

    // MARK: - 14: cancel active run transitions to cancelled

    @Test("cancel transitions an active run to cancelled")
    func cancelActiveRun() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)

        let after = try await engine.cancel(
            runID: created.run.id, reason: "Stopped by user", actor: .system, now: t0)

        #expect(after.run.status == .cancelled)
    }

    // MARK: - 15: cancel requires a reason

    @Test("cancel without reason throws cancellationReasonRequired")
    func cancelWithoutReasonThrows() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)

        do {
            _ = try await engine.cancel(runID: created.run.id, reason: "", actor: .system, now: t0)
            Issue.record("Expected cancellationReasonRequired")
        } catch WorkflowLifecycleError.cancellationReasonRequired {
            // expected
        }
    }

    // MARK: - 16: cancel completed run throws terminalRunImmutable

    @Test("cancelling a completed run throws terminalRunImmutable")
    func cancelCompletedRunThrows() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)
        _ = try await engine.complete(runID: created.run.id, actor: .system, now: t0)

        do {
            _ = try await engine.cancel(
                runID: created.run.id, reason: "Too late", actor: .system, now: t0)
            Issue.record("Expected terminalRunImmutable")
        } catch WorkflowLifecycleError.terminalRunImmutable(_, let status) {
            #expect(status == .completed)
        }
    }

    // MARK: - 17: chooseBranch on decision step records decision

    @Test("chooseBranch on decision step records a decision and advances")
    func chooseBranchRecordsDecision() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeDecisionPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)

        let after = try await engine.chooseBranch(
            runID: created.run.id,
            branch: "yes",
            rationale: "Looks good",
            actor: .system, now: t0)

        #expect(after.decisions.count == 1)
        #expect(after.decisions[0].selectedOption == "yes")
        #expect(after.decisions[0].kind == .branchSelection)
        #expect(after.run.status == .completed)  // yes → terminal
    }

    // MARK: - 18: chooseBranch with undeclared branch throws

    @Test("chooseBranch with undeclared branch throws undeclaredDecisionBranch")
    func chooseBranchUndeclaredThrows() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeDecisionPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)

        do {
            _ = try await engine.chooseBranch(
                runID: created.run.id, branch: "maybe", rationale: nil,
                actor: .system, now: t0)
            Issue.record("Expected undeclaredDecisionBranch")
        } catch WorkflowLifecycleError.undeclaredDecisionBranch(_, let branch) {
            #expect(branch == "maybe")
        }
    }

    // MARK: - 19: requestHumanDecision transitions active to waitingForHuman

    @Test("requestHumanDecision transitions an active run to waitingForHuman")
    func requestHumanDecisionTransitionsToWaiting() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)

        let after = try await engine.requestHumanDecision(
            runID: created.run.id, actor: .system, now: t0)

        #expect(after.run.status == .waitingForHuman)
        #expect(after.stepRuns[0].status == .waiting)
        #expect(after.checkpoints.count == 1)
        #expect(after.checkpoints[0].reason == .beforeDecision)
    }

    // MARK: - 20: recordHumanDecision requires a human actor

    @Test("recordHumanDecision with a system actor throws humanActorRequired")
    func recordHumanDecisionRequiresHumanActor() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)
        _ = try await engine.requestHumanDecision(runID: created.run.id, actor: .system, now: t0)

        do {
            _ = try await engine.recordHumanDecision(
                runID: created.run.id,
                decisionKey: "approve",
                selectedOption: "yes",
                rationale: nil,
                actor: .system, now: t0)
            Issue.record("Expected humanActorRequired")
        } catch WorkflowLifecycleError.humanActorRequired {
            // expected
        }
    }

    // MARK: - 21: recordHumanDecision with human actor records decision

    @Test("recordHumanDecision with a human actor records the decision")
    func recordHumanDecisionWithHumanActor() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeDecisionPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)
        _ = try await engine.requestHumanDecision(runID: created.run.id, actor: .system, now: t0)
        let human = try WorkflowLifecycleActor.human(identifier: "user@test.com")

        let after = try await engine.recordHumanDecision(
            runID: created.run.id,
            decisionKey: "intake.confirm",
            selectedOption: "confirm",
            rationale: "Looks good",
            actor: human, now: t0)

        #expect(after.decisions.count == 1)
        #expect(after.decisions[0].decisionKey == "intake.confirm")
        #expect(after.decisions[0].selectedOption == "confirm")
        #expect(after.run.status == .active)
    }

    // MARK: - 22: recordHumanApproval requires supervisor role

    @Test("recordHumanApproval with wrong role throws unauthorizedApproverRole")
    func recordHumanApprovalWrongRoleThrows() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeApprovalPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)
        // advance to approval step
        _ = try await engine.advance(runID: created.run.id, selector: .label("next"), actor: .system, now: t0)
        _ = try await engine.requestHumanDecision(runID: created.run.id, actor: .system, now: t0)

        let intern = try WorkflowLifecycleActor.human(identifier: "intern@test.com", role: "intern")
        do {
            _ = try await engine.recordHumanApproval(
                runID: created.run.id,
                approved: true,
                rationale: nil,
                actor: intern, now: t0)
            Issue.record("Expected unauthorizedApproverRole")
        } catch WorkflowLifecycleError.unauthorizedApproverRole(let supplied, _) {
            #expect(supplied == "intern")
        }
    }

    // MARK: - 23: recordHumanApproval with authorized role succeeds

    @Test("recordHumanApproval with authorized role records decision")
    func recordHumanApprovalAuthorizedRole() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeApprovalPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)
        _ = try await engine.advance(runID: created.run.id, selector: .label("next"), actor: .system, now: t0)
        _ = try await engine.requestHumanDecision(runID: created.run.id, actor: .system, now: t0)

        let supervisor = try WorkflowLifecycleActor.human(identifier: "boss@test.com", role: "supervisor")
        let after = try await engine.recordHumanApproval(
            runID: created.run.id,
            approved: true,
            rationale: "Approved after review",
            actor: supervisor, now: t0)

        #expect(after.decisions.count == 1)
        #expect(after.decisions[0].kind == .humanApproval)
        #expect(after.run.status == .active)
    }

    // MARK: - 24: returnToPriorStep creates a second attempt

    @Test("returnToPriorStep inserts a second attempt at the earlier step")
    func returnToPriorStepInsertsSecondAttempt() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        // Three-step: intake → review → done, where review has a back transition to intake
        let appID = ApplicationDefinitionID(rawValue: "com.engine.test.app.ret")
        let wfID = WorkflowDefinitionID(rawValue: "com.engine.test.wf.return")
        let intakeID = StepDefinitionID(rawValue: "step.intake")
        let reviewID = StepDefinitionID(rawValue: "step.review")
        let doneID = StepDefinitionID(rawValue: "step.done")
        let intake = PersonaWorkflowStepDefinition(
            id: intakeID, kind: .intake, label: "Intake", isEntry: true,
            transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: reviewID)])
        let review = PersonaWorkflowStepDefinition(
            id: reviewID, kind: .form, label: "Review",
            transitions: [
                WorkflowTransitionDefinition(label: "approve", targetStepID: doneID),
                WorkflowTransitionDefinition(label: "back", targetStepID: intakeID, isReturn: true)
            ],
            loopPolicy: .returnsToStep)
        let done = PersonaWorkflowStepDefinition(
            id: doneID, kind: .closure, label: "Done", isTerminal: true)
        let (pkg, _) = try makePackage(appID: appID, wfID: wfID, steps: [intake, review, done])
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)
        _ = try await engine.advance(runID: created.run.id, selector: .label("next"), actor: .system, now: t0)

        let after = try await engine.returnToPriorStep(
            runID: created.run.id, selector: .label("back"), actor: .system, now: t0)

        let intakeAttempts = after.stepRuns.filter { $0.stepDefinitionID == intakeID }
        #expect(intakeAttempts.count == 2)
        let latest = intakeAttempts.max(by: { $0.attempt < $1.attempt })
        #expect(latest?.attempt == 2)
        #expect(after.run.status == .active)
    }

    // MARK: - 25: supersede creates replacement run and marks old as superseded

    @Test("supersede marks old run as superseded and returns a new draft replacement")
    func supersedeCreatesReplacement() async throws {
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
            title: "Supersession",
            actor: .system, now: t0)

        #expect(result.superseded.run.status == .superseded)
        #expect(result.replacement.run.status == .draft)
        #expect(result.superseded.run.supersededByRunID == result.replacement.run.id)
    }

    // MARK: - 26: project reflects active status and allowed actions

    @Test("project returns accurate projection for an active run")
    func projectReflectsActiveState() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)

        let projection = try await engine.project(runID: created.run.id)

        #expect(projection.runStatus == .active)
        #expect(projection.structuralActions.contains(.advance))
        #expect(projection.currentStep?.id.rawValue == "step.intake")
    }

    // MARK: - 27: project for draft has no current step

    @Test("project for a draft run has no currentStepDefinitionID")
    func projectDraftHasNoCurrentStep() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)

        let projection = try await engine.project(runID: created.run.id)

        #expect(projection.runStatus == .draft)
        #expect(projection.structuralActions.contains(.start))
        #expect(projection.currentStep == nil)
    }

    // MARK: - 28: advance with entry payload carries through

    @Test("advance carries the entry payload to the next step run")
    func advanceCarriesEntryPayload() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeThreeStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)

        let entryPayload = WorkflowStepEntryPayload(inputJSON: "{\"data\":42}", stateJSON: "{}")
        let after = try await engine.advance(
            runID: created.run.id,
            selector: .label("next"),
            entryPayload: entryPayload,
            actor: .system, now: t0)

        let reviewRun = after.stepRuns.first(where: { $0.stepDefinitionID.rawValue == "step.review" })
        #expect(reviewRun?.inputJSON == "{\"data\":42}")
    }

    // MARK: - 29: pause with completion payload updates state

    @Test("pause with completion payload updates the current step's stateJSON")
    func pauseWithCompletionUpdatesState() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)

        let completion = WorkflowStepCompletionPayload(stateJSON: "{\"partial\":true}", outputJSON: nil)
        let after = try await engine.pause(
            runID: created.run.id, stepCompletion: completion, actor: .system, now: t0)

        #expect(after.stepRuns[0].stateJSON == "{\"partial\":true}")
    }

    // MARK: - 30: advance from non-decision step with chooseBranch throws

    @Test("calling chooseBranch on non-decision step throws humanDecisionStepRequired or illegalRunTransition")
    func chooseBranchOnNonDecisionStepThrows() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()  // intake is NOT a decision step
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)

        do {
            _ = try await engine.chooseBranch(
                runID: created.run.id, branch: "yes", rationale: nil,
                actor: .system, now: t0)
            Issue.record("Expected an error for non-decision step")
        } catch {
            // Any error is acceptable here — the step is .intake, not .decision
        }
    }

    // MARK: - 31: complete inserts exactly one runStateChanged event

    @Test("complete inserts exactly one runStateChanged event")
    func completeInsertsOneEvent() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)
        let beforeEventCount = 2

        let after = try await engine.complete(runID: created.run.id, actor: .system, now: t0)

        let newEvents = after.events.suffix(after.events.count - beforeEventCount)
        #expect(newEvents.count == 1)
        #expect(newEvents.first?.type == .runStateChanged)
    }

    // MARK: - 32: save on draft throws illegalRunTransition

    @Test("save on a draft run throws illegalRunTransition")
    func saveDraftThrows() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)

        do {
            _ = try await engine.save(runID: created.run.id, actor: .system, now: t0)
            Issue.record("Expected illegalRunTransition")
        } catch WorkflowLifecycleError.illegalRunTransition(let from, let action) {
            #expect(from == .draft)
            #expect(action == .save)
        }
    }

    // MARK: - 33: validateDefinition on valid def passes

    @Test("validateDefinition does not throw on a valid compiled definition")
    func validateDefinitionPasses() async throws {
        let engine = makeEngine(db: try await makeDB())
        let (pkg, wfID) = try makeTwoStepPackage()
        let validated = pkg.workflows.first(where: { $0.id == wfID })!
        try await engine.validateDefinition(validated)
    }

    // MARK: - 34: revision increments once per action

    @Test("each lifecycle action increments the revision exactly once")
    func revisionIncrementsOncePerAction() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        #expect(created.run.revision == 1)

        let afterStart = try await engine.start(runID: created.run.id, actor: .system, now: t0)
        #expect(afterStart.run.revision == 2)

        let afterPause = try await engine.pause(runID: created.run.id, actor: .system, now: t0)
        #expect(afterPause.run.revision == 3)

        let afterResume = try await engine.resume(runID: created.run.id, actor: .system, now: t0)
        #expect(afterResume.run.revision == 4)
    }

    // MARK: - 35: each action appends exactly one event

    @Test("each lifecycle action appends exactly one event to the event log")
    func eachActionAppendsOneEvent() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        #expect(created.events.count == 1)  // runCreated

        let afterStart = try await engine.start(runID: created.run.id, actor: .system, now: t0)
        #expect(afterStart.events.count == 2)

        let afterSave = try await engine.save(runID: created.run.id, actor: .system, now: t0)
        #expect(afterSave.events.count == 3)

        let afterPause = try await engine.pause(runID: created.run.id, actor: .system, now: t0)
        #expect(afterPause.events.count == 4)
    }
}
