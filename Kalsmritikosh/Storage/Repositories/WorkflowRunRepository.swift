//
//  WorkflowRunRepository.swift
//  Kalsmritikosh
//
//  PJE-003 — Persistent workflow run ledger (schema v75).
//
//  Guarantees:
//  • SAVEPOINT-atomic: every mutation writes its CAS update + child row + event, or rolls back entirely.
//  • Optimistic CAS: every mutation takes expectedRevision; a stale revision throws revisionConflict.
//  • One event per mutation: each successful write increments revision exactly once and appends one event.
//  • Reopen fail-closed: reopen verifies contract hash + revision==event-count + latest checkpoint hash
//    + (PJE-006B.1) step-state hashes per recorded semantics — storedUTF8BytesV1 rows strictly
//    (SHA-256 of the exact stored UTF-8 bytes), legacyCanonicalizedJSON rows best-effort, never rewritten.
//  • Canonical isolation: delete cascades to workflow tables only; never touches claims, entities, or events.
//  • Non-ownership: workflow_artifacts.work_product_run_id is SET NULL on work_product_run delete.
//

import Foundation

// MARK: - Errors

public enum WorkflowRunRepositoryError: Error, Equatable, Sendable {
    case runNotFound(UUID)
    case stepRunNotFound(UUID)
    case attentionItemNotFound(UUID)
    case packageWorkflowNotFound(WorkflowDefinitionID)
    case revisionConflict(UUID, expected: Int)
    case duplicateStepAttempt(runID: UUID, stepDefinitionID: StepDefinitionID, attempt: Int)
    case humanDecisionMissingActorIdentifier
    case supersededRunLinkConflict(runID: UUID)
    case snapshotEncodingFailed(String)
    case snapshotDecodingFailed(String)
    case contractHashMismatch(stored: String, computed: String)
    case checkpointHashMismatch(checkpointID: UUID, stored: String, computed: String)
    case revisionEventMismatch(runID: UUID, revision: Int, eventCount: Int)
    case reopenFailed(runID: UUID, reason: String)
    case stepStateHashMismatch(stepRunID: UUID, stored: String, computed: String)
}

// MARK: - Repository

