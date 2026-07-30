//
//  PJE010AutomationRuntimeTests.swift
//  KalsmritikoshTests
//
//  PJE-010 Part B — the automation runtime executes the six safe actions into
//  PROPOSAL-layer outputs, records idempotent execution receipts, guards
//  recursion, validates evidence, and never confirms a Claim, Deadline, or
//  approval.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-010 — automation runtime", .serialized)
@MainActor
struct PJE010AutomationRuntimeTests {

    private let t0 = PJE010Fixtures.t0

    private func makeRig() async throws -> PJE010Rig {
        try await PJE010Fixtures.makeRig(at: PJE007Fixtures.newURL())
    }

    private func workflowEvent(_ key: String = "evt-1") -> PersonaAutomationTriggerEvent {
        PersonaAutomationTriggerEvent(kind: .workflowEvent, eventKey: key)
    }

    private func count(_ db: Database, _ table: String) async throws -> Int {
        Int(try await db.query("SELECT COUNT(*) FROM \(table);", []).first?.int(0) ?? -1)
    }

    // MARK: - Action adapters

    @Test("createSuggestion produces an advisory automation attention item")
    func createSuggestion() async throws {
        let rig = try await makeRig()
        let (ws, runID) = try await PJE010Fixtures.startRun(rig, suffix: "sugg")
        let def = PJE010Fixtures.automation(action: .createSuggestion)
        let outcome = try await rig.coordinator.run(
            definition: def, applicationID: PJE010Fixtures.applicationID,
            request: PersonaAutomationRequest(workspaceID: ws, workflowRunID: runID, title: "Consider X"),
            trigger: workflowEvent(), now: t0.addingTimeInterval(10))
        guard case .produced(let exec) = outcome else { Issue.record("expected produced"); return }
        #expect(exec.status == .succeeded)
        #expect(exec.outputKind == .attentionItem)
        let agg = try await rig.workflowRuns.fetchRun(runID)
        let item = try #require(agg.attentionItems.first { $0.id == exec.outputID })
        #expect(item.sourceKind == .automation)
        #expect(item.severity == .advisory)
        #expect(item.sourceID?.contains("auto.gap-request") == true)
    }

    @Test("createCandidateTask produces a candidate task with automationProposed origin")
    func createCandidateTask() async throws {
        let rig = try await makeRig()
        let (ws, runID) = try await PJE010Fixtures.startRun(rig, suffix: "task")
        let def = PJE010Fixtures.automation(action: .createCandidateTask)
        let outcome = try await rig.coordinator.run(
            definition: def, applicationID: PJE010Fixtures.applicationID,
            request: PersonaAutomationRequest(workspaceID: ws, workflowRunID: runID, title: "Follow up"),
            trigger: workflowEvent(), now: t0.addingTimeInterval(10))
        guard case .produced(let exec) = outcome else { Issue.record("expected produced"); return }
        #expect(exec.outputKind == .candidateTask)
        let taskID = try #require(exec.outputID)
        let rows = try await rig.db.query(
            "SELECT status, origin FROM professional_tasks WHERE id = ?;", [.uuid(taskID)])
        #expect(rows.first?.string(0) == "candidate")
        #expect(rows.first?.string(1) == "automationProposed")
    }

    @Test("createMissingEvidenceRequest produces a candidate evidenceRequest task")
    func createMissingEvidenceRequest() async throws {
        let rig = try await makeRig()
        let (ws, runID) = try await PJE010Fixtures.startRun(rig, suffix: "evreq")
        let def = PJE010Fixtures.automation(action: .createMissingEvidenceRequest)
        let outcome = try await rig.coordinator.run(
            definition: def, applicationID: PJE010Fixtures.applicationID,
            request: PersonaAutomationRequest(workspaceID: ws, workflowRunID: runID, title: "Need the invoice"),
            trigger: workflowEvent(), now: t0.addingTimeInterval(10))
        guard case .produced(let exec) = outcome else { Issue.record("expected produced"); return }
        let taskID = try #require(exec.outputID)
        let rows = try await rig.db.query(
            "SELECT task_type, status FROM professional_tasks WHERE id = ?;", [.uuid(taskID)])
        #expect(rows.first?.string(0) == "evidenceRequest")
        #expect(rows.first?.string(1) == "candidate")
    }

