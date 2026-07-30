//
//  WorkflowLifecycleRelaunchTests.swift
//  KalsmritikoshTests
//
//  PJE-004 — Relaunch reconstruction: a full multi-step lifecycle flow
//  (start → advance → pause → resume → chooseBranch → complete) verified end-to-end,
//  with specific checks that the frozen contract snapshot is preserved faithfully
//  across every action.
//
//  The test also verifies that the reconstructed definition from the contract snapshot
//  matches the original package definition exactly — the engine must never consult a
//  live catalog for lifecycle decisions.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-004 — WorkflowLifecycleRelaunch")
struct WorkflowLifecycleRelaunchTests {

    private let t0 = Date(timeIntervalSince1970: 1_753_300_000)

    // MARK: - Setup

    private func makeDB() async throws -> Database {
        try await MigrationFixtureBuilder.database(atVersion: 77)
    }

    private func insertWorkspace(_ db: Database, id: UUID) async throws {
        try await db.exec("""
        INSERT INTO workspaces (id, title, template_type, created_at, updated_at)
        VALUES (?,?,?,?,?);
        """, [.uuid(id), .text("Relaunch WS"), .text("general"),
              .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
    }

    /// Four-step package:
    /// intake → review (decision: approve/reject) → done (closure)
    ///                                             → intake again via returnsToStep if reject (not modelled here for simplicity)
    ///
    /// To keep the relaunch test tractable we use: intake → decide (yes→done, no→done)
    private func makeRelaunchPackage() throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let appID = ApplicationDefinitionID(rawValue: "com.relaunch.test.app")
        let wfID = WorkflowDefinitionID(rawValue: "com.relaunch.test.wf")
        let intakeID = StepDefinitionID(rawValue: "step.intake")
        let decideID = StepDefinitionID(rawValue: "step.decide")
        let doneID = StepDefinitionID(rawValue: "step.done")

        let intake = PersonaWorkflowStepDefinition(
            id: intakeID, kind: .intake, label: "Intake", isEntry: true,
            transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: decideID)])
        let decide = PersonaWorkflowStepDefinition(
            id: decideID, kind: .decision, label: "Decide",
            transitions: [
                WorkflowTransitionDefinition(label: "approve", targetStepID: doneID),
                WorkflowTransitionDefinition(label: "reject", targetStepID: doneID)
            ],
            decisionBranches: ["approve", "reject"])
        let done = PersonaWorkflowStepDefinition(
            id: doneID, kind: .closure, label: "Done", isTerminal: true)

        let term = PersonaTerminologyDefinition(
            id: TerminologyDefinitionID(rawValue: "com.relaunch.test.term"),
            version: 1, applicationID: appID, labels: [:])
        let app = PersonaApplicationDefinition(id: appID, version: 1, label: "Relaunch App")
        let wfDef = PersonaWorkflowDefinition(
            id: wfID, version: 1, schemaVersion: 1, label: "Relaunch WF",
            steps: [intake, decide, done])
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

    // MARK: - Full lifecycle relaunch test

    /// Full flow: draft → start → advance(intake→decide) → pause → resume →
    ///            chooseBranch(approve) → completed
    /// After each action, re-fetch the aggregate and verify the frozen contract snapshot
    /// is unchanged — the engine never consults a live catalog.
    @Test("Full lifecycle flow start→advance→pause→resume→chooseBranch→complete with frozen snapshot")
    func fullLifecycleFlowWithFrozenSnapshot() async throws {
        let db = try await makeDB()
        let engine = WorkflowLifecycleEngine(repository: WorkflowRunRepository(database: db))
        let (pkg, wfID) = try makeRelaunchPackage()

        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let repo = WorkflowRunRepository(database: db)

        // 1. CREATE — draft, revision 1
        let created = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: "Relaunch Test Run",
            parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)

        #expect(created.run.status == .draft)
        #expect(created.run.revision == 1)
        #expect(created.stepRuns.isEmpty)

        // Capture the frozen contract hash at creation time
        let originalContractHash = created.run.contractSnapshotSHA256

        // 2. START — active, revision 2, entry step inserted
        let t1 = t0.addingTimeInterval(60)
        let afterStart = try await engine.start(
            runID: created.run.id,
            entryPayload: WorkflowStepEntryPayload(inputJSON: "{\"phase\":\"intake\"}", stateJSON: "{}"),
            actor: .system, now: t1)

        #expect(afterStart.run.status == .active)
        #expect(afterStart.run.revision == 2)
        #expect(afterStart.stepRuns.count == 1)
        #expect(afterStart.stepRuns[0].stepDefinitionID.rawValue == "step.intake")
        #expect(afterStart.stepRuns[0].status == .active)
        #expect(afterStart.stepRuns[0].inputJSON == "{\"phase\":\"intake\"}")
        // Contract snapshot is preserved unchanged
        let afterStartFetched = try await repo.fetchRun(created.run.id)
        #expect(afterStartFetched.run.contractSnapshotSHA256 == originalContractHash)

