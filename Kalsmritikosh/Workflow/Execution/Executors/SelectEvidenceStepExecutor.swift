//
//  SelectEvidenceStepExecutor.swift
//  Kalsmritikosh
//
//  PJE-006B — Evidence and Analytical Step Executors.
//  Handles the `selectEvidence` step kind.
//
//  Selects CANONICAL IDs ONLY — never copies canonical text into workflow state,
//  never creates or confirms Claims. Every reference passes the evidence gate
//  (existence + workspace boundary + SensitiveScope) BEFORE it becomes available.
//  Selection order and the explicit selection reason are preserved.
//  Commands: select, deselect, complete.
//

import Foundation

// MARK: - Selected item

/// One workflow-owned selection record. Carries the canonical reference and the
/// selection provenance — never canonical content.
public nonisolated struct SelectedWorkflowEvidenceItem: Codable, Sendable, Equatable {
    public let id: UUID
    public let objectKind: WorkflowEvidenceObjectKind
    public let canonicalObjectID: String
    public let selectionReason: String
    public let selectedBy: String?
    public let selectedAt: Date

    public nonisolated init(
        id: UUID,
        objectKind: WorkflowEvidenceObjectKind,
        canonicalObjectID: String,
        selectionReason: String,
        selectedBy: String?,
        selectedAt: Date
    ) {
        self.id = id
        self.objectKind = objectKind
        self.canonicalObjectID = canonicalObjectID
        self.selectionReason = selectionReason
        self.selectedBy = selectedBy
        self.selectedAt = selectedAt
    }
}

// MARK: - State

public nonisolated struct SelectEvidenceStepState: Codable, Sendable {
    /// Selection order is the array order — never reordered.
    public var items: [SelectedWorkflowEvidenceItem]

    public nonisolated init(items: [SelectedWorkflowEvidenceItem] = []) {
        self.items = items
    }
}

// MARK: - Command

public enum SelectEvidenceStepCommand: Sendable, Equatable {
    case select(kind: WorkflowEvidenceObjectKind, canonicalObjectID: String, reason: String)
    case deselect(itemID: UUID)
    case complete
}

extension SelectEvidenceStepCommand: Codable {
    private enum CodingKeys: String, CodingKey { case type, kind, canonicalObjectID, reason, itemID }

    public nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "select":
            self = .select(
                kind: try c.decode(WorkflowEvidenceObjectKind.self, forKey: .kind),
                canonicalObjectID: try c.decode(String.self, forKey: .canonicalObjectID),
                reason: try c.decode(String.self, forKey: .reason)
            )
        case "deselect":
            self = .deselect(itemID: try c.decode(UUID.self, forKey: .itemID))
        case "complete":
            self = .complete
        default:
            throw WorkflowStepExecutionError.malformedCommandJSON
        }
    }

    public nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .select(let kind, let canonicalObjectID, let reason):
            try c.encode("select", forKey: .type)
            try c.encode(kind, forKey: .kind)
            try c.encode(canonicalObjectID, forKey: .canonicalObjectID)
            try c.encode(reason, forKey: .reason)
        case .deselect(let itemID):
            try c.encode("deselect", forKey: .type)
            try c.encode(itemID, forKey: .itemID)
        case .complete:
            try c.encode("complete", forKey: .type)
        }
    }
}

// MARK: - Executor

public nonisolated struct SelectEvidenceStepExecutor: WorkflowStepExecutor {

    public nonisolated let executorID = WorkflowStepExecutorID(
        rawValue: "com.kalsmritikosh.step.selectEvidence"
    )
    public nonisolated let executorVersion = WorkflowStepExecutorVersion(rawValue: "1.0")
    public nonisolated let handledKind: WorkflowStepKind = .selectEvidence

    private let gate: any WorkflowEvidenceReferenceGating

    /// The gate is mandatory — selection without scope/boundary verification is not allowed.
    public nonisolated init(gate: any WorkflowEvidenceReferenceGating) {
        self.gate = gate
    }

    public func prepare(
        context: WorkflowStepPreparationContext
    ) async throws -> WorkflowStepPreparationResult {
        guard context.step.kind == handledKind else {
            throw WorkflowStepExecutionError.executorKindMismatch(
                executor: executorID, expected: handledKind, actual: context.step.kind
            )
        }
        let (json, sha) = try makeEnvelope(state: SelectEvidenceStepState(), stepKind: handledKind)
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
        var state = try decodeCurrentState(SelectEvidenceStepState.self, from: context.stepRun)
        let command: SelectEvidenceStepCommand
        do {
            command = try WorkflowStepPayloadCodec.decode(SelectEvidenceStepCommand.self, from: commandJSON)
        } catch {
            throw WorkflowStepExecutionError.malformedCommandJSON
        }

        func save() throws -> WorkflowStepExecutionResult {
            let (json, sha) = try makeEnvelope(state: state, stepKind: handledKind)
            return WorkflowStepExecutionResult(stateJSON: json, stateSHA256: sha, disposition: .remainActive)
        }

        switch command {
        case .select(let kind, let canonicalObjectID, let reason):
            let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedReason.isEmpty else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "reason", reason: "Selection reason must not be blank"
                )
            }
            guard let objectUUID = UUID(uuidString: canonicalObjectID) else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "canonicalObjectID", reason: "Not a valid canonical object UUID"
                )
            }
            let canonicalForm = objectUUID.uuidString
            guard !state.items.contains(where: {
                $0.objectKind == kind && $0.canonicalObjectID == canonicalForm
            }) else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "canonicalObjectID", reason: "Object is already selected"
                )
            }
            // Gate BEFORE the item becomes available — existence, boundary, sensitive scope
            let verdict = await gate.verdict(
                kind: kind,
                canonicalObjectID: objectUUID,
                workspaceID: context.aggregate.run.workspaceID
            )
            guard case .permitted = verdict else {
                if case .denied(let why) = verdict {
                    throw WorkflowStepExecutionError.validationFailed(
                        field: "canonicalObjectID", reason: why
                    )
                }
                throw WorkflowStepExecutionError.validationFailed(
                    field: "canonicalObjectID", reason: "Reference denied"
                )
            }
            state.items.append(SelectedWorkflowEvidenceItem(
                id: UUID(),
                objectKind: kind,
                canonicalObjectID: canonicalForm,
                selectionReason: trimmedReason,
                selectedBy: context.actor.identifier,
                selectedAt: context.executedAt
            ))
            return try save()

        case .deselect(let itemID):
            guard state.items.contains(where: { $0.id == itemID }) else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "itemID", reason: "No selected item with this ID"
                )
            }
            state.items.removeAll { $0.id == itemID }
            return try save()

        case .complete:
            guard !state.items.isEmpty else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind, reason: "At least one evidence item must be selected"
                )
            }
            guard let firstTransition = context.step.transitions.first else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind, reason: "No transitions declared"
                )
            }
            let (json, sha) = try makeEnvelope(state: state, stepKind: handledKind)
            return WorkflowStepExecutionResult(
                stateJSON: json, stateSHA256: sha,
                disposition: .advance(.label(firstTransition.label))
            )
        }
    }
}