    @Test("createCandidateDeadline produces a pending candidate with automationProposed origin")
    func createCandidateDeadline() async throws {
        let rig = try await makeRig()
        let (ws, runID) = try await PJE010Fixtures.startRun(rig, suffix: "deadline")
        let taskID = try await PJE010Fixtures.seedTask(rig, ws: ws)
        let def = PJE010Fixtures.automation(action: .createCandidateDeadline)
        let outcome = try await rig.coordinator.run(
            definition: def, applicationID: PJE010Fixtures.applicationID,
            request: PersonaAutomationRequest(
                workspaceID: ws, workflowRunID: runID, title: "Filing due",
                targetTaskID: taskID, deadlineValue: PJE010Fixtures.dayDeadline(), deadlineKind: .filing),
            trigger: workflowEvent(), now: t0.addingTimeInterval(10))
        guard case .produced(let exec) = outcome else { Issue.record("expected produced"); return }
        #expect(exec.outputKind == .candidateDeadline)
        let candID = try #require(exec.outputID)
        let rows = try await rig.db.query(
            "SELECT status, origin FROM deadline_candidates WHERE id = ?;", [.uuid(candID)])
        #expect(rows.first?.string(0) == "pending")
        #expect(rows.first?.string(1) == "automationProposed")
        // No CONFIRMED deadline was created.
        #expect(try await count(rig.db, "deadlines") == 0)
    }