        // 3. ADVANCE intake → decide — active, revision 3, two step runs
        let t2 = t0.addingTimeInterval(120)
        let afterAdvance = try await engine.advance(
            runID: created.run.id,
            selector: .label("next"),
            completion: WorkflowStepCompletionPayload(
                stateJSON: "{\"intake\":\"complete\"}", outputJSON: "{\"ok\":true}"),
            entryPayload: WorkflowStepEntryPayload(inputJSON: "{\"phase\":\"decide\"}", stateJSON: "{}"),
            actor: .system, now: t2)

        #expect(afterAdvance.run.status == .active)
        #expect(afterAdvance.run.revision == 3)
        #expect(afterAdvance.stepRuns.count == 2)
        let intakeRun = afterAdvance.stepRuns.first(where: { $0.stepDefinitionID.rawValue == "step.intake" })
        let decideRun = afterAdvance.stepRuns.first(where: { $0.stepDefinitionID.rawValue == "step.decide" })
        #expect(intakeRun?.status == .completed)
        #expect(intakeRun?.outputJSON == "{\"ok\":true}")
        #expect(decideRun?.status == .active)
        #expect(decideRun?.inputJSON == "{\"phase\":\"decide\"}")
        // Frozen snapshot unchanged
        let afterAdvanceFetched = try await repo.fetchRun(created.run.id)
        #expect(afterAdvanceFetched.run.contractSnapshotSHA256 == originalContractHash)

        // 4. PAUSE — paused, revision 4
        let t3 = t0.addingTimeInterval(180)
        let afterPause = try await engine.pause(
            runID: created.run.id,
            stepCompletion: WorkflowStepCompletionPayload(
                stateJSON: "{\"partial\":true}", outputJSON: nil),
            actor: .system, now: t3)

        #expect(afterPause.run.status == .paused)
        #expect(afterPause.run.revision == 4)
        #expect(afterPause.run.pausedAt != nil)
        #expect(afterPause.stepRuns.first(where: { $0.stepDefinitionID.rawValue == "step.decide" })?.status == .waiting)
        // Frozen snapshot unchanged
        let afterPauseFetched = try await repo.fetchRun(created.run.id)
        #expect(afterPauseFetched.run.contractSnapshotSHA256 == originalContractHash)

        // 5. RESUME — active, revision 5
        let t4 = t0.addingTimeInterval(240)
        let afterResume = try await engine.resume(
            runID: created.run.id, actor: .system, now: t4)

        #expect(afterResume.run.status == .active)
        #expect(afterResume.run.revision == 5)
        #expect(afterResume.run.pausedAt == nil)
        #expect(afterResume.stepRuns.first(where: { $0.stepDefinitionID.rawValue == "step.decide" })?.status == .active)
        // Frozen snapshot unchanged
        let afterResumeFetched = try await repo.fetchRun(created.run.id)
        #expect(afterResumeFetched.run.contractSnapshotSHA256 == originalContractHash)

        // 6. CHOOSE BRANCH (approve → done) — completed, revision 6
        let t5 = t0.addingTimeInterval(300)
        let afterBranch = try await engine.chooseBranch(
            runID: created.run.id,
            branch: "approve",
            rationale: "Evidence reviewed and approved",
            completion: WorkflowStepCompletionPayload(
                stateJSON: "{\"decided\":\"approve\"}", outputJSON: "{\"approved\":true}"),
            actor: .system, now: t5)

        #expect(afterBranch.run.status == .completed)
        #expect(afterBranch.run.revision == 6)
        #expect(afterBranch.run.completedAt != nil)
        #expect(afterBranch.decisions.count == 1)
        #expect(afterBranch.decisions[0].selectedOption == "approve")
        #expect(afterBranch.decisions[0].rationale == "Evidence reviewed and approved")
        // Frozen snapshot unchanged after completion
        let finalFetched = try await repo.fetchRun(created.run.id)
        #expect(finalFetched.run.contractSnapshotSHA256 == originalContractHash)
        #expect(finalFetched.run.status == .completed)

        // 7. VERIFY: event log is gapless 1..6
        let seqs = finalFetched.events.map(\.sequence).sorted()
        #expect(seqs == Array(1...6), "Event sequences must be 1..6 with no gaps")

        // 8. VERIFY: frozen contract reconstructs the original workflow definition
        let reconstructed = try #require(finalFetched.contract.reconstructDefinition(),
            "Contract snapshot must reconstruct the original workflow definition")
        let opDef = OperationalWorkflowDefinition(validated: reconstructed)
        #expect(opDef.validated.entryStepID.rawValue == "step.intake")
        #expect(opDef.validated.terminalStepIDs.contains(StepDefinitionID(rawValue: "step.done")))
        #expect(opDef.stepByID[StepDefinitionID(rawValue: "step.decide")] != nil)
        #expect(opDef.stepByID.count == 3)

        // 9. VERIFY: terminal run is now immutable
        do {
            _ = try await engine.save(runID: created.run.id, actor: .system, now: t5)
            Issue.record("Expected terminalRunImmutable after completion")
        } catch WorkflowLifecycleError.terminalRunImmutable(_, let status) {
            #expect(status == .completed)
        }

        // 10. VERIFY: project for completed run shows no allowed actions
        let projection = try await engine.project(runID: created.run.id)
        #expect(projection.runStatus == .completed)
        #expect(projection.structuralActions.isEmpty)
    }
}
