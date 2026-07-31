//
//  RegisteredMethodStepExecutorTests.swift
//  KalsmritikoshTests
//
//  PM-003 — the v2 registered-method step executor driven through the execution
//  engine: exact selection, run linking, human-only completed-result attachment,
//  requirement satisfaction, provenance from the stored snapshot, and exact reopen.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PM-003 — RegisteredMethodStepExecutor (v2)", .serialized)
struct RegisteredMethodStepExecutorTests {

    private let t0 = PM003Fixtures.t0

    private struct Case {
        let rig: PM003Rig
        let ws: UUID
        let entity: UUID
        let runID: UUID
        let stepRunID: UUID
    }

    private func makeCase(suffix: String) async throws -> Case {
        let rig = try await PM003Fixtures.makeRig(at: PJE006CFixtures.newDatabaseURL())
        let ws = UUID(); try await PJE007Fixtures.seedWorkspace(rig.db, id: ws)
        let entity = try await PJE007Fixtures.seedEntity(rig.db, in: ws)
        let pkg = try PM003Fixtures.methodV2Package(suffix: suffix)
        let (runID, stepRunID) = try await PM003Fixtures.startMethodRun(rig, package: pkg, workspaceID: ws, at: t0)
        return Case(rig: rig, ws: ws, entity: entity, runID: runID, stepRunID: stepRunID)
    }

    private var selection: WorkflowProfessionalMethodSelection {
        WorkflowProfessionalMethodSelection(methodDefinitionID: PM003Fixtures.methodDefID, methodDefinitionVersion: 1)
    }

