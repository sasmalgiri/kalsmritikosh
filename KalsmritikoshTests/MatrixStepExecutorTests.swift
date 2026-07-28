//
//  MatrixStepExecutorTests.swift
//  KalsmritikoshTests
//
//  PJE-006A — MatrixStepExecutor: row/column/cell commands, custom Codable, completion guard.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-006A — MatrixStepExecutor")
struct MatrixStepExecutorTests {

    private let executor = MatrixStepExecutor()

    // MARK: - Identity

    @Test("executorID, executorVersion, handledKind are stable")
    func identity() {
        #expect(executor.executorID.rawValue == "com.kalsmritikosh.step.matrix")
        #expect(executor.executorVersion.rawValue == "1.0")
        #expect(executor.handledKind == .matrix)
    }

    // MARK: - prepare()

    @Test("prepare() returns empty MatrixStepState")
    func prepareEmptyState() async throws {
        let rig = try makeExecutorTestRig(kind: .matrix)
        let result = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let state = try decodeEnvelopeState(MatrixStepState.self, from: result.stateJSON)
        #expect(state.rowIDs.isEmpty)
        #expect(state.columnIDs.isEmpty)
        #expect(state.cells.isEmpty)
    }

    // MARK: - addRow / addColumn

    @Test("addRow and addColumn populate dimension lists")
    func addRowAndColumn() async throws {
        let rig = try makeExecutorTestRig(kind: .matrix)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let addRow = try WorkflowStepPayloadCodec.encode(MatrixStepCommand.addRow(id: "r1"))
        let ec1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        let r1 = try await executor.execute(context: ec1, commandJSON: addRow)
        let addCol = try WorkflowStepPayloadCodec.encode(MatrixStepCommand.addColumn(id: "c1"))
        let ec2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        let r2 = try await executor.execute(context: ec2, commandJSON: addCol)
        let state = try decodeEnvelopeState(MatrixStepState.self, from: r2.stateJSON)
        #expect(state.rowIDs == ["r1"])
        #expect(state.columnIDs == ["c1"])
    }

    // MARK: - setCell

    @Test("setCell stores cell at composite key")
    func setCell() async throws {
        let rig = try makeExecutorTestRig(kind: .matrix)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let cmd = try WorkflowStepPayloadCodec.encode(
            MatrixStepCommand.setCell(rowID: "r1", columnID: "c1", value: .text("X"), label: nil))
        let ec = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        let result = try await executor.execute(context: ec, commandJSON: cmd)
        let state = try decodeEnvelopeState(MatrixStepState.self, from: result.stateJSON)
        let key = WorkflowMatrixCellKey(rowID: "r1", columnID: "c1")
        #expect(state.cells[key]?.value == .text("X"))
    }

    // MARK: - removeRow cascades

    @Test("removeRow removes cells in that row")
    func removeRowCascades() async throws {
        let rig = try makeExecutorTestRig(kind: .matrix)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let setCellCmd = try WorkflowStepPayloadCodec.encode(
            MatrixStepCommand.setCell(rowID: "r1", columnID: "c1", value: .boolean(true), label: nil))
        let ec1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        let r1 = try await executor.execute(context: ec1, commandJSON: setCellCmd)
        let removeRowCmd = try WorkflowStepPayloadCodec.encode(MatrixStepCommand.removeRow(id: "r1"))
        let ec2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        let r2 = try await executor.execute(context: ec2, commandJSON: removeRowCmd)
        let state = try decodeEnvelopeState(MatrixStepState.self, from: r2.stateJSON)
        let key = WorkflowMatrixCellKey(rowID: "r1", columnID: "c1")
        #expect(state.cells[key] == nil)
    }

    // MARK: - MatrixStepState custom Codable

    @Test("MatrixStepState custom Codable roundtrips composite key correctly")
    func customCodableRoundtrip() throws {
        var state = MatrixStepState(rowIDs: ["r1", "r2"], columnIDs: ["c1"])
        let key = WorkflowMatrixCellKey(rowID: "r1", columnID: "c1")
        state.cells[key] = WorkflowMatrixCell(value: .number(99), label: "Score")
        let executor2 = MatrixStepExecutor()
        let (json, _) = try executor2.makeEnvelope(state: state, stepKind: .matrix)
        let decoded = try decodeEnvelopeState(MatrixStepState.self, from: json)
        #expect(decoded.cells[key]?.value == .number(99))
        #expect(decoded.cells[key]?.label == "Score")
        #expect(decoded.rowIDs == ["r1", "r2"])
    }

    // MARK: - complete

    @Test("complete with at least one row and column returns advance")
    func completeWithRowAndColumn() async throws {
        let rig = try makeExecutorTestRig(kind: .matrix)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let addRow = try WorkflowStepPayloadCodec.encode(MatrixStepCommand.addRow(id: "r1"))
        let ec1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        let r1 = try await executor.execute(context: ec1, commandJSON: addRow)
        let addCol = try WorkflowStepPayloadCodec.encode(MatrixStepCommand.addColumn(id: "c1"))
        let ec2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        let r2 = try await executor.execute(context: ec2, commandJSON: addCol)
        let completeCmd = try WorkflowStepPayloadCodec.encode(MatrixStepCommand.complete)
        let ec3 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r2.stateJSON)
        let result = try await executor.execute(context: ec3, commandJSON: completeCmd)
        if case .advance(.label(let label)) = result.disposition {
            #expect(label == "next")
        } else {
            Issue.record("Expected .advance(.label(\"next\"))")
        }
    }

    @Test("complete with no rows or columns throws completionNotReady")
    func completeEmptyFails() async throws {
        let rig = try makeExecutorTestRig(kind: .matrix)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let cmd = try WorkflowStepPayloadCodec.encode(MatrixStepCommand.complete)
        let ec = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        await #expect(throws: (any Error).self) {
            _ = try await executor.execute(context: ec, commandJSON: cmd)
        }
    }
}
