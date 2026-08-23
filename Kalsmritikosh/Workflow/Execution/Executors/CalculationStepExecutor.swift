//
//  CalculationStepExecutor.swift
//  Kalsmritikosh
//
//  PJE-006B — Evidence and Analytical Step Executors.
//  Handles the `calculation` step kind.
//
//  A CLOSED deterministic operation vocabulary — no eval, no JavaScript, no Python,
//  no free-form formulas. Each calculation records its input references, literal
//  inputs, operation ID + version, normalized parameters, result, units, and
//  warnings, and recomputes deterministically after relaunch. Unsupported, missing,
//  or nonnumeric inputs fail closed. A calculated result is NOT evidence — promotion
//  goes through the established reviewed derivation path, never from here.
//  Commands: define, recalculate, remove, complete.
//

import Foundation

// MARK: - Operation vocabulary

/// The closed set of safe deterministic operations. Version is per-executor-release.
public enum WorkflowCalculationOperation: String, Codable, Sendable, CaseIterable, Equatable {
    case sum
    case count
    case minimum
    case maximum
    case average
    case difference
    case percentage
    case ratio
    case dateDifference

    /// Version token of the operation semantics implemented in WorkflowCalculationEngine.
    public static nonisolated let semanticsVersion = "1.0"
}

// MARK: - Literal input

/// A literal input value snapshotted at definition time. The calculation always
/// recomputes from these literals — never from a live canonical read.
public nonisolated enum WorkflowCalculationLiteral: Sendable, Equatable {
    case number(Double)
    case date(String)   // strict ISO-8601 (e.g. 2026-07-28T00:00:00Z)
}

extension WorkflowCalculationLiteral: Codable {
    private enum CodingKeys: String, CodingKey { case type, value }

    public nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "number": self = .number(try c.decode(Double.self, forKey: .value))
        case "date":   self = .date(try c.decode(String.self, forKey: .value))
        default: throw WorkflowStepExecutionError.malformedStateJSON
        }
    }

    public nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .number(let v): try c.encode("number", forKey: .type); try c.encode(v, forKey: .value)
        case .date(let v):   try c.encode("date", forKey: .type);   try c.encode(v, forKey: .value)
        }
    }
}

// MARK: - Input (literal + optional canonical provenance)

public nonisolated struct WorkflowCalculationInput: Codable, Sendable, Equatable {
    public let literal: WorkflowCalculationLiteral
    /// Optional canonical provenance — where this literal was read from.
    public let referenceKind: WorkflowEvidenceObjectKind?
    public let referenceID: String?

    public nonisolated init(
        literal: WorkflowCalculationLiteral,
        referenceKind: WorkflowEvidenceObjectKind? = nil,
        referenceID: String? = nil
    ) {
        self.literal = literal
        self.referenceKind = referenceKind
        self.referenceID = referenceID
    }
}

// MARK: - Calculation record

public nonisolated struct WorkflowCalculationRecord: Codable, Sendable, Equatable {
    public let id: UUID
    public let operation: WorkflowCalculationOperation
    public let operationVersion: String
    public let inputs: [WorkflowCalculationInput]
    public let normalizedParameters: [String: String]
    public let result: Double
    public let units: String?
    public let warnings: [String]

    public nonisolated init(
        id: UUID,
        operation: WorkflowCalculationOperation,
        operationVersion: String,
        inputs: [WorkflowCalculationInput],
        normalizedParameters: [String: String],
        result: Double,
        units: String?,
        warnings: [String]
    ) {
        self.id = id
        self.operation = operation
        self.operationVersion = operationVersion
        self.inputs = inputs
        self.normalizedParameters = normalizedParameters
        self.result = result
        self.units = units
        self.warnings = warnings
    }
}

// MARK: - State

public nonisolated struct CalculationStepState: Codable, Sendable {
    public var calculations: [WorkflowCalculationRecord]

    public nonisolated init(calculations: [WorkflowCalculationRecord] = []) {
        self.calculations = calculations
    }
}

// MARK: - Command

public enum CalculationStepCommand: Sendable, Equatable {
    case define(
        operation: WorkflowCalculationOperation,
        inputs: [WorkflowCalculationInput],
        units: String?
    )
    case recalculate(calculationID: UUID)
    case remove(calculationID: UUID)
    case complete
}

extension CalculationStepCommand: Codable {
    private enum CodingKeys: String, CodingKey { case type, operation, inputs, units, calculationID }

