//
//  WorkbenchTransformRepositoryTests.swift
//  KalsmritikoshTests
//
//  LAB-002 — the transform repository over a real ledger. Proves a transformation is persisted
//  atomically with COMPLETE, reproducible lineage: a calculated column becomes deterministicCalculation
//  cells (status DETERMINISTICALLY_DERIVED) whose derivations pin the exact input source cells + engine
//  version + output; a filter becomes a recorded projection; an aggregate becomes grouped derivations.
//  Also proves the fail-closed guarantees: an unsupported kind is refused with nothing written, a stale
//  revision conflicts, a bad formula rolls back atomically, and the READ-ONLY source cells are never
//  mutated. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("LAB-002 — transform repository")
struct WorkbenchTransformRepositoryTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private struct Fixture {
        let db: Database
        let datasets: WorkbenchDatasetRepository
        let transforms: WorkbenchTransformRepository
        let datasetID: UUID
        let amountFieldID: UUID
        let catFieldID: UUID
        let rowIDs: [UUID]
        let amountCellIDs: [UUID]
        var revision: Int
    }

    /// A dataset with fields (cat: text, amount: number) and three source rows: (A,100)(B,50)(A,25).
    private func seed() async throws -> Fixture {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(ws), .text("W"), .real(0), .real(0)])
        let datasets = WorkbenchDatasetRepository(database: db)
        let transforms = WorkbenchTransformRepository(database: db)
        var rec = try await datasets.createDataset(workspaceID: ws, title: "Payments", mode: .advanced, actor: "u", at: t0)
        let dID = rec.dataset.id
        rec = try await datasets.addField(datasetID: dID, name: "cat", valueShape: .text, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        rec = try await datasets.addField(datasetID: dID, name: "amount", valueShape: .number, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        let catField = rec.fields.first { $0.name == "cat" }!.id
        let amtField = rec.fields.first { $0.name == "amount" }!.id
        var rowIDs: [UUID] = []
        var amountCells: [UUID] = []
        for (cat, amt) in [("A", "100"), ("B", "50"), ("A", "25")] {
            rec = try await datasets.addRow(datasetID: dID, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
            let rowID = rec.rows.max { $0.ordinal < $1.ordinal }!.id
            rowIDs.append(rowID)
            rec = try await datasets.setCell(datasetID: dID, rowID: rowID, fieldID: catField, kind: .sourceValue,
                                             value: cat, status: .directlyObserved, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
            rec = try await datasets.setCell(datasetID: dID, rowID: rowID, fieldID: amtField, kind: .sourceValue,
                                             value: amt, status: .directlyObserved, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
            amountCells.append(rec.cells.first { $0.rowID == rowID && $0.fieldID == amtField }!.id)
        }
        return Fixture(db: db, datasets: datasets, transforms: transforms, datasetID: dID,
                       amountFieldID: amtField, catFieldID: catField, rowIDs: rowIDs,
                       amountCellIDs: amountCells, revision: rec.dataset.revision)
    }

    // MARK: - Calculated column

    @Test("Applying a calculated column persists derived cells + reproducible lineage")
    func calculatedColumnPersists() async throws {
        let f = try await seed()
        let tx = try await f.transforms.applyTransform(
            datasetID: f.datasetID, spec: .calculatedColumn(newField: "doubled", shape: .number, formula: "[amount] * 2"),
            expectedRevision: f.revision, actor: "analyst", at: t0)

        // Transformation row: engine version pinned, kind, formula.
        #expect(tx.transformation.engineVersion == WorkbenchTransformEngine.engineVersion)
        #expect(tx.transformation.kind == .calculatedColumn)
        #expect(tx.transformation.formulaText == "[amount] * 2")
        #expect(tx.transformation.targetFieldID != nil)

        // Three derivations, each with a derived output cell of kind deterministicCalculation.
        #expect(tx.derivations.count == 3)
        let rec = try await f.datasets.fetch(datasetID: f.datasetID)!
        let newField = rec.fields.first { $0.name == "doubled" }!
        let derivedCells = rec.cells.filter { $0.fieldID == newField.id }
        #expect(derivedCells.count == 3)
        #expect(derivedCells.allSatisfy { $0.kind == .deterministicCalculation })
        #expect(derivedCells.allSatisfy { $0.status == .deterministicallyDerived })
        #expect(Set(derivedCells.compactMap { $0.value }) == ["200", "100", "50"])

        // Each derivation's inputs pin the exact source amount cell.
        for d in tx.derivations {
            let inputs = try await f.transforms.inputs(derivationID: d.id)
            #expect(inputs.count == 1)
            #expect(f.amountCellIDs.contains(inputs[0].inputCellID))
        }

        // A 'transformed' event was appended and the dataset revision advanced.
        #expect(rec.dataset.revision == f.revision + 1)
        #expect(rec.events.contains { $0.action == .transformed })
    }

    @Test("recompute reproduces the stored transformation's outputs against current data")
    func recomputeReproduces() async throws {
        let f = try await seed()
        let tx = try await f.transforms.applyTransform(
            datasetID: f.datasetID, spec: .calculatedColumn(newField: "d", shape: .number, formula: "[amount] + 1"),
            expectedRevision: f.revision, actor: "u", at: t0)
        let outcome = try await f.transforms.recompute(transformationID: tx.transformation.id)
        guard case .column(let col) = outcome else { Issue.record("expected column"); return }
        #expect(Set(col.perRow.map { $0.value.storedString }) == ["101", "51", "26"])
    }

    // MARK: - Filter (projection) + aggregate

    @Test("A filter persists as a projection transformation with no derived cells")
    func filterPersistsProjection() async throws {
        let f = try await seed()
        let tx = try await f.transforms.applyTransform(
            datasetID: f.datasetID, spec: .filter(predicate: "[amount] > 60"),
            expectedRevision: f.revision, actor: "u", at: t0)
        #expect(tx.transformation.kind == .filter)
        #expect(tx.derivations.isEmpty)
        #expect(tx.transformation.resultJSON?.contains(f.rowIDs[0].uuidString) == true)   // (A,100) kept
        #expect(tx.transformation.resultJSON?.contains(f.rowIDs[1].uuidString) == false)  // (B,50) dropped
        // No new field was created by a projection.
        let rec = try await f.datasets.fetch(datasetID: f.datasetID)!
        #expect(rec.fields.count == 2)
    }

    @Test("A grouped aggregate persists grouped derivations pinned to their group's input cells")
    func aggregatePersists() async throws {
        let f = try await seed()
        let tx = try await f.transforms.applyTransform(
            datasetID: f.datasetID, spec: .aggregate(function: .sum, field: "amount", groupBy: ["cat"]),
            expectedRevision: f.revision, actor: "u", at: t0)
        #expect(tx.transformation.kind == .aggregate)
        let byKey = Dictionary(uniqueKeysWithValues: tx.derivations.map { ($0.resultKey ?? "", $0) })
        #expect(byKey["A"]?.outputValue == "125")
        #expect(byKey["B"]?.outputValue == "50")
        #expect(byKey["A"]?.outputCellID == nil)   // an aggregate produces no grid cell
        // Group A's inputs are the two A-row amount cells.
        let aInputs = try await f.transforms.inputs(derivationID: byKey["A"]!.id)
        #expect(Set(aInputs.map(\.inputCellID)) == Set([f.amountCellIDs[0], f.amountCellIDs[2]]))
    }

    // MARK: - Fail-closed guarantees

    @Test("An unsupported kind is refused and nothing is written")
    func unsupportedRefused() async throws {
        let f = try await seed()
        await #expect(throws: WorkbenchTransformError.self) {
            _ = try await f.transforms.applyTransform(datasetID: f.datasetID, spec: .pivot,
                                                      expectedRevision: f.revision, actor: "u", at: t0)
        }
        #expect(try await f.transforms.transformations(datasetID: f.datasetID).isEmpty)
        #expect(try await f.datasets.fetch(datasetID: f.datasetID)!.dataset.revision == f.revision)
    }

    @Test("A stale expected revision conflicts and writes nothing")
    func revisionConflict() async throws {
        let f = try await seed()
        await #expect(throws: WorkbenchError.self) {
            _ = try await f.transforms.applyTransform(
                datasetID: f.datasetID, spec: .calculatedColumn(newField: "d", shape: .number, formula: "[amount]"),
                expectedRevision: f.revision - 1, actor: "u", at: t0)
        }
        #expect(try await f.transforms.transformations(datasetID: f.datasetID).isEmpty)
    }

    @Test("A bad formula rolls back atomically: no field, no transformation, revision unchanged")
    func badFormulaRollsBack() async throws {
        let f = try await seed()
        await #expect(throws: WorkbenchTransformError.self) {
            _ = try await f.transforms.applyTransform(
                datasetID: f.datasetID, spec: .calculatedColumn(newField: "d", shape: .number, formula: "[nonexistent] + 1"),
                expectedRevision: f.revision, actor: "u", at: t0)
        }
        let rec = try await f.datasets.fetch(datasetID: f.datasetID)!
        #expect(rec.fields.count == 2)
        #expect(rec.dataset.revision == f.revision)
        #expect(try await f.transforms.transformations(datasetID: f.datasetID).isEmpty)
    }

    @Test("The read-only source cells are never mutated by a transformation")
    func sourceCellsUntouched() async throws {
        let f = try await seed()
        _ = try await f.transforms.applyTransform(
            datasetID: f.datasetID, spec: .calculatedColumn(newField: "d", shape: .number, formula: "[amount] * 10"),
            expectedRevision: f.revision, actor: "u", at: t0)
        let rec = try await f.datasets.fetch(datasetID: f.datasetID)!
        let sourceAmounts = rec.cells.filter { $0.fieldID == f.amountFieldID }
        #expect(sourceAmounts.allSatisfy { $0.kind == .sourceValue })
        #expect(Set(sourceAmounts.compactMap { $0.value }) == ["100", "50", "25"])
    }

    @Test("Applied transformations carry a monotone per-dataset sequence")
    func sequenceMonotone() async throws {
        let f = try await seed()
        var rev = f.revision
        let t1 = try await f.transforms.applyTransform(datasetID: f.datasetID, spec: .filter(predicate: "[amount] > 0"),
                                                       expectedRevision: rev, actor: "u", at: t0)
        rev = try await f.datasets.fetch(datasetID: f.datasetID)!.dataset.revision
        let t2 = try await f.transforms.applyTransform(datasetID: f.datasetID, spec: .sort(field: "amount", direction: .ascending),
                                                       expectedRevision: rev, actor: "u", at: t0)
        #expect(t1.transformation.sequence == 1)
        #expect(t2.transformation.sequence == 2)
        #expect(try await f.transforms.transformations(datasetID: f.datasetID).map(\.sequence) == [1, 2])
    }
}
