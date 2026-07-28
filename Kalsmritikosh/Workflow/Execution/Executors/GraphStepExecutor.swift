//
//  GraphStepExecutor.swift
//  Kalsmritikosh
//
//  PJE-006B — Evidence and Analytical Step Executors.
//  Handles the `graph` step kind.
//
//  Nodes and edges are stored separately. Nodes reference canonical objects
//  (gate-verified) or explicit proposal nodes. Every edge declares relationship
//  type, direction, provenance, and status. All edges are PROPOSAL-LAYER state:
//  an inferred or user-drawn edge never becomes a canonical relationship
//  automatically, and no graph operation touches the production evidence graph.
//  Commands: addCanonicalNode, addProposalNode, removeNode, addEdge,
//            setEdgeStatus, removeEdge, complete.
//

import Foundation

// MARK: - Node reference

/// A node either references a canonical object by exact ID, or is an explicit
/// proposal node that exists only inside this workflow.
public enum WorkflowGraphNodeReference: Sendable, Equatable {
    case canonical(kind: WorkflowEvidenceObjectKind, canonicalObjectID: String)
    case proposal(label: String)
}

extension WorkflowGraphNodeReference: Codable {
    private enum CodingKeys: String, CodingKey { case type, kind, canonicalObjectID, label }

    public nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "canonical":
            self = .canonical(
                kind: try c.decode(WorkflowEvidenceObjectKind.self, forKey: .kind),
                canonicalObjectID: try c.decode(String.self, forKey: .canonicalObjectID)
            )
        case "proposal":
            self = .proposal(label: try c.decode(String.self, forKey: .label))
        default:
            throw WorkflowStepExecutionError.malformedStateJSON
        }
    }

    public nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .canonical(let kind, let canonicalObjectID):
            try c.encode("canonical", forKey: .type)
            try c.encode(kind, forKey: .kind)
            try c.encode(canonicalObjectID, forKey: .canonicalObjectID)
        case .proposal(let label):
            try c.encode("proposal", forKey: .type)
            try c.encode(label, forKey: .label)
        }
    }
}

// MARK: - Node

public nonisolated struct WorkflowGraphNode: Codable, Sendable, Equatable {
    public let id: UUID
    public let reference: WorkflowGraphNodeReference

    public nonisolated init(id: UUID, reference: WorkflowGraphNodeReference) {
        self.id = id
        self.reference = reference
    }
}

// MARK: - Edge vocabulary

public enum WorkflowGraphEdgeDirection: String, Codable, Sendable, CaseIterable, Equatable {
    case directed
    case bidirectional
}

/// Where an edge came from. Closed vocabulary — every edge must declare its origin.
public enum WorkflowGraphEdgeProvenance: Sendable, Equatable {
    case userDrawn(actorIdentifier: String?)
    case inferred(basis: String)
}

extension WorkflowGraphEdgeProvenance: Codable {
    private enum CodingKeys: String, CodingKey { case type, actorIdentifier, basis }

    public nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "userDrawn":
            self = .userDrawn(actorIdentifier: try c.decodeIfPresent(String.self, forKey: .actorIdentifier))
        case "inferred":
            self = .inferred(basis: try c.decode(String.self, forKey: .basis))
        default:
            throw WorkflowStepExecutionError.malformedStateJSON
        }
    }

    public nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .userDrawn(let actorIdentifier):
            try c.encode("userDrawn", forKey: .type)
            if let actorIdentifier = actorIdentifier {
                try c.encode(actorIdentifier, forKey: .actorIdentifier)
            }
        case .inferred(let basis):
            try c.encode("inferred", forKey: .type)
            try c.encode(basis, forKey: .basis)
        }
    }
}

/// Proposal-layer edge status. There is deliberately NO "canonical" or "promoted"
/// status — promotion to a canonical relationship is a separate, reviewed path.
public enum WorkflowGraphEdgeStatus: String, Codable, Sendable, CaseIterable, Equatable {
    case candidate
    case supported
    case disputed
    case withdrawn
}

// MARK: - Edge

