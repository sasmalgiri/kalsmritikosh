//
//  WorkProductBuildStepExecutor.swift
//  Kalsmritikosh
//
//  PJE-006C — Handles the `workProductBuild` step kind.
//
//  Storage-free: this executor holds no persistence or assembly dependencies of
//  any kind. It validates workflow-owned state against the FROZEN step artifact
//  and contract work-product definitions and emits `.buildWorkProduct(request)`;
//  the WorkflowWorkProductBuildCoordinator performs the actual composition and
//  atomic persistence.
//  Commands: setSubjectLabel, setCorpusSnapshot, build, complete.
//

import Foundation

// MARK: - Status

public enum WorkProductBuildStepStatus: String, Codable, CaseIterable, Sendable {
    case ready
    case built
}

// MARK: - State

public nonisolated struct WorkProductBuildStepState: Codable, Hashable, Sendable {
    public let status: WorkProductBuildStepStatus
    public let subjectLabel: String?
    public let corpusSnapshotID: UUID?
    public let workProductRunID: UUID?
    public let workflowArtifactID: UUID?
    public let builtAt: Date?

    public nonisolated init(
        status: WorkProductBuildStepStatus = .ready,
        subjectLabel: String? = nil,
        corpusSnapshotID: UUID? = nil,
        workProductRunID: UUID? = nil,
        workflowArtifactID: UUID? = nil,
        builtAt: Date? = nil
    ) {
        self.status = status
        self.subjectLabel = subjectLabel
        self.corpusSnapshotID = corpusSnapshotID
        self.workProductRunID = workProductRunID
        self.workflowArtifactID = workflowArtifactID
        self.builtAt = builtAt
    }
}

// MARK: - Command

public enum WorkProductBuildStepCommand: Sendable, Equatable {
    case setSubjectLabel(String)
    case setCorpusSnapshot(UUID?)
    case build(WorkflowWorkProductBuildRequest)
    case complete
}

extension WorkProductBuildStepCommand: Codable {
    private enum CodingKeys: String, CodingKey { case type, subjectLabel, corpusSnapshotID, request }

    public nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "setSubjectLabel":
            self = .setSubjectLabel(try c.decode(String.self, forKey: .subjectLabel))
        case "setCorpusSnapshot":
            self = .setCorpusSnapshot(try c.decodeIfPresent(UUID.self, forKey: .corpusSnapshotID))
        case "build":
            self = .build(try c.decode(WorkflowWorkProductBuildRequest.self, forKey: .request))
        case "complete":
            self = .complete
        default:
            throw WorkflowStepExecutionError.malformedCommandJSON
        }
    }

    public nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .setSubjectLabel(let label):
            try c.encode("setSubjectLabel", forKey: .type)
            try c.encode(label, forKey: .subjectLabel)
        case .setCorpusSnapshot(let id):
            try c.encode("setCorpusSnapshot", forKey: .type)
            if let id = id { try c.encode(id, forKey: .corpusSnapshotID) }
        case .build(let request):
            try c.encode("build", forKey: .type)
            try c.encode(request, forKey: .request)
        case .complete:
            try c.encode("complete", forKey: .type)
        }
    }
}

// MARK: - Executor

