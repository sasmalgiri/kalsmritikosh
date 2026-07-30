//
//  WorkflowAttachmentCoordinator.swift
//  Kalsmritikosh
//
//  PJE-007 Part F — the canonical attachment bridge. A workflow attachment
//  references an ALREADY-INGESTED canonical source version; PJE-007 never
//  ingests arbitrary file bytes directly:
//
//      existing ingestion path → canonical logical source → exact source
//      version → workflow attachment binding
//
//  One source store, one content hash, existing parsing/custody, existing
//  parent-child source relations (`source_relations` remains the authority),
//  no duplicate attachment bytes. Logical-source ID, content hash, media type
//  and byte count are RESOLVED from the canonical store — never accepted from
//  the caller. Corrections are append-only via artifact supersession.
//

import Foundation

// MARK: - Request

/// A request to bind an already-ingested canonical source version to the
/// current workflow run as an attachment artifact. Deliberately excludes
/// logical-source ID, content hash, media type and byte count — those are
/// resolved from the canonical source store, not trusted from the caller.
public struct WorkflowCanonicalAttachmentRequest: Codable, Hashable, Sendable {
    public let artifactDefinitionID: String
    public let sourceVersionID: UUID
    public let parentLogicalSourceID: UUID?
    public let expectedRelation: String?
    public let displayName: String

    public nonisolated init(
        artifactDefinitionID: String,
        sourceVersionID: UUID,
        parentLogicalSourceID: UUID? = nil,
        expectedRelation: String? = nil,
        displayName: String
    ) {
        self.artifactDefinitionID = artifactDefinitionID
        self.sourceVersionID = sourceVersionID
        self.parentLogicalSourceID = parentLogicalSourceID
        self.expectedRelation = expectedRelation
        self.displayName = displayName
    }
}

// MARK: - Coordinator errors (structural; integrity failures use WorkflowProvenanceError)

public enum WorkflowAttachmentError: Error, Equatable {
    case runTerminal(UUID)
    case noCurrentStep(UUID)
    case artifactDefinitionIsWorkProduct(String)
    case displayNameBlank
}

// MARK: - Coordinator

