//
//  WorkflowRunRepository+Provenance.swift
//  Kalsmritikosh
//
//  PJE-007 — provenance persistence primitives, reopen verification, the
//  canonical-attachment operation, and inspection accessors.
//
//  All snapshot writes happen INSIDE the same SAVEPOINT as the state mutation
//  they describe: a provenance failure rolls back revision, state, transition,
//  decision, artifact, checkpoint and event together. No second event is ever
//  appended merely for provenance.
//

import Foundation

// MARK: - Persistence input

/// Everything the repository needs to persist one provenance snapshot inside
/// an owning SAVEPOINT. The snapshot JSON/hash are pre-encoded by
/// WorkflowProvenanceCodec; references duplicate the snapshot's ordered list
/// for row-level normalization.
public nonisolated struct WorkflowProvenancePersistenceInput: Sendable {
    public let ownerKind: WorkflowProvenanceOwnerKind
    public let ownerID: UUID
    public let producerID: String
    public let producerVersion: String
    public let sourceStateSHA256: String?
    public let snapshotJSON: String
    public let snapshotSHA256: String
    public let references: [WorkflowProvenanceReference]

    public nonisolated init(
        ownerKind: WorkflowProvenanceOwnerKind,
        ownerID: UUID,
        producerID: String,
        producerVersion: String,
        sourceStateSHA256: String?,
        snapshotJSON: String,
        snapshotSHA256: String,
        references: [WorkflowProvenanceReference]
    ) {
        self.ownerKind = ownerKind
        self.ownerID = ownerID
        self.producerID = producerID
        self.producerVersion = producerVersion
        self.sourceStateSHA256 = sourceStateSHA256
        self.snapshotJSON = snapshotJSON
        self.snapshotSHA256 = snapshotSHA256
        self.references = references
    }

    /// Build an input by encoding the snapshot with the codec (one hash rule).
    public static nonisolated func make(
        snapshot: WorkflowProvenanceSnapshot
    ) throws -> WorkflowProvenancePersistenceInput {
        let encoded = try WorkflowProvenanceCodec.encode(snapshot)
        return WorkflowProvenancePersistenceInput(
            ownerKind: snapshot.ownerKind,
            ownerID: snapshot.ownerID,
            producerID: snapshot.producerID,
            producerVersion: snapshot.producerVersion,
            sourceStateSHA256: snapshot.sourceStateSHA256,
            snapshotJSON: encoded.json,
            snapshotSHA256: encoded.sha256,
            references: snapshot.references)
    }
}

// MARK: - Row model for inspection

public nonisolated struct WorkflowProvenanceSnapshotRow: Sendable {
    public let id: UUID
    public let workflowRunID: UUID
    public let ownerKind: WorkflowProvenanceOwnerKind
    public let ownerID: UUID
    public let workflowRunRevision: Int
    public let producerID: String
    public let producerVersion: String
    public let sourceStateSHA256: String?
    public let snapshotJSON: String
    public let snapshotSHA256: String
    public let createdAt: Date
}

extension WorkflowRunRepository {

    // MARK: - Shared snapshot writer (call inside an owning SAVEPOINT)

