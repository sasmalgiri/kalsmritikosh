//
//  WorkbenchTransform.swift
//  Kalsmritikosh
//
//  LAB-002 (Stage C) — the vocabulary of a safe transformation and the durable lineage a derived value
//  carries. A transformation NEVER mutates canonical evidence and never overwrites a source cell: it
//  produces new `deterministicCalculation` cells (a calculated / running-total column), a projection
//  (filter / sort / deduplicate → an ordered row-id set), or grouped aggregate results — each with a
//  complete audit trail. Per the contract, every derived value stores its formula/transformation, the
//  EXACT input cell IDs it read, the engine version, and its output, so the value is reproducible.
//
//  Kinds the engine cannot yet compute correctly (pivot / join / rolling calculation) are recognised
//  but returned as an honest `.unsupported` outcome — never silently mis-computed (see the "no silent
//  fallbacks" rule and the LAB-005 "unsupported transformation" data-quality warning).
//

import Foundation

/// The closed set of transformation kinds. `supported` lists the ones LAB-002 computes; the rest are
/// recognised so the engine can report them honestly instead of guessing.
public nonisolated enum WorkbenchTransformKind: String, Codable, Sendable, Equatable, CaseIterable {
    case calculatedColumn
    case runningTotal
    case filter
    case sort
    case deduplicate
    case aggregate
    case pivot
    case join
    case rollingCalculation

    public nonisolated static let supported: Set<WorkbenchTransformKind> =
        [.calculatedColumn, .runningTotal, .filter, .sort, .deduplicate, .aggregate]

    public nonisolated var isSupported: Bool { WorkbenchTransformKind.supported.contains(self) }
}

public nonisolated enum WorkbenchSortDirection: String, Codable, Sendable, Equatable {
    case ascending
    case descending
}

public nonisolated enum WorkbenchAggregateFunction: String, Codable, Sendable, Equatable {
    case count, sum, average, min, max
}

/// The parameters of a transformation, serialised into `workbench_transformations.spec_json`. A Codable
/// enum keeps each kind's parameters exactly typed (no optional soup) and round-trips deterministically.
public nonisolated enum WorkbenchTransformSpec: Codable, Sendable, Equatable {
    case calculatedColumn(newField: String, shape: FactSchemaRegistry.ValueShape, formula: String)
    case runningTotal(newField: String, over: String)
    case filter(predicate: String)
    case sort(field: String, direction: WorkbenchSortDirection)
    case deduplicate(keyFields: [String])
    case aggregate(function: WorkbenchAggregateFunction, field: String?, groupBy: [String])
    case pivot
    case join
    case rollingCalculation

    public nonisolated var kind: WorkbenchTransformKind {
        switch self {
        case .calculatedColumn: return .calculatedColumn
        case .runningTotal: return .runningTotal
        case .filter: return .filter
        case .sort: return .sort
        case .deduplicate: return .deduplicate
        case .aggregate: return .aggregate
        case .pivot: return .pivot
        case .join: return .join
        case .rollingCalculation: return .rollingCalculation
        }
    }

    /// The canonical formula source of this transform, if any (persisted as `formula_text` for reproduction).
    public nonisolated var formulaText: String? {
        switch self {
        case .calculatedColumn(_, _, let formula): return formula
        case .filter(let predicate): return predicate
        case .runningTotal(_, let over): return over
        default: return nil
        }
    }
}

// MARK: - Computed (pre-persistence) results — pure output of WorkbenchTransformEngine

/// One computed derived value with its complete lineage. `rowID` is the row it belongs to for a
/// row-wise column; `resultKey` labels an aggregate group. `inputCellIDs` are the EXACT source cells read.
public nonisolated struct WorkbenchDerivedValue: Sendable, Equatable {
    public let rowID: UUID?
    public let resultKey: String?
    public let value: WorkbenchValue
    public let inputCellIDs: [UUID]

    public nonisolated init(rowID: UUID?, resultKey: String?, value: WorkbenchValue, inputCellIDs: [UUID]) {
        self.rowID = rowID; self.resultKey = resultKey; self.value = value; self.inputCellIDs = inputCellIDs
    }
}

/// A row-wise derived column: a new field plus one derived value per row (in row order).
public nonisolated struct WorkbenchColumnResult: Sendable, Equatable {
    public let newFieldName: String
    public let shape: FactSchemaRegistry.ValueShape
    public let formula: String
    public let perRow: [WorkbenchDerivedValue]
    public nonisolated init(newFieldName: String, shape: FactSchemaRegistry.ValueShape, formula: String, perRow: [WorkbenchDerivedValue]) {
        self.newFieldName = newFieldName; self.shape = shape; self.formula = formula; self.perRow = perRow
    }
}

