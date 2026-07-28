//
//  WorkProductBuildStepExecutorTests.swift
//  KalsmritikoshTests
//
//  PJE-006C — WorkProductBuildStepExecutor: repository-free validation against
//  frozen artifact/work-product definitions; emits buildWorkProduct only. 9 tests.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-006C — WorkProductBuildStepExecutor")
@MainActor
struct WorkProductBuildStepExecutorTests {

    private let wpDefID = "com.wp.def.summary"
    private let artifactID = "artifact.summary"

    private func makeRig(suffix: String = "") throws -> ExecutorTestRig {
        try makeExecutorTestRig(
            kind: .workProductBuild,
            suffix: suffix,
            artifacts: [PersonaWorkflowArtifactDefinition(
                id: artifactID, label: "Summary report",
                workProductTemplateID: wpDefID, isRequired: true)],
            workProducts: [PersonaWorkProductDefinition(
                id: WorkProductDefinitionID(rawValue: wpDefID),
                version: 1, label: "General summary", template: .generalSummary)])
    }

    private func rigAndState(
        suffix: String = ""
    ) async throws -> (WorkProductBuildStepExecutor, ExecutorTestRig, String) {
        let executor = WorkProductBuildStepExecutor()
        let rig = try makeRig(suffix: suffix)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        return (executor, rig, prep.stateJSON)
    }

    private func request(
        artifactDefinitionID: String? = nil,
        workProductDefinitionID: String? = nil,
        purpose: SensitiveUsePurpose = .export,
        workspaceID: UUID
    ) -> WorkflowWorkProductBuildRequest {
        WorkflowWorkProductBuildRequest(
            artifactDefinitionID: artifactDefinitionID ?? artifactID,
            workProductDefinitionID: workProductDefinitionID ?? wpDefID,
            subjectLabel: "Case subject",
            corpusSnapshotID: nil,
            access: SensitiveAccessContext(scope: SensitiveScope(
                workspaceID: workspaceID, maximumSensitivity: .restricted,
                permitsPrivilegedMaterial: false, purpose: purpose)))
    }

    private func buildJSON(_ request: WorkflowWorkProductBuildRequest) throws -> String {
        try WorkflowStepPayloadCodec.encode(WorkProductBuildStepCommand.build(request))
    }

