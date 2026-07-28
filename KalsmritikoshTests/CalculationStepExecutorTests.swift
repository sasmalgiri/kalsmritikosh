//
//  CalculationStepExecutorTests.swift
//  KalsmritikoshTests
//
//  PJE-006B — CalculationStepExecutor: closed deterministic operation vocabulary,
//  fail-closed inputs, deterministic recalculation. 14 tests.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-006B — CalculationStepExecutor")
struct CalculationStepExecutorTests {

    private func rigAndState(
        gate: FixtureEvidenceGate = FixtureEvidenceGate()
    ) async throws -> (CalculationStepExecutor, ExecutorTestRig, String) {
        let executor = CalculationStepExecutor(gate: gate)
        let rig = try makeExecutorTestRig(kind: .calculation)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        return (executor, rig, prep.stateJSON)
    }

    private func numbers(_ values: [Double]) -> [WorkflowCalculationInput] {
        values.map { WorkflowCalculationInput(literal: .number($0)) }
    }

    private func defineJSON(
        _ op: WorkflowCalculationOperation,
        inputs: [WorkflowCalculationInput],
        units: String? = nil
    ) throws -> String {
        try WorkflowStepPayloadCodec.encode(
            CalculationStepCommand.define(operation: op, inputs: inputs, units: units))
    }

    private func define(
        _ op: WorkflowCalculationOperation,
        inputs: [WorkflowCalculationInput],
        units: String? = nil,
        executor: CalculationStepExecutor,
        rig: ExecutorTestRig,
        stateJSON: String
    ) async throws -> WorkflowCalculationRecord {
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        let r = try await executor.execute(
            context: ctx, commandJSON: try defineJSON(op, inputs: inputs, units: units))
        let state = try decodeEnvelopeState(CalculationStepState.self, from: r.stateJSON)
        return state.calculations.last!
    }