/// A projection: the ordered subset of row IDs a filter / sort / deduplicate yields (canonical rows untouched).
public nonisolated struct WorkbenchProjectionResult: Sendable, Equatable {
    public let orderedRowIDs: [UUID]
    public nonisolated init(orderedRowIDs: [UUID]) { self.orderedRowIDs = orderedRowIDs }
}

/// Grouped (or ungrouped) aggregate results, each derived value labelled by its group key.
public nonisolated struct WorkbenchAggregateResult: Sendable, Equatable {
    public let function: WorkbenchAggregateFunction
    public let groups: [WorkbenchDerivedValue]
    public nonisolated init(function: WorkbenchAggregateFunction, groups: [WorkbenchDerivedValue]) {
        self.function = function; self.groups = groups
    }
}

/// The outcome of computing a transform against a dataset record — persisted by WorkbenchTransformRepository.
public nonisolated enum WorkbenchTransformOutcome: Sendable, Equatable {
    case column(WorkbenchColumnResult)
    case projection(WorkbenchProjectionResult)
    case aggregate(WorkbenchAggregateResult)
    case unsupported(WorkbenchTransformKind, reason: String)
}

public nonisolated enum WorkbenchTransformError: Error, Sendable, Equatable {
    case emptyFieldName
    case unknownField(String)
    case parse(WorkbenchExpressionError)
    case evaluation(WorkbenchEvaluationError)
    case notMaterializable(WorkbenchTransformKind)   // caller asked to persist an unsupported outcome
}

// MARK: - Durable lineage models (mirror the v93 tables)

public nonisolated struct WorkbenchTransformation: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let datasetID: UUID
    public let sequence: Int
    public let kind: WorkbenchTransformKind
    public let formulaText: String?
    public let engineVersion: String
    public let specJSON: String
    public let targetFieldID: UUID?
    public let resultJSON: String?
    public let actor: String
    public let createdAt: Date

    public nonisolated init(id: UUID, datasetID: UUID, sequence: Int, kind: WorkbenchTransformKind,
                            formulaText: String?, engineVersion: String, specJSON: String,
                            targetFieldID: UUID?, resultJSON: String?, actor: String, createdAt: Date) {
        self.id = id; self.datasetID = datasetID; self.sequence = sequence; self.kind = kind
        self.formulaText = formulaText; self.engineVersion = engineVersion; self.specJSON = specJSON
        self.targetFieldID = targetFieldID; self.resultJSON = resultJSON; self.actor = actor; self.createdAt = createdAt
    }
}

public nonisolated struct WorkbenchDerivation: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let transformationID: UUID
    public let datasetID: UUID
    public let outputCellID: UUID?
    public let resultKey: String?
    public let outputValue: String?
    public let createdAt: Date

    public nonisolated init(id: UUID, transformationID: UUID, datasetID: UUID, outputCellID: UUID?,
                            resultKey: String?, outputValue: String?, createdAt: Date) {
        self.id = id; self.transformationID = transformationID; self.datasetID = datasetID
        self.outputCellID = outputCellID; self.resultKey = resultKey; self.outputValue = outputValue; self.createdAt = createdAt
    }
}

public nonisolated struct WorkbenchDerivationInput: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let derivationID: UUID
    public let inputCellID: UUID
    public let ordinal: Int

    public nonisolated init(id: UUID, derivationID: UUID, inputCellID: UUID, ordinal: Int) {
        self.id = id; self.derivationID = derivationID; self.inputCellID = inputCellID; self.ordinal = ordinal
    }
}

/// The full durable record of one applied transformation (reproduction / audit anchor).
public nonisolated struct WorkbenchTransformationRecord: Sendable, Equatable {
    public let transformation: WorkbenchTransformation
    public let derivations: [WorkbenchDerivation]
    public let inputs: [WorkbenchDerivationInput]
    public nonisolated init(transformation: WorkbenchTransformation, derivations: [WorkbenchDerivation], inputs: [WorkbenchDerivationInput]) {
        self.transformation = transformation; self.derivations = derivations; self.inputs = inputs
    }
    /// Input cell IDs for a derivation, in ordinal order.
    public nonisolated func inputs(for derivationID: UUID) -> [UUID] {
        inputs.filter { $0.derivationID == derivationID }.sorted { $0.ordinal < $1.ordinal }.map(\.inputCellID)
    }
}
