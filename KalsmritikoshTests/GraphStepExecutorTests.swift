//
//  GraphStepExecutorTests.swift
//  KalsmritikoshTests
//
//  PJE-006B — GraphStepExecutor: separated node/edge references, declared
//  provenance/direction/status, proposal-layer edges only. 12 tests.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-006B — GraphStepExecutor")
struct GraphStepExecutorTests {

    private func rigAndState(
        gate: FixtureEvidenceGate = FixtureEvidenceGate()
    ) async throws -> (GraphStepExecutor, ExecutorTestRig, String) {
        let executor = GraphStepExecutor(gate: gate)
        let rig = try makeExecutorTestRig(kind: .graph)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        return (executor, rig, prep.stateJSON)
    }

    private func addCanonical(kind: WorkflowEvidenceObjectKind = .entity, id: UUID = UUID()) throws -> String {
        try WorkflowStepPayloadCodec.encode(
            GraphStepCommand.addCanonicalNode(kind: kind, canonicalObjectID: id.uuidString))
    }

    private func addProposal(label: String = "Suspected intermediary") throws -> String {
        try WorkflowStepPayloadCodec.encode(GraphStepCommand.addProposalNode(label: label))
    }

    /// Builds a two-node graph and returns (stateJSON, nodeIDs).
    private func twoNodeGraph(
        executor: GraphStepExecutor, rig: ExecutorTestRig, prepJSON: String
    ) async throws -> (String, [UUID]) {
        let ctx1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prepJSON)
        let r1 = try await executor.execute(context: ctx1, commandJSON: try addCanonical())
        let ctx2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        let r2 = try await executor.execute(context: ctx2, commandJSON: try addProposal())
        let state = try decodeEnvelopeState(GraphStepState.self, from: r2.stateJSON)
        return (r2.stateJSON, state.nodes.map(\.id))
    }

    @Test("canonical node stores the exact canonical reference")
    func canonicalNodeStoresReference() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let objectID = UUID()
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        let r = try await executor.execute(
            context: ctx, commandJSON: try addCanonical(kind: .event, id: objectID))
        let state = try decodeEnvelopeState(GraphStepState.self, from: r.stateJSON)
        #expect(state.nodes.count == 1)
        #expect(state.nodes[0].reference == .canonical(kind: .event, canonicalObjectID: objectID.uuidString))
    }

    @Test("proposal node is an explicit proposal reference, no canonical ID")
    func proposalNodeExplicit() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        let r = try await executor.execute(context: ctx, commandJSON: try addProposal(label: "Ghost entity"))
        let state = try decodeEnvelopeState(GraphStepState.self, from: r.stateJSON)
        #expect(state.nodes[0].reference == .proposal(label: "Ghost entity"))
    }

    @Test("duplicate canonical node is rejected")
    func duplicateCanonicalRejected() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let objectID = UUID()
        let ctx1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prepJSON)
        let r1 = try await executor.execute(context: ctx1, commandJSON: try addCanonical(id: objectID))
        let ctx2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx2, commandJSON: try addCanonical(id: objectID))
        }
    }

    @Test("gate denial blocks a canonical node")
    func gateDenialBlocksNode() async throws {
        let deniedID = UUID()
        let (executor, rig, stateJSON) = try await rigAndState(
            gate: FixtureEvidenceGate(deniedIDs: [deniedID]))
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: try addCanonical(id: deniedID))
        }
    }

    @Test("new edge declares type, direction, provenance — and enters as candidate")
    func edgeDeclaresAllAttributes() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let (stateJSON, nodeIDs) = try await twoNodeGraph(executor: executor, rig: rig, prepJSON: prepJSON)
        let edge = try WorkflowStepPayloadCodec.encode(GraphStepCommand.addEdge(
            sourceNodeID: nodeIDs[0], targetNodeID: nodeIDs[1],
            relationshipType: "transferred_funds_to", direction: .directed,
            provenance: .userDrawn(actorIdentifier: "analyst-1")))
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        let r = try await executor.execute(context: ctx, commandJSON: edge)
        let state = try decodeEnvelopeState(GraphStepState.self, from: r.stateJSON)
        #expect(state.edges.count == 1)
        #expect(state.edges[0].relationshipType == "transferred_funds_to")
        #expect(state.edges[0].direction == .directed)
        #expect(state.edges[0].provenance == .userDrawn(actorIdentifier: "analyst-1"))
        #expect(state.edges[0].status == .candidate, "New edges must enter as proposal-layer candidates")
    }

    @Test("edge endpoints must be existing nodes")
    func edgeRequiresExistingNodes() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let (stateJSON, nodeIDs) = try await twoNodeGraph(executor: executor, rig: rig, prepJSON: prepJSON)
        let edge = try WorkflowStepPayloadCodec.encode(GraphStepCommand.addEdge(
            sourceNodeID: nodeIDs[0], targetNodeID: UUID(),
            relationshipType: "linked_to", direction: .directed,
            provenance: .userDrawn(actorIdentifier: nil)))
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: edge)
        }
    }

    @Test("self-loop edges are rejected")
    func selfLoopRejected() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let (stateJSON, nodeIDs) = try await twoNodeGraph(executor: executor, rig: rig, prepJSON: prepJSON)
        let edge = try WorkflowStepPayloadCodec.encode(GraphStepCommand.addEdge(
            sourceNodeID: nodeIDs[0], targetNodeID: nodeIDs[0],
            relationshipType: "self", direction: .directed,
            provenance: .userDrawn(actorIdentifier: nil)))
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: edge)
        }
    }

    @Test("inferred edge requires a non-blank basis")
    func inferredEdgeRequiresBasis() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let (stateJSON, nodeIDs) = try await twoNodeGraph(executor: executor, rig: rig, prepJSON: prepJSON)
        let edge = try WorkflowStepPayloadCodec.encode(GraphStepCommand.addEdge(
            sourceNodeID: nodeIDs[0], targetNodeID: nodeIDs[1],
            relationshipType: "linked_to", direction: .bidirectional,
            provenance: .inferred(basis: "   ")))
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: edge)
        }
    }

    @Test("edge status transitions stay within the proposal vocabulary")
    func edgeStatusTransitions() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let (stateJSON, nodeIDs) = try await twoNodeGraph(executor: executor, rig: rig, prepJSON: prepJSON)
        let edge = try WorkflowStepPayloadCodec.encode(GraphStepCommand.addEdge(
            sourceNodeID: nodeIDs[0], targetNodeID: nodeIDs[1],
            relationshipType: "linked_to", direction: .directed,
            provenance: .inferred(basis: "co-occurrence in filing")))
        let ctx1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        let r1 = try await executor.execute(context: ctx1, commandJSON: edge)
        let edgeID = try decodeEnvelopeState(GraphStepState.self, from: r1.stateJSON).edges[0].id

        let setStatus = try WorkflowStepPayloadCodec.encode(
            GraphStepCommand.setEdgeStatus(edgeID: edgeID, status: .disputed))
        let ctx2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        let r2 = try await executor.execute(context: ctx2, commandJSON: setStatus)
        let state = try decodeEnvelopeState(GraphStepState.self, from: r2.stateJSON)
        #expect(state.edges[0].status == .disputed)
        // The vocabulary itself contains no canonical/promoted case.
        #expect(Set(WorkflowGraphEdgeStatus.allCases) ==
                Set([.candidate, .supported, .disputed, .withdrawn]))
    }

    @Test("removing a node cascades to its edges")
    func removeNodeCascadesEdges() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let (stateJSON, nodeIDs) = try await twoNodeGraph(executor: executor, rig: rig, prepJSON: prepJSON)
        let edge = try WorkflowStepPayloadCodec.encode(GraphStepCommand.addEdge(
            sourceNodeID: nodeIDs[0], targetNodeID: nodeIDs[1],
            relationshipType: "linked_to", direction: .directed,
            provenance: .userDrawn(actorIdentifier: nil)))
        let ctx1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        let r1 = try await executor.execute(context: ctx1, commandJSON: edge)

        let remove = try WorkflowStepPayloadCodec.encode(GraphStepCommand.removeNode(nodeID: nodeIDs[0]))
        let ctx2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        let r2 = try await executor.execute(context: ctx2, commandJSON: remove)
        let state = try decodeEnvelopeState(GraphStepState.self, from: r2.stateJSON)
        #expect(state.nodes.count == 1)
        #expect(state.edges.isEmpty)
    }

    @Test("nodes and edges are stored as separate collections in state")
    func nodesAndEdgesSeparate() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let (stateJSON, _) = try await twoNodeGraph(executor: executor, rig: rig, prepJSON: prepJSON)
        let data = try #require(stateJSON.data(using: .utf8))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let state = try #require(root["state"] as? [String: Any])
        #expect(state["nodes"] is [Any])
        #expect(state["edges"] is [Any])
    }

    @Test("complete requires at least one node, then advances")
    func completeRequiresNode() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let complete = try WorkflowStepPayloadCodec.encode(GraphStepCommand.complete)
        let ctx1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prepJSON)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx1, commandJSON: complete)
        }
        let ctx2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prepJSON)
        let r1 = try await executor.execute(context: ctx2, commandJSON: try addProposal())
        let ctx3 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        let r2 = try await executor.execute(context: ctx3, commandJSON: complete)
        #expect(r2.disposition == .advance(.label("next")))
    }
}
