//
//  WorkbenchTransformEngine.swift
//  Kalsmritikosh
//
//  LAB-002 (Stage C) — the pure, deterministic computation core. Given a WorkbenchDatasetRecord (the
//  read-back state of a dataset) and a WorkbenchTransformSpec, it computes a WorkbenchTransformOutcome:
//  a row-wise derived column, a projection (filter / sort / deduplicate), or grouped aggregates — each
//  derived value carrying the EXACT input cell IDs it read. It touches nothing but its inputs: no
//  database, no network, no clock, no randomness. The same record + spec always yields the same
//  outcome, which is precisely what makes a persisted derived value reproducible from
//  (formula + inputs + engine version). Unsupported kinds return an honest `.unsupported` outcome.
//

import Foundation

public nonisolated enum WorkbenchTransformEngine {

    public static let engineVersion = WorkbenchTransformEngineVersion.current

    /// Compute a transform against a dataset record. Throws only for a mis-specified transform
    /// (unknown field / un-parseable formula); an unsupported kind is a returned outcome, not a throw.
    public nonisolated static func compute(_ spec: WorkbenchTransformSpec,
                                           over record: WorkbenchDatasetRecord) throws -> WorkbenchTransformOutcome {
        let index = Index(record: record)
        switch spec {
        case .calculatedColumn(let newField, let shape, let formula):
            return .column(try computeColumn(newField: newField, shape: shape, formula: formula, index: index, running: false, overField: nil))
        case .runningTotal(let newField, let over):
            return .column(try computeRunningTotal(newField: newField, over: over, index: index))
        case .filter(let predicate):
            return .projection(try computeFilter(predicate: predicate, index: index))
        case .sort(let field, let direction):
            return .projection(try computeSort(field: field, direction: direction, index: index))
        case .deduplicate(let keyFields):
            return .projection(try computeDeduplicate(keyFields: keyFields, index: index))
        case .aggregate(let function, let field, let groupBy):
            return .aggregate(try computeAggregate(function: function, field: field, groupBy: groupBy, index: index))
        case .pivot:
            return .unsupported(.pivot, reason: "Pivot requires reshaping into a new dataset; deferred beyond LAB-002.")
        case .join:
            return .unsupported(.join, reason: "Join across datasets is deferred beyond LAB-002.")
        case .rollingCalculation:
            return .unsupported(.rollingCalculation, reason: "Windowed rolling calculations are deferred beyond LAB-002.")
        }
    }

    // MARK: - Row-wise calculated column

    private nonisolated static func computeColumn(newField: String, shape: FactSchemaRegistry.ValueShape, formula: String,
                                                  index: Index, running: Bool, overField: String?) throws -> WorkbenchColumnResult {
        guard !newField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkbenchTransformError.emptyFieldName }
        let expr: WorkbenchExpr
        do { expr = try WorkbenchExpressionParser.parse(formula) }
        catch let e as WorkbenchExpressionError { throw WorkbenchTransformError.parse(e) }
        for name in expr.referencedFields where index.field(named: name) == nil {
            throw WorkbenchTransformError.unknownField(name)
        }
        var perRow: [WorkbenchDerivedValue] = []
        for row in index.rows {
            let ctx = index.context(rowID: row.id)
            let value: WorkbenchValue
            do { value = try WorkbenchExpressionEvaluator.evaluate(expr, in: ctx) }
            catch let e as WorkbenchEvaluationError { throw WorkbenchTransformError.evaluation(e) }
            let inputs = expr.referencedFields.compactMap { index.cellID(rowID: row.id, fieldName: $0) }
            perRow.append(WorkbenchDerivedValue(rowID: row.id, resultKey: nil, value: value, inputCellIDs: inputs))
        }
        return WorkbenchColumnResult(newFieldName: newField, shape: shape, formula: formula, perRow: perRow)
    }

    // MARK: - Running total (ordered cumulative sum)

    private nonisolated static func computeRunningTotal(newField: String, over: String, index: Index) throws -> WorkbenchColumnResult {
        guard !newField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkbenchTransformError.emptyFieldName }
        guard let field = index.field(named: over) else { throw WorkbenchTransformError.unknownField(over) }
        var runningSum = 0.0
        var accumulatedInputs: [UUID] = []
        var perRow: [WorkbenchDerivedValue] = []
        for row in index.rows {   // already in ordinal order
            if let cellID = index.cellID(rowID: row.id, fieldID: field.id) { accumulatedInputs.append(cellID) }
            let v = WorkbenchValue.coerce(index.cellValue(rowID: row.id, fieldID: field.id), shape: field.valueShape)
            if let n = v.asNumber { runningSum += n }
            perRow.append(WorkbenchDerivedValue(rowID: row.id, resultKey: nil, value: .number(runningSum), inputCellIDs: accumulatedInputs))
        }
        return WorkbenchColumnResult(newFieldName: newField, shape: .number, formula: "RUNNING_TOTAL([\(over)])", perRow: perRow)
    }

    // MARK: - Filter (predicate → kept rows)

    private nonisolated static func computeFilter(predicate: String, index: Index) throws -> WorkbenchProjectionResult {
        let expr: WorkbenchExpr
        do { expr = try WorkbenchExpressionParser.parse(predicate) }
        catch let e as WorkbenchExpressionError { throw WorkbenchTransformError.parse(e) }
        for name in expr.referencedFields where index.field(named: name) == nil { throw WorkbenchTransformError.unknownField(name) }
        var kept: [UUID] = []
        for row in index.rows {
            let v: WorkbenchValue
            do { v = try WorkbenchExpressionEvaluator.evaluate(expr, in: index.context(rowID: row.id)) }
            catch let e as WorkbenchEvaluationError { throw WorkbenchTransformError.evaluation(e) }
            if v.asBool { kept.append(row.id) }
        }
        return WorkbenchProjectionResult(orderedRowIDs: kept)
    }

    // MARK: - Sort (deterministic; ties break by original ordinal)

    private nonisolated static func computeSort(field: String, direction: WorkbenchSortDirection, index: Index) throws -> WorkbenchProjectionResult {
        guard let f = index.field(named: field) else { throw WorkbenchTransformError.unknownField(field) }
        let decorated = index.rows.map { row -> (UUID, WorkbenchValue, Int) in
            (row.id, WorkbenchValue.coerce(index.cellValue(rowID: row.id, fieldID: f.id), shape: f.valueShape), row.ordinal)
        }
        let sorted = decorated.sorted { a, b in
            // Null / missing values always sort last, regardless of direction (blanks at the bottom).
            if a.1.isNull != b.1.isNull { return !a.1.isNull }
            if a.1.isNull && b.1.isNull { return a.2 < b.2 }
            let c = compareValues(a.1, b.1)
            if c != 0 { return direction == .ascending ? c < 0 : c > 0 }
            return a.2 < b.2   // stable tie-break by original position (independent of direction)
        }
        return WorkbenchProjectionResult(orderedRowIDs: sorted.map(\.0))
    }

    // MARK: - Deduplicate (keep first row per distinct key tuple)

    private nonisolated static func computeDeduplicate(keyFields: [String], index: Index) throws -> WorkbenchProjectionResult {
        var resolved: [WorkbenchField] = []
        for name in keyFields {
            guard let f = index.field(named: name) else { throw WorkbenchTransformError.unknownField(name) }
            resolved.append(f)
        }
        var seen: Set<String> = []
        var kept: [UUID] = []
        for row in index.rows {
            let key = resolved.map { f -> String in
                let v = WorkbenchValue.coerce(index.cellValue(rowID: row.id, fieldID: f.id), shape: f.valueShape)
                return v.storedString.map { "\($0.count):\($0)" } ?? "∅"
            }.joined(separator: "\u{1F}")
            if seen.insert(key).inserted { kept.append(row.id) }
        }
        return WorkbenchProjectionResult(orderedRowIDs: kept)
    }

    // MARK: - Aggregate (optionally grouped)

    private nonisolated static func computeAggregate(function: WorkbenchAggregateFunction, field: String?,
                                                     groupBy: [String], index: Index) throws -> WorkbenchAggregateResult {
        var groupFields: [WorkbenchField] = []
        for name in groupBy {
            guard let f = index.field(named: name) else { throw WorkbenchTransformError.unknownField(name) }
            groupFields.append(f)
        }
        var target: WorkbenchField?
        if let field {
            guard let f = index.field(named: field) else { throw WorkbenchTransformError.unknownField(field) }
            target = f
        } else if function != .count {
            throw WorkbenchTransformError.unknownField("<aggregate field>")
        }

        // Group rows in first-seen key order for determinism.
        var order: [String] = []
        var members: [String: [WorkbenchRow]] = [:]
        for row in index.rows {
            let key = groupFields.map { f -> String in
                WorkbenchValue.coerce(index.cellValue(rowID: row.id, fieldID: f.id), shape: f.valueShape).storedString ?? "∅"
            }.joined(separator: " · ")
            if members[key] == nil { order.append(key); members[key] = [] }
            members[key]?.append(row)
        }
        if order.isEmpty { order = [""]; members[""] = [] }

        var groups: [WorkbenchDerivedValue] = []
        for key in order {
            let rows = members[key] ?? []
            var inputCells: [UUID] = []
            var numbers: [Double] = []
            for row in rows {
                if let t = target {
                    if let cid = index.cellID(rowID: row.id, fieldID: t.id) { inputCells.append(cid) }
                    let v = WorkbenchValue.coerce(index.cellValue(rowID: row.id, fieldID: t.id), shape: t.valueShape)
                    if let n = v.asNumber { numbers.append(n) }
                } else {
                    // COUNT with no target: any one cell of the row anchors the input lineage.
                    if let anyCell = index.anyCellID(rowID: row.id) { inputCells.append(anyCell) }
                }
            }
            let value: WorkbenchValue
            switch function {
            case .count: value = .number(Double(rows.count))
            case .sum: value = .number(numbers.reduce(0, +))
            case .average: value = numbers.isEmpty ? .null : .number(numbers.reduce(0, +) / Double(numbers.count))
            case .min: value = numbers.min().map(WorkbenchValue.number) ?? .null
            case .max: value = numbers.max().map(WorkbenchValue.number) ?? .null
            }
            groups.append(WorkbenchDerivedValue(rowID: nil, resultKey: key, value: value, inputCellIDs: inputCells))
        }
        return WorkbenchAggregateResult(function: function, groups: groups)
    }

    // MARK: - Value comparison for sort (nulls last)

    nonisolated static func compareValues(_ a: WorkbenchValue, _ b: WorkbenchValue) -> Int {
        if a.isNull || b.isNull {
            if a.isNull && b.isNull { return 0 }
            return a.isNull ? 1 : -1
        }
        if case .date(let x) = a, case .date(let y) = b { return x == y ? 0 : (x < y ? -1 : 1) }
        if case .number(let x) = a, case .number(let y) = b { return x == y ? 0 : (x < y ? -1 : 1) }
        if let x = a.asNumber, let y = b.asNumber, case .number = a { return x == y ? 0 : (x < y ? -1 : 1) }
        let x = a.asText, y = b.asText
        return x == y ? 0 : (x < y ? -1 : 1)
    }

    // MARK: - Precomputed dataset index (fast, deterministic lookups)

    private nonisolated struct Index {
        let rows: [WorkbenchRow]
        private let fieldsByName: [String: WorkbenchField]
        private let fieldsByID: [UUID: WorkbenchField]
        private let cellByRowField: [String: WorkbenchCell]

        init(record: WorkbenchDatasetRecord) {
            self.rows = record.rows.sorted { $0.ordinal < $1.ordinal }
            var byName: [String: WorkbenchField] = [:]
            var byID: [UUID: WorkbenchField] = [:]
            for f in record.fields { byName[f.name] = f; byID[f.id] = f }
            self.fieldsByName = byName
            self.fieldsByID = byID
            var cells: [String: WorkbenchCell] = [:]
            for c in record.cells { cells["\(c.rowID.uuidString)|\(c.fieldID.uuidString)"] = c }
            self.cellByRowField = cells
        }

        func field(named name: String) -> WorkbenchField? { fieldsByName[name] }

        func cell(rowID: UUID, fieldID: UUID) -> WorkbenchCell? { cellByRowField["\(rowID.uuidString)|\(fieldID.uuidString)"] }
        func cellValue(rowID: UUID, fieldID: UUID) -> String? { cell(rowID: rowID, fieldID: fieldID)?.value }
        func cellID(rowID: UUID, fieldID: UUID) -> UUID? { cell(rowID: rowID, fieldID: fieldID)?.id }
        func cellID(rowID: UUID, fieldName: String) -> UUID? {
            guard let f = fieldsByName[fieldName] else { return nil }
            return cellID(rowID: rowID, fieldID: f.id)
        }
        func anyCellID(rowID: UUID) -> UUID? {
            fieldsByID.keys.compactMap { cellID(rowID: rowID, fieldID: $0) }.sorted { $0.uuidString < $1.uuidString }.first
        }

        /// A full row context: EVERY field bound (missing cell → `.null`), so a formula referencing an
        /// existing-but-empty column sees null rather than an unknown-field error.
        func context(rowID: UUID) -> WorkbenchRowContext {
            var values: [String: WorkbenchValue] = [:]
            for (name, f) in fieldsByName {
                values[name] = WorkbenchValue.coerce(cellValue(rowID: rowID, fieldID: f.id), shape: f.valueShape)
            }
            return WorkbenchRowContext(values: values)
        }
    }
}