public actor WorkflowRunRepository {
    private let database: Database
    private let codec = WorkflowRunSnapshotCodec()

    public init(database: Database) { self.database = database }

    // MARK: - Step-state hash semantics (PJE-006B.1)

    /// Classifies which hash contract a (stateJSON, stateSHA256) pair satisfies at write time.
    /// A row whose hash equals the SHA-256 of the exact stored UTF-8 bytes is recorded as
    /// `storedUTF8BytesV1`; anything else keeps the `legacyCanonicalizedJSON` label so
    /// verification never guesses which historical algorithm produced it.
    private nonisolated static func hashSemantics(
        stateJSON: String, stateSHA256: String
    ) -> WorkflowStepStateHashSemantics {
        stateSHA256 == WorkflowPersistedJSONIntegrity.rawSHA256(of: stateJSON)
            ? .storedUTF8BytesV1
            : .legacyCanonicalizedJSON
    }

    /// The recorded hash semantics for a step run (test/audit accessor).
    public func stepStateHashSemantics(
        stepRunID: UUID
    ) async throws -> WorkflowStepStateHashSemantics? {
        let rows = try await database.query(
            "SELECT state_hash_semantics FROM workflow_step_runs WHERE id = ?;",
            [.uuid(stepRunID)])
        guard let raw = rows.first?.string(0) else { return nil }
        return WorkflowStepStateHashSemantics(rawValue: raw)
    }

    // MARK: - Coordinated work-product build (PJE-006C)

    /// Test-only fault points for the atomic work-product build (production passes nil).
    internal enum WorkProductBuildFaultPoint: Sendable, Equatable {
        case afterCAS
        case afterWorkProductInsert
        case afterArtifactInsert
        case afterStepStateUpdate
        case beforeEventInsert
    }

    /// ONE SAVEPOINT: workflow revision CAS -> current-step ownership check ->
    /// immutable work-product run (+ children, via the SHARED writer) ->
    /// workflow artifact link -> step-state update (storedUTF8BytesV1) ->
    /// one .artifactRecorded event. Any failure rolls back EVERYTHING --
    /// no orphaned work-product run, no artifact, no state update, no revision, no event.
    @discardableResult
    internal func applyWorkProductBuild(
        workflowRunID: UUID,
        stepRunID: UUID,
        expectedRevision: Int,
        assembled: AssembledWorkProduct,
        workProductRunID: UUID,
        artifactID: UUID,
        artifactDefinitionID: String,
        subjectLabel: String,
        corpusSnapshotID: UUID?,
        newStepStateJSON: String,
        newStepStateSHA256: String,
        actor: WorkflowLifecycleActor,
        at now: Date,
        fault: (@Sendable (WorkProductBuildFaultPoint) throws -> Void)? = nil
    ) async throws -> ReopenedWorkflowRun {
        let eventID = UUID()
        let sp = "wfr_wpbuild_\(artifactID.uuidString.replacingOccurrences(of: "-", with: ""))"

        try await database.withSavepoint(sp) { db in
            // 1. Win the workflow revision CAS.
            try db.exec("""
                UPDATE workflow_runs
                   SET revision = revision + 1, updated_at = ?
                 WHERE id = ? AND revision = ?;
                """, [.date(now), .uuid(workflowRunID), .integer(Int64(expectedRevision))])
            let changes = try db.query("SELECT changes();", [])
            guard Int(changes.first?.int(0) ?? 0) == 1 else {
                throw WorkflowRunRepositoryError.revisionConflict(workflowRunID, expected: expectedRevision)
            }
            let newRevision = expectedRevision + 1
            try fault?(.afterCAS)

            // 2. Verify current-step ownership.
            let ownerRows = try db.query(
                "SELECT current_step_run_id, workspace_id FROM workflow_runs WHERE id = ?;",
                [.uuid(workflowRunID)])
            guard let ownerRow = ownerRows.first, let workspaceID = ownerRow.uuid(1) else {
                throw WorkflowRunRepositoryError.runNotFound(workflowRunID)
            }
            guard ownerRow.uuid(0) == stepRunID else {
                throw WorkflowRunRepositoryError.stepRunNotFound(stepRunID)
            }

            // 3. Insert the immutable work-product run + children via the SHARED writer.
            _ = try WorkProductRunPersistenceWriter.insert(
                assembled: assembled,
                runID: workProductRunID,
                workspaceID: workspaceID,
                subjectLabel: subjectLabel,
                corpusSnapshotID: corpusSnapshotID,
                database: db)
            try fault?(.afterWorkProductInsert)

            // 4. Insert the workflow artifact link (kind .workProductRun).
            try db.exec("""
                INSERT INTO workflow_artifacts
                    (id, run_id, step_run_id, artifact_definition_id, kind, label,
                     work_product_run_id, target_kind, target_id, reference_uri,
                     media_type, content_sha256, metadata_json,
                     supersedes_artifact_id, created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [
                    .uuid(artifactID), .uuid(workflowRunID), .uuid(stepRunID),
                    .text(artifactDefinitionID),
                    .text(WorkflowArtifactKind.workProductRun.rawValue),
                    .text(assembled.workProduct.title),
                    .uuid(workProductRunID),
                    .null, .null, .null, .null, .null,
                    .text("{}"), .null, .date(now)
                ])
            try fault?(.afterArtifactInsert)

            // 5. Update current step state under the stored-byte hash contract.
            let semantics = Self.hashSemantics(
                stateJSON: newStepStateJSON, stateSHA256: newStepStateSHA256)
            try db.exec("""
                UPDATE workflow_step_runs
                   SET state_json = ?, state_sha256 = ?, state_hash_semantics = ?, updated_at = ?
                 WHERE id = ? AND run_id = ?;
                """, [
                    .text(newStepStateJSON), .text(newStepStateSHA256),
                    .text(semantics.rawValue), .date(now),
                    .uuid(stepRunID), .uuid(workflowRunID)
                ])
            let stepChanges = try db.query("SELECT changes();", [])
            guard Int(stepChanges.first?.int(0) ?? 0) == 1 else {
                throw WorkflowRunRepositoryError.stepRunNotFound(stepRunID)
            }
            try fault?(.afterStepStateUpdate)
            try fault?(.beforeEventInsert)

            // 6. Append exactly one event.
            let evtSeqRows = try db.query(
                "SELECT COALESCE(MAX(sequence), 0) + 1 FROM workflow_run_events WHERE run_id = ?;",
                [.uuid(workflowRunID)])
            let evtSeq = Int(evtSeqRows.first?.int(0) ?? 1)
            try db.exec("""
                INSERT INTO workflow_run_events
                    (id, run_id, sequence, run_revision, type, actor_kind,
                     actor_identifier, payload_json, occurred_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [
                    .uuid(eventID), .uuid(workflowRunID),
                    .integer(Int64(evtSeq)), .integer(Int64(newRevision)),
                    .text(WorkflowRunEventType.artifactRecorded.rawValue),
                    .text(actor.kind.rawValue), .optionalText(actor.identifier),
                    .text("{}"), .date(now)
                ])
        }

        return try await reopen(workflowRunID)
    }

    // MARK: - Create run

    /// Create a new workflow run record, inserting the frozen contract snapshot and first event.
    /// Returns a fully reopened aggregate. Revision = 1 on creation.
    @discardableResult
    public func createRun(
        package: ResolvedPersonaApplicationPackage,
        selectedWorkflowID: WorkflowDefinitionID,
        workspaceID: Workspace.ID,
        title: String?,
        parentRunID: UUID?,
        actorKind: WorkflowDecisionActorKind,
        actorIdentifier: String?,
        now: Date
    ) async throws -> ReopenedWorkflowRun {
        let contract = try WorkflowRunContractSnapshot(from: package, selectedWorkflowID: selectedWorkflowID)
        let encoded = try codec.encode(contract)

        guard let selectedValidated = package.workflows.first(where: { $0.definition.id == selectedWorkflowID }) else {
            throw WorkflowRunRepositoryError.packageWorkflowNotFound(selectedWorkflowID)
        }
        let wfVersion = selectedValidated.definition.version

        if let pid = parentRunID {
            let rows = try await database.query("SELECT COUNT(*) FROM workflow_runs WHERE id = ?;", [.uuid(pid)])
            guard Int(rows.first?.int(0) ?? 0) == 1 else {
                throw WorkflowRunRepositoryError.runNotFound(pid)
            }
        }

        let runID = UUID()
        let eventID = UUID()
        let sp = "wfr_create_\(runID.uuidString.replacingOccurrences(of: "-", with: ""))"

        try await database.withSavepoint(sp) { db in
            try db.exec("""
                INSERT INTO workflow_runs
                    (id, workspace_id, application_definition_id, application_definition_version,
                     workflow_definition_id, workflow_definition_version, title, status,
                     current_step_definition_id, current_step_run_id,
                     contract_snapshot_json, contract_snapshot_sha256, snapshot_schema_version,
                     revision, parent_run_id, superseded_by_run_id,
                     created_at, updated_at,
                     started_at, paused_at, completed_at, cancelled_at, cancellation_reason)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [
                    .uuid(runID), .uuid(workspaceID),
                    .text(package.applicationKey.id.rawValue),
                    .integer(Int64(package.applicationKey.version)),
                    .text(selectedWorkflowID.rawValue),
                    .integer(Int64(wfVersion)),
                    .optionalText(title),
                    .text(WorkflowRunStatus.draft.rawValue),
                    .null, .null,
                    .text(encoded.json), .text(encoded.sha256), .integer(1),
                    .integer(1),
                    parentRunID.map { SQLValue.uuid($0) } ?? .null,
                    .null,
                    .date(now), .date(now),
                    .null, .null, .null, .null, .null
                ])
            try db.exec("""
                INSERT INTO workflow_run_events
                    (id, run_id, sequence, run_revision, type, actor_kind,
                     actor_identifier, payload_json, occurred_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [
                    .uuid(eventID), .uuid(runID),
                    .integer(1), .integer(1),
                    .text(WorkflowRunEventType.runCreated.rawValue),
                    .text(actorKind.rawValue), .optionalText(actorIdentifier),
                    .text("{}"), .date(now)
                ])
        }

        return try await reopen(runID)
    }

    // MARK: - Update run state

    @discardableResult
    public func updateRunState(
        runID: UUID,
        newStatus: WorkflowRunStatus,
        currentStepDefinitionID: StepDefinitionID?,
        currentStepRunID: UUID?,
        timestamps: WorkflowRunTimestampPatch,
        cancellationReason: String?,
        expectedRevision: Int,
        actorKind: WorkflowDecisionActorKind,
        actorIdentifier: String?,
        now: Date
    ) async throws -> ReopenedWorkflowRun {
        let eventID = UUID()
        let sp = "wfr_state_\(runID.uuidString.replacingOccurrences(of: "-", with: ""))\(expectedRevision)"

        try await database.withSavepoint(sp) { db in
            try db.exec("""
                UPDATE workflow_runs
                   SET revision = revision + 1,
                       status = ?, current_step_definition_id = ?,
                       current_step_run_id = ?,
                       started_at = ?, paused_at = ?, completed_at = ?, cancelled_at = ?,
                       cancellation_reason = ?,
                       updated_at = ?
                 WHERE id = ? AND revision = ?;
                """, [
                    .text(newStatus.rawValue),
                    currentStepDefinitionID.map { SQLValue.text($0.rawValue) } ?? .null,
                    currentStepRunID.map { SQLValue.uuid($0) } ?? .null,
                    SQLValue.optionalDate(timestamps.startedAt),
                    SQLValue.optionalDate(timestamps.pausedAt),
                    SQLValue.optionalDate(timestamps.completedAt),
                    SQLValue.optionalDate(timestamps.cancelledAt),
                    .optionalText(cancellationReason),
                    .date(now),
                    .uuid(runID), .integer(Int64(expectedRevision))
                ])
            let changes = try db.query("SELECT changes();", [])
            guard Int(changes.first?.int(0) ?? 0) == 1 else {
                throw WorkflowRunRepositoryError.revisionConflict(runID, expected: expectedRevision)
            }
            let newRevision = expectedRevision + 1
            let evtSeqRows = try db.query(
                "SELECT COALESCE(MAX(sequence), 0) + 1 FROM workflow_run_events WHERE run_id = ?;",
                [.uuid(runID)])
            let evtSeq = Int(evtSeqRows.first?.int(0) ?? 1)
            try db.exec("""
                INSERT INTO workflow_run_events
                    (id, run_id, sequence, run_revision, type, actor_kind,
                     actor_identifier, payload_json, occurred_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [
                    .uuid(eventID), .uuid(runID),
                    .integer(Int64(evtSeq)), .integer(Int64(newRevision)),
                    .text(WorkflowRunEventType.runStateChanged.rawValue),
                    .text(actorKind.rawValue), .optionalText(actorIdentifier),
                    .text("{}"), .date(now)
                ])
        }

        return try await reopen(runID)
    }

    // MARK: - Insert step run

    @discardableResult
    public func insertStepRun(
        runID: UUID,
        stepDefinitionID: StepDefinitionID,
        stepKind: WorkflowStepKind,
        attempt: Int,
        inputJSON: String,
        stateJSON: String,
        stateSHA256: String,
        executorID: String?,
        executorVersion: String?,
        expectedRevision: Int,
        actorKind: WorkflowDecisionActorKind,
        actorIdentifier: String?,
        now: Date
    ) async throws -> ReopenedWorkflowRun {
        let stepRunID = UUID()
        let eventID = UUID()
        let sp = "wfr_step_\(stepRunID.uuidString.replacingOccurrences(of: "-", with: ""))"

        try await database.withSavepoint(sp) { db in
            // CAS
            try db.exec("""
                UPDATE workflow_runs
                   SET revision = revision + 1, updated_at = ?
                 WHERE id = ? AND revision = ?;
                """, [.date(now), .uuid(runID), .integer(Int64(expectedRevision))])
            let changes = try db.query("SELECT changes();", [])
            guard Int(changes.first?.int(0) ?? 0) == 1 else {
                throw WorkflowRunRepositoryError.revisionConflict(runID, expected: expectedRevision)
            }
            let newRevision = expectedRevision + 1

            // Duplicate attempt check
            let dupRows = try db.query("""
                SELECT COUNT(*) FROM workflow_step_runs
                 WHERE run_id = ? AND step_definition_id = ? AND attempt = ?;
                """, [.uuid(runID), .text(stepDefinitionID.rawValue), .integer(Int64(attempt))])
            guard Int(dupRows.first?.int(0) ?? 0) == 0 else {
                throw WorkflowRunRepositoryError.duplicateStepAttempt(
                    runID: runID, stepDefinitionID: stepDefinitionID, attempt: attempt)
            }

            // Next sequence within this run
            let seqRows = try db.query(
                "SELECT COALESCE(MAX(sequence), 0) + 1 FROM workflow_step_runs WHERE run_id = ?;",
                [.uuid(runID)])
            let sequence = Int(seqRows.first?.int(0) ?? 1)

            let semantics = Self.hashSemantics(stateJSON: stateJSON, stateSHA256: stateSHA256)
            try db.exec("""
                INSERT INTO workflow_step_runs
                    (id, run_id, step_definition_id, step_kind, attempt, sequence,
                     status, executor_id, executor_version,
                     input_json, state_json, output_json, state_sha256,
                     state_hash_semantics, entered_at, updated_at, completed_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [
                    .uuid(stepRunID), .uuid(runID),
                    .text(stepDefinitionID.rawValue), .text(stepKind.rawValue),
                    .integer(Int64(attempt)), .integer(Int64(sequence)),
                    .text(WorkflowStepRunStatus.ready.rawValue),
                    .optionalText(executorID), .optionalText(executorVersion),
                    .text(inputJSON), .text(stateJSON), .null, .text(stateSHA256),
                    .text(semantics.rawValue),
                    .date(now), .date(now), .null
                ])

            let evtSeqRows = try db.query(
                "SELECT COALESCE(MAX(sequence), 0) + 1 FROM workflow_run_events WHERE run_id = ?;",
                [.uuid(runID)])
            let evtSeq = Int(evtSeqRows.first?.int(0) ?? 1)
            try db.exec("""
                INSERT INTO workflow_run_events
                    (id, run_id, sequence, run_revision, type, actor_kind,
                     actor_identifier, payload_json, occurred_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [
                    .uuid(eventID), .uuid(runID),
                    .integer(Int64(evtSeq)), .integer(Int64(newRevision)),
                    .text(WorkflowRunEventType.stepRunInserted.rawValue),
                    .text(actorKind.rawValue), .optionalText(actorIdentifier),
                    .text("{}"), .date(now)
                ])
        }

        return try await reopen(runID)
    }

    // MARK: - Update step run state

    @discardableResult
    public func updateStepRunState(
        stepRunID: UUID,
        runID: UUID,
        newStatus: WorkflowStepRunStatus,
        stateJSON: String,
        stateSHA256: String,
        outputJSON: String?,
        expectedRevision: Int,
        actorKind: WorkflowDecisionActorKind,
        actorIdentifier: String?,
        now: Date
    ) async throws -> ReopenedWorkflowRun {
        let eventID = UUID()
        let sp = "wfr_stepup_\(stepRunID.uuidString.replacingOccurrences(of: "-", with: ""))\(expectedRevision)"

        try await database.withSavepoint(sp) { db in
            // CAS on the parent run
            try db.exec("""
                UPDATE workflow_runs
                   SET revision = revision + 1, updated_at = ?
                 WHERE id = ? AND revision = ?;
                """, [.date(now), .uuid(runID), .integer(Int64(expectedRevision))])
            let changes = try db.query("SELECT changes();", [])
            guard Int(changes.first?.int(0) ?? 0) == 1 else {
                throw WorkflowRunRepositoryError.revisionConflict(runID, expected: expectedRevision)
            }
            let newRevision = expectedRevision + 1

            let completedAt: SQLValue = (newStatus == .completed || newStatus == .cancelled || newStatus == .superseded)
                ? .date(now) : .null

            // PJE-006B.1: a legitimate state mutation records (or upgrades to) the
            // semantics its hash actually satisfies.
            let semantics = Self.hashSemantics(stateJSON: stateJSON, stateSHA256: stateSHA256)
            try db.exec("""
                UPDATE workflow_step_runs
                   SET status = ?, state_json = ?, state_sha256 = ?,
                       state_hash_semantics = ?,
                       output_json = ?, updated_at = ?, completed_at = ?
                 WHERE id = ? AND run_id = ?;
                """, [
                    .text(newStatus.rawValue), .text(stateJSON), .text(stateSHA256),
                    .text(semantics.rawValue),
                    outputJSON.map { SQLValue.text($0) } ?? .null,
                    .date(now), completedAt,
                    .uuid(stepRunID), .uuid(runID)
                ])

            let evtSeqRows = try db.query(
                "SELECT COALESCE(MAX(sequence), 0) + 1 FROM workflow_run_events WHERE run_id = ?;",
                [.uuid(runID)])
            let evtSeq = Int(evtSeqRows.first?.int(0) ?? 1)
            try db.exec("""
                INSERT INTO workflow_run_events
                    (id, run_id, sequence, run_revision, type, actor_kind,
                     actor_identifier, payload_json, occurred_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [
                    .uuid(eventID), .uuid(runID),
                    .integer(Int64(evtSeq)), .integer(Int64(newRevision)),
                    .text(WorkflowRunEventType.stepRunUpdated.rawValue),
                    .text(actorKind.rawValue), .optionalText(actorIdentifier),
                    .text("{}"), .date(now)
                ])
        }

        return try await reopen(runID)
    }

    // MARK: - Insert decision

    @discardableResult
    public func insertDecision(
        runID: UUID,
        stepRunID: UUID,
        decisionKey: String,
        kind: WorkflowDecisionKind,
        selectedOption: String,
        rationale: String?,
        actorKind: WorkflowDecisionActorKind,
        actorIdentifier: String?,
        supersedesDecisionID: UUID?,
        metadataJSON: String,
        expectedRevision: Int,
        now: Date
    ) async throws -> ReopenedWorkflowRun {
        // Human decisions require a non-blank actor identifier
        if kind == .humanDecision || kind == .humanApproval {
            guard actorKind == .human, let id = actorIdentifier, !id.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw WorkflowRunRepositoryError.humanDecisionMissingActorIdentifier
            }
        }

        let decisionID = UUID()
        let eventID = UUID()
        let sp = "wfr_dec_\(decisionID.uuidString.replacingOccurrences(of: "-", with: ""))"

        try await database.withSavepoint(sp) { db in
            try db.exec("""
                UPDATE workflow_runs
                   SET revision = revision + 1, updated_at = ?
                 WHERE id = ? AND revision = ?;
                """, [.date(now), .uuid(runID), .integer(Int64(expectedRevision))])
            let changes = try db.query("SELECT changes();", [])
            guard Int(changes.first?.int(0) ?? 0) == 1 else {
                throw WorkflowRunRepositoryError.revisionConflict(runID, expected: expectedRevision)
            }
            let newRevision = expectedRevision + 1

            try db.exec("""
                INSERT INTO workflow_decisions
                    (id, run_id, step_run_id, decision_key, kind, selected_option,
                     rationale, actor_kind, actor_identifier, supersedes_decision_id,
                     metadata_json, decided_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?);
                """, [
                    .uuid(decisionID), .uuid(runID), .uuid(stepRunID),
                    .text(decisionKey), .text(kind.rawValue), .text(selectedOption),
                    .optionalText(rationale),
                    .text(actorKind.rawValue), .optionalText(actorIdentifier),
                    supersedesDecisionID.map { SQLValue.uuid($0) } ?? .null,
                    .text(metadataJSON), .date(now)
                ])

            let evtSeqRows = try db.query(
                "SELECT COALESCE(MAX(sequence), 0) + 1 FROM workflow_run_events WHERE run_id = ?;",
                [.uuid(runID)])
            let evtSeq = Int(evtSeqRows.first?.int(0) ?? 1)
            try db.exec("""
                INSERT INTO workflow_run_events
                    (id, run_id, sequence, run_revision, type, actor_kind,
                     actor_identifier, payload_json, occurred_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [
                    .uuid(eventID), .uuid(runID),
                    .integer(Int64(evtSeq)), .integer(Int64(newRevision)),
                    .text(WorkflowRunEventType.decisionRecorded.rawValue),
                    .text(actorKind.rawValue), .optionalText(actorIdentifier),
                    .text("{}"), .date(now)
                ])
        }

        return try await reopen(runID)
    }

    // MARK: - Record artifact

    @discardableResult
    public func recordArtifact(
        runID: UUID,
        stepRunID: UUID?,
        artifactDefinitionID: String,
        kind: WorkflowArtifactKind,
        label: String,
        workProductRunID: UUID?,
        targetKind: String?,
        targetID: String?,
        referenceURI: String?,
        mediaType: String?,
        contentSHA256: String?,
        metadataJSON: String,
        supersedesArtifactID: UUID?,
        expectedRevision: Int,
        actorKind: WorkflowDecisionActorKind,
        actorIdentifier: String?,
        now: Date
    ) async throws -> ReopenedWorkflowRun {
        let artifactID = UUID()
        let eventID = UUID()
        let sp = "wfr_art_\(artifactID.uuidString.replacingOccurrences(of: "-", with: ""))"

        try await database.withSavepoint(sp) { db in
            try db.exec("""
                UPDATE workflow_runs
                   SET revision = revision + 1, updated_at = ?
                 WHERE id = ? AND revision = ?;
                """, [.date(now), .uuid(runID), .integer(Int64(expectedRevision))])
            let changes = try db.query("SELECT changes();", [])
            guard Int(changes.first?.int(0) ?? 0) == 1 else {
                throw WorkflowRunRepositoryError.revisionConflict(runID, expected: expectedRevision)
            }
            let newRevision = expectedRevision + 1

            try db.exec("""
                INSERT INTO workflow_artifacts
                    (id, run_id, step_run_id, artifact_definition_id, kind, label,
                     work_product_run_id, target_kind, target_id, reference_uri,
                     media_type, content_sha256, metadata_json,
                     supersedes_artifact_id, created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [
                    .uuid(artifactID), .uuid(runID),
                    stepRunID.map { SQLValue.uuid($0) } ?? .null,
                    .text(artifactDefinitionID), .text(kind.rawValue), .text(label),
                    workProductRunID.map { SQLValue.uuid($0) } ?? .null,
                    .optionalText(targetKind), .optionalText(targetID), .optionalText(referenceURI),
                    .optionalText(mediaType), .optionalText(contentSHA256),
                    .text(metadataJSON),
                    supersedesArtifactID.map { SQLValue.uuid($0) } ?? .null,
                    .date(now)
                ])

            let evtSeqRows = try db.query(
                "SELECT COALESCE(MAX(sequence), 0) + 1 FROM workflow_run_events WHERE run_id = ?;",
                [.uuid(runID)])
            let evtSeq = Int(evtSeqRows.first?.int(0) ?? 1)
            try db.exec("""
                INSERT INTO workflow_run_events
                    (id, run_id, sequence, run_revision, type, actor_kind,
                     actor_identifier, payload_json, occurred_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [
                    .uuid(eventID), .uuid(runID),
                    .integer(Int64(evtSeq)), .integer(Int64(newRevision)),
                    .text(WorkflowRunEventType.artifactRecorded.rawValue),
                    .text(actorKind.rawValue), .optionalText(actorIdentifier),
                    .text("{}"), .date(now)
                ])
        }

        return try await reopen(runID)
    }

    // MARK: - Create attention item

    @discardableResult
    public func createAttentionItem(
        runID: UUID,
        stepRunID: UUID?,
        sourceKind: WorkflowAttentionSourceKind,
        sourceID: String?,
        severity: WorkflowAttentionSeverity,
        title: String,
        detail: String?,
        expectedRevision: Int,
        actorKind: WorkflowDecisionActorKind,
        actorIdentifier: String?,
        now: Date
    ) async throws -> ReopenedWorkflowRun {
        let itemID = UUID()
        let eventID = UUID()
        let sp = "wfr_att_\(itemID.uuidString.replacingOccurrences(of: "-", with: ""))"

        try await database.withSavepoint(sp) { db in
            try db.exec("""
                UPDATE workflow_runs
                   SET revision = revision + 1, updated_at = ?
                 WHERE id = ? AND revision = ?;
                """, [.date(now), .uuid(runID), .integer(Int64(expectedRevision))])
            let changes = try db.query("SELECT changes();", [])
            guard Int(changes.first?.int(0) ?? 0) == 1 else {
                throw WorkflowRunRepositoryError.revisionConflict(runID, expected: expectedRevision)
            }
            let newRevision = expectedRevision + 1

            try db.exec("""
                INSERT INTO workflow_attention_items
                    (id, run_id, step_run_id, source_kind, source_id, severity, status,
                     title, detail, created_at, resolved_at, resolved_by, resolution_note)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [
                    .uuid(itemID), .uuid(runID),
                    stepRunID.map { SQLValue.uuid($0) } ?? .null,
                    .text(sourceKind.rawValue), .optionalText(sourceID),
                    .text(severity.rawValue),
                    .text(WorkflowAttentionStatus.open.rawValue),
                    .text(title), .optionalText(detail),
                    .date(now), .null, .null, .null
                ])

            let evtSeqRows = try db.query(
                "SELECT COALESCE(MAX(sequence), 0) + 1 FROM workflow_run_events WHERE run_id = ?;",
                [.uuid(runID)])
            let evtSeq = Int(evtSeqRows.first?.int(0) ?? 1)
            try db.exec("""
                INSERT INTO workflow_run_events
                    (id, run_id, sequence, run_revision, type, actor_kind,
                     actor_identifier, payload_json, occurred_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [
                    .uuid(eventID), .uuid(runID),
                    .integer(Int64(evtSeq)), .integer(Int64(newRevision)),
                    .text(WorkflowRunEventType.attentionCreated.rawValue),
                    .text(actorKind.rawValue), .optionalText(actorIdentifier),
                    .text("{}"), .date(now)
                ])
        }

        return try await reopen(runID)
    }

    // MARK: - Resolve attention item

    @discardableResult
    public func resolveAttentionItem(
        attentionItemID: UUID,
        runID: UUID,
        newStatus: WorkflowAttentionStatus,
        resolvedBy: String?,
        resolutionNote: String?,
        expectedRevision: Int,
        actorKind: WorkflowDecisionActorKind,
        actorIdentifier: String?,
        now: Date
    ) async throws -> ReopenedWorkflowRun {
        let eventID = UUID()
        let sp = "wfr_attup_\(attentionItemID.uuidString.replacingOccurrences(of: "-", with: ""))\(expectedRevision)"

        try await database.withSavepoint(sp) { db in
            try db.exec("""
                UPDATE workflow_runs
                   SET revision = revision + 1, updated_at = ?
                 WHERE id = ? AND revision = ?;
                """, [.date(now), .uuid(runID), .integer(Int64(expectedRevision))])
            let changes = try db.query("SELECT changes();", [])
            guard Int(changes.first?.int(0) ?? 0) == 1 else {
                throw WorkflowRunRepositoryError.revisionConflict(runID, expected: expectedRevision)
            }
            let newRevision = expectedRevision + 1

            try db.exec("""
                UPDATE workflow_attention_items
                   SET status = ?, resolved_at = ?, resolved_by = ?, resolution_note = ?
                 WHERE id = ? AND run_id = ?;
                """, [
                    .text(newStatus.rawValue), .date(now),
                    .optionalText(resolvedBy), .optionalText(resolutionNote),
                    .uuid(attentionItemID), .uuid(runID)
                ])

            let evtSeqRows = try db.query(
                "SELECT COALESCE(MAX(sequence), 0) + 1 FROM workflow_run_events WHERE run_id = ?;",
                [.uuid(runID)])
            let evtSeq = Int(evtSeqRows.first?.int(0) ?? 1)
            try db.exec("""
                INSERT INTO workflow_run_events
                    (id, run_id, sequence, run_revision, type, actor_kind,
                     actor_identifier, payload_json, occurred_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [
                    .uuid(eventID), .uuid(runID),
                    .integer(Int64(evtSeq)), .integer(Int64(newRevision)),
                    .text(WorkflowRunEventType.attentionUpdated.rawValue),
                    .text(actorKind.rawValue), .optionalText(actorIdentifier),
                    .text("{}"), .date(now)
                ])
        }

        return try await reopen(runID)
    }

    // MARK: - Create checkpoint

    /// Build a canonical checkpoint from the current persisted aggregate state.
    /// The checkpoint JSON is created by the repository from the DB — not supplied by the caller.
    @discardableResult
    public func createCheckpoint(
        runID: UUID,
        reason: WorkflowCheckpointReason,
        expectedRevision: Int,
        actorKind: WorkflowDecisionActorKind,
        actorIdentifier: String?,
        now: Date
    ) async throws -> ReopenedWorkflowRun {
        let checkpointID = UUID()
        let eventID = UUID()
        let sp = "wfr_ckpt_\(checkpointID.uuidString.replacingOccurrences(of: "-", with: ""))"

        try await database.withSavepoint(sp) { db in
            // CAS
            try db.exec("""
                UPDATE workflow_runs
                   SET revision = revision + 1, updated_at = ?
                 WHERE id = ? AND revision = ?;
                """, [.date(now), .uuid(runID), .integer(Int64(expectedRevision))])
            let changes = try db.query("SELECT changes();", [])
            guard Int(changes.first?.int(0) ?? 0) == 1 else {
                throw WorkflowRunRepositoryError.revisionConflict(runID, expected: expectedRevision)
            }
            let newRevision = expectedRevision + 1

            // Build checkpoint payload from persisted aggregate state inside the SAVEPOINT
            let runRows = try db.query("""
                SELECT id, workspace_id, application_definition_id, application_definition_version,
                       workflow_definition_id, workflow_definition_version, title, status,
                       current_step_definition_id, current_step_run_id,
                       contract_snapshot_json, contract_snapshot_sha256, snapshot_schema_version,
                       revision, parent_run_id, superseded_by_run_id,
                       created_at, updated_at, started_at, paused_at, completed_at,
                       cancelled_at, cancellation_reason
                FROM workflow_runs WHERE id = ?;
                """, [.uuid(runID)])
            guard let runRow = runRows.first, let run = Self.decodeRun(runRow) else {
                throw WorkflowRunRepositoryError.runNotFound(runID)
            }

            let stepRows = try db.query("""
                SELECT id, run_id, step_definition_id, step_kind, attempt, sequence,
                       status, executor_id, executor_version, input_json, state_json,
                       output_json, state_sha256, entered_at, updated_at, completed_at
                FROM workflow_step_runs WHERE run_id = ? ORDER BY sequence ASC;
                """, [.uuid(runID)])
            let stepRuns = stepRows.compactMap { Self.decodeStepRun($0) }

            let decisionRows = try db.query("""
                SELECT id, run_id, step_run_id, decision_key, kind, selected_option,
                       rationale, actor_kind, actor_identifier, supersedes_decision_id,
                       metadata_json, decided_at
                FROM workflow_decisions WHERE run_id = ? ORDER BY decided_at ASC;
                """, [.uuid(runID)])
            let decisions = decisionRows.compactMap { Self.decodeDecision($0) }

            let artifactRows = try db.query("""
                SELECT id, run_id, step_run_id, artifact_definition_id, kind, label,
                       work_product_run_id, target_kind, target_id, reference_uri,
                       media_type, content_sha256, metadata_json,
                       supersedes_artifact_id, created_at
                FROM workflow_artifacts WHERE run_id = ? ORDER BY created_at ASC;
                """, [.uuid(runID)])
            let artifacts = artifactRows.compactMap { Self.decodeArtifact($0) }

            let attentionRows = try db.query("""
                SELECT id, run_id, step_run_id, source_kind, source_id, severity, status,
                       title, detail, created_at, resolved_at, resolved_by, resolution_note
                FROM workflow_attention_items WHERE run_id = ? ORDER BY created_at ASC;
                """, [.uuid(runID)])
            let attentionItems = attentionRows.compactMap { Self.decodeAttentionItem($0) }

            let eventRows = try db.query("""
                SELECT id, run_id, sequence, run_revision, type, actor_kind,
                       actor_identifier, payload_json, occurred_at
                FROM workflow_run_events WHERE run_id = ? ORDER BY sequence ASC;
                """, [.uuid(runID)])
            let events = eventRows.compactMap { Self.decodeEvent($0) }

            let payload = WorkflowCheckpointPayload(
                run: run,
                stepRuns: stepRuns,
                decisions: decisions,
                artifacts: artifacts,
                attentionItems: attentionItems,
                events: events,
                lastEventSequence: events.last?.sequence ?? 0,
                runRevision: newRevision
            )

            let encodedCheckpoint = try WorkflowRunSnapshotCodec().encodeCheckpoint(payload)

            try db.exec("""
                INSERT INTO workflow_checkpoints
                    (id, run_id, run_revision, reason, snapshot_json, snapshot_sha256, created_at)
                VALUES (?,?,?,?,?,?,?);
                """, [
                    .uuid(checkpointID), .uuid(runID),
                    .integer(Int64(newRevision)),
                    .text(reason.rawValue),
                    .text(encodedCheckpoint.json), .text(encodedCheckpoint.sha256),
                    .date(now)
                ])

            let evtSeqRows = try db.query(
                "SELECT COALESCE(MAX(sequence), 0) + 1 FROM workflow_run_events WHERE run_id = ?;",
                [.uuid(runID)])
            let evtSeq = Int(evtSeqRows.first?.int(0) ?? 1)
            try db.exec("""
                INSERT INTO workflow_run_events
                    (id, run_id, sequence, run_revision, type, actor_kind,
                     actor_identifier, payload_json, occurred_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [
                    .uuid(eventID), .uuid(runID),
                    .integer(Int64(evtSeq)), .integer(Int64(newRevision)),
                    .text(WorkflowRunEventType.checkpointCreated.rawValue),
                    .text(actorKind.rawValue), .optionalText(actorIdentifier),
                    .text("{}"), .date(now)
                ])
        }

        return try await reopen(runID)
    }

    // MARK: - Link supersession

    @discardableResult
    public func linkSupersession(
        runID: UUID,
        supersededByRunID: UUID,
        expectedRevision: Int,
        actorKind: WorkflowDecisionActorKind,
        actorIdentifier: String?,
        now: Date
    ) async throws -> ReopenedWorkflowRun {
        guard runID != supersededByRunID else {
            throw WorkflowRunRepositoryError.supersededRunLinkConflict(runID: runID)
        }

        let eventID = UUID()
        let sp = "wfr_sup_\(runID.uuidString.replacingOccurrences(of: "-", with: ""))\(expectedRevision)"

        try await database.withSavepoint(sp) { db in
            try db.exec("""
                UPDATE workflow_runs
                   SET revision = revision + 1, superseded_by_run_id = ?, updated_at = ?
                 WHERE id = ? AND revision = ? AND superseded_by_run_id IS NULL;
                """, [.uuid(supersededByRunID), .date(now),
                      .uuid(runID), .integer(Int64(expectedRevision))])
            let changes = try db.query("SELECT changes();", [])
            guard Int(changes.first?.int(0) ?? 0) == 1 else {
                // Could be revision conflict OR already superseded; check revision
                let revRows = try db.query(
                    "SELECT revision FROM workflow_runs WHERE id = ?;", [.uuid(runID)])
                if let rev = revRows.first?.int(0), Int(rev) != expectedRevision {
                    throw WorkflowRunRepositoryError.revisionConflict(runID, expected: expectedRevision)
                }
                throw WorkflowRunRepositoryError.supersededRunLinkConflict(runID: runID)
            }
            let newRevision = expectedRevision + 1

            let evtSeqRows = try db.query(
                "SELECT COALESCE(MAX(sequence), 0) + 1 FROM workflow_run_events WHERE run_id = ?;",
                [.uuid(runID)])
            let evtSeq = Int(evtSeqRows.first?.int(0) ?? 1)
            try db.exec("""
                INSERT INTO workflow_run_events
                    (id, run_id, sequence, run_revision, type, actor_kind,
                     actor_identifier, payload_json, occurred_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [
                    .uuid(eventID), .uuid(runID),
                    .integer(Int64(evtSeq)), .integer(Int64(newRevision)),
                    .text(WorkflowRunEventType.runSupersessionLinked.rawValue),
                    .text(actorKind.rawValue), .optionalText(actorIdentifier),
                    .text("{}"), .date(now)
                ])
        }

        return try await reopen(runID)
    }

    // MARK: - Delete

    /// Delete a run and cascade to all its child rows. Never touches the ledger, claims, or entities.
    public func delete(_ runID: UUID) async throws {
        try await database.exec("DELETE FROM workflow_runs WHERE id = ?;", [.uuid(runID)])
    }

    // MARK: - Reads

    /// Reopen the full aggregate for a run. Verifies contract hash + invariants.
    public func fetchRun(_ runID: UUID) async throws -> ReopenedWorkflowRun {
        try await reopen(runID)
    }

    /// Return run IDs for a workspace, ordered by created_at DESC.
    public func fetchRunIDs(workspaceID: Workspace.ID, limit: Int = 100) async throws -> [UUID] {
        let rows = try await database.query("""
            SELECT id FROM workflow_runs WHERE workspace_id = ?
             ORDER BY created_at DESC LIMIT ?;
            """, [.uuid(workspaceID), .integer(Int64(limit))])
        return rows.compactMap { $0.uuid(0) }
    }

    /// Return run IDs for a workspace + application, ordered by created_at DESC.
    public func fetchRunIDs(
        workspaceID: Workspace.ID,
        applicationDefinitionID: ApplicationDefinitionID,
        status: WorkflowRunStatus? = nil,
        limit: Int = 100
    ) async throws -> [UUID] {
        if let status {
            let rows = try await database.query("""
                SELECT id FROM workflow_runs
                 WHERE workspace_id = ? AND application_definition_id = ? AND status = ?
                 ORDER BY created_at DESC LIMIT ?;
                """, [.uuid(workspaceID), .text(applicationDefinitionID.rawValue),
                      .text(status.rawValue), .integer(Int64(limit))])
            return rows.compactMap { $0.uuid(0) }
        } else {
            let rows = try await database.query("""
                SELECT id FROM workflow_runs
                 WHERE workspace_id = ? AND application_definition_id = ?
                 ORDER BY created_at DESC LIMIT ?;
                """, [.uuid(workspaceID), .text(applicationDefinitionID.rawValue),
                      .integer(Int64(limit))])
            return rows.compactMap { $0.uuid(0) }
        }
    }

    // MARK: - Private: reopen

    private func reopen(_ runID: UUID) async throws -> ReopenedWorkflowRun {
        let runRows = try await database.query("""
            SELECT id, workspace_id, application_definition_id, application_definition_version,
                   workflow_definition_id, workflow_definition_version, title, status,
                   current_step_definition_id, current_step_run_id,
                   contract_snapshot_json, contract_snapshot_sha256, snapshot_schema_version,
                   revision, parent_run_id, superseded_by_run_id,
                   created_at, updated_at, started_at, paused_at, completed_at,
                   cancelled_at, cancellation_reason
            FROM workflow_runs WHERE id = ?;
            """, [.uuid(runID)])
        guard let runRow = runRows.first, let run = Self.decodeRun(runRow) else {
            throw WorkflowRunRepositoryError.runNotFound(runID)
        }

        // Verify contract hash
        let contract = try codec.decode(
            json: run.contractSnapshotJSON,
            expectedSHA256: run.contractSnapshotSHA256
        )

        let stepRows = try await database.query("""
            SELECT id, run_id, step_definition_id, step_kind, attempt, sequence,
                   status, executor_id, executor_version, input_json, state_json,
                   output_json, state_sha256, entered_at, updated_at, completed_at,
                   state_hash_semantics
            FROM workflow_step_runs WHERE run_id = ? ORDER BY sequence ASC;
            """, [.uuid(runID)])
        let stepRuns = stepRows.compactMap { Self.decodeStepRun($0) }

        // PJE-006B.1: verify step-state integrity per each row's RECORDED semantics.
        // storedUTF8BytesV1 — strict: stored hash must equal SHA-256 of the exact stored bytes.
        // legacyCanonicalizedJSON — best-effort only: legacy rows were written under mixed
        //   historical algorithms and were never enforced at reopen; they are never mutated
        //   here and upgrade only on the next legitimate state mutation.
        for row in stepRows {
            guard
                let stepRunID = row.uuid(0),
                let stateJSON = row.string(10),
                let storedHash = row.string(12),
                let semanticsRaw = row.string(16),
                let semantics = WorkflowStepStateHashSemantics(rawValue: semanticsRaw)
            else { continue }
            if semantics == .storedUTF8BytesV1 {
                let computed = WorkflowPersistedJSONIntegrity.rawSHA256(of: stateJSON)
                guard computed == storedHash else {
                    throw WorkflowRunRepositoryError.stepStateHashMismatch(
                        stepRunID: stepRunID, stored: storedHash, computed: computed)
                }
            }
        }

        let decisionRows = try await database.query("""
            SELECT id, run_id, step_run_id, decision_key, kind, selected_option,
                   rationale, actor_kind, actor_identifier, supersedes_decision_id,
                   metadata_json, decided_at
            FROM workflow_decisions WHERE run_id = ? ORDER BY decided_at ASC;
            """, [.uuid(runID)])
        let decisions = decisionRows.compactMap { Self.decodeDecision($0) }

        let artifactRows = try await database.query("""
            SELECT id, run_id, step_run_id, artifact_definition_id, kind, label,
                   work_product_run_id, target_kind, target_id, reference_uri,
                   media_type, content_sha256, metadata_json,
                   supersedes_artifact_id, created_at
            FROM workflow_artifacts WHERE run_id = ? ORDER BY created_at ASC;
            """, [.uuid(runID)])
        let artifacts = artifactRows.compactMap { Self.decodeArtifact($0) }

        let checkpointRows = try await database.query("""
            SELECT id, run_id, run_revision, reason, snapshot_json, snapshot_sha256, created_at
            FROM workflow_checkpoints WHERE run_id = ? ORDER BY run_revision ASC;
            """, [.uuid(runID)])
        let checkpoints = checkpointRows.compactMap { Self.decodeCheckpoint($0) }

        let attentionRows = try await database.query("""
            SELECT id, run_id, step_run_id, source_kind, source_id, severity, status,
                   title, detail, created_at, resolved_at, resolved_by, resolution_note
            FROM workflow_attention_items WHERE run_id = ? ORDER BY created_at ASC;
            """, [.uuid(runID)])
        let attentionItems = attentionRows.compactMap { Self.decodeAttentionItem($0) }

        let eventRows = try await database.query("""
            SELECT id, run_id, sequence, run_revision, type, actor_kind,
                   actor_identifier, payload_json, occurred_at
            FROM workflow_run_events WHERE run_id = ? ORDER BY sequence ASC;
            """, [.uuid(runID)])
        let events = eventRows.compactMap { Self.decodeEvent($0) }

        // Invariant: revision == event count
        guard run.revision == events.count else {
            throw WorkflowRunRepositoryError.revisionEventMismatch(
                runID: runID, revision: run.revision, eventCount: events.count
            )
        }

        // Latest checkpoint hash verification
        if let latest = checkpoints.last {
            guard let checkpointData = latest.snapshotJSON.data(using: .utf8) else {
                throw WorkflowRunRepositoryError.reopenFailed(runID: runID, reason: "checkpoint JSON not UTF-8")
            }
            let computed = WorkflowRunSnapshotCodec.hashString(checkpointData)
            guard computed == latest.snapshotSHA256 else {
                throw WorkflowRunRepositoryError.checkpointHashMismatch(
                    checkpointID: latest.id,
                    stored: latest.snapshotSHA256,
                    computed: computed
                )
            }
        }

        return ReopenedWorkflowRun(
            run: run, contract: contract,
            stepRuns: stepRuns, decisions: decisions,
            artifacts: artifacts, checkpoints: checkpoints,
            attentionItems: attentionItems, events: events
        )
    }

    // MARK: - Private: row decoders

    private nonisolated static func decodeRun(_ r: SQLRow) -> WorkflowRun? {
        guard let id = r.uuid(0),
              let wsID = r.uuid(1),
              let appID = r.string(2),
              let appVer = r.int(3),
              let wfID = r.string(4),
              let wfVer = r.int(5),
              let statusRaw = r.string(7),
              let status = WorkflowRunStatus(rawValue: statusRaw),
              let snapshotJSON = r.string(10),
              let snapshotSHA = r.string(11),
              let snapVer = r.int(12),
              let revision = r.int(13),
              let createdAt = r.date(16),
              let updatedAt = r.date(17)
        else { return nil }

        return WorkflowRun(
            id: id, workspaceID: wsID,
            applicationDefinitionID: ApplicationDefinitionID(rawValue: appID),
            applicationDefinitionVersion: Int(appVer),
            workflowDefinitionID: WorkflowDefinitionID(rawValue: wfID),
            workflowDefinitionVersion: Int(wfVer),
            title: r.string(6),
            status: status,
            currentStepDefinitionID: r.string(8).map { StepDefinitionID(rawValue: $0) },
            currentStepRunID: r.uuid(9),
            contractSnapshotJSON: snapshotJSON,
            contractSnapshotSHA256: snapshotSHA,
            snapshotSchemaVersion: Int(snapVer),
            revision: Int(revision),
            parentRunID: r.uuid(14),
            supersededByRunID: r.uuid(15),
            createdAt: createdAt, updatedAt: updatedAt,
            startedAt: r.date(18), pausedAt: r.date(19),
            completedAt: r.date(20), cancelledAt: r.date(21),
            cancellationReason: r.string(22)
        )
    }

    private nonisolated static func decodeStepRun(_ r: SQLRow) -> WorkflowStepRun? {
        guard let id = r.uuid(0),
              let runID = r.uuid(1),
              let stepDefID = r.string(2),
              let stepKindRaw = r.string(3),
              let stepKind = WorkflowStepKind(rawValue: stepKindRaw),
              let attempt = r.int(4),
              let sequence = r.int(5),
              let statusRaw = r.string(6),
              let status = WorkflowStepRunStatus(rawValue: statusRaw),
              let inputJSON = r.string(9),
              let stateJSON = r.string(10),
              let stateSHA = r.string(12),
              let enteredAt = r.date(13),
              let updatedAt = r.date(14)
        else { return nil }

        return WorkflowStepRun(
            id: id, workflowRunID: runID,
            stepDefinitionID: StepDefinitionID(rawValue: stepDefID),
            stepKind: stepKind,
            attempt: Int(attempt), sequence: Int(sequence),
            status: status,
            executorID: r.string(7), executorVersion: r.string(8),
            inputJSON: inputJSON, stateJSON: stateJSON,
            outputJSON: r.string(11),
            stateSHA256: stateSHA,
            enteredAt: enteredAt, updatedAt: updatedAt,
            completedAt: r.date(15)
        )
    }

    private nonisolated static func decodeDecision(_ r: SQLRow) -> WorkflowDecision? {
        guard let id = r.uuid(0),
              let runID = r.uuid(1),
              let stepRunID = r.uuid(2),
              let decisionKey = r.string(3),
              let kindRaw = r.string(4),
              let kind = WorkflowDecisionKind(rawValue: kindRaw),
              let selectedOption = r.string(5),
              let actorKindRaw = r.string(7),
              let actorKind = WorkflowDecisionActorKind(rawValue: actorKindRaw),
              let metadataJSON = r.string(10),
              let decidedAt = r.date(11)
        else { return nil }

        return WorkflowDecision(
            id: id, workflowRunID: runID, stepRunID: stepRunID,
            decisionKey: decisionKey, kind: kind, selectedOption: selectedOption,
            rationale: r.string(6),
            actorKind: actorKind, actorIdentifier: r.string(8),
            supersedesDecisionID: r.uuid(9),
            metadataJSON: metadataJSON, decidedAt: decidedAt
        )
    }

    private nonisolated static func decodeArtifact(_ r: SQLRow) -> WorkflowArtifact? {
        guard let id = r.uuid(0),
              let runID = r.uuid(1),
              let artifactDefID = r.string(3),
              let kindRaw = r.string(4),
              let kind = WorkflowArtifactKind(rawValue: kindRaw),
              let label = r.string(5),
              let metadataJSON = r.string(12),
              let createdAt = r.date(14)
        else { return nil }

        return WorkflowArtifact(
            id: id, workflowRunID: runID, stepRunID: r.uuid(2),
            artifactDefinitionID: artifactDefID, kind: kind, label: label,
            workProductRunID: r.uuid(6),
            targetKind: r.string(7), targetID: r.string(8), referenceURI: r.string(9),
            mediaType: r.string(10), contentSHA256: r.string(11),
            metadataJSON: metadataJSON,
            supersedesArtifactID: r.uuid(13),
            createdAt: createdAt
        )
    }

    private nonisolated static func decodeCheckpoint(_ r: SQLRow) -> WorkflowCheckpoint? {
        guard let id = r.uuid(0),
              let runID = r.uuid(1),
              let runRevision = r.int(2),
              let reasonRaw = r.string(3),
              let reason = WorkflowCheckpointReason(rawValue: reasonRaw),
              let snapshotJSON = r.string(4),
              let snapshotSHA = r.string(5),
              let createdAt = r.date(6)
        else { return nil }

        return WorkflowCheckpoint(
            id: id, workflowRunID: runID,
            runRevision: Int(runRevision),
            reason: reason,
            snapshotJSON: snapshotJSON,
            snapshotSHA256: snapshotSHA,
            createdAt: createdAt
        )
    }

    private nonisolated static func decodeAttentionItem(_ r: SQLRow) -> WorkflowAttentionItem? {
        guard let id = r.uuid(0),
              let runID = r.uuid(1),
              let sourceKindRaw = r.string(3),
              let sourceKind = WorkflowAttentionSourceKind(rawValue: sourceKindRaw),
              let severityRaw = r.string(5),
              let severity = WorkflowAttentionSeverity(rawValue: severityRaw),
              let statusRaw = r.string(6),
              let status = WorkflowAttentionStatus(rawValue: statusRaw),
              let title = r.string(7),
              let createdAt = r.date(9)
        else { return nil }

        return WorkflowAttentionItem(
            id: id, workflowRunID: runID, stepRunID: r.uuid(2),
            sourceKind: sourceKind, sourceID: r.string(4),
            severity: severity, status: status,
            title: title, detail: r.string(8),
            createdAt: createdAt,
            resolvedAt: r.date(10), resolvedBy: r.string(11), resolutionNote: r.string(12)
        )
    }

    private nonisolated static func decodeEvent(_ r: SQLRow) -> WorkflowRunEvent? {
        guard let id = r.uuid(0),
              let runID = r.uuid(1),
              let sequence = r.int(2),
              let runRevision = r.int(3),
              let typeRaw = r.string(4),
              let type = WorkflowRunEventType(rawValue: typeRaw),
              let actorKindRaw = r.string(5),
              let actorKind = WorkflowDecisionActorKind(rawValue: actorKindRaw),
              let payloadJSON = r.string(7),
              let occurredAt = r.date(8)
        else { return nil }

        return WorkflowRunEvent(
            id: id, workflowRunID: runID,
            sequence: Int(sequence), runRevision: Int(runRevision),
            type: type, actorKind: actorKind,
            actorIdentifier: r.string(6),
            payloadJSON: payloadJSON, occurredAt: occurredAt
        )
    }
}

// MARK: - Lifecycle plan types (PJE-004)

/// Immutable description of what one lifecycle action should persist.
/// Built by WorkflowLifecycleEngine; executed atomically by applyLifecyclePlan.
public struct WorkflowLifecycleRunPatch: Sendable {
    public let newStatus: WorkflowRunStatus
    public let currentStepDefinitionID: StepDefinitionID?
    public let currentStepRunID: UUID?
    public let startedAt: Date?
    public let pausedAt: Date?
    public let completedAt: Date?
    public let cancelledAt: Date?
    public let cancellationReason: String?
    public let supersededByRunID: UUID?

    public nonisolated init(
        newStatus: WorkflowRunStatus,
        currentStepDefinitionID: StepDefinitionID?,
        currentStepRunID: UUID?,
        startedAt: Date?,
        pausedAt: Date?,
        completedAt: Date?,
        cancelledAt: Date?,
        cancellationReason: String?,
        supersededByRunID: UUID?
    ) {
        self.newStatus = newStatus
        self.currentStepDefinitionID = currentStepDefinitionID
        self.currentStepRunID = currentStepRunID
        self.startedAt = startedAt
        self.pausedAt = pausedAt
        self.completedAt = completedAt
        self.cancelledAt = cancelledAt
        self.cancellationReason = cancellationReason
        self.supersededByRunID = supersededByRunID
    }
}

public struct WorkflowLifecycleStepInsert: Sendable {
    public let id: UUID
    public let stepDefinitionID: StepDefinitionID
    public let stepKind: WorkflowStepKind
    public let attempt: Int
    public let status: WorkflowStepRunStatus
    public let inputJSON: String
    public let stateJSON: String
    public let stateSHA256: String
    public let outputJSON: String?
    public let executorID: String?
    public let executorVersion: String?
    public let completedAt: Date?

    public nonisolated init(
        id: UUID,
        stepDefinitionID: StepDefinitionID,
        stepKind: WorkflowStepKind,
        attempt: Int,
        status: WorkflowStepRunStatus,
        inputJSON: String,
        stateJSON: String,
        stateSHA256: String,
        outputJSON: String?,
        executorID: String?,
        executorVersion: String?,
        completedAt: Date?
    ) {
        self.id = id
        self.stepDefinitionID = stepDefinitionID
        self.stepKind = stepKind
        self.attempt = attempt
        self.status = status
        self.inputJSON = inputJSON
        self.stateJSON = stateJSON
        self.stateSHA256 = stateSHA256
        self.outputJSON = outputJSON
        self.executorID = executorID
        self.executorVersion = executorVersion
        self.completedAt = completedAt
    }
}

public struct WorkflowLifecycleStepPatch: Sendable {
    public let id: UUID
    public let newStatus: WorkflowStepRunStatus
    public let stateJSON: String
    public let stateSHA256: String
    public let outputJSON: String?
    public let completedAt: Date?

    public nonisolated init(
        id: UUID,
        newStatus: WorkflowStepRunStatus,
        stateJSON: String,
        stateSHA256: String,
        outputJSON: String?,
        completedAt: Date?
    ) {
        self.id = id
        self.newStatus = newStatus
        self.stateJSON = stateJSON
        self.stateSHA256 = stateSHA256
        self.outputJSON = outputJSON
        self.completedAt = completedAt
    }
}

public struct WorkflowLifecycleDecisionInsert: Sendable {
    public let id: UUID
    public let stepRunID: UUID
    public let decisionKey: String
    public let kind: WorkflowDecisionKind
    public let selectedOption: String
    public let rationale: String?
    public let actorKind: WorkflowDecisionActorKind
    public let actorIdentifier: String?
    public let supersedesDecisionID: UUID?
    public let metadataJSON: String

    public nonisolated init(
        id: UUID,
        stepRunID: UUID,
        decisionKey: String,
        kind: WorkflowDecisionKind,
        selectedOption: String,
        rationale: String?,
        actorKind: WorkflowDecisionActorKind,
        actorIdentifier: String?,
        supersedesDecisionID: UUID?,
        metadataJSON: String
    ) {
        self.id = id
        self.stepRunID = stepRunID
        self.decisionKey = decisionKey
        self.kind = kind
        self.selectedOption = selectedOption
        self.rationale = rationale
        self.actorKind = actorKind
        self.actorIdentifier = actorIdentifier
        self.supersedesDecisionID = supersedesDecisionID
        self.metadataJSON = metadataJSON
    }
}

public struct WorkflowLifecyclePlan: Sendable {
    public let runPatch: WorkflowLifecycleRunPatch
    public let stepsToInsert: [WorkflowLifecycleStepInsert]
    public let stepsToUpdate: [WorkflowLifecycleStepPatch]
    public let decisionToInsert: WorkflowLifecycleDecisionInsert?
    /// When non-nil, a checkpoint is created inside the same SAVEPOINT (no separate event).
    public let checkpointReason: WorkflowCheckpointReason?
    public let eventType: WorkflowRunEventType
    public let actorKind: WorkflowDecisionActorKind
    public let actorIdentifier: String?

    public nonisolated init(
        runPatch: WorkflowLifecycleRunPatch,
        stepsToInsert: [WorkflowLifecycleStepInsert],
        stepsToUpdate: [WorkflowLifecycleStepPatch],
        decisionToInsert: WorkflowLifecycleDecisionInsert?,
        checkpointReason: WorkflowCheckpointReason?,
        eventType: WorkflowRunEventType,
        actorKind: WorkflowDecisionActorKind,
        actorIdentifier: String?
    ) {
        self.runPatch = runPatch
        self.stepsToInsert = stepsToInsert
        self.stepsToUpdate = stepsToUpdate
        self.decisionToInsert = decisionToInsert
        self.checkpointReason = checkpointReason
        self.eventType = eventType
        self.actorKind = actorKind
        self.actorIdentifier = actorIdentifier
    }
}

// MARK: - Lifecycle persistence primitives

extension WorkflowRunRepository {

    /// Apply a lifecycle plan atomically in one SAVEPOINT.
    /// Order: CAS update → step updates → step inserts → step pointer update →
    ///        decision insert → checkpoint (if any) → one event.
    @discardableResult
    public func applyLifecyclePlan(
        runID: UUID,
        expectedRevision: Int,
        plan: WorkflowLifecyclePlan,
        now: Date
    ) async throws -> ReopenedWorkflowRun {
        let eventID = UUID()
        let runHexLC = runID.uuidString.replacingOccurrences(of: "-", with: "")
        let sp = "wfr_lc_\(runHexLC)\(expectedRevision)"

        try await database.withSavepoint(sp) { db in
            // 1. CAS update — status/timestamps only; step pointer set after insert
            try db.exec("""
                UPDATE workflow_runs
                   SET revision = revision + 1,
                       status = ?,
                       current_step_definition_id = ?,
                       started_at = ?, paused_at = ?, completed_at = ?, cancelled_at = ?,
                       cancellation_reason = ?,
                       updated_at = ?
                 WHERE id = ? AND revision = ?;
                """, [
                    .text(plan.runPatch.newStatus.rawValue),
                    plan.runPatch.currentStepDefinitionID.map { SQLValue.text($0.rawValue) } ?? .null,
                    SQLValue.optionalDate(plan.runPatch.startedAt),
                    SQLValue.optionalDate(plan.runPatch.pausedAt),
                    SQLValue.optionalDate(plan.runPatch.completedAt),
                    SQLValue.optionalDate(plan.runPatch.cancelledAt),
                    .optionalText(plan.runPatch.cancellationReason),
                    .date(now),
                    .uuid(runID), .integer(Int64(expectedRevision))
                ])
            let changes = try db.query("SELECT changes();", [])
            guard Int(changes.first?.int(0) ?? 0) == 1 else {
                throw WorkflowRunRepositoryError.revisionConflict(runID, expected: expectedRevision)
            }
            let newRevision = expectedRevision + 1

            // 2. Update existing step runs
            for patch in plan.stepsToUpdate {
                let completedAt: SQLValue = patch.completedAt.map { .date($0) } ?? .null
                let semantics = Self.hashSemantics(
                    stateJSON: patch.stateJSON, stateSHA256: patch.stateSHA256)
                try db.exec("""
                    UPDATE workflow_step_runs
                       SET status = ?, state_json = ?, state_sha256 = ?,
                           state_hash_semantics = ?,
                           output_json = ?, updated_at = ?, completed_at = ?
                     WHERE id = ? AND run_id = ?;
                    """, [
                        .text(patch.newStatus.rawValue),
                        .text(patch.stateJSON), .text(patch.stateSHA256),
                        .text(semantics.rawValue),
                        patch.outputJSON.map { SQLValue.text($0) } ?? .null,
                        .date(now), completedAt,
                        .uuid(patch.id), .uuid(runID)
                    ])
            }

            // 3. Insert new step runs
            for insert in plan.stepsToInsert {
                // Duplicate attempt guard
                let dupRows = try db.query("""
                    SELECT COUNT(*) FROM workflow_step_runs
                     WHERE run_id = ? AND step_definition_id = ? AND attempt = ?;
                    """, [.uuid(runID), .text(insert.stepDefinitionID.rawValue), .integer(Int64(insert.attempt))])
                guard Int(dupRows.first?.int(0) ?? 0) == 0 else {
                    throw WorkflowRunRepositoryError.duplicateStepAttempt(
                        runID: runID, stepDefinitionID: insert.stepDefinitionID, attempt: insert.attempt)
                }
                let seqRows = try db.query(
                    "SELECT COALESCE(MAX(sequence), 0) + 1 FROM workflow_step_runs WHERE run_id = ?;",
                    [.uuid(runID)])
                let sequence = Int(seqRows.first?.int(0) ?? 1)
                let completedAt: SQLValue = insert.completedAt.map { .date($0) } ?? .null
                let semantics = Self.hashSemantics(
                    stateJSON: insert.stateJSON, stateSHA256: insert.stateSHA256)
                try db.exec("""
                    INSERT INTO workflow_step_runs
                        (id, run_id, step_definition_id, step_kind, attempt, sequence,
                         status, executor_id, executor_version,
                         input_json, state_json, output_json, state_sha256,
                         state_hash_semantics, entered_at, updated_at, completed_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                    """, [
                        .uuid(insert.id), .uuid(runID),
                        .text(insert.stepDefinitionID.rawValue), .text(insert.stepKind.rawValue),
                        .integer(Int64(insert.attempt)), .integer(Int64(sequence)),
                        .text(insert.status.rawValue),
                        .optionalText(insert.executorID), .optionalText(insert.executorVersion),
                        .text(insert.inputJSON), .text(insert.stateJSON),
                        insert.outputJSON.map { SQLValue.text($0) } ?? .null,
                        .text(insert.stateSHA256),
                        .text(semantics.rawValue),
                        .date(now), .date(now), completedAt
                    ])
            }

            // 4. Set current_step_run_id now that the referenced row exists
            try db.exec("""
                UPDATE workflow_runs SET current_step_run_id = ? WHERE id = ?;
                """, [
                    plan.runPatch.currentStepRunID.map { SQLValue.uuid($0) } ?? .null,
                    .uuid(runID)
                ])

            // 5. Insert decision (if any)
            if let d = plan.decisionToInsert {
                try db.exec("""
                    INSERT INTO workflow_decisions
                        (id, run_id, step_run_id, decision_key, kind, selected_option,
                         rationale, actor_kind, actor_identifier, supersedes_decision_id,
                         metadata_json, decided_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?);
                    """, [
                        .uuid(d.id), .uuid(runID), .uuid(d.stepRunID),
                        .text(d.decisionKey), .text(d.kind.rawValue), .text(d.selectedOption),
                        .optionalText(d.rationale),
                        .text(d.actorKind.rawValue), .optionalText(d.actorIdentifier),
                        d.supersedesDecisionID.map { SQLValue.uuid($0) } ?? .null,
                        .text(d.metadataJSON), .date(now)
                    ])
            }

            // 6. Build and insert checkpoint (if requested) — no separate event
            if let reason = plan.checkpointReason {
                let checkpointID = UUID()
                let runRows = try db.query("""
                    SELECT id, workspace_id, application_definition_id, application_definition_version,
                           workflow_definition_id, workflow_definition_version, title, status,
                           current_step_definition_id, current_step_run_id,
                           contract_snapshot_json, contract_snapshot_sha256, snapshot_schema_version,
                           revision, parent_run_id, superseded_by_run_id,
                           created_at, updated_at, started_at, paused_at, completed_at,
                           cancelled_at, cancellation_reason
                    FROM workflow_runs WHERE id = ?;
                    """, [.uuid(runID)])
                guard let runRow = runRows.first, let run = Self.decodeRun(runRow) else {
                    throw WorkflowRunRepositoryError.runNotFound(runID)
                }
                let stepRows = try db.query("""
                    SELECT id, run_id, step_definition_id, step_kind, attempt, sequence,
                           status, executor_id, executor_version, input_json, state_json,
                           output_json, state_sha256, entered_at, updated_at, completed_at
                    FROM workflow_step_runs WHERE run_id = ? ORDER BY sequence ASC;
                    """, [.uuid(runID)])
                let stepRuns = stepRows.compactMap { Self.decodeStepRun($0) }
                let decisionRows = try db.query("""
                    SELECT id, run_id, step_run_id, decision_key, kind, selected_option,
                           rationale, actor_kind, actor_identifier, supersedes_decision_id,
                           metadata_json, decided_at
                    FROM workflow_decisions WHERE run_id = ? ORDER BY decided_at ASC;
                    """, [.uuid(runID)])
                let decisions = decisionRows.compactMap { Self.decodeDecision($0) }
                let artifactRows = try db.query("""
                    SELECT id, run_id, step_run_id, artifact_definition_id, kind, label,
                           work_product_run_id, target_kind, target_id, reference_uri,
                           media_type, content_sha256, metadata_json,
                           supersedes_artifact_id, created_at
                    FROM workflow_artifacts WHERE run_id = ? ORDER BY created_at ASC;
                    """, [.uuid(runID)])
                let artifacts = artifactRows.compactMap { Self.decodeArtifact($0) }
                let attentionRows = try db.query("""
                    SELECT id, run_id, step_run_id, source_kind, source_id, severity, status,
                           title, detail, created_at, resolved_at, resolved_by, resolution_note
                    FROM workflow_attention_items WHERE run_id = ? ORDER BY created_at ASC;
                    """, [.uuid(runID)])
                let attentionItems = attentionRows.compactMap { Self.decodeAttentionItem($0) }
                let eventRows = try db.query("""
                    SELECT id, run_id, sequence, run_revision, type, actor_kind,
                           actor_identifier, payload_json, occurred_at
                    FROM workflow_run_events WHERE run_id = ? ORDER BY sequence ASC;
                    """, [.uuid(runID)])
                let events = eventRows.compactMap { Self.decodeEvent($0) }
                let payload = WorkflowCheckpointPayload(
                    run: run, stepRuns: stepRuns, decisions: decisions,
                    artifacts: artifacts, attentionItems: attentionItems,
                    events: events,
                    lastEventSequence: events.last?.sequence ?? 0,
                    runRevision: newRevision
                )
                let encodedCheckpoint = try WorkflowRunSnapshotCodec().encodeCheckpoint(payload)
                try db.exec("""
                    INSERT INTO workflow_checkpoints
                        (id, run_id, run_revision, reason, snapshot_json, snapshot_sha256, created_at)
                    VALUES (?,?,?,?,?,?,?);
                    """, [
                        .uuid(checkpointID), .uuid(runID),
                        .integer(Int64(newRevision)),
                        .text(reason.rawValue),
                        .text(encodedCheckpoint.json), .text(encodedCheckpoint.sha256),
                        .date(now)
                    ])
            }

            // 7. One event
            let evtSeqRows = try db.query(
                "SELECT COALESCE(MAX(sequence), 0) + 1 FROM workflow_run_events WHERE run_id = ?;",
                [.uuid(runID)])
            let evtSeq = Int(evtSeqRows.first?.int(0) ?? 1)
            try db.exec("""
                INSERT INTO workflow_run_events
                    (id, run_id, sequence, run_revision, type, actor_kind,
                     actor_identifier, payload_json, occurred_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [
                    .uuid(eventID), .uuid(runID),
                    .integer(Int64(evtSeq)), .integer(Int64(newRevision)),
                    .text(plan.eventType.rawValue),
                    .text(plan.actorKind.rawValue), .optionalText(plan.actorIdentifier),
                    .text("{}"), .date(now)
                ])
        }

        return try await reopen(runID)
    }

    /// Atomically supersede an existing run and create a new draft replacement.
    /// Both the supersession update and the new run creation happen in one SAVEPOINT.
    @discardableResult
    public func applySupersession(
        runID: UUID,
        expectedRevision: Int,
        package: ResolvedPersonaApplicationPackage,
        selectedWorkflowID: WorkflowDefinitionID,
        workspaceID: Workspace.ID,
        title: String?,
        actorKind: WorkflowDecisionActorKind,
        actorIdentifier: String?,
        now: Date
    ) async throws -> WorkflowSupersessionResult {
        let contract = try WorkflowRunContractSnapshot(from: package, selectedWorkflowID: selectedWorkflowID)
        let encoded = try codec.encode(contract)
        guard let selectedValidated = package.workflows.first(where: { $0.definition.id == selectedWorkflowID }) else {
            throw WorkflowRunRepositoryError.packageWorkflowNotFound(selectedWorkflowID)
        }
        let wfVersion = selectedValidated.definition.version

        let newRunID = UUID()
        let oldEventID = UUID()
        let newEventID = UUID()
        let sp = "wfr_sup2_\(runID.uuidString.replacingOccurrences(of: "-", with: ""))\(expectedRevision)"

        try await database.withSavepoint(sp) { db in
            // 1. Create the replacement run as draft first so the FK on superseded_by_run_id
            //    is satisfied when we update the old run in step 3 (PRAGMA foreign_keys=ON).
            try db.exec("""
                INSERT INTO workflow_runs
                    (id, workspace_id, application_definition_id, application_definition_version,
                     workflow_definition_id, workflow_definition_version, title, status,
                     current_step_definition_id, current_step_run_id,
                     contract_snapshot_json, contract_snapshot_sha256, snapshot_schema_version,
                     revision, parent_run_id, superseded_by_run_id,
                     created_at, updated_at,
                     started_at, paused_at, completed_at, cancelled_at, cancellation_reason)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [
                    .uuid(newRunID), .uuid(workspaceID),
                    .text(package.applicationKey.id.rawValue),
                    .integer(Int64(package.applicationKey.version)),
                    .text(selectedWorkflowID.rawValue),
                    .integer(Int64(wfVersion)),
                    .optionalText(title),
                    .text(WorkflowRunStatus.draft.rawValue),
                    .null, .null,
                    .text(encoded.json), .text(encoded.sha256), .integer(1),
                    .integer(1),
                    .uuid(runID),
                    .null,
                    .date(now), .date(now),
                    .null, .null, .null, .null, .null
                ])

            // 2. Append runCreated event to new run
            try db.exec("""
                INSERT INTO workflow_run_events
                    (id, run_id, sequence, run_revision, type, actor_kind,
                     actor_identifier, payload_json, occurred_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [
                    .uuid(newEventID), .uuid(newRunID),
                    .integer(1), .integer(1),
                    .text(WorkflowRunEventType.runCreated.rawValue),
                    .text(actorKind.rawValue), .optionalText(actorIdentifier),
                    .text("{}"), .date(now)
                ])

            // 3. CAS the old run to superseded + set superseded_by_run_id (FK now satisfied)
            try db.exec("""
                UPDATE workflow_runs
                   SET revision = revision + 1,
                       status = ?,
                       superseded_by_run_id = ?,
                       updated_at = ?
                 WHERE id = ? AND revision = ? AND superseded_by_run_id IS NULL;
                """, [
                    .text(WorkflowRunStatus.superseded.rawValue),
                    .uuid(newRunID),
                    .date(now),
                    .uuid(runID), .integer(Int64(expectedRevision))
                ])
            let changes = try db.query("SELECT changes();", [])
            guard Int(changes.first?.int(0) ?? 0) == 1 else {
                let revRows = try db.query(
                    "SELECT revision FROM workflow_runs WHERE id = ?;", [.uuid(runID)])
                if let rev = revRows.first?.int(0), Int(rev) != expectedRevision {
                    throw WorkflowRunRepositoryError.revisionConflict(runID, expected: expectedRevision)
                }
                throw WorkflowRunRepositoryError.supersededRunLinkConflict(runID: runID)
            }
            let oldNewRevision = expectedRevision + 1

            // 4. Mark current step run as superseded (if any)
            try db.exec("""
                UPDATE workflow_step_runs
                   SET status = ?, updated_at = ?, completed_at = ?
                 WHERE run_id = ? AND status NOT IN ('completed','cancelled','superseded');
                """, [
                    .text(WorkflowStepRunStatus.superseded.rawValue),
                    .date(now), .date(now),
                    .uuid(runID)
                ])

            // 5. Append event to old run
            let oldEvtSeqRows = try db.query(
                "SELECT COALESCE(MAX(sequence), 0) + 1 FROM workflow_run_events WHERE run_id = ?;",
                [.uuid(runID)])
            let oldEvtSeq = Int(oldEvtSeqRows.first?.int(0) ?? 1)
            try db.exec("""
                INSERT INTO workflow_run_events
                    (id, run_id, sequence, run_revision, type, actor_kind,
                     actor_identifier, payload_json, occurred_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [
                    .uuid(oldEventID), .uuid(runID),
                    .integer(Int64(oldEvtSeq)), .integer(Int64(oldNewRevision)),
                    .text(WorkflowRunEventType.runSupersessionLinked.rawValue),
                    .text(actorKind.rawValue), .optionalText(actorIdentifier),
                    .text("{}"), .date(now)
                ])
        }

        let superseded = try await reopen(runID)
        let replacement = try await reopen(newRunID)
        return WorkflowSupersessionResult(superseded: superseded, replacement: replacement)
    }
}