public nonisolated struct WorkProductBuildStepExecutor: WorkflowStepExecutor {

    public nonisolated let executorID = WorkflowStepExecutorID(
        rawValue: "com.kalsmritikosh.step.work-product-build"
    )
    public nonisolated let executorVersion = WorkflowStepExecutorVersion(rawValue: "1")
    public nonisolated let handledKind: WorkflowStepKind = .workProductBuild

    public nonisolated init() {}

    public func prepare(
        context: WorkflowStepPreparationContext
    ) async throws -> WorkflowStepPreparationResult {
        guard context.step.kind == handledKind else {
            throw WorkflowStepExecutionError.executorKindMismatch(
                executor: executorID, expected: handledKind, actual: context.step.kind
            )
        }
        let (json, sha) = try makeEnvelope(state: WorkProductBuildStepState(), stepKind: handledKind)
        return WorkflowStepPreparationResult(
            inputJSON: "{}", stateJSON: json, stateSHA256: sha,
            executorID: executorID, executorVersion: executorVersion
        )
    }

    public func execute(
        context: WorkflowStepExecutionContext,
        commandJSON: String
    ) async throws -> WorkflowStepExecutionResult {
        guard context.step.kind == handledKind else {
            throw WorkflowStepExecutionError.executorKindMismatch(
                executor: executorID, expected: handledKind, actual: context.step.kind
            )
        }
        let state = try decodeCurrentState(WorkProductBuildStepState.self, from: context.stepRun)
        let command: WorkProductBuildStepCommand
        do {
            command = try WorkflowStepPayloadCodec.decode(WorkProductBuildStepCommand.self, from: commandJSON)
        } catch {
            throw WorkflowStepExecutionError.malformedCommandJSON
        }

        func save(_ newState: WorkProductBuildStepState) throws -> WorkflowStepExecutionResult {
            let (json, sha) = try makeEnvelope(state: newState, stepKind: handledKind)
            return WorkflowStepExecutionResult(stateJSON: json, stateSHA256: sha, disposition: .remainActive)
        }

        switch command {
        case .setSubjectLabel(let label):
            guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "subjectLabel", reason: "Subject label must not be blank")
            }
            return try save(WorkProductBuildStepState(
                status: state.status, subjectLabel: label,
                corpusSnapshotID: state.corpusSnapshotID,
                workProductRunID: state.workProductRunID,
                workflowArtifactID: state.workflowArtifactID, builtAt: state.builtAt))

        case .setCorpusSnapshot(let snapshotID):
            return try save(WorkProductBuildStepState(
                status: state.status, subjectLabel: state.subjectLabel,
                corpusSnapshotID: snapshotID,
                workProductRunID: state.workProductRunID,
                workflowArtifactID: state.workflowArtifactID, builtAt: state.builtAt))

        case .build(let request):
            guard state.status == .ready else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "status", reason: "Work product already built for this step")
            }
            guard !request.subjectLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "subjectLabel", reason: "Subject label must not be blank")
            }
            // Artifact definition must exist on the FROZEN step and declare a template.
            guard let artifact = context.step.artifacts.first(where: { $0.id == request.artifactDefinitionID }) else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "artifactDefinitionID",
                    reason: "Artifact definition is not declared on this step")
            }
            guard let templateID = artifact.workProductTemplateID else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "artifactDefinitionID",
                    reason: "Artifact definition declares no work-product template")
            }
            // Work-product definition must exist in the FROZEN run contract, and IDs must match.
            guard context.aggregate.contract.workProducts.contains(where: { $0.id == request.workProductDefinitionID }) else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "workProductDefinitionID",
                    reason: "Work-product definition is not in the frozen run contract")
            }
            guard templateID == request.workProductDefinitionID else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "workProductDefinitionID",
                    reason: "Artifact template ID does not match the requested work-product definition")
            }
            // Access envelope: export purpose, matching workspace — verified here AND
            // fail-closed again inside the assembly service.
            guard request.access.scope.purpose == .export else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "access", reason: "Work-product build requires an export-purpose scope")
            }
            guard request.access.scope.workspaceID == context.aggregate.run.workspaceID else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "access", reason: "Access scope workspace does not match the run workspace")
            }
            // The executor only REQUESTS the build — the coordinator performs it.
            let (json, sha) = try makeEnvelope(state: state, stepKind: handledKind)
            return WorkflowStepExecutionResult(
                stateJSON: json, stateSHA256: sha,
                disposition: .buildWorkProduct(request)
            )

        case .complete:
            guard state.status == .built,
                  state.workProductRunID != nil,
                  state.workflowArtifactID != nil else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind,
                    reason: "A saved work product and linked workflow artifact are required before completion")
            }
            // The linked artifact must correspond to a declared step artifact definition.
            let declaredIDs = Set(context.step.artifacts.map { $0.id })
            let linked = context.aggregate.artifacts.first { $0.id == state.workflowArtifactID }
            guard let linked = linked, declaredIDs.contains(linked.artifactDefinitionID) else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind,
                    reason: "Linked artifact does not match a declared artifact definition")
            }
            guard let firstTransition = context.step.transitions.first else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind, reason: "No transitions declared")
            }
            let (json, sha) = try makeEnvelope(state: state, stepKind: handledKind)
            return WorkflowStepExecutionResult(
                stateJSON: json, stateSHA256: sha,
                disposition: .advance(.label(firstTransition.label))
            )
        }
    }
}