    public nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "define":
            self = .define(
                operation: try c.decode(WorkflowCalculationOperation.self, forKey: .operation),
                inputs: try c.decode([WorkflowCalculationInput].self, forKey: .inputs),
                units: try c.decodeIfPresent(String.self, forKey: .units)
            )
        case "recalculate":
            self = .recalculate(calculationID: try c.decode(UUID.self, forKey: .calculationID))
        case "remove":
            self = .remove(calculationID: try c.decode(UUID.self, forKey: .calculationID))
        case "complete":
            self = .complete
        default:
            throw WorkflowStepExecutionError.malformedCommandJSON
        }
    }

    public nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .define(let operation, let inputs, let units):
            try c.encode("define", forKey: .type)
            try c.encode(operation, forKey: .operation)
            try c.encode(inputs, forKey: .inputs)
            if let units = units { try c.encode(units, forKey: .units) }
        case .recalculate(let calculationID):
            try c.encode("recalculate", forKey: .type)
            try c.encode(calculationID, forKey: .calculationID)
        case .remove(let calculationID):
            try c.encode("remove", forKey: .type)
            try c.encode(calculationID, forKey: .calculationID)
        case .complete:
            try c.encode("complete", forKey: .type)
        }
    }
}

// MARK: - Deterministic calculation engine

/// Pure functions — same inputs, same result, on every launch.
public enum WorkflowCalculationEngine {

    /// Strict fixed-format ISO-8601 parser. No locale, no calendar drift.
    private static nonisolated func parseDate(_ iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let d = formatter.date(from: iso) { return d }
        // Also accept date-only form (interpreted at 00:00:00Z)
        let dateOnly = ISO8601DateFormatter()
        dateOnly.formatOptions = [.withFullDate]
        return dateOnly.date(from: iso)
    }

    private static nonisolated func numericValues(
        _ inputs: [WorkflowCalculationInput]
    ) throws -> [Double] {
        try inputs.map { input in
            guard case .number(let v) = input.literal else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "inputs", reason: "Nonnumeric input in a numeric operation"
                )
            }
            guard v.isFinite else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "inputs", reason: "Non-finite numeric input"
                )
            }
            return v
        }
    }

    /// Computes the operation. Throws on unsupported arity, nonnumeric input,
    /// unparseable dates, or division by zero — always fail closed.
    public static nonisolated func compute(
        operation: WorkflowCalculationOperation,
        inputs: [WorkflowCalculationInput]
    ) throws -> (result: Double, normalizedParameters: [String: String], warnings: [String]) {
        var warnings: [String] = []
        var parameters: [String: String] = [
            "operation": operation.rawValue,
            "inputCount": String(inputs.count)
        ]

        switch operation {
        case .count:
            return (Double(inputs.count), parameters, warnings)

        case .sum:
            let values = try numericValues(inputs)
            guard !values.isEmpty else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "inputs", reason: "sum requires at least one input"
                )
            }
            return (values.reduce(0, +), parameters, warnings)

        case .minimum:
            let values = try numericValues(inputs)
            guard let m = values.min() else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "inputs", reason: "minimum requires at least one input"
                )
            }
            return (m, parameters, warnings)

        case .maximum:
            let values = try numericValues(inputs)
            guard let m = values.max() else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "inputs", reason: "maximum requires at least one input"
                )
            }
            return (m, parameters, warnings)

        case .average:
            let values = try numericValues(inputs)
            guard !values.isEmpty else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "inputs", reason: "average requires at least one input"
                )
            }
            return (values.reduce(0, +) / Double(values.count), parameters, warnings)

        case .difference:
            let values = try numericValues(inputs)
            guard values.count == 2 else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "inputs", reason: "difference requires exactly two inputs"
                )
            }
            return (values[0] - values[1], parameters, warnings)

        case .percentage:
            let values = try numericValues(inputs)
            guard values.count == 2 else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "inputs", reason: "percentage requires exactly two inputs"
                )
            }
            guard values[1] != 0 else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "inputs", reason: "percentage denominator must not be zero"
                )
            }
            parameters["unit"] = "percent"
            return (values[0] / values[1] * 100.0, parameters, warnings)

        case .ratio:
            let values = try numericValues(inputs)
            guard values.count == 2 else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "inputs", reason: "ratio requires exactly two inputs"
                )
            }
            guard values[1] != 0 else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "inputs", reason: "ratio denominator must not be zero"
                )
            }
            return (values[0] / values[1], parameters, warnings)

        case .dateDifference:
            guard inputs.count == 2 else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "inputs", reason: "dateDifference requires exactly two inputs"
                )
            }
            let dates: [Date] = try inputs.map { input in
                guard case .date(let iso) = input.literal else {
                    throw WorkflowStepExecutionError.validationFailed(
                        field: "inputs", reason: "dateDifference requires date inputs"
                    )
                }
                guard let d = parseDate(iso) else {
                    throw WorkflowStepExecutionError.validationFailed(
                        field: "inputs", reason: "Unparseable ISO-8601 date: \(iso)"
                    )
                }
                return d
            }
            parameters["unit"] = "days"
            let seconds = dates[1].timeIntervalSince(dates[0])
            let days = seconds / 86_400.0
            if days != days.rounded(.towardZero) {
                warnings.append("Date difference is not a whole number of days")
            }
            return (days, parameters, warnings)
        }
    }
}

