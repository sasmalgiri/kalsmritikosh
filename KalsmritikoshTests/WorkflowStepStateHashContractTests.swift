//
//  WorkflowStepStateHashContractTests.swift
//  KalsmritikoshTests
//
//  PJE-006B.1 — Unified step-state hash contract:
//  state_sha256 = SHA-256 of the exact UTF-8 bytes stored in state_json.
//  Covers the historical JSONEncoder-vs-JSONSerialization ordering mismatch,
//  strict storedUTF8BytesV1 verification, legacy tolerance, tamper detection,
//  semantics-driven relaunch verification, legacy upgrade-on-mutation,
//  reopen non-mutation, and checkpoint/contract hashing stability. 13 tests.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-006B.1 — WorkflowStepStateHashContract")
@MainActor
struct WorkflowStepStateHashContractTests {

    private let t0 = Date(timeIntervalSince1970: 1_753_500_000)

    // MARK: - Helpers

    private func makeDB() async throws -> Database {
        try await MigrationFixtureBuilder.database(atVersion: 76)
    }

    private func insertWorkspace(_ db: Database, id: UUID) async throws {
        try await db.exec("""
        INSERT INTO workspaces (id, title, template_type, created_at, updated_at)
        VALUES (?,?,?,?,?);
        """, [.uuid(id), .text("Hash WS"), .text("general"),
              .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
    }

    private func makePackage(suffix: String) throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let appID = ApplicationDefinitionID(rawValue: "com.hash.test.\(suffix)")
        let wfID  = WorkflowDefinitionID(rawValue: "com.hash.test.wf.\(suffix)")
        let doneID = StepDefinitionID(rawValue: "step.done.\(suffix)")
        let entry = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.entry.\(suffix)"),
            kind: .intake, label: "Entry", isEntry: true,
            transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: doneID)])
        let done = PersonaWorkflowStepDefinition(
            id: doneID, kind: .closure, label: "Done", isTerminal: true)
        let wfDef = PersonaWorkflowDefinition(
            id: wfID, version: 1, schemaVersion: 1, label: "Hash WF", steps: [entry, done])
        let validated = try WorkflowDefinitionCompiler().compile(wfDef)
        let app = PersonaApplicationDefinition(id: appID, version: 1, label: "Hash App")
        let termID = TerminologyDefinitionID(rawValue: "com.hash.test.term.\(suffix)")
        let term = PersonaTerminologyDefinition(id: termID, version: 1, applicationID: appID, labels: [:])
        let pkg = ResolvedPersonaApplicationPackage(
            applicationKey: RegistryKey(id: appID, version: 1),
            application: app, toolKeys: [], tools: [],
            workflowKeys: [RegistryKey(id: wfID, version: 1)], workflows: [validated],
            terminologyKey: RegistryKey(id: termID, version: 1), terminology: term,
            objectSchemaKeys: [], objectSchemas: [],
            workProductKeys: [], workProducts: [],
            validatorKeys: [], validators: [],
            automationKeys: [], automations: [])
        return (pkg, wfID)
    }

    /// Creates a run and inserts one step run with the given state/hash pair.
    /// Returns (repo, runID, stepRunID).
    private func seededRun(
        db: Database, suffix: String, stateJSON: String, stateSHA256: String
    ) async throws -> (WorkflowRunRepository, UUID, UUID) {
        let repo = WorkflowRunRepository(database: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makePackage(suffix: suffix)
        let created = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: wsID,
            title: nil, parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0)
        let after = try await repo.insertStepRun(
            runID: created.run.id,
            stepDefinitionID: StepDefinitionID(rawValue: "step.entry.\(suffix)"),
            stepKind: .intake, attempt: 1,
            inputJSON: "{}", stateJSON: stateJSON, stateSHA256: stateSHA256,
            executorID: "com.kalsmritikosh.step.intake", executorVersion: "1.0",
            expectedRevision: created.run.revision,
            actorKind: .system, actorIdentifier: nil, now: t0)
        let stepRunID = try #require(after.stepRuns.first?.id)
        return (repo, created.run.id, stepRunID)
    }

    /// Envelope JSON with a UUID-keyed dictionary state — the shape that exposed
    /// the historical serializer-ordering mismatch.
    private func uuidKeyedEnvelopeJSON() throws -> String {
        var reviews: [String: WorkflowEvidenceReviewRecord] = [:]
        for i in 0..<3 {
            let id = UUID()
            reviews[id.uuidString] = WorkflowEvidenceReviewRecord(
                itemID: id, status: .reviewed, note: "r\(i)",
                reviewedBy: nil, reviewedAt: t0)
        }
        let envelope = WorkflowStepStateEnvelope(
            stepKind: .reviewEvidence,
            executorID: "com.kalsmritikosh.step.reviewEvidence",
            executorVersion: "1.0",
            state: ReviewEvidenceStepState(reviews: reviews))
        return try WorkflowStepPayloadCodec.encode(envelope)
    }

    // MARK: - Contract function

    @Test("Encoded state hash equals SHA-256 of the exact stored bytes — every time")
    func encodedStateHashEqualsExactStoredBytes() async throws {
        let executor = ReviewEvidenceStepExecutor()
        for i in 0..<50 {
            var reviews: [String: WorkflowEvidenceReviewRecord] = [:]
            for _ in 0..<3 {
                let id = UUID()
                reviews[id.uuidString] = WorkflowEvidenceReviewRecord(
                    itemID: id, status: .needsFollowUp, note: "n\(i)",
                    reviewedBy: nil, reviewedAt: t0)
            }
            let (json, sha) = try executor.makeEnvelope(
                state: ReviewEvidenceStepState(reviews: reviews),
                stepKind: .reviewEvidence)
            #expect(sha == WorkflowPersistedJSONIntegrity.rawSHA256(of: json))
        }
    }

    @Test("UUID-key dictionaries reproduce the historical canonicalization mismatch")
    func uuidKeyDictionaryReproducesHistoricalMismatch() async throws {
        var mismatches = 0
        for _ in 0..<300 {
            let json = try uuidKeyedEnvelopeJSON()
            let canonical = try WorkflowStepPayloadCodec.hashJSON(json)
            let raw = WorkflowPersistedJSONIntegrity.rawSHA256(of: json)
            if canonical != raw { mismatches += 1 }
        }
        #expect(mismatches > 0,
                "JSONSerialization's numeric key sort must diverge from JSONEncoder's scalar sort for some UUID key sets")
    }

    @Test("Integrity function validates JSON and never reserializes before hashing")
    func integrityFunctionValidatesAndHashesExactBytes() async throws {
        let json = try uuidKeyedEnvelopeJSON()
        let viaContract = try WorkflowPersistedJSONIntegrity.sha256(storedJSON: json)
        #expect(viaContract == WorkflowPersistedJSONIntegrity.rawSHA256(of: json))
        #expect(throws: WorkflowStepExecutionError.self) {
            _ = try WorkflowPersistedJSONIntegrity.sha256(storedJSON: "not json at all")
        }
    }

    @Test("Lifecycle codec routes through the unified contract")
    func lifecycleCodecRoutesThroughUnifiedContract() async throws {
        let codec = WorkflowLifecyclePayloadCodec()
        let json = try uuidKeyedEnvelopeJSON()
        #expect(try codec.stateSHA256(for: json)
                == WorkflowPersistedJSONIntegrity.sha256(storedJSON: json))
        #expect(throws: (any Error).self) {
            _ = try codec.stateSHA256(for: "{broken")
        }
    }

    // MARK: - Repository semantics

    @Test("A row whose hash satisfies the stored-bytes contract is recorded as storedUTF8BytesV1 and verifies deterministically")
    func newSemanticsVerifyDeterministically() async throws {
        let db = try await makeDB()
        let json = try uuidKeyedEnvelopeJSON()
        let sha = try WorkflowPersistedJSONIntegrity.sha256(storedJSON: json)
        let (repo, runID, stepRunID) = try await seededRun(
            db: db, suffix: "v1", stateJSON: json, stateSHA256: sha)
        #expect(try await repo.stepStateHashSemantics(stepRunID: stepRunID) == .storedUTF8BytesV1)
        for _ in 0..<10 {
            let reopened = try await repo.fetchRun(runID)
            #expect(reopened.stepRuns.first?.stateSHA256 == sha)
        }
    }

    @Test("A legacy-labelled row still reopens")
    func legacySemanticsStillReopen() async throws {
        let db = try await makeDB()
        // Hash deliberately does NOT satisfy the stored-bytes contract → legacy label.
        let (repo, runID, stepRunID) = try await seededRun(
            db: db, suffix: "legacy", stateJSON: "{\"a\":1}", stateSHA256: "not-a-matching-hash")
        #expect(try await repo.stepStateHashSemantics(stepRunID: stepRunID) == .legacyCanonicalizedJSON)
        let reopened = try await repo.fetchRun(runID)
        #expect(reopened.stepRuns.count == 1)
    }

    @Test("Tampered stored JSON on a storedUTF8BytesV1 row fails reopen")
    func tamperedStoredJSONFails() async throws {
        let db = try await makeDB()
        let json = "{\"value\":42}"
        let sha = try WorkflowPersistedJSONIntegrity.sha256(storedJSON: json)
        let (repo, runID, stepRunID) = try await seededRun(
            db: db, suffix: "tampjson", stateJSON: json, stateSHA256: sha)
        try await db.exec(
            "UPDATE workflow_step_runs SET state_json = ? WHERE id = ?;",
            [.text("{\"value\":43}"), .uuid(stepRunID)])
        await #expect(throws: WorkflowRunRepositoryError.self) {
            _ = try await repo.fetchRun(runID)
        }
    }

    @Test("Tampered stored hash on a storedUTF8BytesV1 row fails reopen")
    func tamperedHashFails() async throws {
        let db = try await makeDB()
        let json = "{\"value\":42}"
        let sha = try WorkflowPersistedJSONIntegrity.sha256(storedJSON: json)
        let (repo, runID, stepRunID) = try await seededRun(
            db: db, suffix: "tamphash", stateJSON: json, stateSHA256: sha)
        try await db.exec(
            "UPDATE workflow_step_runs SET state_sha256 = ? WHERE id = ?;",
            [.text(String(repeating: "0", count: 64)), .uuid(stepRunID)])
        await #expect(throws: WorkflowRunRepositoryError.self) {
            _ = try await repo.fetchRun(runID)
        }
    }

    @Test("Relaunch verification uses the RECORDED semantics, not a guess")
    func relaunchVerificationUsesRecordedSemantics() async throws {
        let db = try await makeDB()
        // Legacy row whose hash matches NEITHER algorithm — reopens fine as legacy…
        let (repo, runID, stepRunID) = try await seededRun(
            db: db, suffix: "sem", stateJSON: "{\"a\":1}", stateSHA256: "historic-hash")
        _ = try await repo.fetchRun(runID)
        // …but relabelling the SAME row as storedUTF8BytesV1 makes reopen fail:
        // the semantics column drives verification.
        try await db.exec(
            "UPDATE workflow_step_runs SET state_hash_semantics = ? WHERE id = ?;",
            [.text(WorkflowStepStateHashSemantics.storedUTF8BytesV1.rawValue), .uuid(stepRunID)])
        await #expect(throws: WorkflowRunRepositoryError.self) {
            _ = try await repo.fetchRun(runID)
        }
    }

    @Test("Updating a legacy step upgrades it to storedUTF8BytesV1")
    func legacyStepUpgradesOnUpdate() async throws {
        let db = try await makeDB()
        let (repo, runID, stepRunID) = try await seededRun(
            db: db, suffix: "upg", stateJSON: "{\"a\":1}", stateSHA256: "historic-hash")
        #expect(try await repo.stepStateHashSemantics(stepRunID: stepRunID) == .legacyCanonicalizedJSON)

        let newJSON = try uuidKeyedEnvelopeJSON()
        let newSHA = try WorkflowPersistedJSONIntegrity.sha256(storedJSON: newJSON)
        let current = try await repo.fetchRun(runID)
        _ = try await repo.updateStepRunState(
            stepRunID: stepRunID, runID: runID,
            newStatus: .active, stateJSON: newJSON, stateSHA256: newSHA,
            outputJSON: nil, expectedRevision: current.run.revision,
            actorKind: .system, actorIdentifier: nil, now: t0.addingTimeInterval(60))
        #expect(try await repo.stepStateHashSemantics(stepRunID: stepRunID) == .storedUTF8BytesV1)
    }

    @Test("Reopening never mutates a legacy row")
    func reopenDoesNotMutate() async throws {
        let db = try await makeDB()
        let (repo, runID, stepRunID) = try await seededRun(
            db: db, suffix: "nomut", stateJSON: "{\"a\":1}", stateSHA256: "historic-hash")
        let before = try await db.query("""
            SELECT state_json, state_sha256, state_hash_semantics, updated_at
              FROM workflow_step_runs WHERE id = ?;
            """, [.uuid(stepRunID)])
        _ = try await repo.fetchRun(runID)
        _ = try await repo.fetchRun(runID)
        let after = try await db.query("""
            SELECT state_json, state_sha256, state_hash_semantics, updated_at
              FROM workflow_step_runs WHERE id = ?;
            """, [.uuid(stepRunID)])
        #expect(before.first?.string(0) == after.first?.string(0))
        #expect(before.first?.string(1) == after.first?.string(1))
        #expect(before.first?.string(2) == after.first?.string(2))
        #expect(after.first?.string(2) == WorkflowStepStateHashSemantics.legacyCanonicalizedJSON.rawValue)
        #expect(before.first?.double(3) == after.first?.double(3))
    }

    @Test("Checkpoint and contract hashing are unchanged by the new contract")
    func checkpointAndContractHashingUnchanged() async throws {
        let db = try await makeDB()
        let json = "{\"value\":1}"
        let sha = try WorkflowPersistedJSONIntegrity.sha256(storedJSON: json)
        let (repo, runID, _) = try await seededRun(
            db: db, suffix: "ckpt", stateJSON: json, stateSHA256: sha)
        let current = try await repo.fetchRun(runID)
        let after = try await repo.createCheckpoint(
            runID: runID, reason: .explicitSave,
            expectedRevision: current.run.revision,
            actorKind: .system, actorIdentifier: nil, now: t0.addingTimeInterval(30))
        let checkpoint = try #require(after.checkpoints.last)
        // Checkpoint hash contract: SHA-256 of the stored snapshot bytes (unchanged).
        let snapshotData = Data(checkpoint.snapshotJSON.utf8)
        #expect(checkpoint.snapshotSHA256 == WorkflowRunSnapshotCodec.hashString(snapshotData))
        // Contract snapshot still verifies on reopen.
        let reopened = try await repo.fetchRun(runID)
        #expect(reopened.run.contractSnapshotSHA256 == current.run.contractSnapshotSHA256)
    }

    @Test("Engine-persisted step states are storedUTF8BytesV1 end to end")
    func enginePersistedStatesAreV1() async throws {
        let db = try await makeDB()
        let repo = WorkflowRunRepository(database: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let (pkg, wfID) = try makePackage(suffix: "engine")
        let builder = WorkflowStepExecutorRegistryBuilder()
        let intake = IntakeStepExecutor()
        try builder.register(intake)
        try builder.bind(WorkflowStepExecutorBinding(
            workflowSchemaVersion: 1, stepKind: .intake,
            executorID: intake.executorID, executorVersion: intake.executorVersion))
        let engine = WorkflowStepExecutionEngine(
            registry: builder.build(),
            lifecycleEngine: WorkflowLifecycleEngine(repository: repo),
            repository: repo)
        let created = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: wsID,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
        let started = try await engine.startRun(runID: created.run.id, actor: .system, now: t0)
        let setCmd = try WorkflowStepPayloadCodec.encode(IntakeStepCommand.setTitle("Unified"))
        let after = try await engine.executeCommand(
            runID: started.run.id, commandJSON: setCmd, actor: .system, now: t0.addingTimeInterval(10))
        let stepRunID = try #require(after.run.currentStepRunID)
        let stepRun = try #require(after.stepRuns.first { $0.id == stepRunID })
        #expect(try await repo.stepStateHashSemantics(stepRunID: stepRunID) == .storedUTF8BytesV1)
        #expect(stepRun.stateSHA256 == WorkflowPersistedJSONIntegrity.rawSHA256(of: stepRun.stateJSON))
    }
}
