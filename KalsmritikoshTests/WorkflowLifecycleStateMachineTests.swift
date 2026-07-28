//
//  WorkflowLifecycleStateMachineTests.swift
//  KalsmritikoshTests
//
//  PJE-004 — WorkflowLifecycleStateMachine: run-status transitions, step compatibility,
//  forward/return/branch resolution, human-actor enforcement, and projection.
//  20 tests, no database required.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-004 — WorkflowLifecycleStateMachine")
struct WorkflowLifecycleStateMachineTests {

    private let sm = WorkflowLifecycleStateMachine()

    // MARK: - Helpers

    private func makeOpDef(steps: [PersonaWorkflowStepDefinition],
                           entryID: StepDefinitionID) -> OperationalWorkflowDefinition {
        let terminal = steps.first(where: { $0.isTerminal })
        let terminalIDs: Set<StepDefinitionID> = terminal.map { [$0.id] } ?? []
        let reachable = Set(steps.map(\.id))
        let raw = PersonaWorkflowDefinition(
            id: WorkflowDefinitionID(rawValue: "wf.test"), version: 1, schemaVersion: 1,
            label: "Test", steps: steps)
        let validated = ValidatedWorkflowDefinition(
            definition: raw,
            entryStepID: entryID,
            terminalStepIDs: terminalIDs,
            reachableStepIDs: reachable)
        return OperationalWorkflowDefinition(validated: validated)
    }

