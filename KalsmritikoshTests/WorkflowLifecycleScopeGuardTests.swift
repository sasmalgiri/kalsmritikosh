//
//  WorkflowLifecycleScopeGuardTests.swift
//  KalsmritikoshTests
//
//  PJE-004 — Lifecycle scope guards: terminal-run immutability, draft-only start,
//  cancellation-reason requirement, human-actor enforcement, invalid-JSON payload
//  rejection, and illegal state transition guards.
//  12 tests.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-004 — WorkflowLifecycleScopeGuards")
struct WorkflowLifecycleScopeGuardTests {

    private let t0 = Date(timeIntervalSince1970: 1_753_200_000)

    // MARK: - Helpers

    private func makeDB() async throws -> Database {
        try await MigrationFixtureBuilder.database(atVersion: 75)
    }

    private func makeEngine(db: Database) -> WorkflowLifecycleEngine {
        WorkflowLifecycleEngine(repository: WorkflowRunRepository(database: db))
    }

    private func insertWorkspace(_ db: Database, id: UUID) async throws {
        try await db.exec("""
        INSERT INTO workspaces (id, title, template_type, created_at, updated_at)
        VALUES (?,?,?,?,?);
        """, [.uuid(id), .text("Guard WS"), .text("general"),
              .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
    }

    private func makeTwoStepPackage() throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let appID = ApplicationDefinitionID(rawValue: "com.guard.test.app")
        let wfID = WorkflowDefinitionID(rawValue: "com.guard.test.wf")
        let intakeID = StepDefinitionID(rawValue: "step.intake")
        let doneID = StepDefinitionID(rawValue: "step.done")
        let intake = PersonaWorkflowStepDefinition(
            id: intakeID, kind: .intake, label: "Intake", isEntry: true,
            transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: doneID)])
        let done = PersonaWorkflowStepDefinition(
            id: doneID, kind: .closure, label: "Done", isTerminal: true)
        let term = PersonaTerminologyDefinition(
            id: TerminologyDefinitionID(rawValue: "com.guard.test.term"), version: 1,
            applicationID: appID, labels: [:])
        let app = PersonaApplicationDefinition(id: appID, version: 1, label: "Guard App")
        let wfDef = PersonaWorkflowDefinition(
            id: wfID, version: 1, schemaVersion: 1, label: "Guard WF", steps: [intake, done])
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

    // MARK: - 1: Completed run is immutable