    @Test("createCandidateDeadline without a target task and value is rejected")
    func candidateDeadlineRequiresTargetAndValue() async throws {
        let rig = try await makeRig()
        let (ws, runID) = try await PJE010Fixtures.startRun(rig, suffix: "nodl")
        let def = PJE010Fixtures.automation(action: .createCandidateDeadline)
        await #expect(throws: (any Error).self) {
            _ = try await rig.coordinator.run(
                definition: def, applicationID: PJE010Fixtures.applicationID,
                request: PersonaAutomationRequest(workspaceID: ws, workflowRunID: runID, title: "x"),
                trigger: self.workflowEvent(), now: self.t0.addingTimeInterval(10))
        }
    }

    // MARK: - Idempotency

    @Test("Replaying the same trigger event produces one output (skippedDuplicate)")
    func idempotentReplay() async throws {
        let rig = try await makeRig()
        let (ws, runID) = try await PJE010Fixtures.startRun(rig, suffix: "idem")
        let def = PJE010Fixtures.automation(action: .createCandidateTask)
        let request = PersonaAutomationRequest(workspaceID: ws, workflowRunID: runID, title: "Once")
        let first = try await rig.coordinator.run(
            definition: def, applicationID: PJE010Fixtures.applicationID,
            request: request, trigger: workflowEvent("same-event"), now: t0.addingTimeInterval(10))
        let tasksAfterFirst = try await count(rig.db, "professional_tasks")
        let second = try await rig.coordinator.run(
            definition: def, applicationID: PJE010Fixtures.applicationID,
            request: request, trigger: workflowEvent("same-event"), now: t0.addingTimeInterval(20))
        guard case .produced(let e1) = first, case .skippedDuplicate(let e2) = second else {
            Issue.record("expected produced then skippedDuplicate"); return
        }
        #expect(e1.id == e2.id)
        #expect(try await count(rig.db, "professional_tasks") == tasksAfterFirst)  // no second task
        #expect(try await rig.executions.executions(inWorkspace: ws).count == 1)   // one receipt
    }

    @Test("A different trigger event produces a new output")
    func differentEventNewOutput() async throws {
        let rig = try await makeRig()
        let (ws, runID) = try await PJE010Fixtures.startRun(rig, suffix: "diffevt")
        let def = PJE010Fixtures.automation(action: .createCandidateTask)
        let req = PersonaAutomationRequest(workspaceID: ws, workflowRunID: runID, title: "A")
        _ = try await rig.coordinator.run(definition: def, applicationID: PJE010Fixtures.applicationID,
            request: req, trigger: workflowEvent("evt-A"), now: t0.addingTimeInterval(10))
        _ = try await rig.coordinator.run(definition: def, applicationID: PJE010Fixtures.applicationID,
            request: req, trigger: workflowEvent("evt-B"), now: t0.addingTimeInterval(20))
        #expect(try await count(rig.db, "professional_tasks") == 2)
    }

    // MARK: - Triggers

    @Test("A delivered trigger that does not match the definition is rejected")
    func triggerMismatchRejected() async throws {
        let rig = try await makeRig()
        let (ws, runID) = try await PJE010Fixtures.startRun(rig, suffix: "mismatch")
        let def = PJE010Fixtures.automation(trigger: .workflowEvent, action: .createSuggestion)
        await #expect(throws: (any Error).self) {
            _ = try await rig.coordinator.run(
                definition: def, applicationID: PJE010Fixtures.applicationID,
                request: PersonaAutomationRequest(workspaceID: ws, workflowRunID: runID, title: "x"),
                trigger: PersonaAutomationTriggerEvent(kind: .manual, eventKey: "m"),
                now: self.t0.addingTimeInterval(10))
        }
    }

    @Test("An automation-created attention item does not re-trigger the same automation (recursion suppressed)")
    func recursionSuppressed() async throws {
        let rig = try await makeRig()
        let (ws, runID) = try await PJE010Fixtures.startRun(rig, suffix: "recursion")
        let def = PJE010Fixtures.automation(trigger: .attentionCreated, action: .createSuggestion)
        let before = try await count(rig.db, "workflow_attention_items")
        let outcome = try await rig.coordinator.run(
            definition: def, applicationID: PJE010Fixtures.applicationID,
            request: PersonaAutomationRequest(workspaceID: ws, workflowRunID: runID, title: "loop?"),
            trigger: PersonaAutomationTriggerEvent(
                kind: .attentionCreated, eventKey: "att-1", originIsAutomation: true),
            now: t0.addingTimeInterval(10))
        #expect(outcome == .suppressedRecursion)
        #expect(try await count(rig.db, "workflow_attention_items") == before)  // no new item
    }

    @Test("Responding to an automation-created attention item is allowed with explicit opt-in")
    func recursionOptIn() async throws {
        let rig = try await makeRig()
        let (ws, runID) = try await PJE010Fixtures.startRun(rig, suffix: "optin")
        let def = PJE010Fixtures.automation(trigger: .attentionCreated, action: .createSuggestion)
        let outcome = try await rig.coordinator.run(
            definition: def, applicationID: PJE010Fixtures.applicationID,
            request: PersonaAutomationRequest(workspaceID: ws, workflowRunID: runID, title: "handle it"),
            trigger: PersonaAutomationTriggerEvent(
                kind: .attentionCreated, eventKey: "att-2",
                originIsAutomation: true, respondToAutomationOrigin: true),
            now: t0.addingTimeInterval(10))
        guard case .produced = outcome else { Issue.record("expected produced"); return }
    }

    @Test("A trigger past the recursion depth limit is rejected")
    func recursionDepthLimit() async throws {
        let rig = try await makeRig()
        let (ws, runID) = try await PJE010Fixtures.startRun(rig, suffix: "depth")
        let def = PJE010Fixtures.automation(trigger: .workflowEvent, action: .createSuggestion)
        await #expect(throws: (any Error).self) {
            _ = try await rig.coordinator.run(
                definition: def, applicationID: PJE010Fixtures.applicationID,
                request: PersonaAutomationRequest(workspaceID: ws, workflowRunID: runID, title: "deep"),
                trigger: PersonaAutomationTriggerEvent(kind: .workflowEvent, eventKey: "d", recursionDepth: 5),
                now: self.t0.addingTimeInterval(10))
        }
    }

    // MARK: - Evidence

    @Test("A valid in-workspace evidence reference is accepted")
    func evidenceReferenceAccepted() async throws {
        let rig = try await makeRig()
        let (ws, runID) = try await PJE010Fixtures.startRun(rig, suffix: "ev-ok")
        let entity = try await PJE007Fixtures.seedEntity(rig.db, in: ws)
        let def = PJE010Fixtures.automation(action: .createSuggestion)
        let outcome = try await rig.coordinator.run(
            definition: def, applicationID: PJE010Fixtures.applicationID,
            request: PersonaAutomationRequest(
                workspaceID: ws, workflowRunID: runID, title: "cite",
                evidenceReferences: [WorkflowProvenanceReference(kind: .entity, canonicalObjectID: entity, role: .supporting)]),
            trigger: workflowEvent(), now: t0.addingTimeInterval(10))
        guard case .produced = outcome else { Issue.record("expected produced"); return }
    }

    @Test("A cross-workspace evidence reference fails closed")
    func evidenceReferenceDenied() async throws {
        let rig = try await makeRig()
        let (ws, runID) = try await PJE010Fixtures.startRun(rig, suffix: "ev-bad")
        let wsB = UUID()
        try await PJE007Fixtures.seedWorkspace(rig.db, id: wsB)
        let foreign = try await PJE007Fixtures.seedEntity(rig.db, in: wsB)
        let def = PJE010Fixtures.automation(action: .createSuggestion)
        await #expect(throws: (any Error).self) {
            _ = try await rig.coordinator.run(
                definition: def, applicationID: PJE010Fixtures.applicationID,
                request: PersonaAutomationRequest(
                    workspaceID: ws, workflowRunID: runID, title: "cite",
                    evidenceReferences: [WorkflowProvenanceReference(kind: .entity, canonicalObjectID: foreign, role: .supporting)]),
                trigger: self.workflowEvent(), now: self.t0.addingTimeInterval(10))
        }
    }

    // MARK: - Atomicity / rollback

    @Test("A failed output leaves no proposal and no succeeded receipt (failed receipt only)")
    func failedOutputNoProposalNoSuccess() async throws {
        let rig = try await makeRig()
        let (ws, runID) = try await PJE010Fixtures.startRun(rig, suffix: "failout")
        let def = PJE010Fixtures.automation(action: .createCandidateDeadline)
        let deadlinesBefore = try await count(rig.db, "deadline_candidates")
        // A valid run reserves the receipt, but a non-existent target task makes
        // the candidate-deadline OUTPUT fail (FK) AFTER the receipt is reserved.
        await #expect(throws: (any Error).self) {
            _ = try await rig.coordinator.run(
                definition: def, applicationID: PJE010Fixtures.applicationID,
                request: PersonaAutomationRequest(
                    workspaceID: ws, workflowRunID: runID, title: "x",
                    targetTaskID: UUID(), deadlineValue: PJE010Fixtures.dayDeadline(), deadlineKind: .due),
                trigger: self.workflowEvent(), now: self.t0.addingTimeInterval(10))
        }
        #expect(try await count(rig.db, "deadline_candidates") == deadlinesBefore)  // no proposal
        let executions = try await rig.executions.executions(inWorkspace: ws)
        #expect(executions.count == 1)
        #expect(executions.first?.status == .failed)     // failed receipt only
        #expect(executions.first?.outputID == nil)
    }

    // MARK: - Never confirms truth objects

    @Test("Automation never mutates canonical claims/events or creates a confirmed deadline")
    func neverConfirmsTruthObjects() async throws {
        let rig = try await makeRig()
        let (ws, runID) = try await PJE010Fixtures.startRun(rig, suffix: "notruth")
        let taskID = try await PJE010Fixtures.seedTask(rig, ws: ws)
        let claimsBefore = try await count(rig.db, "claims")
        let def = PJE010Fixtures.automation(action: .createCandidateDeadline)
        _ = try await rig.coordinator.run(
            definition: def, applicationID: PJE010Fixtures.applicationID,
            request: PersonaAutomationRequest(
                workspaceID: ws, workflowRunID: runID, title: "due",
                targetTaskID: taskID, deadlineValue: PJE010Fixtures.dayDeadline(), deadlineKind: .due),
            trigger: workflowEvent(), now: t0.addingTimeInterval(10))
        #expect(try await count(rig.db, "claims") == claimsBefore)
        #expect(try await count(rig.db, "deadlines") == 0)   // no confirmed deadline
    }

    // MARK: - Reopen / version / tamper

    @Test("The execution receipt records the pinned automation version and reopens")
    func executionRecordsVersionAndReopens() async throws {
        let rig = try await makeRig()
        let (ws, runID) = try await PJE010Fixtures.startRun(rig, suffix: "version")
        let def = PJE010Fixtures.automation(version: 3, action: .createCandidateTask)
        let outcome = try await rig.coordinator.run(
            definition: def, applicationID: PJE010Fixtures.applicationID,
            request: PersonaAutomationRequest(workspaceID: ws, workflowRunID: runID, title: "v3"),
            trigger: workflowEvent(), now: t0.addingTimeInterval(10))
        guard case .produced(let exec) = outcome else { Issue.record("expected produced"); return }
        let reopened = try #require(try await rig.executions.execution(id: exec.id))
        #expect(reopened.automationDefinitionVersion == 3)
        #expect(reopened.status == .succeeded)
    }

    @Test("Tampering the persisted request JSON is detected on reopen")
    func requestTamperDetected() async throws {
        let rig = try await makeRig()
        let (ws, runID) = try await PJE010Fixtures.startRun(rig, suffix: "reqtamper")
        let def = PJE010Fixtures.automation(action: .createCandidateTask)
        let outcome = try await rig.coordinator.run(
            definition: def, applicationID: PJE010Fixtures.applicationID,
            request: PersonaAutomationRequest(workspaceID: ws, workflowRunID: runID, title: "t"),
            trigger: workflowEvent(), now: t0.addingTimeInterval(10))
        guard case .produced(let exec) = outcome else { Issue.record("expected produced"); return }
        try await rig.db.exec(
            "UPDATE workflow_automation_executions SET request_json = ? WHERE id = ?;",
            [.text("{\"tampered\":true}"), .uuid(exec.id)])
        await #expect(throws: WorkflowAutomationExecutionError.self) {
            _ = try await rig.executions.execution(id: exec.id)
        }
    }

    @Test("Tampering the persisted result JSON is detected on reopen")
    func resultTamperDetected() async throws {
        let rig = try await makeRig()
        let (ws, runID) = try await PJE010Fixtures.startRun(rig, suffix: "restamper")
        let def = PJE010Fixtures.automation(action: .createCandidateTask)
        let outcome = try await rig.coordinator.run(
            definition: def, applicationID: PJE010Fixtures.applicationID,
            request: PersonaAutomationRequest(workspaceID: ws, workflowRunID: runID, title: "t"),
            trigger: workflowEvent(), now: t0.addingTimeInterval(10))
        guard case .produced(let exec) = outcome else { Issue.record("expected produced"); return }
        try await rig.db.exec(
            "UPDATE workflow_automation_executions SET result_json = ? WHERE id = ?;",
            [.text("{\"tampered\":true}"), .uuid(exec.id)])
        await #expect(throws: WorkflowAutomationExecutionError.self) {
            _ = try await rig.executions.execution(id: exec.id)
        }
    }

    @Test("Deleting the proposal output is represented honestly (the receipt is not fabricated)")
    func outputDeletionVisible() async throws {
        let rig = try await makeRig()
        let (ws, runID) = try await PJE010Fixtures.startRun(rig, suffix: "outdel")
        let def = PJE010Fixtures.automation(action: .createCandidateTask)
        let outcome = try await rig.coordinator.run(
            definition: def, applicationID: PJE010Fixtures.applicationID,
            request: PersonaAutomationRequest(workspaceID: ws, workflowRunID: runID, title: "gone"),
            trigger: workflowEvent(), now: t0.addingTimeInterval(10))
        guard case .produced(let exec) = outcome else { Issue.record("expected produced"); return }
        let taskID = try #require(exec.outputID)
        try await rig.db.exec("DELETE FROM professional_tasks WHERE id = ?;", [.uuid(taskID)])
        let reopened = try #require(try await rig.executions.execution(id: exec.id))
        #expect(reopened.outputID == taskID)   // the receipt still points at the (now-gone) output
        let taskCount = Int(try await rig.db.query(
            "SELECT COUNT(*) FROM professional_tasks WHERE id = ?;", [.uuid(taskID)]).first?.int(0) ?? -1)
        #expect(taskCount == 0)
    }

    @Test("A candidate task from automation is never born open")
    func candidateNeverBornOpen() async throws {
        let rig = try await makeRig()
        let (ws, runID) = try await PJE010Fixtures.startRun(rig, suffix: "notopen")
        let def = PJE010Fixtures.automation(action: .createCandidateTask)
        let outcome = try await rig.coordinator.run(
            definition: def, applicationID: PJE010Fixtures.applicationID,
            request: PersonaAutomationRequest(workspaceID: ws, workflowRunID: runID, title: "c"),
            trigger: workflowEvent(), now: t0.addingTimeInterval(10))
        guard case .produced(let exec) = outcome else { Issue.record("expected produced"); return }
        let status = try await rig.db.query(
            "SELECT status FROM professional_tasks WHERE id = ?;", [.uuid(try #require(exec.outputID))]).first?.string(0)
        #expect(status == "candidate")
    }
}
