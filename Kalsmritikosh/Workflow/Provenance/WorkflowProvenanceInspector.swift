//
//  WorkflowProvenanceInspector.swift
//  Kalsmritikosh
//
//  PJE-007 Part I — scoped provenance inspection. There is NO unrestricted
//  public read of provenance references: every inspection carries a
//  SensitiveAccessContext, and the CURRENT SensitiveScope is reapplied —
//  historical permission at snapshot-creation time never grants permanent
//  visibility. Denied references never expose label, note or locator; missing
//  targets stay represented as unresolved instead of being silently dropped;
//  original reference order is retained. Legacy rows report provenance as
//  unavailable — they are never rewritten or guessed.
//

import Foundation

// MARK: - Availability vocabulary

public nonisolated enum WorkflowProvenanceReferenceAvailability: Sendable, Equatable {
    case available
    case accessDenied
    case unresolved
    case brokenLineage
}

// MARK: - Inspection results

/// One reference as exposed to an inspecting caller. When access is denied
/// (or lineage is broken) the workflow annotations — label, note, locator —
/// are stripped; the reference itself stays visible so counts remain honest.
public nonisolated struct WorkflowProvenanceInspectionReference: Sendable, Equatable {
    public let kind: WorkflowProvenanceReferenceKind
    public let canonicalObjectID: UUID
    public let role: WorkflowProvenanceRole
    public let disposition: WorkflowProvenanceDisposition
    public let availability: WorkflowProvenanceReferenceAvailability
    public let sourceVersionID: UUID?
    public let locatorJSON: String?
    public let label: String?
    public let note: String?
}

public nonisolated struct WorkflowProvenanceInspection: Sendable {
    public let owner: WorkflowProvenanceOwner
    public let producerID: String
    public let producerVersion: String
    public let references: [WorkflowProvenanceInspectionReference]
    public let inaccessibleReferenceCount: Int
    public let unresolvedReferenceCount: Int
}

/// Result of inspecting one attachment artifact. Integrity violations
/// (hash/relationship/binding mismatches, scope denial) throw; a missing
/// canonical source is REPORTED as unresolved, never silently removed.
public nonisolated struct WorkflowAttachmentInspection: Sendable, Equatable {
    public let artifactID: UUID
    public let binding: WorkflowAttachmentBinding
    public let sourceAvailability: WorkflowProvenanceReferenceAvailability
}

// MARK: - Inspector

