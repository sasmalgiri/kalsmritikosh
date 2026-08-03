//
//  WorkbenchTransformEngineTests.swift
//  KalsmritikoshTests
//
//  LAB-002 — the pure transform engine. Proves each supported transform computes the right result AND
//  pins each derived value to the EXACT input cell IDs it read (calculated column, running total,
//  filter, sort, deduplicate, aggregate), that unsupported kinds return an honest `.unsupported`
//  outcome (never a silent wrong answer), that a mis-specified field throws, and that the same record
//  + spec is reproducible. DB-free: records are built directly from the public value types.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("LAB-002 — transform engine")
struct WorkbenchTransformEngineTests {

    private let ds = UUID()
    private let epoch = Date(timeIntervalSinceReferenceDate: 0)

    /// Build a record with the given fields and row values (row-major, aligned to `fields`). Returns
    /// the record plus a lookup of cell IDs by (rowIndex, fieldName) for lineage assertions.
    private func makeRecord(fields: [(String, FactSchemaRegistry.ValueShape)],
                            rows: [[String?]]) -> (WorkbenchDatasetRecord, [String: UUID]) {
        let dataset = WorkbenchDataset(id: ds, workspaceID: UUID(), title: "T", mode: .advanced,
                                       revision: 1, createdAt: epoch, updatedAt: epoch)
        var fieldModels: [WorkbenchField] = []
        var fieldID: [String: UUID] = [:]
        for (i, (name, shape)) in fields.enumerated() {
            let id = UUID(); fieldID[name] = id
            fieldModels.append(WorkbenchField(id: id, datasetID: ds, name: name, valueShape: shape, ordinal: i, createdAt: epoch))
        }
        var rowModels: [WorkbenchRow] = []
        var cellModels: [WorkbenchCell] = []
        var cellLookup: [String: UUID] = [:]
        for (ri, values) in rows.enumerated() {
            let rowID = UUID()
            rowModels.append(WorkbenchRow(id: rowID, datasetID: ds, ordinal: ri, createdAt: epoch))
            for (ci, (name, _)) in fields.enumerated() {
                let v = ci < values.count ? values[ci] : nil
                let cellID = UUID(); cellLookup["\(ri)|\(name)"] = cellID
                cellModels.append(WorkbenchCell(id: cellID, datasetID: ds, rowID: rowID, fieldID: fieldID[name]!,
                                                kind: .sourceValue, value: v, status: .directlyObserved, createdAt: epoch))
            }
        }
        let record = WorkbenchDatasetRecord(dataset: dataset, fields: fieldModels, rows: rowModels,
                                            cells: cellModels, bindings: [], savedViews: [], events: [])
        return (record, cellLookup)
    }

    // MARK: - Calculated column

    @Test("A calculated column computes per-row values pinned to their exact input cells")
    func calculatedColumn() throws {
        let (rec, cells) = makeRecord(fields: [("amount", .number)], rows: [["100"], ["200"]])
        let outcome = try WorkbenchTransformEngine.compute(
            .calculatedColumn(newField: "double", shape: .number, formula: "[amount] * 2"), over: rec)
        guard case .column(let col) = outcome else { Issue.record("expected column"); return }
        #expect(col.newFieldName == "double")
        #expect(col.perRow.map(\.value) == [.number(200), .number(400)])
        #expect(col.perRow[0].inputCellIDs == [cells["0|amount"]!])
        #expect(col.perRow[1].inputCellIDs == [cells["1|amount"]!])
    }

    @Test("A calculated column over two fields records both input cells, in reference order")
    func calculatedColumnTwoInputs() throws {
        let (rec, cells) = makeRecord(fields: [("gross", .money), ("tax", .money)], rows: [["1000", "200"]])
        let outcome = try WorkbenchTransformEngine.compute(
            .calculatedColumn(newField: "net", shape: .money, formula: "[gross] - [tax]"), over: rec)
        guard case .column(let col) = outcome else { Issue.record("expected column"); return }
        #expect(col.perRow[0].value == .number(800))
        #expect(col.perRow[0].inputCellIDs == [cells["0|gross"]!, cells["0|tax"]!])
    }

    // MARK: - Running total

    @Test("A running total accumulates in row order and grows its input lineage")
    func runningTotal() throws {
        let (rec, cells) = makeRecord(fields: [("amount", .number)], rows: [["100"], ["200"], ["50"]])
        let outcome = try WorkbenchTransformEngine.compute(.runningTotal(newField: "cum", over: "amount"), over: rec)
        guard case .column(let col) = outcome else { Issue.record("expected column"); return }
        #expect(col.perRow.map(\.value) == [.number(100), .number(300), .number(350)])
        #expect(col.perRow[0].inputCellIDs == [cells["0|amount"]!])
        #expect(col.perRow[2].inputCellIDs == [cells["0|amount"]!, cells["1|amount"]!, cells["2|amount"]!])
    }

    // MARK: - Filter / sort / deduplicate (projections)

    @Test("A filter keeps only the rows whose predicate is true")
    func filter() throws {
        let (rec, _) = makeRecord(fields: [("amount", .number)], rows: [["100"], ["200"], ["50"]])
        let outcome = try WorkbenchTransformEngine.compute(.filter(predicate: "[amount] > 120"), over: rec)
        guard case .projection(let proj) = outcome else { Issue.record("expected projection"); return }
        #expect(proj.orderedRowIDs == [rec.rows[1].id])
    }

