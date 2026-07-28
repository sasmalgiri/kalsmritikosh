//
//  TableStepExecutorTests.swift
//  KalsmritikoshTests
//
//  PJE-006A — TableStepExecutor: row/cell commands, completion guard.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-006A — TableStepExecutor")
struct TableStepExecutorTests {

    private let executor = TableStepExecutor()

    // MARK: - Identity

    @Test("executorID, executorVersion, handledKind are stable")
    func identity() {
        #expect(executor.executorID.rawValue == "com.kalsmritikosh.step.table")
        #expect(executor.executorVersion.rawValue == "1.0")
        #expect(executor.handledKind == .table)
    }

    // MARK: - prepare()

    @Test("prepare() returns empty TableStepState")
    func prepareEmptyState() async throws {
        let rig = try makeExecutorTestRig(kind: .table)
        let result = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let state = try decodeEnvelopeState(TableStepState.self, from: result.stateJSON)
        #expect(state.rows.isEmpty)
    }

    // MARK: - addRow

    @Test("addRow appends a new row")
    func addRow() async throws {
        let rig = try makeExecutorTestRig(kind: .table)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let cmd = try WorkflowStepPayloadCodec.encode(TableStepCommand.addRow(id: "row1"))
        let ec = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        let result = try await executor.execute(context: ec, commandJSON: cmd)
        let state = try decodeEnvelopeState(TableStepState.self, from: result.stateJSON)
        #expect(state.rows.count == 1)
        #expect(state.rows.first?.id == "row1")
    }

    // MARK: - setCell

    @Test("setCell creates the row if it doesn't exist")
    func setCellCreatesRow() async throws {
        let rig = try makeExecutorTestRig(kind: .table)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let cmd = try WorkflowStepPayloadCodec.encode(
            TableStepCommand.setCell(rowID: "r1", columnID: "c1", value: .text("Hello")))
        let ec = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        let result = try await executor.execute(context: ec, commandJSON: cmd)
        let state = try decodeEnvelopeState(TableStepState.self, from: result.stateJSON)
        #expect(state.rows.count == 1)
        #expect(state.rows.first?.cells["c1"] == .text("Hello"))
    }

    // MARK: - clearCell

    @Test("clearCell removes the cell value")
    func clearCell() async throws {
        let rig = try makeExecutorTestRig(kind: .table)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let setCmd = try WorkflowStepPayloadCodec.encode(
            TableStepCommand.setCell(rowID: "r1", columnID: "col", value: .number(42)))
        let ec1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        let r1 = try await executor.execute(context: ec1, commandJSON: setCmd)
        let clearCmd = try WorkflowStepPayloadCodec.encode(
            TableStepCommand.clearCell(rowID: "r1", columnID: "col"))
        let ec2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        let r2 = try await executor.execute(context: ec2, commandJSON: clearCmd)
        let state = try decodeEnvelopeState(TableStepState.self, from: r2.stateJSON)
        #expect(state.rows.first?.cells["col"] == nil)
    }

    // MARK: - removeRow

    @Test("removeRow removes the row")
    func removeRow() async throws {
        let rig = try makeExecutorTestRig(kind: .table)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let addCmd = try WorkflowStepPayloadCodec.encode(TableStepCommand.addRow(id: "r1"))
        let ec1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        let r1 = try await executor.execute(context: ec1, commandJSON: addCmd)
        let removeCmd = try WorkflowStepPayloadCodec.encode(TableStepCommand.removeRow(id: "r1"))
        let ec2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        let r2 = try await executor.execute(context: ec2, commandJSON: removeCmd)
        let state = try decodeEnvelopeState(TableStepState.self, from: r2.stateJSON)
        #expect(state.rows.isEmpty)
    }

    // MARK: - complete

    @Test("complete with rows returns advance")
    func completeWithRows() async throws {
        let rig = try makeExecutorTestRig(kind: .table)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let addCmd = try WorkflowStepPayloadCodec.encode(TableStepCommand.addRow(id: "r1"))
        let ec1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        let r1 = try await executor.execute(context: ec1, commandJSON: addCmd)
        let completeCmd = try WorkflowStepPayloadCodec.encode(TableStepCommand.complete)
        let ec2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        let result = try await executor.execute(context: ec2, commandJSON: completeCmd)
        if case .advance(.label(let label)) = result.disposition {
            #expect(label == "next")
        } else {
            Issue.record("Expected .advance(.label(\"next\"))")
        }
    }

    @Test("complete with no rows throws completionNotReady")
    func completeNoRowsFails() async throws {
        let rig = try makeExecutorTestRig(kind: .table)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let cmd = try WorkflowStepPayloadCodec.encode(TableStepCommand.complete)
        let ec = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        await #expect(throws: (any Error).self) {
            _ = try await executor.execute(context: ec, commandJSON: cmd)
        }
    }

    // MARK: - value types

    @Test("WorkflowTableCellValue.empty roundtrips through encode/decode")
    func emptyCellValue() throws {
        let json = try WorkflowStepPayloadCodec.encode(WorkflowTableCellValue.empty)
        let decoded = try WorkflowStepPayloadCodec.decode(WorkflowTableCellValue.self, from: json)
        #expect(decoded == .empty)
    }
}
