//
//  WorkflowStepExecutionEngineTests.swift
//  KalsmritikoshTests
//
//  PJE-006A — WorkflowStepExecutionEngine: startRun, executeCommand, routing.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-006A — WorkflowStepExecutionEngine")
struct WorkflowStepExecutionEngineTests {

    private let t0 = Date(timeIntervalSince1970: 1_753_000_000)

    // MARK: - DB / engine factories

    private func makeDB() async throws -> Database {
        try await MigrationFixtureBuilder.database(atVersion: 76)
    }

    private func makeRegistry(executors: [any WorkflowStepExecutor]) throws -> WorkflowStepExecutorRegistry {
        let builder = WorkflowStepExecutorRegistryBuilder()
        for e in executors {
            try builder.register(e)
            try builder.bind(WorkflowStepExecutorBinding(
                workflowSchemaVersion: 1, stepKind: e.handledKind,
                executorID: e.executorID, executorVersion: e.executorVersion))
        }
        return builder.build()
    }

    private func makeEngine(
        db: Database,
        executors: [any WorkflowStepExecutor]
    ) throws -> WorkflowStepExecutionEngine {
        let repo = WorkflowRunRepository(database: db)
        let registry = try makeRegistry(executors: executors)
        let lifecycle = WorkflowLifecycleEngine(repository: repo)
        return WorkflowStepExecutionEngine(
            registry: registry, lifecycleEngine: lifecycle, repository: repo)
    }

    private func insertWorkspace(_ db: Database, id: UUID) async throws {
        try await db.exec("""
        INSERT INTO workspaces (id, title, template_type, created_at, updated_at)
        VALUES (?,?,?,?,?);
        """, [.uuid(id), .text("Test WS"), .text("general"),
              .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
    }

    private func makePackage(
        appSuffix: String,
        steps: [PersonaWorkflowStepDefinition]
    ) throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let appID = ApplicationDefinitionID(rawValue: "com.engine.test.\(appSuffix)")
        let wfID  = WorkflowDefinitionID(rawValue: "com.engine.test.wf.\(appSuffix)")
        let wfDef = PersonaWorkflowDefinition(
            id: wfID, version: 1, schemaVersion: 1, label: "Engine Test WF", steps: steps)
        let validated = try WorkflowDefinitionCompiler().compile(wfDef)
        let app    = PersonaApplicationDefinition(id: appID, version: 1, label: "Engine Test App")
        let termID = TerminologyDefinitionID(rawValue: "com.engine.test.term.\(appSuffix)")
        let term   = PersonaTerminologyDefinition(id: termID, version: 1, applicationID: appID, labels: [:])
        let pkg    = ResolvedPersonaApplicationPackage(
            applicationKey: RegistryKey(id: appID, version: 1),
            application: app, toolKeys: [], tools: [],
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

    private func intakeClosureSteps() -> [PersonaWorkflowStepDefinition] {
        let doneID = StepDefinitionID(rawValue: "step.done.engine")
        let entry = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.entry.engine"),
            kind: .intake, label: "Entry", isEntry: true,
            transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: doneID)])
        let done = PersonaWorkflowStepDefinition(
            id: doneID, kind: .closure, label: "Done", isTerminal: true)
        return [entry, done]
    }

    // MARK: - startRun

