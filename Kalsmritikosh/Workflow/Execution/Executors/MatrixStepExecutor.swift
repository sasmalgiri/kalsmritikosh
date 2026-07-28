//
//  MatrixStepExecutor.swift
//  Kalsmritikosh
//
//  PJE-006A — Step Executor Runtime and Working-Surface Pack.
//  Handles the `matrix` step kind.
//  cells is keyed by (rowID, columnID). Custom Codable encodes as array-of-entries
//  to avoid CodingKey issues with composite keys.
//  Commands: setCell, clearCell, addRow, removeRow, addColumn, removeColumn, complete.
//

import Foundation

// MARK: - Matrix cell key

public nonisolated struct WorkflowMatrixCellKey: Hashable, Sendable, Equatable {
    public let rowID: String
    public let columnID: String

    public nonisolated init(rowID: String, columnID: String) {
        self.rowID = rowID
        self.columnID = columnID
    }
}

// MARK: - Matrix cell

public nonisolated struct WorkflowMatrixCell: Codable, Sendable, Equatable {
    public var value: WorkflowTableCellValue
    public var label: String?

    public nonisolated init(value: WorkflowTableCellValue, label: String? = nil) {
        self.value = value
        self.label = label
    }
}

// MARK: - Matrix state Codable helper (file-private to break extension isolation)

fileprivate struct MatrixStateCellEntry: Codable {
    let rowID: String
    let columnID: String
    let cell: WorkflowMatrixCell

    private enum CodingKeys: String, CodingKey { case rowID, columnID, cell }

    nonisolated init(rowID: String, columnID: String, cell: WorkflowMatrixCell) {
        self.rowID = rowID; self.columnID = columnID; self.cell = cell
    }
    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rowID = try c.decode(String.self, forKey: .rowID)
        columnID = try c.decode(String.self, forKey: .columnID)
        cell = try c.decode(WorkflowMatrixCell.self, forKey: .cell)
    }
    nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(rowID, forKey: .rowID)
        try c.encode(columnID, forKey: .columnID)
        try c.encode(cell, forKey: .cell)
    }
}

// MARK: - Matrix state

public nonisolated struct MatrixStepState: Codable, Sendable {
    public var rowIDs: [String]
    public var columnIDs: [String]
    public var cells: [WorkflowMatrixCellKey: WorkflowMatrixCell]

    public nonisolated init(
        rowIDs: [String] = [],
        columnIDs: [String] = [],
        cells: [WorkflowMatrixCellKey: WorkflowMatrixCell] = [:]
    ) {
        self.rowIDs = rowIDs
        self.columnIDs = columnIDs
        self.cells = cells
    }

    private enum CodingKeys: String, CodingKey { case rowIDs, columnIDs, cells }

    public nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rowIDs = try c.decode([String].self, forKey: .rowIDs)
        columnIDs = try c.decode([String].self, forKey: .columnIDs)
        let entries = try c.decode([MatrixStateCellEntry].self, forKey: .cells)
        cells = Dictionary(uniqueKeysWithValues: entries.map {
            (WorkflowMatrixCellKey(rowID: $0.rowID, columnID: $0.columnID), $0.cell)
        })
    }

    public nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(rowIDs, forKey: .rowIDs)
        try c.encode(columnIDs, forKey: .columnIDs)
        let unsorted: [MatrixStateCellEntry] = cells.map { key, cell in
            MatrixStateCellEntry(rowID: key.rowID, columnID: key.columnID, cell: cell)
        }
        let entries = unsorted.sorted { l, r in
            l.rowID == r.rowID ? l.columnID < r.columnID : l.rowID < r.rowID
        }
        try c.encode(entries, forKey: .cells)
    }
}

// MARK: - Matrix command

public enum MatrixStepCommand: Sendable, Equatable {
    case setCell(rowID: String, columnID: String, value: WorkflowTableCellValue, label: String?)
    case clearCell(rowID: String, columnID: String)
    case addRow(id: String)
    case removeRow(id: String)
    case addColumn(id: String)
    case removeColumn(id: String)
    case complete
}