public actor WorkflowAttachmentCoordinator {

    private let workflowRuns: WorkflowRunRepository
    private let database: Database
    private let sourceRelations: SourceRelationsRepository
    private let gate: any WorkflowEvidenceReferenceGating
    private let scopes: SensitiveScopeRepository

    public init(
        workflowRuns: WorkflowRunRepository,
        database: Database,
        sourceRelations: SourceRelationsRepository,
        gate: any WorkflowEvidenceReferenceGating,
        scopes: SensitiveScopeRepository
    ) {
        self.workflowRuns = workflowRuns
        self.database = database
        self.sourceRelations = sourceRelations
        self.gate = gate
        self.scopes = scopes
    }

    /// Validate and atomically bind one canonical source version to the run.
    /// `supersedes` names a prior attachment artifact for append-only
    /// correction; the historical artifact is never overwritten or deleted.
    @discardableResult
    public func attachCanonicalSource(
        runID: UUID,
        request: WorkflowCanonicalAttachmentRequest,
        supersedes: UUID? = nil,
        actor: WorkflowLifecycleActor,
        at now: Date = Date()
    ) async throws -> ReopenedWorkflowRun {
        // 1. Run is nonterminal.
        let aggregate = try await workflowRuns.fetchRun(runID)
        switch aggregate.run.status {
        case .completed, .cancelled, .superseded:
            throw WorkflowAttachmentError.runTerminal(runID)
        case .draft, .active, .paused, .waitingForHuman, .blocked:
            break
        }

        // 2. Current step exists on the FROZEN contract.
        guard
            let validated = aggregate.contract.reconstructDefinition(),
            let currentStepDefID = aggregate.run.currentStepDefinitionID,
            let stepDef = validated.definition.steps.first(where: { $0.id == currentStepDefID })
        else {
            throw WorkflowAttachmentError.noCurrentStep(runID)
        }

        // 3–4. Artifact definition exists on the frozen current step and is
        // NOT a work-product definition.
        guard let artifactDef = stepDef.artifacts.first(where: { $0.id == request.artifactDefinitionID }) else {
            throw WorkflowProvenanceError.artifactDefinitionNotFound(request.artifactDefinitionID)
        }
        guard artifactDef.workProductTemplateID == nil else {
            throw WorkflowAttachmentError.artifactDefinitionIsWorkProduct(request.artifactDefinitionID)
        }

        // 12. Display name is nonblank (checked early — it is caller input).
        let displayName = request.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else {
            throw WorkflowAttachmentError.displayNameBlank
        }

        // Supersession target, when named, must be an existing attachment
        // artifact of THIS run. Append-only: the prior artifact is untouched.
        if let supersedes = supersedes {
            guard let prior = aggregate.artifacts.first(where: { $0.id == supersedes }) else {
                throw WorkflowProvenanceError.canonicalTargetNotFound(
                    kind: .workflowArtifact, id: supersedes)
            }
            guard prior.kind == .attachment else {
                throw WorkflowProvenanceError.artifactKindMismatch(supersedes)
            }
        }

        // 5. Exact source version exists; resolve canonical hash + media type.
        let versionRows = try await database.query("""
            SELECT sv.logical_source_id, sv.content_hash, sd.mime_type, sd.detected_type
              FROM source_versions sv
              LEFT JOIN source_documents sd ON sd.id = sv.document_id
             WHERE sv.id = ?;
            """, [.uuid(request.sourceVersionID)])
        guard let versionRow = versionRows.first,
              let logicalSourceID = versionRow.uuid(0),
              let contentHash = versionRow.string(1) else {
            throw WorkflowProvenanceError.attachmentSourceVersionNotFound(request.sourceVersionID)
        }
        let mediaType = versionRow.string(2) ?? versionRow.string(3)

        // 6. Its logical source exists; resolve canonical byte count.
        let fileRows = try await database.query(
            "SELECT size_bytes FROM files WHERE id = ?;", [.uuid(logicalSourceID)])
        guard let fileRow = fileRows.first else {
            throw WorkflowProvenanceError.attachmentLogicalSourceMismatch(logicalSourceID)
        }
        let byteCount = fileRow.int(0).map { Int($0) }

        // 7–8. Workspace boundary + SensitiveScope, through the SAME fail-closed
        // gate the evidence executors use.
        let verdict = await gate.verdict(
            kind: .sourceVersion,
            canonicalObjectID: request.sourceVersionID,
            workspaceID: aggregate.run.workspaceID)
        guard case .permitted = verdict else {
            throw WorkflowProvenanceError.attachmentAccessDenied(request.sourceVersionID)
        }

        // 9. Broken sensitivity lineage denies (explicit, in addition to the gate).
        do {
            let resolution = try await scopes.effectiveLabel(
                for: SensitiveScopeTarget(kind: .sourceVersion, id: request.sourceVersionID))
            if case .brokenLineage = resolution {
                throw WorkflowProvenanceError.attachmentAccessDenied(request.sourceVersionID)
            }
        } catch let error as WorkflowProvenanceError {
            throw error
        } catch {
            // Fail closed: unresolvable sensitivity is a denial.
            throw WorkflowProvenanceError.attachmentAccessDenied(request.sourceVersionID)
        }

        // 10–11. Parent relation, when supplied, must exist EXACTLY in
        // source_relations; the expected relation must match the stored edge.
        var resolvedRelation: String? = nil
        if let parentID = request.parentLogicalSourceID {
            let links = await sourceRelations.parents(of: logicalSourceID)
                .filter { $0.parentFileID == parentID }
            guard !links.isEmpty else {
                throw WorkflowProvenanceError.attachmentRelationMismatch(request.sourceVersionID)
            }
            if let expected = request.expectedRelation {
                guard links.contains(where: { $0.relation == expected }) else {
                    throw WorkflowProvenanceError.attachmentRelationMismatch(request.sourceVersionID)
                }
                resolvedRelation = expected
            } else {
                resolvedRelation = links.first?.relation
            }
        } else if request.expectedRelation != nil {
            // An expected relation without a parent edge cannot be verified.
            throw WorkflowProvenanceError.attachmentRelationMismatch(request.sourceVersionID)
        }

        // Binding + provenance: everything canonical comes from the resolved
        // rows above, never from the request.
        let artifactID = UUID()
        let binding = WorkflowAttachmentBinding(
            artifactID: artifactID,
            logicalSourceID: logicalSourceID,
            sourceVersionID: request.sourceVersionID,
            parentLogicalSourceID: request.parentLogicalSourceID,
            sourceRelation: resolvedRelation,
            displayName: displayName,
            mediaType: mediaType,
            byteCount: byteCount,
            sourceContentSHA256: contentHash,
            createdAt: now)
        let provenance = try WorkflowProvenancePersistenceInput.make(
            snapshot: WorkflowProvenanceSnapshot(
                ownerKind: .artifact,
                workflowRunID: runID,
                ownerID: artifactID,
                workflowRunRevision: aggregate.run.revision + 1,
                producerID: WorkflowProvenanceProducers.attachmentID,
                producerVersion: WorkflowProvenanceProducers.attachmentVersion,
                sourceStateSHA256: nil,
                references: [WorkflowProvenanceReference(
                    kind: .sourceVersion,
                    canonicalObjectID: request.sourceVersionID,
                    role: .attachmentSource,
                    sourceVersionID: request.sourceVersionID,
                    label: displayName)]))

        return try await workflowRuns.applyCanonicalAttachment(
            workflowRunID: runID,
            expectedRevision: aggregate.run.revision,
            artifactID: artifactID,
            artifactDefinitionID: request.artifactDefinitionID,
            supersedesArtifactID: supersedes,
            binding: binding,
            provenance: provenance,
            actor: actor,
            at: now)
    }
}