public nonisolated struct WorkflowGraphEdge: Codable, Sendable, Equatable {
    public let id: UUID
    public let sourceNodeID: UUID
    public let targetNodeID: UUID
    public let relationshipType: String
    public let direction: WorkflowGraphEdgeDirection
    public let provenance: WorkflowGraphEdgeProvenance
    public var status: WorkflowGraphEdgeStatus

    public nonisolated init(
        id: UUID,
        sourceNodeID: UUID,
        targetNodeID: UUID,
        relationshipType: String,
        direction: WorkflowGraphEdgeDirection,
        provenance: WorkflowGraphEdgeProvenance,
        status: WorkflowGraphEdgeStatus
    ) {
        self.id = id
        self.sourceNodeID = sourceNodeID
        self.targetNodeID = targetNodeID
        self.relationshipType = relationshipType
        self.direction = direction
        self.provenance = provenance
        self.status = status
    }
}

// MARK: - State

public nonisolated struct GraphStepState: Codable, Sendable {
    /// Nodes and edges stored separately — the required shape.
    public var nodes: [WorkflowGraphNode]
    public var edges: [WorkflowGraphEdge]

    public nonisolated init(nodes: [WorkflowGraphNode] = [], edges: [WorkflowGraphEdge] = []) {
        self.nodes = nodes
        self.edges = edges
    }
}

// MARK: - Command

public enum GraphStepCommand: Sendable, Equatable {
    case addCanonicalNode(kind: WorkflowEvidenceObjectKind, canonicalObjectID: String)
    case addProposalNode(label: String)
    case removeNode(nodeID: UUID)
    case addEdge(
        sourceNodeID: UUID,
        targetNodeID: UUID,
        relationshipType: String,
        direction: WorkflowGraphEdgeDirection,
        provenance: WorkflowGraphEdgeProvenance
    )
    case setEdgeStatus(edgeID: UUID, status: WorkflowGraphEdgeStatus)
    case removeEdge(edgeID: UUID)
    case complete
}

extension GraphStepCommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, kind, canonicalObjectID, label, nodeID
        case sourceNodeID, targetNodeID, relationshipType, direction, provenance
        case edgeID, status
    }

    public nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "addCanonicalNode":
            self = .addCanonicalNode(
                kind: try c.decode(WorkflowEvidenceObjectKind.self, forKey: .kind),
                canonicalObjectID: try c.decode(String.self, forKey: .canonicalObjectID)
            )
        case "addProposalNode":
            self = .addProposalNode(label: try c.decode(String.self, forKey: .label))
        case "removeNode":
            self = .removeNode(nodeID: try c.decode(UUID.self, forKey: .nodeID))
        case "addEdge":
            self = .addEdge(
                sourceNodeID: try c.decode(UUID.self, forKey: .sourceNodeID),
                targetNodeID: try c.decode(UUID.self, forKey: .targetNodeID),
                relationshipType: try c.decode(String.self, forKey: .relationshipType),
                direction: try c.decode(WorkflowGraphEdgeDirection.self, forKey: .direction),
                provenance: try c.decode(WorkflowGraphEdgeProvenance.self, forKey: .provenance)
            )
        case "setEdgeStatus":
            self = .setEdgeStatus(
                edgeID: try c.decode(UUID.self, forKey: .edgeID),
                status: try c.decode(WorkflowGraphEdgeStatus.self, forKey: .status)
            )
        case "removeEdge":
            self = .removeEdge(edgeID: try c.decode(UUID.self, forKey: .edgeID))
        case "complete":
            self = .complete
        default:
            throw WorkflowStepExecutionError.malformedCommandJSON
        }
    }

    public nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .addCanonicalNode(let kind, let canonicalObjectID):
            try c.encode("addCanonicalNode", forKey: .type)
            try c.encode(kind, forKey: .kind)
            try c.encode(canonicalObjectID, forKey: .canonicalObjectID)
        case .addProposalNode(let label):
            try c.encode("addProposalNode", forKey: .type)
            try c.encode(label, forKey: .label)
        case .removeNode(let nodeID):
            try c.encode("removeNode", forKey: .type)
            try c.encode(nodeID, forKey: .nodeID)
        case .addEdge(let sourceNodeID, let targetNodeID, let relationshipType, let direction, let provenance):
            try c.encode("addEdge", forKey: .type)
            try c.encode(sourceNodeID, forKey: .sourceNodeID)
            try c.encode(targetNodeID, forKey: .targetNodeID)
            try c.encode(relationshipType, forKey: .relationshipType)
            try c.encode(direction, forKey: .direction)
            try c.encode(provenance, forKey: .provenance)
        case .setEdgeStatus(let edgeID, let status):
            try c.encode("setEdgeStatus", forKey: .type)
            try c.encode(edgeID, forKey: .edgeID)
            try c.encode(status, forKey: .status)
        case .removeEdge(let edgeID):
            try c.encode("removeEdge", forKey: .type)
            try c.encode(edgeID, forKey: .edgeID)
        case .complete:
            try c.encode("complete", forKey: .type)
        }
    }
}