public actor WorkflowProvenanceInspector {

    private let repository: WorkflowRunRepository
    private let database: Database
    private let scopes: SensitiveScopeRepository

    public init(
        repository: WorkflowRunRepository,
        database: Database,
        scopes: SensitiveScopeRepository
    ) {
        self.repository = repository
        self.database = database
        self.scopes = scopes
    }

    // MARK: - Owner inspection

    public func inspect(
        owner: WorkflowProvenanceOwner,
        access: SensitiveAccessContext
    ) async throws -> WorkflowProvenanceInspection {
        guard let semantics = try await repository.provenanceSemantics(owner: owner) else {
            throw WorkflowProvenanceError.snapshotMissing(ownerKind: owner.kind, ownerID: owner.id)
        }
        guard semantics == .snapshotV1 else {
            throw WorkflowProvenanceError.legacyProvenanceUnavailable(owner.id)
        }
        let rows = try await repository.provenanceSnapshots(owner: owner)
        guard let latest = rows.last else {
            throw WorkflowProvenanceError.snapshotMissing(ownerKind: owner.kind, ownerID: owner.id)
        }
        let snapshot = try WorkflowProvenanceCodec.decodeAndVerify(
            json: latest.snapshotJSON,
            expectedSHA256: latest.snapshotSHA256,
            snapshotID: latest.id)
        guard snapshot.ownerID == owner.id, snapshot.ownerKind == owner.kind else {
            throw WorkflowProvenanceError.snapshotOwnerMismatch(latest.id)
        }

        let workspaceRows = try await database.query(
            "SELECT workspace_id FROM workflow_runs WHERE id = ?;",
            [.uuid(snapshot.workflowRunID)])
        guard let workspaceID = workspaceRows.first?.uuid(0) else {
            throw WorkflowProvenanceError.snapshotOwnerMismatch(latest.id)
        }

        var references: [WorkflowProvenanceInspectionReference] = []
        var inaccessible = 0
        var unresolved = 0
        for reference in snapshot.references {
            let availability = await availability(
                for: reference,
                workflowRunID: snapshot.workflowRunID,
                workspaceID: workspaceID,
                access: access)
            switch availability {
            case .accessDenied, .brokenLineage: inaccessible += 1
            case .unresolved:                   unresolved += 1
            case .available:                    break
            }
            // Denied/broken references never expose workflow annotations.
            let exposed = availability == .available || availability == .unresolved
            references.append(WorkflowProvenanceInspectionReference(
                kind: reference.kind,
                canonicalObjectID: reference.canonicalObjectID,
                role: reference.role,
                disposition: reference.disposition,
                availability: availability,
                sourceVersionID: exposed ? reference.sourceVersionID : nil,
                locatorJSON: exposed ? reference.locatorJSON : nil,
                label: exposed ? reference.label : nil,
                note: exposed ? reference.note : nil))
        }

        return WorkflowProvenanceInspection(
            owner: owner,
            producerID: snapshot.producerID,
            producerVersion: snapshot.producerVersion,
            references: references,
            inaccessibleReferenceCount: inaccessible,
            unresolvedReferenceCount: unresolved)
    }

    // MARK: - Attachment inspection

    public func inspectAttachment(
        artifactID: UUID,
        access: SensitiveAccessContext
    ) async throws -> WorkflowAttachmentInspection {
        let artifactRows = try await database.query("""
            SELECT kind, target_id, content_sha256, provenance_semantics
              FROM workflow_artifacts WHERE id = ?;
            """, [.uuid(artifactID)])
        guard let artifactRow = artifactRows.first, let kindRaw = artifactRow.string(0) else {
            throw WorkflowProvenanceError.canonicalTargetNotFound(
                kind: .workflowArtifact, id: artifactID)
        }
        guard kindRaw == WorkflowArtifactKind.attachment.rawValue else {
            throw WorkflowProvenanceError.artifactKindMismatch(artifactID)
        }
        guard artifactRow.string(3) == WorkflowProvenanceSemantics.snapshotV1.rawValue else {
            throw WorkflowProvenanceError.legacyProvenanceUnavailable(artifactID)
        }
        guard let binding = try await repository.attachmentBinding(artifactID: artifactID) else {
            throw WorkflowProvenanceError.snapshotMissing(ownerKind: .artifact, ownerID: artifactID)
        }

        // The artifact row and its binding must describe the SAME source version
        // and hash — a divergence is tampering, not a lookup miss.
        guard artifactRow.string(1) == binding.sourceVersionID.uuidString else {
            throw WorkflowProvenanceError.attachmentLogicalSourceMismatch(artifactID)
        }
        guard artifactRow.string(2) == binding.sourceContentSHA256 else {
            throw WorkflowProvenanceError.attachmentHashMismatch(artifactID)
        }

        // Missing canonical source: reported unresolved, never silently removed.
        let versionRows = try await database.query(
            "SELECT logical_source_id, content_hash FROM source_versions WHERE id = ?;",
            [.uuid(binding.sourceVersionID)])
        guard let versionRow = versionRows.first,
              let logicalSourceID = versionRow.uuid(0),
              let canonicalHash = versionRow.string(1) else {
            return WorkflowAttachmentInspection(
                artifactID: artifactID, binding: binding, sourceAvailability: .unresolved)
        }
        guard logicalSourceID == binding.logicalSourceID else {
            throw WorkflowProvenanceError.attachmentLogicalSourceMismatch(artifactID)
        }
        guard canonicalHash == binding.sourceContentSHA256 else {
            throw WorkflowProvenanceError.attachmentHashMismatch(artifactID)
        }

        // Current scope is reapplied — creation-time permission is not durable.
        do {
            let resolution = try await scopes.effectiveLabel(
                for: SensitiveScopeTarget(kind: .sourceVersion, id: binding.sourceVersionID))
            switch resolution {
            case .brokenLineage:
                throw WorkflowProvenanceError.attachmentAccessDenied(artifactID)
            case .resolved(let label):
                guard access.scope.permits(label) else {
                    throw WorkflowProvenanceError.attachmentAccessDenied(artifactID)
                }
            }
        } catch let error as WorkflowProvenanceError {
            throw error
        } catch {
            throw WorkflowProvenanceError.attachmentAccessDenied(artifactID)
        }

        // Parent relation, where recorded, must still resolve exactly.
        if let parentID = binding.parentLogicalSourceID {
            var sql = """
                SELECT COUNT(*) FROM source_relations
                 WHERE parent_file_id = ? AND child_file_id = ?
                """
            var params: [SQLValue] = [.uuid(parentID), .uuid(binding.logicalSourceID)]
            if let relation = binding.sourceRelation {
                sql += " AND relation = ?"
                params.append(.text(relation))
            }
            sql += ";"
            let relationRows = try await database.query(sql, params)
            guard Int(relationRows.first?.int(0) ?? 0) > 0 else {
                throw WorkflowProvenanceError.attachmentRelationMismatch(artifactID)
            }
        }

        return WorkflowAttachmentInspection(
            artifactID: artifactID, binding: binding, sourceAvailability: .available)
    }

    // MARK: - Per-reference availability (fail closed)

    private func availability(
        for reference: WorkflowProvenanceReference,
        workflowRunID: UUID,
        workspaceID: UUID,
        access: SensitiveAccessContext
    ) async -> WorkflowProvenanceReferenceAvailability {
        switch reference.kind {
        case .workflowArtifact:
            return await ownedRowAvailability(
                sql: "SELECT run_id FROM workflow_artifacts WHERE id = ?;",
                id: reference.canonicalObjectID, expectedOwner: workflowRunID)
        case .workProductRun:
            return await ownedRowAvailability(
                sql: "SELECT workspace_id FROM work_product_runs WHERE id = ?;",
                id: reference.canonicalObjectID, expectedOwner: workspaceID)
        case .issue:
            return await ownedRowAvailability(
                sql: "SELECT workspace_id FROM professional_issues WHERE id = ?;",
                id: reference.canonicalObjectID, expectedOwner: workspaceID)
        case .claim, .evidenceBlock, .sourceVersion, .entity, .event, .gap, .contradiction:
            do {
                try await WorkflowTargetValidator.validate(
                    kind: reference.kind.rawValue,
                    targetID: reference.canonicalObjectID,
                    workspaceID: workspaceID,
                    database: database)
            } catch WorkflowTargetValidationError.targetNotFound {
                return .unresolved
            } catch {
                return .accessDenied
            }
            guard let scopeKind = Self.scopeTargetKind(for: reference.kind) else {
                return .available   // gap / contradiction carry no sensitivity lineage
            }
            do {
                let resolution = try await scopes.effectiveLabel(
                    for: SensitiveScopeTarget(kind: scopeKind, id: reference.canonicalObjectID))
                switch resolution {
                case .brokenLineage:
                    return .brokenLineage
                case .resolved(let label):
                    return access.scope.permits(label) ? .available : .accessDenied
                }
            } catch {
                return .accessDenied
            }
        }
    }

    private func ownedRowAvailability(
        sql: String,
        id: UUID,
        expectedOwner: UUID
    ) async -> WorkflowProvenanceReferenceAvailability {
        do {
            let rows = try await database.query(sql, [.uuid(id)])
            guard let owner = rows.first?.uuid(0) else { return .unresolved }
            return owner == expectedOwner ? .available : .accessDenied
        } catch {
            return .accessDenied
        }
    }

    private static nonisolated func scopeTargetKind(
        for kind: WorkflowProvenanceReferenceKind
    ) -> SensitiveScopeTargetKind? {
        switch kind {
        case .claim:         return .claim
        case .evidenceBlock: return .evidenceBlock
        case .sourceVersion: return .sourceVersion
        case .entity:        return .entity
        case .event:         return .event
        case .issue, .gap, .contradiction, .workflowArtifact, .workProductRun:
            return nil
        }
    }
}
