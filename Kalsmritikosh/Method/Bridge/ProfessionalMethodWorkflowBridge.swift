//
//  ProfessionalMethodWorkflowBridge.swift
//  Kalsmritikosh
//
//  PM-003 — the reference-only bridge connecting persisted Stage-4 MethodRun
//  aggregates to Stage-3 `.method` workflow steps. It resolves exact registered
//  definitions, validates a linked MethodRun against the exact workflow invocation
//  back-references, and builds a completed-result reference whose provenance is
//  DERIVED solely from persisted method evidence links (fail-closed through the
//  shared canonical gate). It reads and translates references only — it never
//  mutates a canonical row (Claim / evidence / entity / event / contradiction /
//  gap) or a method row (finding / review / validation). Lifecycle transitions
//  (start/pause/complete/cancel/supersede) are PM-004, NOT here.
//

import Foundation

public actor ProfessionalMethodWorkflowBridge: WorkflowProfessionalMethodRunResolving {

    let registry: ProfessionalMethodRegistry
    let repository: MethodRunRepository
    let evidenceGate: any WorkflowEvidenceReferenceGating

    public init(
        registry: ProfessionalMethodRegistry,
        repository: MethodRunRepository,
        evidenceGate: any WorkflowEvidenceReferenceGating
    ) {
        self.registry = registry
        self.repository = repository
        self.evidenceGate = evidenceGate
    }

    // MARK: - Selection

    public func validateSelection(_ selection: WorkflowProfessionalMethodSelection) async throws {
        let id = ProfessionalMethodDefinitionID(rawValue: selection.methodDefinitionID)
        guard registry.latest(id: id) != nil else {
            throw ProfessionalMethodWorkflowBridgeError.unknownMethodDefinition(selection.methodDefinitionID)
        }
        guard registry.definition(id: id, version: selection.methodDefinitionVersion) != nil else {
            throw ProfessionalMethodWorkflowBridgeError.unknownMethodVersion(
                id: selection.methodDefinitionID, version: selection.methodDefinitionVersion)
        }
    }

    // MARK: - Application-level draft-run creation

    /// The application-level path for creating a registered method run. Resolves
    /// the exact definition (rejecting unknown versions BEFORE any database write),
    /// then creates only a `.draft` run through the accepted PM-002 repository with
    /// the exact workflow invocation back-references. Not for direct executor use.
    public func createDraftRun(
        selection: WorkflowProfessionalMethodSelection,
        workspaceID: UUID,
        workflowRunID: UUID,
        workflowStepRunID: UUID,
        title: String?,
        createdBy: String,
        now: Date
    ) async throws -> WorkflowProfessionalMethodRunReference {
        try await validateSelection(selection)
        let run = try await repository.createRun(
            workspaceID: workspaceID,
            methodDefinitionID: ProfessionalMethodDefinitionID(rawValue: selection.methodDefinitionID),
            methodDefinitionVersion: selection.methodDefinitionVersion,
            workflowRunID: workflowRunID,
            workflowStepRunID: workflowStepRunID,
            title: title,
            createdBy: createdBy,
            now: now)
        return WorkflowProfessionalMethodRunReference(
            methodRunID: run.id,
            methodDefinitionID: run.methodDefinitionID.rawValue,
            methodDefinitionVersion: run.methodDefinitionVersion)
    }

    // MARK: - Linked-run validation

    public func validateLinkedRun(
        runID: UUID,
        selection: WorkflowProfessionalMethodSelection,
        workspaceID: UUID,
        workflowRunID: UUID,
        workflowStepRunID: UUID
    ) async throws -> WorkflowProfessionalMethodRunReference {
        try await validateSelection(selection)
        guard let run = try await repository.run(id: runID) else {
            throw ProfessionalMethodWorkflowBridgeError.methodRunNotFound(runID)
        }
        guard run.workspaceID == workspaceID else {
            throw ProfessionalMethodWorkflowBridgeError.workspaceMismatch(runID)
        }
        guard run.methodDefinitionID.rawValue == selection.methodDefinitionID,
              run.methodDefinitionVersion == selection.methodDefinitionVersion else {
            throw ProfessionalMethodWorkflowBridgeError.definitionMismatch(runID)
        }
        guard run.workflowRunID == workflowRunID else {
            throw ProfessionalMethodWorkflowBridgeError.workflowRunMismatch(runID)
        }
        guard run.workflowStepRunID == workflowStepRunID else {
            throw ProfessionalMethodWorkflowBridgeError.workflowStepMismatch(runID)
        }
        guard run.status != .cancelled, run.status != .superseded, run.supersededByRunID == nil else {
            throw ProfessionalMethodWorkflowBridgeError.terminalInvalidRun(runID, status: run.status.rawValue)
        }
        // A linked run may be draft/active/waitingForHuman/blocked/completed.
        // Linking must not modify it — this method performs no write.
        return WorkflowProfessionalMethodRunReference(
            methodRunID: run.id,
            methodDefinitionID: run.methodDefinitionID.rawValue,
            methodDefinitionVersion: run.methodDefinitionVersion)
    }

    // MARK: - Completed-result construction

    public func completedResult(
        runID: UUID,
        selection: WorkflowProfessionalMethodSelection,
        workspaceID: UUID,
        workflowRunID: UUID,
        workflowStepRunID: UUID,
        summary: String,
        completedBy: String,
        limitations: [String]
    ) async throws -> WorkflowProfessionalMethodResultReference {
        // All linked-run checks must hold.
        let runReference = try await validateLinkedRun(
            runID: runID, selection: selection, workspaceID: workspaceID,
            workflowRunID: workflowRunID, workflowStepRunID: workflowStepRunID)

        // Read the whole aggregate through the accepted single-snapshot path.
        guard let aggregate = try await repository.aggregate(runID: runID) else {
            throw ProfessionalMethodWorkflowBridgeError.methodRunNotFound(runID)
        }
        let run = aggregate.run
        guard run.status == .completed else {
            throw ProfessionalMethodWorkflowBridgeError.runNotCompleted(runID, status: run.status.rawValue)
        }
        guard let completedAt = run.completedAt else {
            throw ProfessionalMethodWorkflowBridgeError.missingCompletionTimestamp(runID)
        }
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProfessionalMethodWorkflowBridgeError.invalidResultNarrative("summary must not be blank")
        }
        guard !completedBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProfessionalMethodWorkflowBridgeError.invalidResultNarrative("completedBy must not be blank")
        }

        // Provenance is derived SOLELY from persisted method evidence links, in a
        // deterministic order (ordinal, then stable id). No caller-supplied
        // provenance; contradicting/contextual links are preserved, not dropped.
        let links = aggregate.evidenceLinks.sorted {
            ($0.ordinal, $0.id.uuidString) < ($1.ordinal, $1.id.uuidString)
        }
        guard !links.isEmpty else {
            throw ProfessionalMethodWorkflowBridgeError.emptyProvenance(runID)
        }
        var provenance: [WorkflowMethodProvenanceReference] = []
        for link in links {
            guard let gateKind = link.targetKind.evidenceGateKind else {
                // A workflow-output kind is not canonical evidence.
                throw ProfessionalMethodWorkflowBridgeError.deniedCanonicalReference(
                    kind: link.targetKind.rawValue, id: link.targetID)
            }
            let verdict = await evidenceGate.verdict(
                kind: gateKind, canonicalObjectID: link.targetID, workspaceID: workspaceID)
            guard verdict.isPermitted else {
                throw ProfessionalMethodWorkflowBridgeError.deniedCanonicalReference(
                    kind: link.targetKind.rawValue, id: link.targetID)
            }
            provenance.append(WorkflowMethodProvenanceReference(
                objectKind: gateKind.rawValue, canonicalObjectID: link.targetID.uuidString))
        }

        let result = WorkflowProfessionalMethodResultReference(
            run: runReference,
            completedRevision: run.revision,
            summary: summary,
            provenanceReferences: provenance,
            completedBy: completedBy,
            completedAt: completedAt,
            limitations: limitations)
        try result.validateStructure()
        return result
    }
}