    @Test("A valid build request emits .buildWorkProduct without performing anything")
    func validBuildEmitsRequest() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let wsID = UUID()
        let ctx = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: stateJSON, workspaceID: wsID)
        let req = request(workspaceID: wsID)
        let r = try await executor.execute(context: ctx, commandJSON: try buildJSON(req))
        #expect(r.disposition == .buildWorkProduct(req))
        // Executor state is UNCHANGED — the coordinator owns the persisted transition.
        let state = try decodeEnvelopeState(WorkProductBuildStepState.self, from: r.stateJSON)
        #expect(state.status == .ready)
        #expect(state.workProductRunID == nil)
    }

    @Test("The frozen artifact definition is required")
    func frozenArtifactRequired() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let wsID = UUID()
        let ctx = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: stateJSON, workspaceID: wsID)
        let req = request(artifactDefinitionID: "artifact.ghost", workspaceID: wsID)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: try buildJSON(req))
        }
    }

    @Test("The frozen work-product definition is required")
    func frozenWorkProductDefinitionRequired() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let wsID = UUID()
        let ctx = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: stateJSON, workspaceID: wsID)
        let req = request(workProductDefinitionID: "com.wp.def.ghost", workspaceID: wsID)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: try buildJSON(req))
        }
    }

    @Test("Template IDs must match exactly between artifact and work-product definition")
    func templateIDsMustMatch() async throws {
        // Second work-product def exists in contract but the artifact points at the first.
        let executor = WorkProductBuildStepExecutor()
        let rig = try makeExecutorTestRig(
            kind: .workProductBuild, suffix: "mismatch",
            artifacts: [PersonaWorkflowArtifactDefinition(
                id: artifactID, label: "Report",
                workProductTemplateID: wpDefID, isRequired: true)],
            workProducts: [
                PersonaWorkProductDefinition(
                    id: WorkProductDefinitionID(rawValue: wpDefID),
                    version: 1, label: "Summary", template: .generalSummary),
                PersonaWorkProductDefinition(
                    id: WorkProductDefinitionID(rawValue: "com.wp.def.other"),
                    version: 1, label: "Other", template: .chronology)
            ])
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let wsID = UUID()
        let ctx = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: prep.stateJSON, workspaceID: wsID)
        let req = request(workProductDefinitionID: "com.wp.def.other", workspaceID: wsID)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: try buildJSON(req))
        }
    }

    @Test("An export-purpose scope is required")
    func exportPurposeRequired() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let wsID = UUID()
        let ctx = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: stateJSON, workspaceID: wsID)
        let req = request(purpose: .retrieval, workspaceID: wsID)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: try buildJSON(req))
        }
    }

    @Test("The access workspace must match the run workspace")
    func workspaceMustMatch() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let ctx = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: stateJSON, workspaceID: UUID())
        let req = request(workspaceID: UUID())   // different workspace
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: try buildJSON(req))
        }
    }

    @Test("Completion requires a saved run and linked artifact matching a declared definition")
    func completionRequiresBuiltState() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        // Not built yet → refused.
        let ctx1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prepJSON)
        let complete = try WorkflowStepPayloadCodec.encode(WorkProductBuildStepCommand.complete)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx1, commandJSON: complete)
        }
    }

    @Test("Completion advances once the built state and matching artifact are present")
    func completionAdvancesWhenBuilt() async throws {
        let (executor, rig, _) = try await rigAndState(suffix: "built")
        let t0 = Date(timeIntervalSince1970: 1_753_600_000)
        let wpRunID = UUID(), wfArtifactID = UUID()
        // A coordinator-produced state: built + linked artifact.
        let builtState = WorkProductBuildStepState(
            status: .built, subjectLabel: "Case subject", corpusSnapshotID: nil,
            workProductRunID: wpRunID, workflowArtifactID: wfArtifactID, builtAt: t0)
        let envelope = WorkflowStepStateEnvelope(
            stepKind: .workProductBuild,
            executorID: executor.executorID.rawValue,
            executorVersion: executor.executorVersion.rawValue,
            state: builtState)
        let builtJSON = try WorkflowStepPayloadCodec.encode(envelope)
        let artifact = WorkflowArtifact(
            id: wfArtifactID, workflowRunID: UUID(), stepRunID: nil,
            artifactDefinitionID: artifactID, kind: .workProductRun,
            label: "Summary report", workProductRunID: wpRunID,
            targetKind: nil, targetID: nil, referenceURI: nil,
            mediaType: nil, contentSHA256: nil, metadataJSON: "{}",
            supersedesArtifactID: nil, createdAt: t0)
        let ctx = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: builtJSON, artifacts: [artifact])
        let complete = try WorkflowStepPayloadCodec.encode(WorkProductBuildStepCommand.complete)
        let r = try await executor.execute(context: ctx, commandJSON: complete)
        #expect(r.disposition == .advance(.label("next")))
    }

    @Test("The executor is repository-free — it never mutates built state itself")
    func executorNeverSetsBuiltState() async throws {
        let (executor, rig, prepJSON) = try await rigAndState(suffix: "nofab")
        let wsID = UUID()
        var stateJSON = prepJSON
        // Run every non-build command; none may produce a built status.
        let ctx1 = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: stateJSON, workspaceID: wsID)
        stateJSON = try await executor.execute(
            context: ctx1,
            commandJSON: try WorkflowStepPayloadCodec.encode(
                WorkProductBuildStepCommand.setSubjectLabel("Subject"))).stateJSON
        let ctx2 = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: stateJSON, workspaceID: wsID)
        stateJSON = try await executor.execute(
            context: ctx2,
            commandJSON: try WorkflowStepPayloadCodec.encode(
                WorkProductBuildStepCommand.setCorpusSnapshot(nil))).stateJSON
        let state = try decodeEnvelopeState(WorkProductBuildStepState.self, from: stateJSON)
        #expect(state.status == .ready)
        #expect(state.workProductRunID == nil)
        #expect(state.workflowArtifactID == nil)
    }
}