// MARK: - Executor

public nonisolated struct GraphStepExecutor: WorkflowStepExecutor {

    public nonisolated let executorID = WorkflowStepExecutorID(
        rawValue: "com.kalsmritikosh.step.graph"
    )
    public nonisolated let executorVersion = WorkflowStepExecutorVersion(rawValue: "1.0")
    public nonisolated let handledKind: WorkflowStepKind = .graph

    private let gate: any WorkflowEvidenceReferenceGating

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
        let (json, sha) = try makeEnvelope(state: GraphStepState(), stepKind: handledKind)
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
        var state = try decodeCurrentState(GraphStepState.self, from: context.stepRun)
        let command: GraphStepCommand
        do {
            command = try WorkflowStepPayloadCodec.decode(GraphStepCommand.self, from: commandJSON)
        } catch {
            throw WorkflowStepExecutionError.malformedCommandJSON
        }

        func save() throws -> WorkflowStepExecutionResult {
            let (json, sha) = try makeEnvelope(state: state, stepKind: handledKind)
            return WorkflowStepExecutionResult(stateJSON: json, stateSHA256: sha, disposition: .remainActive)
        }

        switch command {
        case .addCanonicalNode(let kind, let canonicalObjectID):
            guard let objectUUID = UUID(uuidString: canonicalObjectID) else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "canonicalObjectID", reason: "Not a valid canonical object UUID"
                )
            }
            let canonicalForm = objectUUID.uuidString
            let duplicate = state.nodes.contains {
                if case .canonical(let k, let cid) = $0.reference {
                    return k == kind && cid == canonicalForm
                }
                return false
            }
            guard !duplicate else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "canonicalObjectID", reason: "Canonical node already exists in graph"
                )
            }
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
            state.nodes.append(WorkflowGraphNode(
                id: UUID(),
                reference: .canonical(kind: kind, canonicalObjectID: canonicalForm)
            ))
            return try save()

        case .addProposalNode(let label):
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "label", reason: "Proposal node label must not be blank"
                )
            }
            state.nodes.append(WorkflowGraphNode(id: UUID(), reference: .proposal(label: trimmed)))
            return try save()

        case .removeNode(let nodeID):
            guard state.nodes.contains(where: { $0.id == nodeID }) else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "nodeID", reason: "No node with this ID"
                )
            }
            state.nodes.removeAll { $0.id == nodeID }
            state.edges.removeAll { $0.sourceNodeID == nodeID || $0.targetNodeID == nodeID }
            return try save()

        case .addEdge(let sourceNodeID, let targetNodeID, let relationshipType, let direction, let provenance):
            let trimmedType = relationshipType.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedType.isEmpty else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "relationshipType", reason: "Relationship type must not be blank"
                )
            }
            guard sourceNodeID != targetNodeID else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "targetNodeID", reason: "Self-loop edges are not allowed"
                )
            }
            let nodeIDs = Set(state.nodes.map { $0.id })
            guard nodeIDs.contains(sourceNodeID), nodeIDs.contains(targetNodeID) else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "sourceNodeID", reason: "Edge endpoints must be existing nodes"
                )
            }
            if case .inferred(let basis) = provenance,
               basis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "provenance", reason: "Inferred edges must declare a non-blank basis"
                )
            }
            // New edges always enter as proposal-layer candidates.
            state.edges.append(WorkflowGraphEdge(
                id: UUID(),
                sourceNodeID: sourceNodeID,
                targetNodeID: targetNodeID,
                relationshipType: trimmedType,
                direction: direction,
                provenance: provenance,
                status: .candidate
            ))
            return try save()

        case .setEdgeStatus(let edgeID, let status):
            guard let index = state.edges.firstIndex(where: { $0.id == edgeID }) else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "edgeID", reason: "No edge with this ID"
                )
            }
            state.edges[index].status = status
            return try save()

        case .removeEdge(let edgeID):
            guard state.edges.contains(where: { $0.id == edgeID }) else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "edgeID", reason: "No edge with this ID"
                )
            }
            state.edges.removeAll { $0.id == edgeID }
            return try save()

        case .complete:
            guard !state.nodes.isEmpty else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind, reason: "Graph must have at least one node"
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