    @Test("A sort orders ascending / descending and puts null last, breaking ties by original order")
    func sort() throws {
        let (rec, _) = makeRecord(fields: [("amount", .number)], rows: [["200"], ["100"], [nil], ["100"]])
        let asc = try WorkbenchTransformEngine.compute(.sort(field: "amount", direction: .ascending), over: rec)
        guard case .projection(let a) = asc else { Issue.record("expected projection"); return }
        // 100 (row1), 100 (row3, tie broken by original order), 200 (row0), null (row2, last)
        #expect(a.orderedRowIDs == [rec.rows[1].id, rec.rows[3].id, rec.rows[0].id, rec.rows[2].id])
        let desc = try WorkbenchTransformEngine.compute(.sort(field: "amount", direction: .descending), over: rec)
        guard case .projection(let d) = desc else { Issue.record("expected projection"); return }
        #expect(d.orderedRowIDs.first == rec.rows[0].id)     // 200 first
        #expect(d.orderedRowIDs.last == rec.rows[2].id)      // null still last
    }

    @Test("Deduplicate keeps the first row for each distinct key")
    func deduplicate() throws {
        let (rec, _) = makeRecord(fields: [("category", .text)], rows: [["A"], ["B"], ["A"], ["B"], ["C"]])
        let outcome = try WorkbenchTransformEngine.compute(.deduplicate(keyFields: ["category"]), over: rec)
        guard case .projection(let proj) = outcome else { Issue.record("expected projection"); return }
        #expect(proj.orderedRowIDs == [rec.rows[0].id, rec.rows[1].id, rec.rows[4].id])
    }

    // MARK: - Aggregate

    @Test("A grouped sum computes one value per group, pinned to that group's input cells")
    func groupedSum() throws {
        let (rec, cells) = makeRecord(fields: [("cat", .text), ("amt", .number)],
                                      rows: [["A", "100"], ["B", "50"], ["A", "25"]])
        let outcome = try WorkbenchTransformEngine.compute(
            .aggregate(function: .sum, field: "amt", groupBy: ["cat"]), over: rec)
        guard case .aggregate(let agg) = outcome else { Issue.record("expected aggregate"); return }
        #expect(agg.function == .sum)
        let byKey = Dictionary(uniqueKeysWithValues: agg.groups.map { ($0.resultKey ?? "", $0) })
        #expect(byKey["A"]?.value == .number(125))
        #expect(byKey["B"]?.value == .number(50))
        #expect(Set(byKey["A"]?.inputCellIDs ?? []) == Set([cells["0|amt"]!, cells["2|amt"]!]))
    }

    @Test("Average / min / max / count aggregate correctly (ungrouped)")
    func aggregateFunctions() throws {
        let (rec, _) = makeRecord(fields: [("amt", .number)], rows: [["10"], ["20"], ["30"]])
        func run(_ fn: WorkbenchAggregateFunction) throws -> WorkbenchValue {
            let o = try WorkbenchTransformEngine.compute(.aggregate(function: fn, field: "amt", groupBy: []), over: rec)
            guard case .aggregate(let a) = o, let g = a.groups.first else { return .null }
            return g.value
        }
        #expect(try run(.average) == .number(20))
        #expect(try run(.min) == .number(10))
        #expect(try run(.max) == .number(30))
        #expect(try run(.count) == .number(3))
        #expect(try run(.sum) == .number(60))
    }

    // MARK: - Honest unsupported + errors

    @Test("Pivot / join / rolling calculation return an honest unsupported outcome")
    func unsupportedKinds() throws {
        let (rec, _) = makeRecord(fields: [("a", .number)], rows: [["1"]])
        for spec in [WorkbenchTransformSpec.pivot, .join, .rollingCalculation] {
            let outcome = try WorkbenchTransformEngine.compute(spec, over: rec)
            guard case .unsupported(let kind, let reason) = outcome else { Issue.record("expected unsupported"); return }
            #expect(kind == spec.kind)
            #expect(!reason.isEmpty)
        }
    }

    @Test("A formula referencing a non-existent field throws")
    func unknownFieldThrows() {
        let (rec, _) = makeRecord(fields: [("a", .number)], rows: [["1"]])
        #expect(throws: WorkbenchTransformError.self) {
            _ = try WorkbenchTransformEngine.compute(.calculatedColumn(newField: "x", shape: .number, formula: "[b] + 1"), over: rec)
        }
    }

    @Test("An un-parseable formula throws a parse error")
    func parseErrorThrows() {
        let (rec, _) = makeRecord(fields: [("a", .number)], rows: [["1"]])
        #expect(throws: WorkbenchTransformError.self) {
            _ = try WorkbenchTransformEngine.compute(.calculatedColumn(newField: "x", shape: .number, formula: "SYSTEM(1)"), over: rec)
        }
    }

    @Test("The engine is reproducible: the same record + spec computes an identical outcome")
    func deterministic() throws {
        let (rec, _) = makeRecord(fields: [("amount", .number)], rows: [["100"], ["200"]])
        let spec = WorkbenchTransformSpec.calculatedColumn(newField: "d", shape: .number, formula: "[amount] * 3")
        let first = try WorkbenchTransformEngine.compute(spec, over: rec)
        let second = try WorkbenchTransformEngine.compute(spec, over: rec)
        #expect(first == second)
    }
}