    /// Insert one snapshot + its ordered reference rows and set the owner row's
    /// provenance_semantics to snapshotV1. Isolated-Database primitive.
    static func insertProvenance(
        _ input: WorkflowProvenancePersistenceInput,
        workflowRunID: UUID,
        newRevision: Int,
        now: Date,
        database db: isolated Database
    ) throws {
        let snapshotID = UUID()
        let stepRunID: SQLValue = input.ownerKind == .stepState ? .uuid(input.ownerID) : .null
        let artifactID: SQLValue = input.ownerKind == .artifact ? .uuid(input.ownerID) : .null
        let decisionID: SQLValue = input.ownerKind == .decision ? .uuid(input.ownerID) : .null

        try db.exec("""
            INSERT INTO workflow_provenance_snapshots
                (id, workflow_run_id, owner_kind, step_run_id, artifact_id, decision_id,
                 workflow_run_revision, producer_id, producer_version,
                 source_state_sha256, snapshot_json, snapshot_sha256, created_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [
                .uuid(snapshotID), .uuid(workflowRunID),
                .text(input.ownerKind.rawValue),
                stepRunID, artifactID, decisionID,
                .integer(Int64(newRevision)),
                .text(input.producerID), .text(input.producerVersion),
                .optionalText(input.sourceStateSHA256),
                .text(input.snapshotJSON), .text(input.snapshotSHA256),
                .date(now)
            ])

        for (ordinal, reference) in input.references.enumerated() {
            try db.exec("""
                INSERT INTO workflow_provenance_references
                    (id, snapshot_id, ordinal, reference_kind, canonical_object_id,
                     role, disposition, source_version_id, locator_json,
                     label, note, created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?);
                """, [
                    .uuid(UUID()), .uuid(snapshotID), .integer(Int64(ordinal)),
                    .text(reference.kind.rawValue), .uuid(reference.canonicalObjectID),
                    .text(reference.role.rawValue), .text(reference.disposition.rawValue),
                    reference.sourceVersionID.map { SQLValue.uuid($0) } ?? .null,
                    .optionalText(reference.locatorJSON),
                    .optionalText(reference.label), .optionalText(reference.note),
                    .date(now)
                ])
        }

        let table: String
        switch input.ownerKind {
        case .stepState: table = "workflow_step_runs"
        case .artifact:  table = "workflow_artifacts"
        case .decision:  table = "workflow_decisions"
        }
        try db.exec(
            "UPDATE \(table) SET provenance_semantics = ? WHERE id = ?;",
            [.text(WorkflowProvenanceSemantics.snapshotV1.rawValue), .uuid(input.ownerID)])
    }

    // MARK: - Reopen verification (strict for snapshotV1, never for legacy)

    /// Verify provenance integrity for one run during reopen. For every owner row
    /// marked snapshotV1: a snapshot exists, its stored-byte hash verifies, its
    /// run/revision ownership is valid, reference rows match count with continuous
    /// ordinals, and — for step owners — the LATEST snapshot's source-state hash
    /// equals the step's current state hash. legacyUntracked rows are skipped and
    /// never rewritten.
    func verifyProvenanceOnReopen(
        runID: UUID,
        runRevision: Int,
        stepRows: [(id: UUID, stateSHA256: String, semantics: String)],
        artifactSemantics: [(id: UUID, semantics: String)],
        decisionSemantics: [(id: UUID, semantics: String)]
    ) async throws {
        let snapshotRows = try await database.query("""
            SELECT id, owner_kind, step_run_id, artifact_id, decision_id,
                   workflow_run_revision, snapshot_json, snapshot_sha256, source_state_sha256
              FROM workflow_provenance_snapshots
             WHERE workflow_run_id = ?
             ORDER BY workflow_run_revision ASC;
            """, [.uuid(runID)])

        struct Row {
            let id: UUID; let ownerKind: String
            let ownerID: UUID; let revision: Int
            let json: String; let sha: String; let stateSHA: String?
        }
        var byOwner: [String: [Row]] = [:]   // "kind:ownerID" → rows (revision asc)
        for r in snapshotRows {
            guard let id = r.uuid(0), let kind = r.string(1),
                  let revision = r.int(5),
                  let json = r.string(6), let sha = r.string(7) else { continue }
            let ownerID = r.uuid(2) ?? r.uuid(3) ?? r.uuid(4)
            guard let ownerID = ownerID else { continue }
            let row = Row(id: id, ownerKind: kind, ownerID: ownerID,
                          revision: Int(revision), json: json, sha: sha,
                          stateSHA: r.string(8))
            byOwner["\(kind):\(ownerID.uuidString)", default: []].append(row)
        }

        func verifyRow(_ row: Row) async throws {
            guard WorkflowPersistedJSONIntegrity.rawSHA256(of: row.json) == row.sha else {
                throw WorkflowProvenanceError.snapshotHashMismatch(row.id)
            }
            guard row.revision >= 1, row.revision <= runRevision else {
                throw WorkflowProvenanceError.snapshotOwnerMismatch(row.id)
            }
            let refCountRows = try await database.query(
                "SELECT COUNT(*), COALESCE(MAX(ordinal), -1) FROM workflow_provenance_references WHERE snapshot_id = ?;",
                [.uuid(row.id)])
            let count = Int(refCountRows.first?.int(0) ?? -1)
            let maxOrdinal = Int(refCountRows.first?.int(1) ?? -1)
            // Continuous ordinals 0..<count
            guard maxOrdinal == count - 1 else {
                throw WorkflowProvenanceError.referenceOrdinalGap(row.id)
            }
            let snapshot = try WorkflowProvenanceCodec.decodeAndVerify(
                json: row.json, expectedSHA256: row.sha, snapshotID: row.id)
            guard snapshot.workflowRunID == runID,
                  snapshot.ownerID == row.ownerID,
                  snapshot.ownerKind.rawValue == row.ownerKind else {
                throw WorkflowProvenanceError.snapshotOwnerMismatch(row.id)
            }
            guard snapshot.references.count == count else {
                throw WorkflowProvenanceError.referenceCountMismatch(row.id)
            }
        }

        for step in stepRows where step.semantics == WorkflowProvenanceSemantics.snapshotV1.rawValue {
            let rows = byOwner["stepState:\(step.id.uuidString)"] ?? []
            guard let latest = rows.last else {
                throw WorkflowProvenanceError.snapshotMissing(ownerKind: .stepState, ownerID: step.id)
            }
            for row in rows { try await verifyRow(row) }
            // The LATEST step snapshot must describe the CURRENT persisted state.
            guard latest.stateSHA == step.stateSHA256 else {
                throw WorkflowProvenanceError.snapshotStateHashMismatch(latest.id)
            }
        }
        for artifact in artifactSemantics where artifact.semantics == WorkflowProvenanceSemantics.snapshotV1.rawValue {
            let rows = byOwner["artifact:\(artifact.id.uuidString)"] ?? []
            guard !rows.isEmpty else {
                throw WorkflowProvenanceError.snapshotMissing(ownerKind: .artifact, ownerID: artifact.id)
            }
            for row in rows { try await verifyRow(row) }
        }
        for decision in decisionSemantics where decision.semantics == WorkflowProvenanceSemantics.snapshotV1.rawValue {
            let rows = byOwner["decision:\(decision.id.uuidString)"] ?? []
            guard !rows.isEmpty else {
                throw WorkflowProvenanceError.snapshotMissing(ownerKind: .decision, ownerID: decision.id)
            }
            for row in rows { try await verifyRow(row) }
        }
    }

    // MARK: - Inspection accessors

    /// All snapshot rows for an owner (revision ascending). Access-scoped
    /// reference exposure is the inspector's job, not this accessor's.
    public func provenanceSnapshots(
        owner: WorkflowProvenanceOwner
    ) async throws -> [WorkflowProvenanceSnapshotRow] {
        let column: String
        switch owner.kind {
        case .stepState: column = "step_run_id"
        case .artifact:  column = "artifact_id"
        case .decision:  column = "decision_id"
        }
        let rows = try await database.query("""
            SELECT id, workflow_run_id, owner_kind, workflow_run_revision,
                   producer_id, producer_version, source_state_sha256,
                   snapshot_json, snapshot_sha256, created_at
              FROM workflow_provenance_snapshots
             WHERE \(column) = ?
             ORDER BY workflow_run_revision ASC;
            """, [.uuid(owner.id)])
        return rows.compactMap { r in
            guard let id = r.uuid(0), let runID = r.uuid(1),
                  let kindRaw = r.string(2), let kind = WorkflowProvenanceOwnerKind(rawValue: kindRaw),
                  let revision = r.int(3),
                  let producerID = r.string(4), let producerVersion = r.string(5),
                  let json = r.string(7), let sha = r.string(8),
                  let createdAt = r.date(9) else { return nil }
            return WorkflowProvenanceSnapshotRow(
                id: id, workflowRunID: runID, ownerKind: kind, ownerID: owner.id,
                workflowRunRevision: Int(revision),
                producerID: producerID, producerVersion: producerVersion,
                sourceStateSHA256: r.string(6),
                snapshotJSON: json, snapshotSHA256: sha, createdAt: createdAt)
        }
    }

    /// The recorded provenance semantics for an owner row (test/audit accessor).
    public func provenanceSemantics(
        owner: WorkflowProvenanceOwner
    ) async throws -> WorkflowProvenanceSemantics? {
        let table: String
        switch owner.kind {
        case .stepState: table = "workflow_step_runs"
        case .artifact:  table = "workflow_artifacts"
        case .decision:  table = "workflow_decisions"
        }
        let rows = try await database.query(
            "SELECT provenance_semantics FROM \(table) WHERE id = ?;", [.uuid(owner.id)])
        guard let raw = rows.first?.string(0) else { return nil }
        return WorkflowProvenanceSemantics(rawValue: raw)
    }

    /// The attachment binding for an attachment artifact (nil when absent).
    public func attachmentBinding(
        artifactID: UUID
    ) async throws -> WorkflowAttachmentBinding? {
        let rows = try await database.query("""
            SELECT artifact_id, logical_source_id, source_version_id,
                   parent_logical_source_id, source_relation, display_name,
                   media_type, byte_count, source_content_sha256, created_at
              FROM workflow_attachment_bindings WHERE artifact_id = ?;
            """, [.uuid(artifactID)])
        guard let r = rows.first,
              let artifact = r.uuid(0), let logical = r.uuid(1), let version = r.uuid(2),
              let displayName = r.string(5), let hash = r.string(8),
              let createdAt = r.date(9) else { return nil }
        return WorkflowAttachmentBinding(
            artifactID: artifact, logicalSourceID: logical, sourceVersionID: version,
            parentLogicalSourceID: r.uuid(3), sourceRelation: r.string(4),
            displayName: displayName, mediaType: r.string(6),
            byteCount: r.int(7).map { Int($0) },
            sourceContentSHA256: hash, createdAt: createdAt)
    }

    // MARK: - Canonical attachment (PJE-007 Part F)

    /// Test-only fault points for the atomic attachment (production passes nil).
    internal enum AttachmentFaultPoint: Sendable, Equatable {
        case afterCAS
        case afterArtifactInsert
        case afterBindingInsert
        case afterSnapshotInsert
        case beforeEventInsert
    }

    /// ONE SAVEPOINT: workflow revision CAS → artifact (.attachment, target
    /// sourceVersion, canonical media/hash) → attachment binding → provenance
    /// snapshot + one .sourceVersion/.attachmentSource reference → semantics →
    /// one .artifactRecorded event. Nothing survives a failure.
    @discardableResult
    internal func applyCanonicalAttachment(
        workflowRunID: UUID,
        expectedRevision: Int,
        artifactID: UUID,
        artifactDefinitionID: String,
        supersedesArtifactID: UUID?,
        binding: WorkflowAttachmentBinding,
        provenance: WorkflowProvenancePersistenceInput,
        actor: WorkflowLifecycleActor,
        at now: Date,
        fault: (@Sendable (AttachmentFaultPoint) throws -> Void)? = nil
    ) async throws -> ReopenedWorkflowRun {
        let eventID = UUID()
        let sp = "wfr_attach_\(artifactID.uuidString.replacingOccurrences(of: "-", with: ""))"

        try await database.withSavepoint(sp) { db in
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

            try db.exec("""
                INSERT INTO workflow_artifacts
                    (id, run_id, step_run_id, artifact_definition_id, kind, label,
                     work_product_run_id, target_kind, target_id, reference_uri,
                     media_type, content_sha256, metadata_json,
                     supersedes_artifact_id, created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [
                    .uuid(artifactID), .uuid(workflowRunID), .null,
                    .text(artifactDefinitionID),
                    .text(WorkflowArtifactKind.attachment.rawValue),
                    .text(binding.displayName),
                    .null,
                    .text("sourceVersion"), .text(binding.sourceVersionID.uuidString),
                    .null,
                    .optionalText(binding.mediaType),
                    .text(binding.sourceContentSHA256),
                    .text("{}"),
                    supersedesArtifactID.map { SQLValue.uuid($0) } ?? .null,
                    .date(now)
                ])
            try fault?(.afterArtifactInsert)

            try db.exec("""
                INSERT INTO workflow_attachment_bindings
                    (artifact_id, logical_source_id, source_version_id,
                     parent_logical_source_id, source_relation, display_name,
                     media_type, byte_count, source_content_sha256, created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?);
                """, [
                    .uuid(artifactID), .uuid(binding.logicalSourceID),
                    .uuid(binding.sourceVersionID),
                    binding.parentLogicalSourceID.map { SQLValue.uuid($0) } ?? .null,
                    .optionalText(binding.sourceRelation),
                    .text(binding.displayName),
                    .optionalText(binding.mediaType),
                    binding.byteCount.map { SQLValue.integer(Int64($0)) } ?? .null,
                    .text(binding.sourceContentSHA256),
                    .date(now)
                ])
            try fault?(.afterBindingInsert)

            try Self.insertProvenance(
                provenance, workflowRunID: workflowRunID,
                newRevision: newRevision, now: now, database: db)
            try fault?(.afterSnapshotInsert)
            try fault?(.beforeEventInsert)

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

        return try await fetchRun(workflowRunID)
    }
}

// MARK: - Attachment binding model

public nonisolated struct WorkflowAttachmentBinding: Sendable, Equatable {
    public let artifactID: UUID
    public let logicalSourceID: UUID
    public let sourceVersionID: UUID
    public let parentLogicalSourceID: UUID?
    public let sourceRelation: String?
    public let displayName: String
    public let mediaType: String?
    public let byteCount: Int?
    public let sourceContentSHA256: String
    public let createdAt: Date

    public nonisolated init(
        artifactID: UUID,
        logicalSourceID: UUID,
        sourceVersionID: UUID,
        parentLogicalSourceID: UUID?,
        sourceRelation: String?,
        displayName: String,
        mediaType: String?,
        byteCount: Int?,
        sourceContentSHA256: String,
        createdAt: Date
    ) {
        self.artifactID = artifactID
        self.logicalSourceID = logicalSourceID
        self.sourceVersionID = sourceVersionID
        self.parentLogicalSourceID = parentLogicalSourceID
        self.sourceRelation = sourceRelation
        self.displayName = displayName
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.sourceContentSHA256 = sourceContentSHA256
        self.createdAt = createdAt
    }
}
