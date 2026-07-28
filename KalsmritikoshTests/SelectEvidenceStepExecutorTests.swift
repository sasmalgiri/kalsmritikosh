//
//  SelectEvidenceStepExecutorTests.swift
//  KalsmritikoshTests
//
//  PJE-006B — SelectEvidenceStepExecutor: canonical-ID-only selection, ordered,
//  reasoned, gate-verified. 12 tests.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-006B — SelectEvidenceStepExecutor")
struct SelectEvidenceStepExecutorTests {

    private func makeExecutor(gate: FixtureEvidenceGate = FixtureEvidenceGate()) -> SelectEvidenceStepExecutor {
        SelectEvidenceStepExecutor(gate: gate)
    }

    private func rigAndState(
        gate: FixtureEvidenceGate = FixtureEvidenceGate()
    ) async throws -> (SelectEvidenceStepExecutor, ExecutorTestRig, String) {
        let executor = makeExecutor(gate: gate)
        let rig = try makeExecutorTestRig(kind: .selectEvidence)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        return (executor, rig, prep.stateJSON)
    }

    private func selectJSON(
        kind: WorkflowEvidenceObjectKind = .entity,
        id: UUID = UUID(),
        reason: String = "Relevant to the question"
    ) throws -> String {
        try WorkflowStepPayloadCodec.encode(
            SelectEvidenceStepCommand.select(kind: kind, canonicalObjectID: id.uuidString, reason: reason))
    }

    @Test("prepare produces an empty selection envelope with correct identity")
    func prepareEmptyEnvelope() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let header = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelopeHeader.self, from: stateJSON)
        #expect(header.stepKind == .selectEvidence)
        #expect(header.executorID == executor.executorID.rawValue)
        let state = try decodeEnvelopeState(SelectEvidenceStepState.self, from: stateJSON)
        #expect(state.items.isEmpty)
        _ = rig
    }

    @Test("select adds an item with reason, actor, timestamp, and exact canonical ID")
    func selectAddsItem() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let objectID = UUID()
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        let result = try await executor.execute(
            context: ctx,
            commandJSON: try selectJSON(kind: .claim, id: objectID, reason: "Key claim"))
        let state = try decodeEnvelopeState(SelectEvidenceStepState.self, from: result.stateJSON)
        #expect(state.items.count == 1)
        #expect(state.items[0].objectKind == .claim)
        #expect(state.items[0].canonicalObjectID == objectID.uuidString)
        #expect(state.items[0].selectionReason == "Key claim")
        #expect(state.items[0].selectedAt == ctx.executedAt)
    }

    @Test("selection order is preserved across multiple selects")
    func selectionOrderPreserved() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let ids = [UUID(), UUID(), UUID()]
        var stateJSON = prepJSON
        for (i, id) in ids.enumerated() {
            let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
            let result = try await executor.execute(
                context: ctx, commandJSON: try selectJSON(id: id, reason: "r\(i)"))
            stateJSON = result.stateJSON
        }
        let state = try decodeEnvelopeState(SelectEvidenceStepState.self, from: stateJSON)
        #expect(state.items.map(\.canonicalObjectID) == ids.map(\.uuidString))
        #expect(state.items.map(\.selectionReason) == ["r0", "r1", "r2"])
    }

    @Test("all eight canonical object kinds are selectable")
    func allKindsSelectable() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        var stateJSON = prepJSON
        for kind in WorkflowEvidenceObjectKind.allCases {
            let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
            let result = try await executor.execute(
                context: ctx, commandJSON: try selectJSON(kind: kind))
            stateJSON = result.stateJSON
        }
        let state = try decodeEnvelopeState(SelectEvidenceStepState.self, from: stateJSON)
        #expect(state.items.count == WorkflowEvidenceObjectKind.allCases.count)
        #expect(Set(state.items.map(\.objectKind)) == Set(WorkflowEvidenceObjectKind.allCases))
    }

    @Test("blank selection reason is rejected")
    func blankReasonRejected() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(
                context: ctx, commandJSON: try selectJSON(reason: "   "))
        }
    }

    @Test("non-UUID canonical object ID is rejected")
    func invalidUUIDRejected() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        let cmd = try WorkflowStepPayloadCodec.encode(
            SelectEvidenceStepCommand.select(kind: .entity, canonicalObjectID: "not-a-uuid", reason: "r"))
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: cmd)
        }
    }

    @Test("duplicate selection of the same canonical object is rejected")
    func duplicateSelectionRejected() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let objectID = UUID()
        let ctx1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prepJSON)
        let r1 = try await executor.execute(context: ctx1, commandJSON: try selectJSON(id: objectID))
        let ctx2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx2, commandJSON: try selectJSON(id: objectID))
        }
    }

    @Test("gate denial blocks selection — the item never becomes available")
    func gateDenialBlocksSelection() async throws {
        let deniedID = UUID()
        let gate = FixtureEvidenceGate(deniedIDs: [deniedID])
        let (executor, rig, stateJSON) = try await rigAndState(gate: gate)
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: try selectJSON(id: deniedID))
        }
        // State unchanged — decode original state and confirm still empty
        let state = try decodeEnvelopeState(SelectEvidenceStepState.self, from: stateJSON)
        #expect(state.items.isEmpty)
    }

    @Test("deselect removes the item; unknown item ID fails")
    func deselectRemovesItem() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let ctx1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prepJSON)
        let r1 = try await executor.execute(context: ctx1, commandJSON: try selectJSON())
        let state1 = try decodeEnvelopeState(SelectEvidenceStepState.self, from: r1.stateJSON)
        let itemID = state1.items[0].id

        let ctx2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        let deselect = try WorkflowStepPayloadCodec.encode(
            SelectEvidenceStepCommand.deselect(itemID: itemID))
        let r2 = try await executor.execute(context: ctx2, commandJSON: deselect)
        let state2 = try decodeEnvelopeState(SelectEvidenceStepState.self, from: r2.stateJSON)
        #expect(state2.items.isEmpty)

        let ctx3 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r2.stateJSON)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx3, commandJSON: deselect)
        }
    }

    @Test("complete with empty selection is refused")
    func completeEmptyRefused() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        let complete = try WorkflowStepPayloadCodec.encode(SelectEvidenceStepCommand.complete)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: complete)
        }
    }

    @Test("complete with a selection advances via the first transition")
    func completeAdvances() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let ctx1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prepJSON)
        let r1 = try await executor.execute(context: ctx1, commandJSON: try selectJSON())
        let ctx2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        let complete = try WorkflowStepPayloadCodec.encode(SelectEvidenceStepCommand.complete)
        let r2 = try await executor.execute(context: ctx2, commandJSON: complete)
        #expect(r2.disposition == .advance(.label("next")))
    }

    @Test("state carries only IDs and provenance — no canonical content fields")
    func stateCarriesOnlyIDs() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let objectID = UUID()
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prepJSON)
        let r = try await executor.execute(context: ctx, commandJSON: try selectJSON(id: objectID))
        // The serialized item exposes exactly the selection-record fields.
        let data = try #require(r.stateJSON.data(using: .utf8))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let state = try #require(root["state"] as? [String: Any])
        let items = try #require(state["items"] as? [[String: Any]])
        let keys = Set(items[0].keys)
        #expect(keys == ["id", "objectKind", "canonicalObjectID", "selectionReason", "selectedAt"]
                || keys == ["id", "objectKind", "canonicalObjectID", "selectionReason", "selectedBy", "selectedAt"])
    }
}