extension MatrixStepCommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, rowID, columnID, value, label, id
    }

    public nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "setCell":
            self = .setCell(
                rowID: try c.decode(String.self, forKey: .rowID),
                columnID: try c.decode(String.self, forKey: .columnID),
                value: try c.decode(WorkflowTableCellValue.self, forKey: .value),
                label: try c.decodeIfPresent(String.self, forKey: .label)
            )
        case "clearCell":
            self = .clearCell(
                rowID: try c.decode(String.self, forKey: .rowID),
                columnID: try c.decode(String.self, forKey: .columnID)
            )
        case "addRow":      self = .addRow(id: try c.decode(String.self, forKey: .id))
        case "removeRow":   self = .removeRow(id: try c.decode(String.self, forKey: .id))
        case "addColumn":   self = .addColumn(id: try c.decode(String.self, forKey: .id))
        case "removeColumn":self = .removeColumn(id: try c.decode(String.self, forKey: .id))
        case "complete":    self = .complete
        default: throw WorkflowStepExecutionError.malformedCommandJSON
        }
    }

    public nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .setCell(let rID, let cID, let v, let l):
            try c.encode("setCell", forKey: .type)
            try c.encode(rID, forKey: .rowID); try c.encode(cID, forKey: .columnID)
            try c.encode(v, forKey: .value)
            if let l = l { try c.encode(l, forKey: .label) }
        case .clearCell(let rID, let cID):
            try c.encode("clearCell", forKey: .type)
            try c.encode(rID, forKey: .rowID); try c.encode(cID, forKey: .columnID)
        case .addRow(let id):      try c.encode("addRow", forKey: .type);      try c.encode(id, forKey: .id)
        case .removeRow(let id):   try c.encode("removeRow", forKey: .type);   try c.encode(id, forKey: .id)
        case .addColumn(let id):   try c.encode("addColumn", forKey: .type);   try c.encode(id, forKey: .id)
        case .removeColumn(let id):try c.encode("removeColumn", forKey: .type);try c.encode(id, forKey: .id)
        case .complete:            try c.encode("complete", forKey: .type)
        }
    }
}

// MARK: - Executor

public nonisolated struct MatrixStepExecutor: WorkflowStepExecutor {

    public nonisolated let executorID = WorkflowStepExecutorID(
        rawValue: "com.kalsmritikosh.step.matrix"
    )
    public nonisolated let executorVersion = WorkflowStepExecutorVersion(rawValue: "1.0")
    public nonisolated let handledKind: WorkflowStepKind = .matrix

    public nonisolated init() {}

    public func prepare(
        context: WorkflowStepPreparationContext
    ) async throws -> WorkflowStepPreparationResult {
        guard context.step.kind == handledKind else {
            throw WorkflowStepExecutionError.executorKindMismatch(
                executor: executorID, expected: handledKind, actual: context.step.kind
            )
        }
        let (json, sha) = try makeEnvelope(state: MatrixStepState(), stepKind: handledKind)
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
        var state = try decodeCurrentState(MatrixStepState.self, from: context.stepRun)
        let command: MatrixStepCommand
        do {
            command = try WorkflowStepPayloadCodec.decode(MatrixStepCommand.self, from: commandJSON)
        } catch {
            throw WorkflowStepExecutionError.malformedCommandJSON
        }

        func save() throws -> WorkflowStepExecutionResult {
            let (json, sha) = try makeEnvelope(state: state, stepKind: handledKind)
            return WorkflowStepExecutionResult(stateJSON: json, stateSHA256: sha, disposition: .remainActive)
        }

        switch command {
        case .setCell(let rID, let cID, let value, let label):
            let key = WorkflowMatrixCellKey(rowID: rID, columnID: cID)
            state.cells[key] = WorkflowMatrixCell(value: value, label: label)
            return try save()
        case .clearCell(let rID, let cID):
            state.cells.removeValue(forKey: WorkflowMatrixCellKey(rowID: rID, columnID: cID))
            return try save()
        case .addRow(let id):
            if !state.rowIDs.contains(id) { state.rowIDs.append(id) }
            return try save()
        case .removeRow(let id):
            state.rowIDs.removeAll { $0 == id }
            state.cells = state.cells.filter { $0.key.rowID != id }
            return try save()
        case .addColumn(let id):
            if !state.columnIDs.contains(id) { state.columnIDs.append(id) }
            return try save()
        case .removeColumn(let id):
            state.columnIDs.removeAll { $0 == id }
            state.cells = state.cells.filter { $0.key.columnID != id }
            return try save()
        case .complete:
            guard !state.rowIDs.isEmpty, !state.columnIDs.isEmpty else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind, reason: "Matrix must have at least one row and one column"
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
