//
//  WorkflowWorkProductBuildCoordinator.swift
//  Kalsmritikosh
//
//  PJE-006C — the ONLY component that turns a `.buildWorkProduct` disposition
//  into a persisted, cited work product.
//
//  It composes through the ACCEPTED WorkProductAssemblyService (whose
//  SensitiveScope and export-integrity gates fail closed), then persists the
//  immutable work-product run + workflow artifact link + step-state update +
//  one event in ONE SAVEPOINT via WorkflowRunRepository.applyWorkProductBuild.
//  No second assembly route, no second persistence store.
//

import Foundation

public enum WorkflowWorkProductBuildError: Error, Equatable {
    case runNotActive(UUID)
    case wrongCurrentStep(expected: WorkflowStepKind)
    case artifactDefinitionMissing(String)
    case workProductDefinitionMissing(String)
    case templateMismatch(artifactTemplateID: String, requested: String)
    case workspaceNotFound(UUID)
    case accessDenied
}

public actor WorkflowWorkProductBuildCoordinator {

    private let assembly: WorkProductAssemblyService
    private let workflowRuns: WorkflowRunRepository
    private let workspaces: WorkspaceRepository

    public init(
        assembly: WorkProductAssemblyService,
        workflowRuns: WorkflowRunRepository,
        workspaces: WorkspaceRepository
    ) {
        self.assembly = assembly
        self.workflowRuns = workflowRuns
        self.workspaces = workspaces
    }

    /// Perform the requested build against the CURRENT workProductBuild step.
    /// Returns the reopened aggregate; the step remains active afterwards —
    /// a later `complete` command advances once PJE-005 confirms the artifact.
    @discardableResult
    public func build(
        runID: UUID,
        request: WorkflowWorkProductBuildRequest,
        actor: WorkflowLifecycleActor,
        now: Date
    ) async throws -> ReopenedWorkflowRun {
        // 1. Reopen the workflow run.
        let aggregate = try await workflowRuns.fetchRun(runID)
        guard aggregate.run.status == .active else {
            throw WorkflowWorkProductBuildError.runNotActive(runID)
        }

        // 2. Verify current step and executor.
        guard
            let stepRunID = aggregate.run.currentStepRunID,
            let stepRun = aggregate.stepRuns.first(where: { $0.id == stepRunID }),
            stepRun.stepKind == .workProductBuild,
            stepRun.executorID == "com.kalsmritikosh.step.work-product-build"
        else {
            throw WorkflowWorkProductBuildError.wrongCurrentStep(expected: .workProductBuild)
        }
        guard
            let validated = aggregate.contract.reconstructDefinition(),
            let currentStepDefID = aggregate.run.currentStepDefinitionID,
            let stepDef = validated.definition.steps.first(where: { $0.id == currentStepDefID })
        else {
            throw WorkflowWorkProductBuildError.wrongCurrentStep(expected: .workProductBuild)
        }

        // 3. Resolve the FROZEN artifact and work-product definitions.
        guard let artifactDef = stepDef.artifacts.first(where: { $0.id == request.artifactDefinitionID }),
              let templateID = artifactDef.workProductTemplateID else {
            throw WorkflowWorkProductBuildError.artifactDefinitionMissing(request.artifactDefinitionID)
        }
        guard let wpDef = aggregate.contract.workProducts.first(where: { $0.id == request.workProductDefinitionID }) else {
            throw WorkflowWorkProductBuildError.workProductDefinitionMissing(request.workProductDefinitionID)
        }
        guard templateID == request.workProductDefinitionID else {
            throw WorkflowWorkProductBuildError.templateMismatch(
                artifactTemplateID: templateID, requested: request.workProductDefinitionID)
        }

        // Access envelope checks — the assembly service re-verifies and fails closed.
        guard request.access.scope.purpose == .export,
              request.access.scope.workspaceID == aggregate.run.workspaceID else {
            throw WorkflowWorkProductBuildError.accessDenied
        }

        // 4. Load the workspace.
        guard let workspace = try await workspaces.find(aggregate.run.workspaceID) else {
            throw WorkflowWorkProductBuildError.workspaceNotFound(aggregate.run.workspaceID)
        }

        // 5–6. Compose through the accepted assembly path; its SensitiveScope and
        // export-integrity gates fail closed (scopedAccessDenied / evidenceIntegrity).
        let assembled = try await assembly.compose(
            workspace: workspace,
            template: wpDef.template,
            subjectLabel: request.subjectLabel,
            corpusSnapshotID: request.corpusSnapshotID,
            access: request.access)

        // 7–10. New step state under the EXACT stored executor identity, persisted
        // atomically with the work-product run, artifact link, and one event.
        let workProductRunID = UUID()
        let artifactID = UUID()
        let currentState = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelope<WorkProductBuildStepState>.self,
            from: stepRun.stateJSON)
        let newState = WorkProductBuildStepState(
            status: .built,
            subjectLabel: request.subjectLabel,
            corpusSnapshotID: request.corpusSnapshotID,
            workProductRunID: workProductRunID,
            workflowArtifactID: artifactID,
            builtAt: now)
        let newEnvelope = WorkflowStepStateEnvelope(
            stepKind: .workProductBuild,
            executorID: currentState.executorID,
            executorVersion: currentState.executorVersion,
            state: newState,
            requirementFacts: currentState.requirementFacts)
        let newStateJSON = try WorkflowStepPayloadCodec.encode(newEnvelope)
        let newStateSHA = try WorkflowPersistedJSONIntegrity.sha256(storedJSON: newStateJSON)

        // 11. PJE-007: artifact provenance from the EXACT assembled product and
        // manifest — source Claim IDs, supporting/contradicting citation source
        // versions, and the manifest's source-version list. Never inferred from
        // rendered prose. Deduplicated by (kind, id, role), first occurrence wins,
        // order preserved.
        let newRevision = aggregate.run.revision + 1
        var artifactReferences: [WorkflowProvenanceReference] = []
        var seenReferenceKeys = Set<String>()
        func appendReference(_ reference: WorkflowProvenanceReference) {
            let key = "\(reference.kind.rawValue):\(reference.canonicalObjectID.uuidString):\(reference.role.rawValue)"
            guard seenReferenceKeys.insert(key).inserted else { return }
            artifactReferences.append(reference)
        }
        for section in assembled.workProduct.sections {
            for claim in section.claims {
                if let claimID = claim.sourceClaimID {
                    appendReference(WorkflowProvenanceReference(
                        kind: .claim, canonicalObjectID: claimID, role: .outputCitation))
                }
                for citation in claim.supporting {
                    guard let versionID = citation.sourceVersionID else { continue }
                    appendReference(WorkflowProvenanceReference(
                        kind: .sourceVersion, canonicalObjectID: versionID,
                        role: .supporting, sourceVersionID: versionID,
                        label: citation.displayLabel))
                }
                for citation in claim.contradicting {
                    guard let versionID = citation.sourceVersionID else { continue }
                    appendReference(WorkflowProvenanceReference(
                        kind: .sourceVersion, canonicalObjectID: versionID,
                        role: .contradicting, sourceVersionID: versionID,
                        label: citation.displayLabel))
                }
            }
        }
        for idString in assembled.manifest.sourceVersionIDs {
            guard let versionID = UUID(uuidString: idString) else { continue }
            appendReference(WorkflowProvenanceReference(
                kind: .sourceVersion, canonicalObjectID: versionID,
                role: .outputCitation, sourceVersionID: versionID))
        }
        let artifactProvenance = try WorkflowProvenancePersistenceInput.make(
            snapshot: WorkflowProvenanceSnapshot(
                ownerKind: .artifact,
                workflowRunID: runID,
                ownerID: artifactID,
                workflowRunRevision: newRevision,
                producerID: WorkflowProvenanceProducers.workProductAssemblyID,
                producerVersion: WorkflowProvenanceProducers.workProductAssemblyVersion,
                sourceStateSHA256: nil,
                references: artifactReferences))
        let stepProvenance = try WorkflowProvenancePersistenceInput.make(
            snapshot: WorkflowProvenanceSnapshot(
                ownerKind: .stepState,
                workflowRunID: runID,
                ownerID: stepRunID,
                workflowRunRevision: newRevision,
                producerID: currentState.executorID,
                producerVersion: currentState.executorVersion,
                sourceStateSHA256: newStateSHA,
                references: [WorkflowProvenanceReference(
                    kind: .workProductRun, canonicalObjectID: workProductRunID,
                    role: .generatedFrom)]))

        return try await workflowRuns.applyWorkProductBuild(
            workflowRunID: runID,
            stepRunID: stepRunID,
            expectedRevision: aggregate.run.revision,
            assembled: assembled,
            workProductRunID: workProductRunID,
            artifactID: artifactID,
            artifactDefinitionID: request.artifactDefinitionID,
            subjectLabel: request.subjectLabel,
            corpusSnapshotID: request.corpusSnapshotID,
            newStepStateJSON: newStateJSON,
            newStepStateSHA256: newStateSHA,
            artifactProvenance: artifactProvenance,
            stepProvenance: stepProvenance,
            actor: actor,
            at: now)
    }
}
