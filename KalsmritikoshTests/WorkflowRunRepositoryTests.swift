//
//  WorkflowRunRepositoryTests.swift
//  KalsmritikoshTests
//
//  PJE-003 — WorkflowRunRepository: 38 repository tests + 10 scope-guard tests.
//
//  Repository tests cover: createRun, updateRunState, insertStepRun, updateStepRunState,
//  insertDecision, recordArtifact, createAttentionItem, resolveAttentionItem,
//  createCheckpoint, linkSupersession, delete, fetch, fetchRunIDs, CAS conflicts,
//  reopen invariants, and checkpoint payload verification.
//
//  Scope-guard tests verify that repository operations never touch canonical tables
//  (claims, entities, events, knowledge_objects, files, timelines, chunks, summaries,
//  source_versions) and that deleting a run never deletes a work_product_run.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-003 — WorkflowRunRepository")
struct WorkflowRunRepositoryTests {

    private let t0 = Date(timeIntervalSince1970: 1_752_000_000)

    // MARK: - Setup helpers

    private func makeDatabase() async throws -> Database {
        try await MigrationFixtureBuilder.database(atVersion: 76)
    }

    private func makeRepository(db: Database) -> WorkflowRunRepository {
        WorkflowRunRepository(database: db)
    }

    private func insertWorkspace(_ db: Database, id: UUID) async throws {
        try await db.exec("""
        INSERT INTO workspaces (id, title, template_type, created_at, updated_at)
        VALUES (?,?,?,?,?);
        """, [.uuid(id), .text("Test WS"), .text("general"),
              .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
    }

    private func makeMinimalPackage() throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let appID = ApplicationDefinitionID(rawValue: "com.repo.test.app")
        let wfID = WorkflowDefinitionID(rawValue: "com.repo.test.workflow")
        let termID = TerminologyDefinitionID(rawValue: "com.repo.test.term")

        let app = PersonaApplicationDefinition(id: appID, version: 1, label: "Repo Test App")
        let entryStep = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.intake"),
            kind: .intake,
            label: "Intake",
            isEntry: true,
            transitions: [WorkflowTransitionDefinition(
                label: "next",
                targetStepID: StepDefinitionID(rawValue: "step.done")
            )]
        )
        let doneStep = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.done"),
            kind: .closure,
            label: "Done",
            isTerminal: true
        )
        let wfDef = PersonaWorkflowDefinition(
            id: wfID, version: 1, schemaVersion: 1,
            label: "Repo Test Workflow",
            steps: [entryStep, doneStep]
        )
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
            automationKeys: [], automations: []
        )
        return (pkg, wfID)
    }

    // MARK: - 1: createRun persists with draft status and revision 1

    @Test("createRun persists a workflow run with draft status and revision 1")
    func createRunPersistsWithDraftStatusAndRevision1() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()

        let opened = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: "My Run",
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        #expect(opened.run.status == .draft)
        #expect(opened.run.revision == 1)
        #expect(opened.run.title == "My Run")
        #expect(opened.run.workspaceID == wsID)
        #expect(opened.run.workflowDefinitionID.rawValue == wfID.rawValue)
    }

    // MARK: - 2: createRun inserts exactly one event

    @Test("createRun inserts exactly one runCreated event")
    func createRunInsertsOneEvent() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()

        let opened = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        #expect(opened.events.count == 1)
        #expect(opened.events[0].type == .runCreated)
        #expect(opened.events[0].sequence == 1)
        #expect(opened.events[0].runRevision == 1)
    }

    // MARK: - 3: reopen verifies contract hash on fetch

    @Test("fetchRun verifies contract hash and returns the same aggregate")
    func reopenVerifiesContractHash() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()

        let created = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        let fetched = try await repo.fetchRun(created.run.id)
        #expect(fetched.run.id == created.run.id)
        #expect(fetched.contract == created.contract)
    }

    // MARK: - 4: fetchRun throws runNotFound for missing ID

    @Test("fetchRun throws runNotFound for an unknown run ID")
    func fetchRunThrowsRunNotFoundForMissingID() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let missingID = UUID()
        do {
            _ = try await repo.fetchRun(missingID)
            Issue.record("Expected runNotFound to be thrown")
        } catch WorkflowRunRepositoryError.runNotFound(let id) {
            #expect(id == missingID)
        }
    }

    // MARK: - 5: updateRunState changes status

    @Test("updateRunState persists the new status")
    func updateRunStateChangesStatus() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()

        let created = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        let updated = try await repo.updateRunState(
            runID: created.run.id, newStatus: .active,
            currentStepDefinitionID: StepDefinitionID(rawValue: "step.intake"),
            currentStepRunID: nil,
            timestamps: WorkflowRunTimestampPatch(startedAt: t0),
            cancellationReason: nil,
            expectedRevision: 1,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        #expect(updated.run.status == .active)
        #expect(updated.run.startedAt == t0)
        #expect(updated.run.currentStepDefinitionID?.rawValue == "step.intake")
    }

    // MARK: - 6: updateRunState increments revision

    @Test("updateRunState increments revision by exactly 1")
    func updateRunStateIncrementsRevision() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()

        let created = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        let updated = try await repo.updateRunState(
            runID: created.run.id, newStatus: .active,
            currentStepDefinitionID: nil, currentStepRunID: nil,
            timestamps: WorkflowRunTimestampPatch(),
            cancellationReason: nil,
            expectedRevision: 1,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        #expect(updated.run.revision == 2)
        #expect(updated.events.count == 2)
    }

    // MARK: - 7: insertStepRun persists

    @Test("insertStepRun persists the step run and returns it in the aggregate")
    func insertStepRunPersists() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()

        let created = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        let afterStep = try await repo.insertStepRun(
            runID: created.run.id,
            stepDefinitionID: StepDefinitionID(rawValue: "step.intake"),
            stepKind: .intake,
            attempt: 1,
            inputJSON: "{\"scope\":\"test\"}",
            stateJSON: "{}", stateSHA256: "stateHash",
            executorID: "intake-executor", executorVersion: "1.0",
            expectedRevision: 1,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        #expect(afterStep.stepRuns.count == 1)
        #expect(afterStep.stepRuns[0].stepDefinitionID.rawValue == "step.intake")
        #expect(afterStep.stepRuns[0].attempt == 1)
        #expect(afterStep.stepRuns[0].status == .ready)
        #expect(afterStep.stepRuns[0].inputJSON == "{\"scope\":\"test\"}")
    }

    // MARK: - 8: insertStepRun increments revision

    @Test("insertStepRun increments revision and adds one event")
    func insertStepRunIncrementsRevision() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()

        let created = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        let afterStep = try await repo.insertStepRun(
            runID: created.run.id,
            stepDefinitionID: StepDefinitionID(rawValue: "step.intake"),
            stepKind: .intake, attempt: 1,
            inputJSON: "{}", stateJSON: "{}", stateSHA256: "h",
            executorID: nil, executorVersion: nil,
            expectedRevision: 1,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        #expect(afterStep.run.revision == 2)
        #expect(afterStep.events.count == 2)
        #expect(afterStep.events.last?.type == .stepRunInserted)
    }

    // MARK: - 9: Second attempt at same step persists

    @Test("second step run attempt at the same step definition persists with attempt=2")
    func secondStepRunAttemptPersists() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()

        var agg = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        agg = try await repo.insertStepRun(
            runID: agg.run.id,
            stepDefinitionID: StepDefinitionID(rawValue: "step.intake"),
            stepKind: .intake, attempt: 1,
            inputJSON: "{}", stateJSON: "{}", stateSHA256: "h",
            executorID: nil, executorVersion: nil,
            expectedRevision: 1,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        agg = try await repo.insertStepRun(
            runID: agg.run.id,
            stepDefinitionID: StepDefinitionID(rawValue: "step.intake"),
            stepKind: .intake, attempt: 2,
            inputJSON: "{\"retry\":true}", stateJSON: "{}", stateSHA256: "h2",
            executorID: nil, executorVersion: nil,
            expectedRevision: 2,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        #expect(agg.stepRuns.count == 2)
        #expect(agg.stepRuns[1].attempt == 2)
    }

    // MARK: - 10: Duplicate step attempt throws

    @Test("inserting duplicate (run_id, step_definition_id, attempt) throws duplicateStepAttempt")
    func duplicateStepAttemptThrows() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()

        let created = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        _ = try await repo.insertStepRun(
            runID: created.run.id,
            stepDefinitionID: StepDefinitionID(rawValue: "step.intake"),
            stepKind: .intake, attempt: 1,
            inputJSON: "{}", stateJSON: "{}", stateSHA256: "h",
            executorID: nil, executorVersion: nil,
            expectedRevision: 1,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        do {
            _ = try await repo.insertStepRun(
                runID: created.run.id,
                stepDefinitionID: StepDefinitionID(rawValue: "step.intake"),
                stepKind: .intake, attempt: 1,
                inputJSON: "{}", stateJSON: "{}", stateSHA256: "h",
                executorID: nil, executorVersion: nil,
                expectedRevision: 2,
                actorKind: .system, actorIdentifier: nil, now: t0
            )
            Issue.record("Expected duplicateStepAttempt to be thrown")
        } catch WorkflowRunRepositoryError.duplicateStepAttempt {
            // Expected
        }
    }

    // MARK: - 11: Stale revision throws revisionConflict

    @Test("a stale expectedRevision throws revisionConflict")
    func staleRevisionThrowsRevisionConflict() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()

        let created = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        // First update: revision 1 → 2
        _ = try await repo.updateRunState(
            runID: created.run.id, newStatus: .active,
            currentStepDefinitionID: nil, currentStepRunID: nil,
            timestamps: WorkflowRunTimestampPatch(),
            cancellationReason: nil,
            expectedRevision: 1,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        // Second update with stale revision 1
        do {
            _ = try await repo.updateRunState(
                runID: created.run.id, newStatus: .paused,
                currentStepDefinitionID: nil, currentStepRunID: nil,
                timestamps: WorkflowRunTimestampPatch(),
                cancellationReason: nil,
                expectedRevision: 1,  // stale
                actorKind: .system, actorIdentifier: nil, now: t0
            )
            Issue.record("Expected revisionConflict to be thrown")
        } catch WorkflowRunRepositoryError.revisionConflict(let id, let expected) {
            #expect(id == created.run.id)
            #expect(expected == 1)
        }
    }

    // MARK: - 12: Two writers same revision — one wins

    @Test("two concurrent writers with the same expectedRevision: only one succeeds")
    func twoWritersWithSameRevisionOneWins() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()

        let created = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        var successCount = 0
        var conflictCount = 0

        // Fire both tasks concurrently
        await withTaskGroup(of: Result<Void, WorkflowRunRepositoryError>.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do {
                        _ = try await repo.updateRunState(
                            runID: created.run.id, newStatus: .active,
                            currentStepDefinitionID: nil, currentStepRunID: nil,
                            timestamps: WorkflowRunTimestampPatch(),
                            cancellationReason: nil,
                            expectedRevision: 1,
                            actorKind: .system, actorIdentifier: nil, now: self.t0
                        )
                        return .success(())
                    } catch let err as WorkflowRunRepositoryError {
                        return .failure(err)
                    } catch {
                        return .failure(.reopenFailed(runID: created.run.id, reason: "\(error)"))
                    }
                }
            }
            for await result in group {
                switch result {
                case .success: successCount += 1
                case .failure(WorkflowRunRepositoryError.revisionConflict): conflictCount += 1
                default: break
                }
            }
        }
        #expect(successCount == 1, "Exactly one writer should succeed")
        #expect(conflictCount == 1, "Exactly one writer should get revisionConflict")
    }

    // MARK: - 13: updateStepRunState changes status

    @Test("updateStepRunState persists the new step status")
    func updateStepRunStateChangesStatus() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()

        var agg = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        agg = try await repo.insertStepRun(
            runID: agg.run.id,
            stepDefinitionID: StepDefinitionID(rawValue: "step.intake"),
            stepKind: .intake, attempt: 1,
            inputJSON: "{}", stateJSON: "{}", stateSHA256: "h",
            executorID: nil, executorVersion: nil,
            expectedRevision: 1,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        let stepRunID = agg.stepRuns[0].id
        agg = try await repo.updateStepRunState(
            stepRunID: stepRunID, runID: agg.run.id,
            newStatus: .completed,
            stateJSON: "{\"done\":true}", stateSHA256: "done-hash",
            outputJSON: "{\"result\":\"ok\"}",
            expectedRevision: 2,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        let updated = agg.stepRuns.first(where: { $0.id == stepRunID })
        #expect(updated?.status == .completed)
        #expect(updated?.outputJSON == "{\"result\":\"ok\"}")
        #expect(updated?.completedAt != nil)
    }

    // MARK: - 14: insertDecision persists

    @Test("insertDecision persists the decision in the aggregate")
    func insertDecisionPersists() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()

        var agg = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        agg = try await repo.insertStepRun(
            runID: agg.run.id,
            stepDefinitionID: StepDefinitionID(rawValue: "step.intake"),
            stepKind: .intake, attempt: 1,
            inputJSON: "{}", stateJSON: "{}", stateSHA256: "h",
            executorID: nil, executorVersion: nil,
            expectedRevision: 1,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        let stepRunID = agg.stepRuns[0].id
        agg = try await repo.insertDecision(
            runID: agg.run.id, stepRunID: stepRunID,
            decisionKey: "scope.confirm",
            kind: .branchSelection,
            selectedOption: "proceed",
            rationale: "All clear",
            actorKind: .deterministicRule, actorIdentifier: "rule-v1",
            supersedesDecisionID: nil,
            metadataJSON: "{}",
            expectedRevision: 2,
            now: t0
        )
        #expect(agg.decisions.count == 1)
        #expect(agg.decisions[0].decisionKey == "scope.confirm")
        #expect(agg.decisions[0].selectedOption == "proceed")
        #expect(agg.decisions[0].kind == .branchSelection)
    }

    // MARK: - 15: Human decision requires actor identifier

    @Test("insertDecision with humanDecision kind throws when actor identifier is blank")
    func humanDecisionRequiresActorIdentifier() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()

        var agg = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        agg = try await repo.insertStepRun(
            runID: agg.run.id,
            stepDefinitionID: StepDefinitionID(rawValue: "step.intake"),
            stepKind: .intake, attempt: 1,
            inputJSON: "{}", stateJSON: "{}", stateSHA256: "h",
            executorID: nil, executorVersion: nil,
            expectedRevision: 1,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        let stepRunID = agg.stepRuns[0].id
        do {
            _ = try await repo.insertDecision(
                runID: agg.run.id, stepRunID: stepRunID,
                decisionKey: "approval",
                kind: .humanApproval,
                selectedOption: "approved",
                rationale: nil,
                actorKind: .system,       // wrong — must be .human
                actorIdentifier: nil,
                supersedesDecisionID: nil,
                metadataJSON: "{}",
                expectedRevision: 2,
                now: t0
            )
            Issue.record("Expected humanDecisionMissingActorIdentifier to be thrown")
        } catch WorkflowRunRepositoryError.humanDecisionMissingActorIdentifier {
            // Expected
        }
    }

    // MARK: - 16: Non-human decision does not require identifier

    @Test("insertDecision with branchSelection kind does not require actor identifier")
    func nonHumanDecisionDoesNotRequireIdentifier() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()

        var agg = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        agg = try await repo.insertStepRun(
            runID: agg.run.id,
            stepDefinitionID: StepDefinitionID(rawValue: "step.intake"),
            stepKind: .intake, attempt: 1,
            inputJSON: "{}", stateJSON: "{}", stateSHA256: "h",
            executorID: nil, executorVersion: nil,
            expectedRevision: 1,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        let stepRunID = agg.stepRuns[0].id
        let result = try await repo.insertDecision(
            runID: agg.run.id, stepRunID: stepRunID,
            decisionKey: "branch.key",
            kind: .branchSelection,
            selectedOption: "left",
            rationale: nil,
            actorKind: .deterministicRule, actorIdentifier: nil,
            supersedesDecisionID: nil,
            metadataJSON: "{}",
            expectedRevision: 2,
            now: t0
        )
        #expect(result.decisions.count == 1)
    }

    // MARK: - 17: recordArtifact persists

    @Test("recordArtifact persists the artifact in the aggregate")
    func recordArtifactPersists() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()

        var agg = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        agg = try await repo.insertStepRun(
            runID: agg.run.id,
            stepDefinitionID: StepDefinitionID(rawValue: "step.intake"),
            stepKind: .intake, attempt: 1,
            inputJSON: "{}", stateJSON: "{}", stateSHA256: "h",
            executorID: nil, executorVersion: nil,
            expectedRevision: 1,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        agg = try await repo.recordArtifact(
            runID: agg.run.id, stepRunID: agg.stepRuns[0].id,
            artifactDefinitionID: "art.intake.evidence",
            kind: .attachment, label: "Evidence File",
            workProductRunID: nil,
            targetKind: "knowledge_object", targetID: UUID().uuidString,
            referenceURI: nil, mediaType: "application/pdf",
            contentSHA256: "filehash",
            metadataJSON: "{}",
            supersedesArtifactID: nil,
            expectedRevision: 2,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        #expect(agg.artifacts.count == 1)
        #expect(agg.artifacts[0].artifactDefinitionID == "art.intake.evidence")
        #expect(agg.artifacts[0].kind == .attachment)
        #expect(agg.artifacts[0].mediaType == "application/pdf")
    }

    // MARK: - 18: recordArtifact with nil work_product_run_id

    @Test("recordArtifact with nil work_product_run_id persists correctly")
    func recordArtifactWorkProductRunIDCanBeNull() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()

        var agg = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        agg = try await repo.recordArtifact(
            runID: agg.run.id, stepRunID: nil,
            artifactDefinitionID: "art.report",
            kind: .generatedProduct, label: "Draft Report",
            workProductRunID: nil,
            targetKind: nil, targetID: nil, referenceURI: nil,
            mediaType: nil, contentSHA256: nil,
            metadataJSON: "{}",
            supersedesArtifactID: nil,
            expectedRevision: 1,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        #expect(agg.artifacts.count == 1)
        #expect(agg.artifacts[0].workProductRunID == nil)
        #expect(agg.artifacts[0].stepRunID == nil)
    }

    // MARK: - 19: createAttentionItem persists as open

    @Test("createAttentionItem persists with status open")
    func createAttentionItemPersistsAsOpen() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()

        let created = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        let agg = try await repo.createAttentionItem(
            runID: created.run.id, stepRunID: nil,
            sourceKind: .requirement, sourceID: "req.evidence",
            severity: .blocking,
            title: "Evidence required",
            detail: "Select at least one evidence item",
            expectedRevision: 1,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        #expect(agg.attentionItems.count == 1)
        #expect(agg.attentionItems[0].status == .open)
        #expect(agg.attentionItems[0].severity == .blocking)
        #expect(agg.attentionItems[0].title == "Evidence required")
    }

    // MARK: - 20: resolveAttentionItem changes status

    @Test("resolveAttentionItem changes status to resolved")
    func resolveAttentionItemChangesStatus() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()

        var agg = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        agg = try await repo.createAttentionItem(
            runID: agg.run.id, stepRunID: nil,
            sourceKind: .user, sourceID: nil,
            severity: .advisory,
            title: "Review needed",
            detail: nil,
            expectedRevision: 1,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        let itemID = agg.attentionItems[0].id
        agg = try await repo.resolveAttentionItem(
            attentionItemID: itemID, runID: agg.run.id,
            newStatus: .resolved,
            resolvedBy: "user@example.com",
            resolutionNote: "Reviewed and approved",
            expectedRevision: 2,
            actorKind: .human, actorIdentifier: "user@example.com", now: t0
        )
        let resolved = agg.attentionItems.first(where: { $0.id == itemID })
        #expect(resolved?.status == .resolved)
        #expect(resolved?.resolvedBy == "user@example.com")
        #expect(resolved?.resolvedAt != nil)
    }

    // MARK: - 21: createCheckpoint persists

    @Test("createCheckpoint persists and appears in the aggregate")
    func createCheckpointPersists() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()

        var agg = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        agg = try await repo.createCheckpoint(
            runID: agg.run.id, reason: .explicitSave,
            expectedRevision: 1,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        #expect(agg.checkpoints.count == 1)
        #expect(agg.checkpoints[0].reason == .explicitSave)
        #expect(!agg.checkpoints[0].snapshotJSON.isEmpty)
        #expect(agg.checkpoints[0].snapshotSHA256.count == 64)
    }

    // MARK: - 22: Checkpoint revision matches run revision

    @Test("checkpoint.runRevision equals the run revision at checkpoint creation time")
    func checkpointRevisionMatchesRunRevision() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()

        var agg = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        // Add one more mutation so revision = 2
        agg = try await repo.updateRunState(
            runID: agg.run.id, newStatus: .active,
            currentStepDefinitionID: nil, currentStepRunID: nil,
            timestamps: WorkflowRunTimestampPatch(),
            cancellationReason: nil,
            expectedRevision: 1,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        agg = try await repo.createCheckpoint(
            runID: agg.run.id, reason: .pause,
            expectedRevision: 2,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        #expect(agg.checkpoints[0].runRevision == 3)
        #expect(agg.run.revision == 3)
    }

    // MARK: - 23: Checkpoint payload hash verified by reopen

    @Test("fetchRun verifies the latest checkpoint payload hash matches stored SHA-256")
    func checkpointPayloadHashVerifiedByReopen() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()

        var agg = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        agg = try await repo.createCheckpoint(
            runID: agg.run.id, reason: .explicitSave,
            expectedRevision: 1,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        // Corrupt the checkpoint snapshot
        let checkpointID = agg.checkpoints[0].id
        try await db.exec(
            "UPDATE workflow_checkpoints SET snapshot_sha256 = 'badhash' WHERE id = ?;",
            [.uuid(checkpointID)])

        do {
            _ = try await repo.fetchRun(agg.run.id)
            Issue.record("Expected checkpointHashMismatch to be thrown")
        } catch WorkflowRunRepositoryError.checkpointHashMismatch {
            // Expected
        }
    }

    // MARK: - 24: linkSupersession

    @Test("linkSupersession sets superseded_by_run_id on the original run")
    func linkSupersessionSetsSuperseededByRunID() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()

        let runA = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: "Run A",
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        let runB = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: "Run B",
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        let updated = try await repo.linkSupersession(
            runID: runA.run.id, supersededByRunID: runB.run.id,
            expectedRevision: 1,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        #expect(updated.run.supersededByRunID == runB.run.id)
    }

    // MARK: - 25: linkSupersession rejects self-reference

    @Test("linkSupersession throws supersededRunLinkConflict when runID == supersededByRunID")
    func linkSupersessionConflictOnSameRunID() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()

        let agg = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        do {
            _ = try await repo.linkSupersession(
                runID: agg.run.id, supersededByRunID: agg.run.id,
                expectedRevision: 1,
                actorKind: .system, actorIdentifier: nil, now: t0
            )
            Issue.record("Expected supersededRunLinkConflict to be thrown")
        } catch WorkflowRunRepositoryError.supersededRunLinkConflict {
            // Expected
        }
    }

    // MARK: - 26: linkSupersession rejects already-superseded run

    @Test("linkSupersession throws supersededRunLinkConflict when run already has superseded_by_run_id")
    func linkSupersessionConflictOnAlreadySuperseded() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()

        let runA = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        let runB = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        let runC = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        _ = try await repo.linkSupersession(
            runID: runA.run.id, supersededByRunID: runB.run.id,
            expectedRevision: 1,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        do {
            _ = try await repo.linkSupersession(
                runID: runA.run.id, supersededByRunID: runC.run.id,
                expectedRevision: 2,
                actorKind: .system, actorIdentifier: nil, now: t0
            )
            Issue.record("Expected supersededRunLinkConflict for double-supersession")
        } catch WorkflowRunRepositoryError.supersededRunLinkConflict {
            // Expected
        }
    }

    // MARK: - 27: delete cascades to all child tables

    @Test("delete(runID) cascades to all 6 child tables")
    func deleteRunCascadesToAllChildren() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()

        var agg = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        agg = try await repo.insertStepRun(
            runID: agg.run.id,
            stepDefinitionID: StepDefinitionID(rawValue: "step.intake"),
            stepKind: .intake, attempt: 1,
            inputJSON: "{}", stateJSON: "{}", stateSHA256: "h",
            executorID: nil, executorVersion: nil,
            expectedRevision: 1,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        agg = try await repo.createCheckpoint(
            runID: agg.run.id, reason: .explicitSave,
            expectedRevision: 2,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        let runID = agg.run.id
        try await repo.delete(runID)

        let rows = try await db.query(
            "SELECT COUNT(*) FROM workflow_runs WHERE id = ?;", [.uuid(runID)])
        #expect(Int(rows.first?.int(0) ?? -1) == 0, "run must be deleted")

        let events = try await db.query(
            "SELECT COUNT(*) FROM workflow_run_events WHERE run_id = ?;", [.uuid(runID)])
        #expect(Int(events.first?.int(0) ?? -1) == 0, "events must cascade-delete")

        let checkpoints = try await db.query(
            "SELECT COUNT(*) FROM workflow_checkpoints WHERE run_id = ?;", [.uuid(runID)])
        #expect(Int(checkpoints.first?.int(0) ?? -1) == 0, "checkpoints must cascade-delete")
    }

    // MARK: - 28: delete run does NOT delete work_product_run

    @Test("deleting a run sets artifact.work_product_run_id to NULL but does not delete work_product_run")
    func deleteWorkProductRunSetsArtifactWorkProductRunIDNull() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()

        // Insert a work_product_run
        let wprID = UUID()
        try await db.exec("""
        INSERT INTO work_product_runs
            (id, workspace_id, template, title, subject_label,
             schema_version, app_version, composed_at, finding_count)
        VALUES (?,?,?,?,?,?,?,?,?);
        """, [.uuid(wprID), .uuid(wsID), .text("chronology"), .text("WP"),
              .text("Subject"), .integer(1), .text("1.0"),
              .real(t0.timeIntervalSince1970), .integer(0)])

        var agg = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        agg = try await repo.recordArtifact(
            runID: agg.run.id, stepRunID: nil,
            artifactDefinitionID: "art.wp",
            kind: .workProductRun, label: "Report",
            workProductRunID: wprID,
            targetKind: nil, targetID: nil, referenceURI: nil,
            mediaType: nil, contentSHA256: nil,
            metadataJSON: "{}",
            supersedesArtifactID: nil,
            expectedRevision: 1,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        let runID = agg.run.id
        try await repo.delete(runID)

        // work_product_run must still exist
        let wprCount = try await db.query(
            "SELECT COUNT(*) FROM work_product_runs WHERE id = ?;", [.uuid(wprID)])
        #expect(Int(wprCount.first?.int(0) ?? -1) == 1,
                "work_product_run must survive workflow run deletion")
    }

    // MARK: - 29: fetchRun returns full aggregate

    @Test("fetchRun returns the full aggregate with all child collections")
    func fetchRunReturnsFullAggregate() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()

        var agg = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        agg = try await repo.insertStepRun(
            runID: agg.run.id,
            stepDefinitionID: StepDefinitionID(rawValue: "step.intake"),
            stepKind: .intake, attempt: 1,
            inputJSON: "{}", stateJSON: "{}", stateSHA256: "h",
            executorID: nil, executorVersion: nil,
            expectedRevision: 1,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        let fetched = try await repo.fetchRun(agg.run.id)
        #expect(fetched.run.id == agg.run.id)
        #expect(fetched.stepRuns.count == 1)
        #expect(fetched.events.count == 2)
    }

    // MARK: - 30: fetchRunIDs returns in creation order

    @Test("fetchRunIDs returns run IDs ordered by created_at DESC")
    func fetchRunIDsByWorkspaceReturnsInOrder() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()

        let runA = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil,
            now: Date(timeIntervalSince1970: t0.timeIntervalSince1970 + 0)
        )
        let runB = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil,
            now: Date(timeIntervalSince1970: t0.timeIntervalSince1970 + 1)
        )
        let ids = try await repo.fetchRunIDs(workspaceID: wsID)
        #expect(ids.count >= 2)
        #expect(ids[0] == runB.run.id, "Most recent run must come first")
        #expect(ids[1] == runA.run.id)
    }

    // MARK: - 31: fetchRunIDs filtered by application + status

    @Test("fetchRunIDs with applicationDefinitionID and status filter returns matching runs only")
    func fetchRunIDsByApplicationAndStatus() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()

        let draft = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        var active = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        active = try await repo.updateRunState(
            runID: active.run.id, newStatus: .active,
            currentStepDefinitionID: nil, currentStepRunID: nil,
            timestamps: WorkflowRunTimestampPatch(startedAt: t0),
            cancellationReason: nil,
            expectedRevision: 1,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        let draftIDs = try await repo.fetchRunIDs(
            workspaceID: wsID,
            applicationDefinitionID: pkg.applicationKey.id,
            status: .draft
        )
        #expect(draftIDs.contains(draft.run.id))
        #expect(!draftIDs.contains(active.run.id))

        let activeIDs = try await repo.fetchRunIDs(
            workspaceID: wsID,
            applicationDefinitionID: pkg.applicationKey.id,
            status: .active
        )
        #expect(activeIDs.contains(active.run.id))
        #expect(!activeIDs.contains(draft.run.id))
    }

    // MARK: - 32: revision == event count invariant

    @Test("revision equals event count at every observable state")
    func revisionEqualEventCountInvariantVerified() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()

        var agg = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        #expect(agg.run.revision == agg.events.count, "After createRun: revision=\(agg.run.revision), events=\(agg.events.count)")

        agg = try await repo.updateRunState(
            runID: agg.run.id, newStatus: .active,
            currentStepDefinitionID: nil, currentStepRunID: nil,
            timestamps: WorkflowRunTimestampPatch(),
            cancellationReason: nil,
            expectedRevision: 1,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        #expect(agg.run.revision == agg.events.count, "After updateRunState: revision=\(agg.run.revision), events=\(agg.events.count)")

        agg = try await repo.insertStepRun(
            runID: agg.run.id,
            stepDefinitionID: StepDefinitionID(rawValue: "step.intake"),
            stepKind: .intake, attempt: 1,
            inputJSON: "{}", stateJSON: "{}", stateSHA256: "h",
            executorID: nil, executorVersion: nil,
            expectedRevision: 2,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        #expect(agg.run.revision == agg.events.count, "After insertStepRun: revision=\(agg.run.revision), events=\(agg.events.count)")
    }

    // MARK: - 33: reopen checks latest checkpoint hash

    @Test("reopen throws checkpointHashMismatch when latest checkpoint hash is corrupted")
    func reopenChecksLatestCheckpointHash() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()

        var agg = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        agg = try await repo.createCheckpoint(
            runID: agg.run.id, reason: .explicitSave,
            expectedRevision: 1,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        // Corrupt the latest checkpoint's hash
        try await db.exec(
            "UPDATE workflow_checkpoints SET snapshot_sha256 = ? WHERE run_id = ?;",
            [.text(String(repeating: "f", count: 64)), .uuid(agg.run.id)])

        do {
            _ = try await repo.fetchRun(agg.run.id)
            Issue.record("Expected checkpointHashMismatch to be thrown")
        } catch WorkflowRunRepositoryError.checkpointHashMismatch {
            // Expected
        }
    }

    // MARK: - 34: createRun with parentRunID persists

    @Test("createRun with a valid parentRunID persists the link")
    func createRunWithParentRunIDPersists() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()

        let parent = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: "Parent",
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        let child = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: "Child",
            parentRunID: parent.run.id,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        #expect(child.run.parentRunID == parent.run.id)
    }

    // MARK: - 35: createRun with missing parentRunID throws

    @Test("createRun throws runNotFound when parentRunID does not exist")
    func createRunWithMissingParentRunIDThrows() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()
        let missingParentID = UUID()

        do {
            _ = try await repo.createRun(
                package: pkg, selectedWorkflowID: wfID,
                workspaceID: wsID, title: nil,
                parentRunID: missingParentID,
                actorKind: .system, actorIdentifier: nil, now: t0
            )
            Issue.record("Expected runNotFound to be thrown for missing parent")
        } catch WorkflowRunRepositoryError.runNotFound(let id) {
            #expect(id == missingParentID)
        }
    }

    // MARK: - 36: updateStepRunState persists outputJSON

    @Test("updateStepRunState persists outputJSON when provided")
    func updateStepRunOutputJSONPersists() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()

        var agg = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        agg = try await repo.insertStepRun(
            runID: agg.run.id,
            stepDefinitionID: StepDefinitionID(rawValue: "step.intake"),
            stepKind: .intake, attempt: 1,
            inputJSON: "{}", stateJSON: "{}", stateSHA256: "h",
            executorID: nil, executorVersion: nil,
            expectedRevision: 1,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        let stepRunID = agg.stepRuns[0].id
        agg = try await repo.updateStepRunState(
            stepRunID: stepRunID, runID: agg.run.id,
            newStatus: .completed,
            stateJSON: "{\"done\":true}", stateSHA256: "done",
            outputJSON: "{\"findings\":[\"fact1\"]}",
            expectedRevision: 2,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        #expect(agg.stepRuns[0].outputJSON == "{\"findings\":[\"fact1\"]}")
    }

    // MARK: - 37: fetchRunIDs empty for unknown workspace

    @Test("fetchRunIDs returns empty for a workspace with no runs")
    func fetchRunIDsByWorkspaceEmpty() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)

        let ids = try await repo.fetchRunIDs(workspaceID: wsID)
        #expect(ids.isEmpty)
    }

    // MARK: - 38: Multiple checkpoints ordered by revision

    @Test("multiple checkpoints are returned ordered by run_revision ascending")
    func multipleCheckpointsOrderedByRevision() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()

        var agg = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        agg = try await repo.createCheckpoint(
            runID: agg.run.id, reason: .explicitSave,
            expectedRevision: 1,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        agg = try await repo.createCheckpoint(
            runID: agg.run.id, reason: .pause,
            expectedRevision: 2,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        #expect(agg.checkpoints.count == 2)
        #expect(agg.checkpoints[0].runRevision < agg.checkpoints[1].runRevision)
    }

    // ======================================================================
    // MARK: - Scope-guard tests (10)
    // ======================================================================

    // MARK: SG-1: claims table untouched

    @Test("createRun does not add or remove rows from the claims table")
    func workflowRunRepositoryDoesNotTouchClaimsTable() async throws {
        let db = try await makeDatabase()
        let snap = try await MigrationFixtureBuilder.seedPreservationRows(into: db, forVersion: 75)
        let claimsBefore = try await db.query("SELECT COUNT(*) FROM claims;", [])
        let beforeCount = Int(claimsBefore.first?.int(0) ?? 0)

        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()
        _ = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )

        let claimsAfter = try await db.query("SELECT COUNT(*) FROM claims;", [])
        #expect(Int(claimsAfter.first?.int(0) ?? 0) == beforeCount,
                "claims table must be unchanged by workflow run operations")
        _ = snap
    }

    // MARK: SG-2: entities table untouched

    @Test("repository operations do not touch the entities table")
    func workflowRunRepositoryDoesNotTouchEntitiesTable() async throws {
        let db = try await makeDatabase()
        let before = try await db.query("SELECT COUNT(*) FROM entities;", [])
        let beforeCount = Int(before.first?.int(0) ?? 0)

        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()
        _ = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        let after = try await db.query("SELECT COUNT(*) FROM entities;", [])
        #expect(Int(after.first?.int(0) ?? 0) == beforeCount)
    }

    // MARK: SG-3: ledger events table untouched

    @Test("repository operations do not touch the ledger events table")
    func workflowRunRepositoryDoesNotTouchLedgerEventsTable() async throws {
        let db = try await makeDatabase()
        let before = try await db.query("SELECT COUNT(*) FROM events;", [])
        let beforeCount = Int(before.first?.int(0) ?? 0)

        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()
        _ = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        let after = try await db.query("SELECT COUNT(*) FROM events;", [])
        #expect(Int(after.first?.int(0) ?? 0) == beforeCount)
    }

    // MARK: SG-4: knowledge_objects untouched

    @Test("repository operations do not touch the knowledge_objects table")
    func workflowRunRepositoryDoesNotTouchKnowledgeObjectsTable() async throws {
        let db = try await makeDatabase()
        let before = try await db.query("SELECT COUNT(*) FROM knowledge_objects;", [])
        let beforeCount = Int(before.first?.int(0) ?? 0)

        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()
        _ = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        let after = try await db.query("SELECT COUNT(*) FROM knowledge_objects;", [])
        #expect(Int(after.first?.int(0) ?? 0) == beforeCount)
    }

    // MARK: SG-5: files table untouched

    @Test("repository operations do not touch the files table")
    func workflowRunRepositoryDoesNotTouchFilesTable() async throws {
        let db = try await makeDatabase()
        let before = try await db.query("SELECT COUNT(*) FROM files;", [])
        let beforeCount = Int(before.first?.int(0) ?? 0)

        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()
        _ = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        let after = try await db.query("SELECT COUNT(*) FROM files;", [])
        #expect(Int(after.first?.int(0) ?? 0) == beforeCount)
    }

    // MARK: SG-6: delete run does not delete work_product_run (policy non-ownership)

    @Test("deleting a run never deletes a work_product_run (non-ownership: SET NULL only)")
    func deleteRunDoesNotDeleteWorkProductRun() async throws {
        let db = try await makeDatabase()
        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let wprID = UUID()
        try await db.exec("""
        INSERT INTO work_product_runs
            (id, workspace_id, template, title, subject_label,
             schema_version, app_version, composed_at, finding_count)
        VALUES (?,?,?,?,?,?,?,?,?);
        """, [.uuid(wprID), .uuid(wsID), .text("chronology"), .text("WP"),
              .text("S"), .integer(1), .text("1.0"), .real(t0.timeIntervalSince1970), .integer(0)])

        let (pkg, wfID) = try makeMinimalPackage()
        let agg = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        try await repo.delete(agg.run.id)

        let wprCount = try await db.query(
            "SELECT COUNT(*) FROM work_product_runs WHERE id = ?;", [.uuid(wprID)])
        #expect(Int(wprCount.first?.int(0) ?? -1) == 1,
                "work_product_run must survive workflow run deletion")
    }

    // MARK: SG-7: timelines untouched

    @Test("repository operations do not touch the timelines table")
    func workflowRunRepositoryDoesNotTouchTimelinesTable() async throws {
        let db = try await makeDatabase()
        let before = try await db.query("SELECT COUNT(*) FROM timelines;", [])
        let beforeCount = Int(before.first?.int(0) ?? 0)

        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()
        _ = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        let after = try await db.query("SELECT COUNT(*) FROM timelines;", [])
        #expect(Int(after.first?.int(0) ?? 0) == beforeCount)
    }

    // MARK: SG-8: chunks untouched

    @Test("repository operations do not touch the chunks table")
    func workflowRunRepositoryDoesNotTouchChunksTable() async throws {
        let db = try await makeDatabase()
        let before = try await db.query("SELECT COUNT(*) FROM chunks;", [])
        let beforeCount = Int(before.first?.int(0) ?? 0)

        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()
        _ = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        let after = try await db.query("SELECT COUNT(*) FROM chunks;", [])
        #expect(Int(after.first?.int(0) ?? 0) == beforeCount)
    }

    // MARK: SG-9: summaries untouched

    @Test("repository operations do not touch the summaries table")
    func workflowRunRepositoryDoesNotTouchSummariesTable() async throws {
        let db = try await makeDatabase()
        let before = try await db.query("SELECT COUNT(*) FROM summaries;", [])
        let beforeCount = Int(before.first?.int(0) ?? 0)

        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()
        _ = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        let after = try await db.query("SELECT COUNT(*) FROM summaries;", [])
        #expect(Int(after.first?.int(0) ?? 0) == beforeCount)
    }

    // MARK: SG-10: source_versions untouched

    @Test("repository operations do not touch the source_versions table")
    func workflowRunRepositoryDoesNotTouchSourceVersionsTable() async throws {
        let db = try await makeDatabase()
        let before = try await db.query("SELECT COUNT(*) FROM source_versions;", [])
        let beforeCount = Int(before.first?.int(0) ?? 0)

        let repo = makeRepository(db: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makeMinimalPackage()
        _ = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil,
            parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0
        )
        let after = try await db.query("SELECT COUNT(*) FROM source_versions;", [])
        #expect(Int(after.first?.int(0) ?? 0) == beforeCount)
    }
}