    @Test("every lifecycle action on a completed run throws terminalRunImmutable")
    func completedRunIsImmutable() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)
        _ = try await engine.complete(runID: created.run.id, actor: .system, now: t0)

        let actionsToTest: [(String, () async throws -> Void)] = [
            ("start", { _ = try await engine.start(runID: created.run.id, actor: .system, now: self.t0) }),
            ("save",  { _ = try await engine.save(runID: created.run.id, actor: .system, now: self.t0) }),
            ("pause", { _ = try await engine.pause(runID: created.run.id, actor: .system, now: self.t0) }),
            ("cancel", { _ = try await engine.cancel(runID: created.run.id, reason: "r", actor: .system, now: self.t0) })
        ]
        for (name, action) in actionsToTest {
            do {
                try await action()
                Issue.record("Expected terminalRunImmutable for action '\(name)'")
            } catch WorkflowLifecycleError.terminalRunImmutable(_, let status) {
                #expect(status == .completed, "Expected completed status for \(name)")
            }
        }
    }

    // MARK: - 2: Cancelled run is immutable

    @Test("every lifecycle action on a cancelled run throws terminalRunImmutable")
    func cancelledRunIsImmutable() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.cancel(runID: created.run.id, reason: "Cancelled", actor: .system, now: t0)

        do {
            _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)
            Issue.record("Expected terminalRunImmutable")
        } catch WorkflowLifecycleError.terminalRunImmutable(_, let status) {
            #expect(status == .cancelled)
        }
    }

    // MARK: - 3: Start can only be called on a draft run

    @Test("start throws invalidDraftState when run is not in draft status")
    func startRequiresDraftStatus() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)

        // Attempting to start active run
        do {
            _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)
            Issue.record("Expected illegalRunTransition or invalidDraftState")
        } catch WorkflowLifecycleError.illegalRunTransition(let from, _) {
            #expect(from == .active)
        }
    }

    // MARK: - 4: Cancel requires non-blank reason

    @Test("cancel with blank reason throws cancellationReasonRequired")
    func cancelBlankReasonThrows() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)

        do {
            _ = try await engine.cancel(runID: created.run.id, reason: "  ", actor: .system, now: t0)
            Issue.record("Expected cancellationReasonRequired")
        } catch WorkflowLifecycleError.cancellationReasonRequired {
            // expected
        }
    }

    // MARK: - 5: Cancel requires a reason string

    @Test("cancel with empty string reason throws cancellationReasonRequired")
    func cancelEmptyReasonThrows() async throws {
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

    // MARK: - 6: Human actor requires non-blank identifier

    @Test("WorkflowLifecycleActor.human with blank identifier throws humanIdentifierRequired")
    func humanActorBlankIdentifierThrows() throws {
        do {
            _ = try WorkflowLifecycleActor.human(identifier: "   ")
            Issue.record("Expected humanIdentifierRequired")
        } catch WorkflowLifecycleError.humanIdentifierRequired {
            // expected
        }
    }

    // MARK: - 7: Human actor with blank role throws humanRoleRequired

    @Test("WorkflowLifecycleActor.human with blank role throws humanRoleRequired")
    func humanActorBlankRoleThrows() throws {
        do {
            _ = try WorkflowLifecycleActor.human(identifier: "user@test.com", role: "  ")
            Issue.record("Expected humanRoleRequired")
        } catch WorkflowLifecycleError.humanRoleRequired {
            // expected
        }
    }

    // MARK: - 8: Invalid JSON in entry payload throws invalidJSONPayload

    @Test("entry payload with invalid JSON throws invalidJSONPayload")
    func invalidJSONEntryPayloadThrows() throws {
        let codec = WorkflowLifecyclePayloadCodec()
        let badPayload = WorkflowStepEntryPayload(
            inputJSON: "not-json", stateJSON: "{}")
        do {
            try codec.validate(badPayload)
            Issue.record("Expected invalidJSONPayload")
        } catch WorkflowLifecycleError.invalidJSONPayload {
            // expected
        }
    }

    // MARK: - 9: Invalid JSON in state throws invalidJSONPayload

    @Test("entry payload with invalid stateJSON throws invalidJSONPayload")
    func invalidJSONStateThrows() throws {
        let codec = WorkflowLifecyclePayloadCodec()
        let badPayload = WorkflowStepEntryPayload(
            inputJSON: "{}", stateJSON: "bad")
        do {
            try codec.validate(badPayload)
            Issue.record("Expected invalidJSONPayload")
        } catch WorkflowLifecycleError.invalidJSONPayload {
            // expected
        }
    }

    // MARK: - 10: Advance from paused run throws illegalRunTransition

    @Test("advance from a paused run throws illegalRunTransition")
    func advanceFromPausedThrows() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)
        _ = try await engine.pause(runID: created.run.id, actor: .system, now: t0)

        do {
            _ = try await engine.advance(
                runID: created.run.id, selector: .label("next"), actor: .system, now: t0)
            Issue.record("Expected illegalRunTransition")
        } catch WorkflowLifecycleError.illegalRunTransition(let from, let action) {
            #expect(from == .paused)
            #expect(action == .advance)
        }
    }

    // MARK: - 11: Block a draft run throws illegalRunTransition

    @Test("block a draft run throws illegalRunTransition")
    func blockDraftRunThrows() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)

        do {
            _ = try await engine.block(runID: created.run.id, actor: .system, now: t0)
            Issue.record("Expected illegalRunTransition")
        } catch WorkflowLifecycleError.illegalRunTransition(let from, let action) {
            #expect(from == .draft)
            #expect(action == .block)
        }
    }

    // MARK: - 12: Resume active run throws illegalRunTransition

    @Test("resume an active run throws illegalRunTransition")
    func resumeActiveRunThrows() async throws {
        let db = try await makeDB()
        let engine = makeEngine(db: db)
        let (pkg, wfID) = try makeTwoStepPackage()
        let created = try await createRun(db: db, pkg: pkg, wfID: wfID)
        _ = try await engine.start(runID: created.run.id, actor: .system, now: t0)

        do {
            _ = try await engine.resume(runID: created.run.id, actor: .system, now: t0)
            Issue.record("Expected illegalRunTransition")
        } catch WorkflowLifecycleError.illegalRunTransition(let from, let action) {
            #expect(from == .active)
            #expect(action == .resume)
        }
    }
}