    /// Decode the current method step's v2 state.
    private func methodState(_ c: Case) async throws -> RegisteredMethodStepState {
        let run = try await c.rig.workflowRepo.fetchRun(c.runID)
        let step = try #require(run.stepRuns.first { $0.stepKind == .method })
        return try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelope<RegisteredMethodStepState>.self, from: step.stateJSON).state
    }

    private func methodFacts(_ c: Case) async throws -> [WorkflowStepRequirementFact] {
        let run = try await c.rig.workflowRepo.fetchRun(c.runID)
        let step = try #require(run.stepRuns.first { $0.stepKind == .method })
        return try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelopeHeader.self, from: step.stateJSON).requirementFacts
    }

    /// Drive select + link + attach(human) so a completed result is present.
    private func driveToResult(_ c: Case, actor: WorkflowLifecycleActor = PM003Fixtures.human("analyst")) async throws {
        var time = t0.addingTimeInterval(10)
        _ = try await PM003Fixtures.exec(c.rig, runID: c.runID,
            RegisteredMethodStepCommand.selectMethod(methodDefinitionID: PM003Fixtures.methodDefID, methodDefinitionVersion: 1),
            actor: PM003Fixtures.system, at: time)
        let methodRunID = try await PM003Fixtures.makeCompletedMethodRun(
            c.rig, workspaceID: c.ws, workflowRunID: c.runID, workflowStepRunID: c.stepRunID, entityID: c.entity, at: t0)
        time.addTimeInterval(10)
        _ = try await PM003Fixtures.exec(c.rig, runID: c.runID,
            RegisteredMethodStepCommand.linkRun(methodRunID: methodRunID), actor: PM003Fixtures.system, at: time)
        time.addTimeInterval(10)
        _ = try await PM003Fixtures.exec(c.rig, runID: c.runID,
            RegisteredMethodStepCommand.attachCompletedResult(summary: "Carrier handoff is the candidate", limitations: ["single source"]),
            actor: actor, at: time)
    }

    // MARK: - Prepare + selection

    @Test("Prepare produces empty v2 state with an unsatisfied result requirement")
    func prepareProducesEmptyState() async throws {
        let c = try await makeCase(suffix: "prepare")
        let state = try await methodState(c)
        #expect(state.selection == nil && state.linkedRun == nil && state.result == nil)
        #expect(state.derivedStatus == .awaitingSelection)
        #expect(try await methodFacts(c).allSatisfy { !$0.isSatisfied })
    }

    @Test("An exact method selection is stored; an unknown selection and a bad version fail")
    func methodSelection() async throws {
        let c = try await makeCase(suffix: "select")
        _ = try await PM003Fixtures.exec(c.rig, runID: c.runID,
            RegisteredMethodStepCommand.selectMethod(methodDefinitionID: PM003Fixtures.methodDefID, methodDefinitionVersion: 1),
            actor: PM003Fixtures.system, at: t0.addingTimeInterval(10))
        #expect(try await methodState(c).selection == selection)
        // Unknown definition → the bridge rejects it.
        await #expect(throws: (any Error).self) {
            _ = try await PM003Fixtures.exec(c.rig, runID: c.runID,
                RegisteredMethodStepCommand.selectMethod(methodDefinitionID: "com.k.ghost", methodDefinitionVersion: 1),
                actor: PM003Fixtures.system, at: self.t0.addingTimeInterval(20))
        }
        // Version below 1 → structural validation fails.
        await #expect(throws: (any Error).self) {
            _ = try await PM003Fixtures.exec(c.rig, runID: c.runID,
                RegisteredMethodStepCommand.selectMethod(methodDefinitionID: PM003Fixtures.methodDefID, methodDefinitionVersion: 0),
                actor: PM003Fixtures.system, at: self.t0.addingTimeInterval(30))
        }
    }

    @Test("The selection cannot change after a run is linked")
    func selectionLockedAfterLink() async throws {
        let c = try await makeCase(suffix: "lock")
        var time = t0.addingTimeInterval(10)
        _ = try await PM003Fixtures.exec(c.rig, runID: c.runID,
            RegisteredMethodStepCommand.selectMethod(methodDefinitionID: PM003Fixtures.methodDefID, methodDefinitionVersion: 1),
            actor: PM003Fixtures.system, at: time)
        let methodRunID = try await PM003Fixtures.makeCompletedMethodRun(
            c.rig, workspaceID: c.ws, workflowRunID: c.runID, workflowStepRunID: c.stepRunID, entityID: c.entity, at: t0, markCompleted: false)
        time.addTimeInterval(10)
        _ = try await PM003Fixtures.exec(c.rig, runID: c.runID,
            RegisteredMethodStepCommand.linkRun(methodRunID: methodRunID), actor: PM003Fixtures.system, at: time)
        await #expect(throws: (any Error).self) {
            _ = try await PM003Fixtures.exec(c.rig, runID: c.runID,
                RegisteredMethodStepCommand.selectMethod(methodDefinitionID: "com.k.other", methodDefinitionVersion: 1),
                actor: PM003Fixtures.system, at: time.addingTimeInterval(10))
        }
    }

    // MARK: - Linking

    @Test("A valid run links; a mismatched run is rejected")
    func linkRun() async throws {
        let c = try await makeCase(suffix: "link")
        _ = try await PM003Fixtures.exec(c.rig, runID: c.runID,
            RegisteredMethodStepCommand.selectMethod(methodDefinitionID: PM003Fixtures.methodDefID, methodDefinitionVersion: 1),
            actor: PM003Fixtures.system, at: t0.addingTimeInterval(10))
        let good = try await PM003Fixtures.makeCompletedMethodRun(
            c.rig, workspaceID: c.ws, workflowRunID: c.runID, workflowStepRunID: c.stepRunID, entityID: c.entity, at: t0, markCompleted: false)
        _ = try await PM003Fixtures.exec(c.rig, runID: c.runID,
            RegisteredMethodStepCommand.linkRun(methodRunID: good), actor: PM003Fixtures.system, at: t0.addingTimeInterval(20))
        #expect(try await methodState(c).linkedRun?.methodRunID == good)
        // A run whose workflow-step reference differs is rejected.
        let mismatched = try await PM003Fixtures.makeCompletedMethodRun(
            c.rig, workspaceID: c.ws, workflowRunID: c.runID, workflowStepRunID: UUID(), entityID: c.entity, at: t0, markCompleted: false)
        await #expect(throws: (any Error).self) {
            _ = try await PM003Fixtures.exec(c.rig, runID: c.runID,
                RegisteredMethodStepCommand.linkRun(methodRunID: mismatched), actor: PM003Fixtures.system, at: self.t0.addingTimeInterval(30))
        }
    }

    // MARK: - Attach + requirement satisfaction

    @Test("A selected or linked-but-incomplete method does not satisfy the result requirement")
    func selectedOrLinkedDoesNotSatisfy() async throws {
        let c = try await makeCase(suffix: "unsat")
        var time = t0.addingTimeInterval(10)
        _ = try await PM003Fixtures.exec(c.rig, runID: c.runID,
            RegisteredMethodStepCommand.selectMethod(methodDefinitionID: PM003Fixtures.methodDefID, methodDefinitionVersion: 1),
            actor: PM003Fixtures.system, at: time)
        #expect(try await methodFacts(c).allSatisfy { !$0.isSatisfied })
        let incomplete = try await PM003Fixtures.makeCompletedMethodRun(
            c.rig, workspaceID: c.ws, workflowRunID: c.runID, workflowStepRunID: c.stepRunID, entityID: c.entity, at: t0, markCompleted: false)
        time.addTimeInterval(10)
        _ = try await PM003Fixtures.exec(c.rig, runID: c.runID,
            RegisteredMethodStepCommand.linkRun(methodRunID: incomplete), actor: PM003Fixtures.system, at: time)
        #expect(try await methodFacts(c).allSatisfy { !$0.isSatisfied })
        // Attaching a result from an INCOMPLETE run is rejected.
        await #expect(throws: (any Error).self) {
            _ = try await PM003Fixtures.exec(c.rig, runID: c.runID,
                RegisteredMethodStepCommand.attachCompletedResult(summary: "s", limitations: []),
                actor: PM003Fixtures.human("analyst"), at: time.addingTimeInterval(10))
        }
    }

    @Test("A completed result attaches only via a human actor and satisfies the requirement")
    func attachCompletedResult() async throws {
        let c = try await makeCase(suffix: "attach")
        // A non-human actor cannot attach.
        var time = t0.addingTimeInterval(10)
        _ = try await PM003Fixtures.exec(c.rig, runID: c.runID,
            RegisteredMethodStepCommand.selectMethod(methodDefinitionID: PM003Fixtures.methodDefID, methodDefinitionVersion: 1),
            actor: PM003Fixtures.system, at: time)
        let methodRunID = try await PM003Fixtures.makeCompletedMethodRun(
            c.rig, workspaceID: c.ws, workflowRunID: c.runID, workflowStepRunID: c.stepRunID, entityID: c.entity, at: t0)
        time.addTimeInterval(10)
        _ = try await PM003Fixtures.exec(c.rig, runID: c.runID,
            RegisteredMethodStepCommand.linkRun(methodRunID: methodRunID), actor: PM003Fixtures.system, at: time)
        await #expect(throws: (any Error).self) {
            _ = try await PM003Fixtures.exec(c.rig, runID: c.runID,
                RegisteredMethodStepCommand.attachCompletedResult(summary: "s", limitations: []),
                actor: PM003Fixtures.system, at: time.addingTimeInterval(10))
        }
        // A human attaches — bridge-derived result, requirement satisfied.
        time.addTimeInterval(20)
        _ = try await PM003Fixtures.exec(c.rig, runID: c.runID,
            RegisteredMethodStepCommand.attachCompletedResult(summary: "Carrier candidate", limitations: ["single source"]),
            actor: PM003Fixtures.human("analyst"), at: time)
        let state = try await methodState(c)
        #expect(state.result?.completedRevision == 2)
        #expect(state.result?.completedBy == "analyst")               // derived from the human actor
        #expect(state.result?.provenanceReferences.map(\.objectKind) == ["entity"])
        #expect(try await methodFacts(c).allSatisfy { $0.isSatisfied })
    }

    @Test("Removing the result returns the requirement to unsatisfied")
    func removeResultRestoresUnsatisfied() async throws {
        let c = try await makeCase(suffix: "remove")
        try await driveToResult(c)
        #expect(try await methodFacts(c).allSatisfy { $0.isSatisfied })
        _ = try await PM003Fixtures.exec(c.rig, runID: c.runID,
            RegisteredMethodStepCommand.removeResult, actor: PM003Fixtures.human("analyst"), at: t0.addingTimeInterval(100))
        #expect(try await methodState(c).result == nil)
        #expect(try await methodFacts(c).allSatisfy { !$0.isSatisfied })
    }

    // MARK: - Completion

    @Test("Completion is blocked without a result and advances with one")
    func completion() async throws {
        let c1 = try await makeCase(suffix: "nocomplete")
        _ = try await PM003Fixtures.exec(c1.rig, runID: c1.runID,
            RegisteredMethodStepCommand.selectMethod(methodDefinitionID: PM003Fixtures.methodDefID, methodDefinitionVersion: 1),
            actor: PM003Fixtures.system, at: t0.addingTimeInterval(10))
        await #expect(throws: (any Error).self) {
            _ = try await PM003Fixtures.exec(c1.rig, runID: c1.runID,
                RegisteredMethodStepCommand.complete, actor: PM003Fixtures.human("analyst"), at: self.t0.addingTimeInterval(20))
        }
        let c2 = try await makeCase(suffix: "docomplete")
        try await driveToResult(c2)
        let ended = try await PM003Fixtures.exec(c2.rig, runID: c2.runID,
            RegisteredMethodStepCommand.complete, actor: PM003Fixtures.human("analyst"), at: t0.addingTimeInterval(100))
        // Advanced off the method step to the closure step.
        let current = try #require(ended.stepRuns.first { $0.id == ended.run.currentStepRunID })
        #expect(current.stepKind == .closure)
    }

    // MARK: - Provenance + reopen

    @Test("Step provenance comes from the stored result snapshot with role .methodInput")
    func provenanceFromStoredSnapshot() async throws {
        let c = try await makeCase(suffix: "prov")
        try await driveToResult(c)
        let run = try await c.rig.workflowRepo.fetchRun(c.runID)
        let step = try #require(run.stepRuns.first { $0.stepKind == .method })
        let inspector = WorkflowProvenanceInspector(repository: c.rig.workflowRepo, database: c.rig.db, scopes: c.rig.scopes)
        let inspection = try await inspector.inspect(
            owner: .stepRun(step.id), access: PJE006CFixtures.exportAccess(workspaceID: c.ws))
        #expect(!inspection.references.isEmpty)
        #expect(inspection.references.allSatisfy { $0.role == .methodInput })
    }

    @Test("The v2 state and hash reopen exactly")
    func stateReopensExactly() async throws {
        let c = try await makeCase(suffix: "reopen")
        try await driveToResult(c)
        let before = try await methodState(c)
        // fetchRun re-verifies contract + per-step state hashes on reopen.
        let rig2Repo = WorkflowRunRepository(database: try MigrationFixtureBuilder.reopen(at: c.rig.url))
        let reopened = try await rig2Repo.fetchRun(c.runID)
        let step = try #require(reopened.stepRuns.first { $0.stepKind == .method })
        let after = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelope<RegisteredMethodStepState>.self, from: step.stateJSON).state
        #expect(after == before)
    }
}