// MARK: - Executor

public nonisolated struct CalculationStepExecutor: WorkflowStepExecutor {

    public nonisolated let executorID = WorkflowStepExecutorID(
        rawValue: "com.kalsmritikosh.step.calculation"
    )
    public nonisolated let executorVersion = WorkflowStepExecutorVersion(rawValue: "1.0")
    public nonisolated let handledKind: WorkflowStepKind = .calculation

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
        let (json, sha) = try makeEnvelope(state: CalculationStepState(), stepKind: handledKind)
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
        var state = try decodeCurrentState(CalculationStepState.self, from: context.stepRun)
        let command: CalculationStepCommand
        do {
            command = try WorkflowStepPayloadCodec.decode(CalculationStepCommand.self, from: commandJSON)
        } catch {
            throw WorkflowStepExecutionError.malformedCommandJSON
        }

        func save() throws -> WorkflowStepExecutionResult {
            let (json, sha) = try makeEnvelope(state: state, stepKind: handledKind)
            return WorkflowStepExecutionResult(stateJSON: json, stateSHA256: sha, disposition: .remainActive)
        }

        switch command {
        case .define(let operation, let inputs, let units):
            // Verify canonical provenance references through the gate (fail closed).
            for input in inputs {
                if let refKind = input.referenceKind {
                    guard let refIDString = input.referenceID,
                          let refUUID = UUID(uuidString: refIDString) else {
                        throw WorkflowStepExecutionError.validationFailed(
                            field: "inputs", reason: "Input reference must carry a valid UUID"
                        )
                    }
                    let verdict = await gate.verdict(
                        kind: refKind,
                        canonicalObjectID: refUUID,
                        workspaceID: context.aggregate.run.workspaceID
                    )
                    guard case .permitted = verdict else {
                        if case .denied(let why) = verdict {
                            throw WorkflowStepExecutionError.validationFailed(
                                field: "inputs", reason: why
                            )
                        }
                        throw WorkflowStepExecutionError.validationFailed(
                            field: "inputs", reason: "Input reference denied"
                        )
                    }
                } else if input.referenceID != nil {
                    throw WorkflowStepExecutionError.validationFailed(
                        field: "inputs", reason: "Input reference ID without a reference kind"
                    )
                }
            }
            let (result, parameters, warnings) = try WorkflowCalculationEngine.compute(
                operation: operation, inputs: inputs
            )
            state.calculations.append(WorkflowCalculationRecord(
                id: UUID(),
                operation: operation,
                operationVersion: WorkflowCalculationOperation.semanticsVersion,
                inputs: inputs,
                normalizedParameters: parameters,
                result: result,
                units: units,
                warnings: warnings
            ))
            return try save()

        case .recalculate(let calculationID):
            guard let index = state.calculations.firstIndex(where: { $0.id == calculationID }) else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "calculationID", reason: "No calculation with this ID"
                )
            }
            let record = state.calculations[index]
            // Deterministic recompute from the STORED inputs — no live reads.
            let (result, parameters, warnings) = try WorkflowCalculationEngine.compute(
                operation: record.operation, inputs: record.inputs
            )
            state.calculations[index] = WorkflowCalculationRecord(
                id: record.id,
                operation: record.operation,
                operationVersion: WorkflowCalculationOperation.semanticsVersion,
                inputs: record.inputs,
                normalizedParameters: parameters,
                result: result,
                units: record.units,
                warnings: warnings
            )
            return try save()

        case .remove(let calculationID):
            guard state.calculations.contains(where: { $0.id == calculationID }) else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "calculationID", reason: "No calculation with this ID"
                )
            }
            state.calculations.removeAll { $0.id == calculationID }
            return try save()

        case .complete:
            guard !state.calculations.isEmpty else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind, reason: "At least one calculation must be defined"
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