    private func twoStepOpDef() -> (OperationalWorkflowDefinition, PersonaWorkflowStepDefinition) {
        let entryID = StepDefinitionID(rawValue: "step.entry")
        let termID = StepDefinitionID(rawValue: "step.done")
        let entry = PersonaWorkflowStepDefinition(
            id: entryID, kind: .intake, label: "Entry", isEntry: true,
            transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: termID)])
        let terminal = PersonaWorkflowStepDefinition(
            id: termID, kind: .closure, label: "Done", isTerminal: true)
        let opDef = makeOpDef(steps: [entry, terminal], entryID: entryID)
        return (opDef, entry)
    }

    // MARK: - 1: Draft allowed actions

    @Test("allowedActions for draft is {start, cancel, supersede}")
    func draftAllowedActions() {
        let allowed = WorkflowLifecycleStateMachine.allowedActions(for: .draft)
        #expect(allowed == [.start, .cancel, .supersede])
    }

    // MARK: - 2: Active allowed actions

    @Test("allowedActions for active includes advance, pause, block, chooseBranch, complete")
    func activeAllowedActions() {
        let allowed = WorkflowLifecycleStateMachine.allowedActions(for: .active)
        #expect(allowed.contains(.advance))
        #expect(allowed.contains(.pause))
        #expect(allowed.contains(.block))
        #expect(allowed.contains(.chooseBranch))
        #expect(allowed.contains(.complete))
        #expect(allowed.contains(.cancel))
        #expect(allowed.contains(.supersede))
        #expect(allowed.contains(.save))
        #expect(allowed.contains(.requestHumanDecision))
        #expect(allowed.contains(.returnToPriorStep))
    }

    // MARK: - 3: Paused allowed actions

    @Test("allowedActions for paused is {save, resume, cancel, supersede}")
    func pausedAllowedActions() {
        let allowed = WorkflowLifecycleStateMachine.allowedActions(for: .paused)
        #expect(allowed == [.save, .resume, .cancel, .supersede])
    }

    // MARK: - 4: WaitingForHuman allowed actions

    @Test("allowedActions for waitingForHuman includes recordHumanDecision and recordHumanApproval")
    func waitingForHumanAllowedActions() {
        let allowed = WorkflowLifecycleStateMachine.allowedActions(for: .waitingForHuman)
        #expect(allowed.contains(.recordHumanDecision))
        #expect(allowed.contains(.recordHumanApproval))
        #expect(allowed.contains(.save))
        #expect(allowed.contains(.cancel))
        #expect(allowed.contains(.supersede))
    }

    // MARK: - 5: Blocked allowed actions

    @Test("allowedActions for blocked is {save, unblock, cancel, supersede}")
    func blockedAllowedActions() {
        let allowed = WorkflowLifecycleStateMachine.allowedActions(for: .blocked)
        #expect(allowed == [.save, .unblock, .cancel, .supersede])
    }

    // MARK: - 6: Terminal run has no allowed actions

    @Test("allowedActions for completed/cancelled/superseded is empty")
    func terminalAllowedActions() {
        #expect(WorkflowLifecycleStateMachine.allowedActions(for: .completed).isEmpty)
        #expect(WorkflowLifecycleStateMachine.allowedActions(for: .cancelled).isEmpty)
        #expect(WorkflowLifecycleStateMachine.allowedActions(for: .superseded).isEmpty)
    }

    // MARK: - 7: Allowed transition succeeds

    @Test("assertRunTransitionAllowed succeeds for draft→start")
    func draftToStartAllowed() throws {
        #expect(throws: Never.self) {
            try sm.assertRunTransitionAllowed(from: .draft, action: .start)
        }
    }

    // MARK: - 8: Illegal transition throws

    @Test("assertRunTransitionAllowed throws illegalRunTransition for paused→advance")
    func pausedToAdvanceIllegal() throws {
        do {
            try sm.assertRunTransitionAllowed(from: .paused, action: .advance)
            Issue.record("Expected illegalRunTransition")
        } catch WorkflowLifecycleError.illegalRunTransition(let from, let action) {
            #expect(from == .paused)
            #expect(action == .advance)
        }
    }

    // MARK: - 9: Terminal run throws terminalRunImmutable

    @Test("assertRunTransitionAllowed throws terminalRunImmutable for completed run")
    func completedRunImmutable() throws {
        do {
            try sm.assertRunTransitionAllowed(from: .completed, action: .save)
            Issue.record("Expected terminalRunImmutable")
        } catch WorkflowLifecycleError.terminalRunImmutable(_, let status) {
            #expect(status == .completed)
        }
    }

    // MARK: - 10: Forward transition by label

    @Test("resolveForwardTransition by label finds correct transition")
    func resolveForwardByLabel() throws {
        let (_, step) = twoStepOpDef()
        let transition = try sm.resolveForwardTransition(
            selector: .label("next"), step: step)
        #expect(transition.label == "next")
        #expect(transition.targetStepID.rawValue == "step.done")
    }

    // MARK: - 11: Forward transition by targetStepID

    @Test("resolveForwardTransition by targetStepID finds correct transition")
    func resolveForwardByTargetID() throws {
        let entryID = StepDefinitionID(rawValue: "step.entry")
        let termID = StepDefinitionID(rawValue: "step.done")
        let entry = PersonaWorkflowStepDefinition(
            id: entryID, kind: .intake, label: "Entry", isEntry: true,
            transitions: [WorkflowTransitionDefinition(label: "go", targetStepID: termID)])
        let t = try sm.resolveForwardTransition(selector: .targetStepID(termID), step: entry)
        #expect(t.targetStepID == termID)
    }

    // MARK: - 12: Forward transition not found

    @Test("resolveForwardTransition for missing label throws transitionNotFound")
    func forwardTransitionNotFound() throws {
        let (_, step) = twoStepOpDef()
        do {
            _ = try sm.resolveForwardTransition(selector: .label("nonexistent"), step: step)
            Issue.record("Expected transitionNotFound")
        } catch WorkflowLifecycleError.transitionNotFound(let sid) {
            #expect(sid == step.id)
        }
    }

    // MARK: - 13: Return transition by label

    @Test("resolveReturnTransition by label finds correct return transition")
    func resolveReturnByLabel() throws {
        let entryID = StepDefinitionID(rawValue: "step.entry")
        let midID = StepDefinitionID(rawValue: "step.middle")
        let termID = StepDefinitionID(rawValue: "step.done")
        let mid = PersonaWorkflowStepDefinition(
            id: midID, kind: .form, label: "Middle",
            transitions: [
                WorkflowTransitionDefinition(label: "forward", targetStepID: termID),
                WorkflowTransitionDefinition(label: "back", targetStepID: entryID, isReturn: true)
            ],
            loopPolicy: .returnsToStep)
        let t = try sm.resolveReturnTransition(selector: .label("back"), step: mid)
        #expect(t.label == "back")
        #expect(t.targetStepID == entryID)
    }

    // MARK: - 14: Decision branch resolution

    @Test("resolveDecisionBranch finds transition whose label matches branch")
    func resolveDecisionBranch() throws {
        let decID = StepDefinitionID(rawValue: "step.dec")
        let termID = StepDefinitionID(rawValue: "step.done")
        let decStep = PersonaWorkflowStepDefinition(
            id: decID, kind: .decision, label: "Dec",
            transitions: [
                WorkflowTransitionDefinition(label: "yes", targetStepID: termID),
                WorkflowTransitionDefinition(label: "no", targetStepID: termID)
            ],
            decisionBranches: ["yes", "no"])
        let t = try sm.resolveDecisionBranch(branch: "yes", step: decStep)
        #expect(t.label == "yes")
    }

    // MARK: - 15: Decision branch not in decisionBranches throws

    @Test("resolveDecisionBranch with undeclared branch throws undeclaredDecisionBranch")
    func undeclaredDecisionBranchThrows() throws {
        let decID = StepDefinitionID(rawValue: "step.dec")
        let termID = StepDefinitionID(rawValue: "step.done")
        let decStep = PersonaWorkflowStepDefinition(
            id: decID, kind: .decision, label: "Dec",
            transitions: [WorkflowTransitionDefinition(label: "yes", targetStepID: termID)],
            decisionBranches: ["yes"])
        do {
            _ = try sm.resolveDecisionBranch(branch: "maybe", step: decStep)
            Issue.record("Expected undeclaredDecisionBranch")
        } catch WorkflowLifecycleError.undeclaredDecisionBranch(let sid, let branch) {
            #expect(sid == decID)
            #expect(branch == "maybe")
        }
    }

    // MARK: - 16: Human actor enforcement — system actor fails

    @Test("assertHumanActor rejects system actor with humanActorRequired")
    func systemActorRejected() throws {
        do {
            try sm.assertHumanActor(WorkflowLifecycleActor.system)
            Issue.record("Expected humanActorRequired")
        } catch WorkflowLifecycleError.humanActorRequired {
            // expected
        }
    }

    // MARK: - 17: Human actor enforcement — human actor passes

    @Test("assertHumanActor accepts a human actor")
    func humanActorAccepted() throws {
        let actor = try WorkflowLifecycleActor.human(identifier: "user@example.com", role: "reviewer")
        #expect(throws: Never.self) { try sm.assertHumanActor(actor) }
    }

    // MARK: - 18: Human approver role passes for allowed role

    @Test("assertHumanApproverRole accepts actor whose role is in approverRoles")
    func humanApproverRoleAccepted() throws {
        let stepID = StepDefinitionID(rawValue: "step.approve")
        let step = PersonaWorkflowStepDefinition(
            id: stepID, kind: .humanApproval, label: "Approve",
            isEntry: true,
            transitions: [WorkflowTransitionDefinition(
                label: "next", targetStepID: StepDefinitionID(rawValue: "step.done"))],
            approverRoles: ["supervisor", "director"])
        let actor = try WorkflowLifecycleActor.human(identifier: "boss@example.com", role: "supervisor")
        #expect(throws: Never.self) {
            try sm.assertHumanApproverRole(actor: actor, step: step)
        }
    }

    // MARK: - 19: Human approver role fails for wrong role

    @Test("assertHumanApproverRole rejects actor with unauthorized role")
    func humanApproverRoleRejected() throws {
        let stepID = StepDefinitionID(rawValue: "step.approve")
        let step = PersonaWorkflowStepDefinition(
            id: stepID, kind: .humanApproval, label: "Approve",
            isEntry: true,
            transitions: [WorkflowTransitionDefinition(
                label: "next", targetStepID: StepDefinitionID(rawValue: "step.done"))],
            approverRoles: ["supervisor"])
        let actor = try WorkflowLifecycleActor.human(identifier: "intern@example.com", role: "intern")
        do {
            try sm.assertHumanApproverRole(actor: actor, step: step)
            Issue.record("Expected unauthorizedApproverRole")
        } catch WorkflowLifecycleError.unauthorizedApproverRole(let supplied, let allowed) {
            #expect(supplied == "intern")
            #expect(allowed == ["supervisor"])
        }
    }

    // MARK: - 20: Projection reflects current run state

    @Test("project returns projection whose structuralActions matches the run status")
    func projectionReflectsRunStatus() {
        let (opDef, step) = twoStepOpDef()
        let runID = UUID()
        let stepRunID = UUID()
        let wsID = UUID()
        let appID = ApplicationDefinitionID(rawValue: "com.test.app")
        let wfID = WorkflowDefinitionID(rawValue: "wf.test")
        let now = Date(timeIntervalSince1970: 1_753_000_000)
        let run = WorkflowRun(
            id: runID,
            workspaceID: wsID,
            applicationDefinitionID: appID,
            applicationDefinitionVersion: 1,
            workflowDefinitionID: wfID,
            workflowDefinitionVersion: 1,
            title: nil,
            status: .active,
            currentStepDefinitionID: step.id,
            currentStepRunID: stepRunID,
            contractSnapshotJSON: "{}",
            contractSnapshotSHA256: "testhash",
            snapshotSchemaVersion: 1,
            revision: 1,
            parentRunID: nil,
            supersededByRunID: nil,
            createdAt: now,
            updatedAt: now,
            startedAt: now,
            pausedAt: nil,
            completedAt: nil,
            cancelledAt: nil,
            cancellationReason: nil)
        let stepRun = WorkflowStepRun(
            id: stepRunID,
            workflowRunID: runID,
            stepDefinitionID: step.id,
            stepKind: .intake,
            attempt: 1,
            sequence: 1,
            status: .active,
            executorID: nil,
            executorVersion: nil,
            inputJSON: "{}",
            stateJSON: "{}",
            outputJSON: nil,
            stateSHA256: "stateHash",
            enteredAt: now,
            updatedAt: now,
            completedAt: nil)
        let projection = sm.project(run: run, currentStepRun: stepRun, opDef: opDef)
        #expect(projection.runStatus == .active)
        let expected = WorkflowLifecycleStateMachine.allowedActions(for: .active)
        #expect(projection.structuralActions == expected)
        #expect(projection.currentStep?.id == step.id)
    }
}
