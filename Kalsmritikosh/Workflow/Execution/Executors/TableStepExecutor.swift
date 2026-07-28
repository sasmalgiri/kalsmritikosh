//
//  TableStepExecutor.swift
//  Kalsmritikosh
//
//  PJE-006A — Step Executor Runtime and Working-Surface Pack.
//  Handles the `table` step kind.
//  Commands: setCell, clearCell, addRow, removeRow, complete.
//

import Foundation

// MARK: - Table cell value

/// Closed enum for typed values in a table cell.
public enum WorkflowTableCellValue: Sendable, Equatable {
    case text(String)
    case number(Double)
    case boolean(Bool)
    case date(String)       // ISO-8601 string
    case selection(String)
    case empty
}

extension WorkflowTableCellValue: Codable {
    private enum CodingKeys: String, CodingKey { case type, value }

    public nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":      self = .text(try c.decode(String.self, forKey: .value))
        case "number":    self = .number(try c.decode(Double.self, forKey: .value))
        case "boolean":   self = .boolean(try c.decode(Bool.self, forKey: .value))
        case "date":      self = .date(try c.decode(String.self, forKey: .value))
        case "selection": self = .selection(try c.decode(String.self, forKey: .value))
        case "empty":     self = .empty
        default: throw WorkflowStepExecutionError.malformedStateJSON
        }
    }

    public nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let v):      try c.encode("text", forKey: .type);      try c.encode(v, forKey: .value)
        case .number(let v):    try c.encode("number", forKey: .type);    try c.encode(v, forKey: .value)
        case .boolean(let v):   try c.encode("boolean", forKey: .type);   try c.encode(v, forKey: .value)
        case .date(let v):      try c.encode("date", forKey: .type);      try c.encode(v, forKey: .value)
        case .selection(let v): try c.encode("selection", forKey: .type); try c.encode(v, forKey: .value)
        case .empty:            try c.encode("empty", forKey: .type)
        }
    }
}

// MARK: - Table state

/// A table row: ordered column-id → value mapping.
public nonisolated struct WorkflowTableRow: Codable, Sendable {
    public var id: String
    public var cells: [String: WorkflowTableCellValue]

    public nonisolated init(id: String, cells: [String: WorkflowTableCellValue] = [:]) {
        self.id = id
        self.cells = cells
    }
}

public nonisolated struct TableStepState: Codable, Sendable {
    public var rows: [WorkflowTableRow]

    public nonisolated init(rows: [WorkflowTableRow] = []) {
        self.rows = rows
    }
}

// MARK: - Table command

public enum TableStepCommand: Sendable, Equatable {
    case setCell(rowID: String, columnID: String, value: WorkflowTableCellValue)
    case clearCell(rowID: String, columnID: String)
    case addRow(id: String)
    case removeRow(id: String)
    case complete
}

extension TableStepCommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, rowID, columnID, value, id
    }

    public nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "setCell":
            self = .setCell(rowID: try c.decode(String.self, forKey: .rowID),
                            columnID: try c.decode(String.self, forKey: .columnID),
                            value: try c.decode(WorkflowTableCellValue.self, forKey: .value))
        case "clearCell":
            self = .clearCell(rowID: try c.decode(String.self, forKey: .rowID),
                              columnID: try c.decode(String.self, forKey: .columnID))
        case "addRow":
            self = .addRow(id: try c.decode(String.self, forKey: .id))
        case "removeRow":
            self = .removeRow(id: try c.decode(String.self, forKey: .id))
        case "complete":
            self = .complete
        default:
            throw WorkflowStepExecutionError.malformedCommandJSON
        }
    }

    public nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .setCell(let rID, let cID, let v):
            try c.encode("setCell", forKey: .type)
            try c.encode(rID, forKey: .rowID); try c.encode(cID, forKey: .columnID)
            try c.encode(v, forKey: .value)
        case .clearCell(let rID, let cID):
            try c.encode("clearCell", forKey: .type)
            try c.encode(rID, forKey: .rowID); try c.encode(cID, forKey: .columnID)
        case .addRow(let id):
            try c.encode("addRow", forKey: .type); try c.encode(id, forKey: .id)
        case .removeRow(let id):
            try c.encode("removeRow", forKey: .type); try c.encode(id, forKey: .id)
        case .complete:
            try c.encode("complete", forKey: .type)
        }
    }
}

// MARK: - Executor

public nonisolated struct TableStepExecutor: WorkflowStepExecutor {

    public nonisolated let executorID = WorkflowStepExecutorID(
        rawValue: "com.kalsmritikosh.step.table"
    )
    public nonisolated let executorVersion = WorkflowStepExecutorVersion(rawValue: "1.0")
    public nonisolated let handledKind: WorkflowStepKind = .table

    public nonisolated init() {}

    public func prepare(
        context: WorkflowStepPreparationContext
    ) async throws -> WorkflowStepPreparationResult {
        guard context.step.kind == handledKind else {
            throw WorkflowStepExecutionError.executorKindMismatch(
                executor: executorID, expected: handledKind, actual: context.step.kind
            )
        }
        let (json, sha) = try makeEnvelope(state: TableStepState(), stepKind: handledKind)
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
        var state = try decodeCurrentState(TableStepState.self, from: context.stepRun)
        let command: TableStepCommand
        do {
            command = try WorkflowStepPayloadCodec.decode(TableStepCommand.self, from: commandJSON)
        } catch {
            throw WorkflowStepExecutionError.malformedCommandJSON
        }

        func save() throws -> WorkflowStepExecutionResult {
            let (json, sha) = try makeEnvelope(state: state, stepKind: handledKind)
            return WorkflowStepExecutionResult(stateJSON: json, stateSHA256: sha, disposition: .remainActive)
        }

        switch command {
        case .setCell(let rowID, let colID, let value):
            if let i = state.rows.firstIndex(where: { $0.id == rowID }) {
                state.rows[i].cells[colID] = value
            } else {
                state.rows.append(WorkflowTableRow(id: rowID, cells: [colID: value]))
            }
            return try save()
        case .clearCell(let rowID, let colID):
            if let i = state.rows.firstIndex(where: { $0.id == rowID }) {
                state.rows[i].cells.removeValue(forKey: colID)
            }
            return try save()
        case .addRow(let id):
            if !state.rows.contains(where: { $0.id == id }) {
                state.rows.append(WorkflowTableRow(id: id))
            }
            return try save()
        case .removeRow(let id):
            state.rows.removeAll { $0.id == id }
            return try save()
        case .complete:
            guard !state.rows.isEmpty else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind, reason: "Table must have at least one row"
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