    @Test("sum, minimum, maximum, average, count produce exact results")
    func aggregateOperations() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let values = numbers([4, 8, 15, 16, 23, 42])
        let sum = try await define(.sum, inputs: values, executor: executor, rig: rig, stateJSON: stateJSON)
        #expect(sum.result == 108)
        let minR = try await define(.minimum, inputs: values, executor: executor, rig: rig, stateJSON: stateJSON)
        #expect(minR.result == 4)
        let maxR = try await define(.maximum, inputs: values, executor: executor, rig: rig, stateJSON: stateJSON)
        #expect(maxR.result == 42)
        let avg = try await define(.average, inputs: values, executor: executor, rig: rig, stateJSON: stateJSON)
        #expect(avg.result == 18)
        let count = try await define(.count, inputs: values, executor: executor, rig: rig, stateJSON: stateJSON)
        #expect(count.result == 6)
    }

    @Test("difference, percentage, ratio produce exact results with normalized parameters")
    func pairwiseOperations() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let diff = try await define(.difference, inputs: numbers([100, 42]),
                                    executor: executor, rig: rig, stateJSON: stateJSON)
        #expect(diff.result == 58)
        let pct = try await define(.percentage, inputs: numbers([25, 200]),
                                   executor: executor, rig: rig, stateJSON: stateJSON)
        #expect(pct.result == 12.5)
        #expect(pct.normalizedParameters["unit"] == "percent")
        let ratio = try await define(.ratio, inputs: numbers([3, 4]),
                                     executor: executor, rig: rig, stateJSON: stateJSON)
        #expect(ratio.result == 0.75)
    }

    @Test("dateDifference computes whole days with unit=days")
    func dateDifferenceDays() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let inputs: [WorkflowCalculationInput] = [
            WorkflowCalculationInput(literal: .date("2025-03-11T00:00:00Z")),
            WorkflowCalculationInput(literal: .date("2025-04-10T00:00:00Z"))
        ]
        let record = try await define(.dateDifference, inputs: inputs,
                                      executor: executor, rig: rig, stateJSON: stateJSON)
        #expect(record.result == 30)
        #expect(record.normalizedParameters["unit"] == "days")
        #expect(record.warnings.isEmpty)
    }

    @Test("fractional dateDifference records a warning")
    func fractionalDateDifferenceWarns() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let inputs: [WorkflowCalculationInput] = [
            WorkflowCalculationInput(literal: .date("2025-03-11T00:00:00Z")),
            WorkflowCalculationInput(literal: .date("2025-03-11T12:00:00Z"))
        ]
        let record = try await define(.dateDifference, inputs: inputs,
                                      executor: executor, rig: rig, stateJSON: stateJSON)
        #expect(record.result == 0.5)
        #expect(!record.warnings.isEmpty)
    }

    @Test("nonnumeric input in a numeric operation fails closed")
    func nonnumericInputFailsClosed() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let mixed: [WorkflowCalculationInput] = [
            WorkflowCalculationInput(literal: .number(1)),
            WorkflowCalculationInput(literal: .date("2025-03-11T00:00:00Z"))
        ]
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: try defineJSON(.sum, inputs: mixed))
        }
    }

    @Test("numeric input in dateDifference fails closed")
    func numberInDateDifferenceFailsClosed() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(
                context: ctx, commandJSON: try defineJSON(.dateDifference, inputs: numbers([1, 2])))
        }
    }

    @Test("unparseable date fails closed")
    func unparseableDateFailsClosed() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let inputs: [WorkflowCalculationInput] = [
            WorkflowCalculationInput(literal: .date("March 11, 2025")),
            WorkflowCalculationInput(literal: .date("2025-04-10T00:00:00Z"))
        ]
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(
                context: ctx, commandJSON: try defineJSON(.dateDifference, inputs: inputs))
        }
    }

    @Test("missing inputs fail closed — empty sum and wrong arity difference")
    func missingInputsFailClosed() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let ctx1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx1, commandJSON: try defineJSON(.sum, inputs: []))
        }
        let ctx2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(
                context: ctx2, commandJSON: try defineJSON(.difference, inputs: numbers([1, 2, 3])))
        }
    }

    @Test("division by zero fails closed for percentage and ratio")
    func divisionByZeroFailsClosed() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let ctx1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(
                context: ctx1, commandJSON: try defineJSON(.percentage, inputs: numbers([5, 0])))
        }
        let ctx2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(
                context: ctx2, commandJSON: try defineJSON(.ratio, inputs: numbers([5, 0])))
        }
    }

    @Test("record carries operation ID, semantics version, inputs, units")
    func recordCarriesProvenance() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let refID = UUID()
        let inputs = [
            WorkflowCalculationInput(literal: .number(1200), referenceKind: .claim, referenceID: refID.uuidString),
            WorkflowCalculationInput(literal: .number(800))
        ]
        let record = try await define(.sum, inputs: inputs, units: "EUR",
                                      executor: executor, rig: rig, stateJSON: stateJSON)
        #expect(record.operation == .sum)
        #expect(record.operationVersion == WorkflowCalculationOperation.semanticsVersion)
        #expect(record.inputs == inputs)
        #expect(record.units == "EUR")
        #expect(record.result == 2000)
    }

    @Test("gate denial on an input provenance reference fails the define")
    func gateDenialOnReferenceFails() async throws {
        let deniedID = UUID()
        let (executor, rig, stateJSON) = try await rigAndState(
            gate: FixtureEvidenceGate(deniedIDs: [deniedID]))
        let inputs = [WorkflowCalculationInput(
            literal: .number(5), referenceKind: .evidenceBlock, referenceID: deniedID.uuidString)]
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: try defineJSON(.sum, inputs: inputs))
        }
    }

    @Test("recalculate recomputes deterministically from stored inputs")
    func recalculateDeterministic() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let ctx1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prepJSON)
        let r1 = try await executor.execute(
            context: ctx1, commandJSON: try defineJSON(.average, inputs: numbers([10, 20, 30])))
        let before = try decodeEnvelopeState(CalculationStepState.self, from: r1.stateJSON).calculations[0]

        let recalc = try WorkflowStepPayloadCodec.encode(
            CalculationStepCommand.recalculate(calculationID: before.id))
        let ctx2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        let r2 = try await executor.execute(context: ctx2, commandJSON: recalc)
        let after = try decodeEnvelopeState(CalculationStepState.self, from: r2.stateJSON).calculations[0]
        #expect(after.id == before.id)
        #expect(after.result == before.result)
        #expect(after.inputs == before.inputs)
        #expect(after.result == 20)
    }

    @Test("remove deletes a calculation; unknown ID fails")
    func removeCalculation() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let ctx1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prepJSON)
        let r1 = try await executor.execute(
            context: ctx1, commandJSON: try defineJSON(.count, inputs: numbers([1])))
        let calcID = try decodeEnvelopeState(CalculationStepState.self, from: r1.stateJSON).calculations[0].id

        let remove = try WorkflowStepPayloadCodec.encode(
            CalculationStepCommand.remove(calculationID: calcID))
        let ctx2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        let r2 = try await executor.execute(context: ctx2, commandJSON: remove)
        #expect(try decodeEnvelopeState(CalculationStepState.self, from: r2.stateJSON).calculations.isEmpty)

        let ctx3 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r2.stateJSON)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx3, commandJSON: remove)
        }
    }

    @Test("complete requires at least one calculation, then advances")
    func completeRequiresCalculation() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let complete = try WorkflowStepPayloadCodec.encode(CalculationStepCommand.complete)
        let ctx1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prepJSON)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx1, commandJSON: complete)
        }
        let ctx2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prepJSON)
        let r1 = try await executor.execute(
            context: ctx2, commandJSON: try defineJSON(.sum, inputs: numbers([1, 2])))
        let ctx3 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        let r2 = try await executor.execute(context: ctx3, commandJSON: complete)
        #expect(r2.disposition == .advance(.label("next")))
    }
}