    @Test("startRun succeeds and leaves run in .active status")
    func startRunSucceeds() async throws {
        let db = try await makeDB()
        let repo = WorkflowRunRepository(database: db)
        let engine = try makeEngine(db: db, executors: [IntakeStepExecutor()])
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makePackage(appSuffix: "start", steps: intakeClosureSteps())
        let created = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil, parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0)
        let started = try await engine.startRun(runID: created.run.id, actor: .system, now: t0)
        #expect(started.run.status == .active)
    }

    @Test("startRun embeds executor identity in step run stateJSON")
    func startRunEmbedExecutorInState() async throws {
        let db = try await makeDB()
        let repo = WorkflowRunRepository(database: db)
        let engine = try makeEngine(db: db, executors: [IntakeStepExecutor()])
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makePackage(appSuffix: "embed", steps: intakeClosureSteps())
        let created = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil, parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0)
        let started = try await engine.startRun(runID: created.run.id, actor: .system, now: t0)
        let currentStepRunID = try #require(started.run.currentStepRunID)
        let stepRun = try #require(started.stepRuns.first(where: { $0.id == currentStepRunID }))
        #expect(stepRun.executorID == "com.kalsmritikosh.step.intake")
        let header = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelopeHeader.self, from: stepRun.stateJSON)
        #expect(header.stepKind == .intake)
    }

    @Test("startRun fails when no binding registered for entry step kind")
    func startRunMissingBinding() async throws {
        let db = try await makeDB()
        let repo = WorkflowRunRepository(database: db)
        let emptyRegistry = WorkflowStepExecutorRegistryBuilder().build()
        let lifecycle = WorkflowLifecycleEngine(repository: repo)
        let engine = WorkflowStepExecutionEngine(
            registry: emptyRegistry, lifecycleEngine: lifecycle, repository: repo)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makePackage(appSuffix: "nobind", steps: intakeClosureSteps())
        let created = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil, parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0)
        await #expect(throws: (any Error).self) {
            _ = try await engine.startRun(runID: created.run.id, actor: .system, now: t0)
        }
    }

    // MARK: - executeCommand remainActive

    @Test("executeCommand remainActive persists updated stateJSON")
    func executeCommandRemainActive() async throws {
        let db = try await makeDB()
        let repo = WorkflowRunRepository(database: db)
        let engine = try makeEngine(db: db, executors: [IntakeStepExecutor()])
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makePackage(appSuffix: "remain", steps: intakeClosureSteps())
        let created = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil, parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0)
        let started = try await engine.startRun(runID: created.run.id, actor: .system, now: t0)
        let cmdJSON = try WorkflowStepPayloadCodec.encode(IntakeStepCommand.setTitle("Engine Test"))
        let after = try await engine.executeCommand(
            runID: started.run.id, commandJSON: cmdJSON, actor: .system, now: t0)
        let stepRunID = try #require(after.run.currentStepRunID)
        let stepRun = try #require(after.stepRuns.first(where: { $0.id == stepRunID }))
        let state = try decodeEnvelopeState(IntakeStepState.self, from: stepRun.stateJSON)
        #expect(state.title == "Engine Test")
    }

    // MARK: - executeCommand advance

    @Test("executeCommand advance completes entry step and moves to closure")
    func executeCommandAdvance() async throws {
        let db = try await makeDB()
        let repo = WorkflowRunRepository(database: db)
        let engine = try makeEngine(db: db, executors: [IntakeStepExecutor()])
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makePackage(appSuffix: "adv", steps: intakeClosureSteps())
        let created = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil, parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0)
        let started = try await engine.startRun(runID: created.run.id, actor: .system, now: t0)
        let setCmd = try WorkflowStepPayloadCodec.encode(IntakeStepCommand.setTitle("Ready"))
        let r1 = try await engine.executeCommand(
            runID: started.run.id, commandJSON: setCmd, actor: .system, now: t0)
        let completeCmd = try WorkflowStepPayloadCodec.encode(IntakeStepCommand.complete)
        let final = try await engine.executeCommand(
            runID: r1.run.id, commandJSON: completeCmd, actor: .system, now: t0)
        #expect(final.run.status == .completed)
    }

    // MARK: - executeCommand on completed run

    @Test("executeCommand on completed run throws")
    func executeCommandAfterCompletion() async throws {
        let db = try await makeDB()
        let repo = WorkflowRunRepository(database: db)
        let engine = try makeEngine(db: db, executors: [IntakeStepExecutor()])
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makePackage(appSuffix: "done", steps: intakeClosureSteps())
        let created = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil, parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0)
        let started = try await engine.startRun(runID: created.run.id, actor: .system, now: t0)
        let setCmd = try WorkflowStepPayloadCodec.encode(IntakeStepCommand.setTitle("Done"))
        let r1 = try await engine.executeCommand(
            runID: started.run.id, commandJSON: setCmd, actor: .system, now: t0)
        let completeCmd = try WorkflowStepPayloadCodec.encode(IntakeStepCommand.complete)
        let completed = try await engine.executeCommand(
            runID: r1.run.id, commandJSON: completeCmd, actor: .system, now: t0)
        #expect(completed.run.status == .completed)
        // Attempt another command on the completed run — should throw
        await #expect(throws: (any Error).self) {
            _ = try await engine.executeCommand(
                runID: completed.run.id, commandJSON: setCmd, actor: .system, now: t0)
        }
    }
}
