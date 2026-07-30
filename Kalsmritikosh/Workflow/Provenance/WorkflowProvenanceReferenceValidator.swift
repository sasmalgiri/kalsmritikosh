//
//  WorkflowProvenanceReferenceValidator.swift
//  Kalsmritikosh
//
//  PJE-007 — defense in depth: executor-produced references are NOT trusted
//  merely because the executor already used the evidence gate. Before any
//  snapshot is persisted, every canonical reference is revalidated through
//  WorkflowEvidenceReferenceGating; workflow-output references
//  (workflowArtifact / workProductRun) are verified for existence AND ownership
//  by the same workflow/workspace. Fail closed on any mismatch.
//

import Foundation

public nonisolated struct WorkflowProvenanceReferenceValidator: Sendable {

    private let gate: any WorkflowEvidenceReferenceGating
    private let database: Database

    public nonisolated init(
        gate: any WorkflowEvidenceReferenceGating,
        database: Database
    ) {
        self.gate = gate
        self.database = database
    }

    /// Revalidate every reference. Throws WorkflowProvenanceError on the first
    /// failure; on success the references are safe to persist.
    public func validate(
        _ references: [WorkflowProvenanceReference],
        workflowRunID: UUID,
        workspaceID: UUID
    ) async throws {
        for reference in references {
            try reference.validateStructure()
            if let gateKind = reference.kind.evidenceGateKind {
                let verdict = await gate.verdict(
                    kind: gateKind,
                    canonicalObjectID: reference.canonicalObjectID,
                    workspaceID: workspaceID)
                guard case .permitted = verdict else {
                    throw WorkflowProvenanceError.referenceDenied(
                        kind: reference.kind, id: reference.canonicalObjectID)
                }
            } else {
                switch reference.kind {
                case .workflowArtifact:
                    let rows = try await database.query(
                        "SELECT run_id FROM workflow_artifacts WHERE id = ?;",
                        [.uuid(reference.canonicalObjectID)])
                    guard let owner = rows.first?.uuid(0) else {
                        throw WorkflowProvenanceError.canonicalTargetNotFound(
                            kind: .workflowArtifact, id: reference.canonicalObjectID)
                    }
                    guard owner == workflowRunID else {
                        throw WorkflowProvenanceError.crossWorkspaceReference(
                            kind: .workflowArtifact, id: reference.canonicalObjectID)
                    }
                case .workProductRun:
                    let rows = try await database.query(
                        "SELECT workspace_id FROM work_product_runs WHERE id = ?;",
                        [.uuid(reference.canonicalObjectID)])
                    guard let owner = rows.first?.uuid(0) else {
                        throw WorkflowProvenanceError.canonicalTargetNotFound(
                            kind: .workProductRun, id: reference.canonicalObjectID)
                    }
                    guard owner == workspaceID else {
                        throw WorkflowProvenanceError.crossWorkspaceReference(
                            kind: .workProductRun, id: reference.canonicalObjectID)
                    }
                default:
                    // All canonical kinds carry an evidenceGateKind — unreachable.
                    throw WorkflowProvenanceError.referenceDenied(
                        kind: reference.kind, id: reference.canonicalObjectID)
                }
            }
        }
    }
}
