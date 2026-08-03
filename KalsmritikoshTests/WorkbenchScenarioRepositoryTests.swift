//
//  WorkbenchScenarioRepositoryTests.swift
//  KalsmritikoshTests
//
//  LAB-003 — the scenario repository over a real ledger. Proves the non-destructive overlay contract:
//  operations replay deterministically; undo/redo move a pointer without rewriting history; a new
//  operation after undo abandons (never resurrects) the redo branch; reset/discard/duplicate behave;
//  compare-against-source + original-lineage retention hold; transform-over-scenario reuses the ONE
//  engine without mutating canonical derivations; staleness is surfaced not silently rebased; promotion
//  requires an explicit reviewed action and leaves canonical evidence unchanged; and close/reopen
//  restores the exact undo/redo position. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("LAB-003 — scenario repository")
struct WorkbenchScenarioRepositoryTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private struct Fixture {
        let db: Database
        let datasets: WorkbenchDatasetRepository
        let transforms: WorkbenchTransformRepository
        let scenarios: WorkbenchScenarioRepository
        let datasetID: UUID
        let catFieldID: UUID
        let amountFieldID: UUID
        let rowIDs: [UUID]
        let amountCellIDs: [UUID]
        var datasetRevision: Int
    }

    /// A dataset with (cat: text, amount: number) and three source rows (A,100)(B,50)(A,25).
    private func seed() async throws -> Fixture {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(ws), .text("W"), .real(0), .real(0)])
        let datasets = WorkbenchDatasetRepository(database: db)
        var rec = try await datasets.createDataset(workspaceID: ws, title: "Payments", mode: .advanced, actor: "u", at: t0)
        let dID = rec.dataset.id
        rec = try await datasets.addField(datasetID: dID, name: "cat", valueShape: .text, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        rec = try await datasets.addField(datasetID: dID, name: "amount", valueShape: .number, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        let catField = rec.fields.first { $0.name == "cat" }!.id
        let amtField = rec.fields.first { $0.name == "amount" }!.id
        var rowIDs: [UUID] = []; var amtCells: [UUID] = []
        for (cat, amt) in [("A", "100"), ("B", "50"), ("A", "25")] {
            rec = try await datasets.addRow(datasetID: dID, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
            let rowID = rec.rows.max { $0.ordinal < $1.ordinal }!.id
            rowIDs.append(rowID)
            rec = try await datasets.setCell(datasetID: dID, rowID: rowID, fieldID: catField, kind: .sourceValue, value: cat, status: .directlyObserved, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
            rec = try await datasets.setCell(datasetID: dID, rowID: rowID, fieldID: amtField, kind: .sourceValue, value: amt, status: .directlyObserved, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
            amtCells.append(rec.cells.first { $0.rowID == rowID && $0.fieldID == amtField }!.id)
        }
        return Fixture(db: db, datasets: datasets, transforms: WorkbenchTransformRepository(database: db),
                       scenarios: WorkbenchScenarioRepository(database: db), datasetID: dID,
                       catFieldID: catField, amountFieldID: amtField, rowIDs: rowIDs, amountCellIDs: amtCells,
                       datasetRevision: rec.dataset.revision)
    }

    // MARK: - Creation + basic operations

    @Test("Creating a scenario captures the base revision, opens active at the origin, records created")
    func create() async throws {
        let f = try await seed()
        let rec = try await f.scenarios.createScenario(datasetID: f.datasetID, title: "What if", actor: "analyst", at: t0)
        #expect(rec.scenario.baseDatasetRevision == f.datasetRevision)
        #expect(rec.scenario.status == .active)
        #expect(rec.scenario.currentOpSeq == 0)
        #expect(rec.events.contains { $0.action == .created })
        #expect(!rec.canUndo && !rec.canRedo)
    }

    @Test("A value override changes the scenario projection but never the source cell")
    func valueOverride() async throws {
        let f = try await seed()
        var rec = try await f.scenarios.createScenario(datasetID: f.datasetID, title: "S", actor: "u", at: t0)
        rec = try await f.scenarios.applyOperation(scenarioID: rec.scenario.id, kind: .valueOverride, rowID: f.rowIDs[0],
                                                   fieldID: f.amountFieldID, afterValue: "999", reason: nil,
                                                   expectedRevision: rec.scenario.revision, actor: "u", at: t0)
        let proj = try await f.scenarios.projection(scenarioID: rec.scenario.id)
        #expect(proj.projectedValue(rowID: f.rowIDs[0], fieldID: f.amountFieldID) == "999")
        // The canonical source cell is untouched.
        let base = try await f.datasets.fetch(datasetID: f.datasetID)!
        #expect(base.cells.first { $0.id == f.amountCellIDs[0] }?.value == "100")
        // before_value captured the original.
        #expect(rec.appliedOperations.first?.beforeValue == "100")
    }

    @Test("A proposed correction requires a reason")
    func proposedCorrectionRequiresReason() async throws {
        let f = try await seed()
        let rec = try await f.scenarios.createScenario(datasetID: f.datasetID, title: "S", actor: "u", at: t0)
        await #expect(throws: WorkbenchScenarioError.self) {
            _ = try await f.scenarios.applyOperation(scenarioID: rec.scenario.id, kind: .proposedCorrection, rowID: f.rowIDs[0],
                                                     fieldID: f.amountFieldID, afterValue: "120", reason: "  ",
                                                     expectedRevision: rec.scenario.revision, actor: "u", at: t0)
        }
        let ok = try await f.scenarios.applyOperation(scenarioID: rec.scenario.id, kind: .proposedCorrection, rowID: f.rowIDs[0],
                                                      fieldID: f.amountFieldID, afterValue: "120", reason: "typo in source",
                                                      expectedRevision: rec.scenario.revision, actor: "u", at: t0)
        #expect(ok.appliedOperations.count == 1)
    }

    @Test("Classification and annotation overlays attach without changing data values")
    func classificationAndAnnotation() async throws {
        let f = try await seed()
        var rec = try await f.scenarios.createScenario(datasetID: f.datasetID, title: "S", actor: "u", at: t0)
        rec = try await f.scenarios.applyOperation(scenarioID: rec.scenario.id, kind: .classification, rowID: f.rowIDs[0],
                                                   fieldID: nil, afterValue: "suspicious", reason: nil, expectedRevision: rec.scenario.revision, actor: "u", at: t0)
        rec = try await f.scenarios.applyOperation(scenarioID: rec.scenario.id, kind: .annotation, rowID: f.rowIDs[0],
                                                   fieldID: f.amountFieldID, afterValue: "check this figure", reason: nil, expectedRevision: rec.scenario.revision, actor: "u", at: t0)
        let proj = try await f.scenarios.projection(scenarioID: rec.scenario.id)
        #expect(proj.classifications[f.rowIDs[0].uuidString] == "suspicious")
        #expect(proj.projectedValue(rowID: f.rowIDs[0], fieldID: f.amountFieldID) == "100")   // data value unchanged
        #expect(proj.annotations["\(f.rowIDs[0].uuidString)|\(f.amountFieldID.uuidString)"] == ["check this figure"])
    }

    // MARK: - Undo / redo / reset

    @Test("Undo and redo move the pointer deterministically without rewriting history")
    func undoRedo() async throws {
        let f = try await seed()
        var rec = try await f.scenarios.createScenario(datasetID: f.datasetID, title: "S", actor: "u", at: t0)
        rec = try await f.scenarios.applyOperation(scenarioID: rec.scenario.id, kind: .valueOverride, rowID: f.rowIDs[0], fieldID: f.amountFieldID, afterValue: "999", reason: nil, expectedRevision: rec.scenario.revision, actor: "u", at: t0)
        rec = try await f.scenarios.undo(scenarioID: rec.scenario.id, expectedRevision: rec.scenario.revision, actor: "u", at: t0)
        #expect(rec.scenario.currentOpSeq == 0)
        #expect(try await f.scenarios.projection(scenarioID: rec.scenario.id).projectedValue(rowID: f.rowIDs[0], fieldID: f.amountFieldID) == "100")
        rec = try await f.scenarios.redo(scenarioID: rec.scenario.id, expectedRevision: rec.scenario.revision, actor: "u", at: t0)
        #expect(try await f.scenarios.projection(scenarioID: rec.scenario.id).projectedValue(rowID: f.rowIDs[0], fieldID: f.amountFieldID) == "999")
        #expect(rec.operations.count == 1)   // history not rewritten
    }

    @Test("Multiple undo walks back to the origin; nothing-to-undo throws")
    func multipleUndo() async throws {
        let f = try await seed()
        var rec = try await f.scenarios.createScenario(datasetID: f.datasetID, title: "S", actor: "u", at: t0)
        rec = try await f.scenarios.applyOperation(scenarioID: rec.scenario.id, kind: .valueOverride, rowID: f.rowIDs[0], fieldID: f.amountFieldID, afterValue: "999", reason: nil, expectedRevision: rec.scenario.revision, actor: "u", at: t0)
        rec = try await f.scenarios.applyOperation(scenarioID: rec.scenario.id, kind: .valueOverride, rowID: f.rowIDs[1], fieldID: f.amountFieldID, afterValue: "888", reason: nil, expectedRevision: rec.scenario.revision, actor: "u", at: t0)
        rec = try await f.scenarios.undo(scenarioID: rec.scenario.id, expectedRevision: rec.scenario.revision, actor: "u", at: t0)
        rec = try await f.scenarios.undo(scenarioID: rec.scenario.id, expectedRevision: rec.scenario.revision, actor: "u", at: t0)
        #expect(rec.scenario.currentOpSeq == 0)
        await #expect(throws: WorkbenchScenarioError.self) {
            _ = try await f.scenarios.undo(scenarioID: rec.scenario.id, expectedRevision: rec.scenario.revision, actor: "u", at: t0)
        }
    }

    @Test("A new operation after undo abandons the redo branch (no silent resurrection)")
    func redoInvalidationAfterBranch() async throws {
        let f = try await seed()
        var rec = try await f.scenarios.createScenario(datasetID: f.datasetID, title: "S", actor: "u", at: t0)
        rec = try await f.scenarios.applyOperation(scenarioID: rec.scenario.id, kind: .valueOverride, rowID: f.rowIDs[0], fieldID: f.amountFieldID, afterValue: "AAA", reason: nil, expectedRevision: rec.scenario.revision, actor: "u", at: t0)
        let opASeq = rec.appliedOperations.first!.sequence
        rec = try await f.scenarios.undo(scenarioID: rec.scenario.id, expectedRevision: rec.scenario.revision, actor: "u", at: t0)
        rec = try await f.scenarios.applyOperation(scenarioID: rec.scenario.id, kind: .valueOverride, rowID: f.rowIDs[0], fieldID: f.amountFieldID, afterValue: "BBB", reason: nil, expectedRevision: rec.scenario.revision, actor: "u", at: t0)
        #expect(!rec.canRedo)   // the A branch was abandoned, not redoable
        #expect(rec.operations.first { $0.sequence == opASeq }?.status == .abandoned)
        #expect(try await f.scenarios.projection(scenarioID: rec.scenario.id).projectedValue(rowID: f.rowIDs[0], fieldID: f.amountFieldID) == "BBB")
    }

    @Test("Reset returns the projection to the source while preserving the log")
    func reset() async throws {
        let f = try await seed()
        var rec = try await f.scenarios.createScenario(datasetID: f.datasetID, title: "S", actor: "u", at: t0)
        rec = try await f.scenarios.applyOperation(scenarioID: rec.scenario.id, kind: .valueOverride, rowID: f.rowIDs[0], fieldID: f.amountFieldID, afterValue: "999", reason: nil, expectedRevision: rec.scenario.revision, actor: "u", at: t0)
        rec = try await f.scenarios.reset(scenarioID: rec.scenario.id, expectedRevision: rec.scenario.revision, actor: "u", at: t0)
        #expect(rec.scenario.currentOpSeq == 0)
        #expect(rec.operations.count == 1)   // preserved
        #expect(try await f.scenarios.projection(scenarioID: rec.scenario.id).diff().isEmpty)
    }

    // MARK: - Discard / duplicate

    @Test("Discard marks the scenario inactive but preserves its history; further edits are refused")
    func discard() async throws {
        let f = try await seed()
        var rec = try await f.scenarios.createScenario(datasetID: f.datasetID, title: "S", actor: "u", at: t0)
        rec = try await f.scenarios.applyOperation(scenarioID: rec.scenario.id, kind: .valueOverride, rowID: f.rowIDs[0], fieldID: f.amountFieldID, afterValue: "999", reason: nil, expectedRevision: rec.scenario.revision, actor: "u", at: t0)
        rec = try await f.scenarios.discard(scenarioID: rec.scenario.id, actor: "u", at: t0)
        #expect(rec.scenario.status == .discarded)
        #expect(rec.operations.count == 1)   // history preserved
        await #expect(throws: WorkbenchScenarioError.self) {
            _ = try await f.scenarios.applyOperation(scenarioID: rec.scenario.id, kind: .valueOverride, rowID: f.rowIDs[1], fieldID: f.amountFieldID, afterValue: "1", reason: nil, expectedRevision: rec.scenario.revision, actor: "u", at: t0)
        }
    }

    @Test("Duplicate creates an independent scenario copying the applied state")
    func duplicate() async throws {
        let f = try await seed()
        var rec = try await f.scenarios.createScenario(datasetID: f.datasetID, title: "S", actor: "u", at: t0)
        rec = try await f.scenarios.applyOperation(scenarioID: rec.scenario.id, kind: .valueOverride, rowID: f.rowIDs[0], fieldID: f.amountFieldID, afterValue: "999", reason: nil, expectedRevision: rec.scenario.revision, actor: "u", at: t0)
        let dup = try await f.scenarios.duplicate(scenarioID: rec.scenario.id, newTitle: "S copy", actor: "u", at: t0)
        #expect(dup.scenario.id != rec.scenario.id)
        #expect(dup.appliedOperations.count == 1)
        #expect(try await f.scenarios.projection(scenarioID: dup.scenario.id).projectedValue(rowID: f.rowIDs[0], fieldID: f.amountFieldID) == "999")
        // Undo on the source does not affect the duplicate.
        _ = try await f.scenarios.undo(scenarioID: rec.scenario.id, expectedRevision: rec.scenario.revision + 1, actor: "u", at: t0)
        #expect(try await f.scenarios.projection(scenarioID: dup.scenario.id).projectedValue(rowID: f.rowIDs[0], fieldID: f.amountFieldID) == "999")
    }

    // MARK: - Compare, lineage, close/reopen

    @Test("Diff reports the source-vs-scenario difference with the original value")
    func compareAgainstSource() async throws {
        let f = try await seed()
        var rec = try await f.scenarios.createScenario(datasetID: f.datasetID, title: "S", actor: "u", at: t0)
        rec = try await f.scenarios.applyOperation(scenarioID: rec.scenario.id, kind: .valueOverride, rowID: f.rowIDs[0], fieldID: f.amountFieldID, afterValue: "999", reason: nil, expectedRevision: rec.scenario.revision, actor: "u", at: t0)
        let diff = try await f.scenarios.diff(scenarioID: rec.scenario.id)
        #expect(diff.count == 1)
        #expect(diff.first?.originalValue == "100")
        #expect(diff.first?.scenarioValue == "999")
    }

    @Test("A scenario override preserves — never replaces — the source cell's canonical lineage")
    func originalLineageRetained() async throws {
        let f = try await seed()
        // Bind the source amount cell to a canonical source version (recorded directly).
        try await f.db.exec("""
            INSERT INTO workbench_source_bindings (id, cell_id, target_kind, target_id, source_version_id, locator_json, ordinal, created_at)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(f.amountCellIDs[0]), .text("sourceVersion"), .text(UUID().uuidString), .uuid(UUID()), .null, .integer(0), .real(1)])
        var rec = try await f.scenarios.createScenario(datasetID: f.datasetID, title: "S", actor: "u", at: t0)
        rec = try await f.scenarios.applyOperation(scenarioID: rec.scenario.id, kind: .valueOverride, rowID: f.rowIDs[0], fieldID: f.amountFieldID, afterValue: "999", reason: nil, expectedRevision: rec.scenario.revision, actor: "u", at: t0)
        let proj = try await f.scenarios.projection(scenarioID: rec.scenario.id)
        #expect(proj.originalBindings(rowID: f.rowIDs[0], fieldID: f.amountFieldID).count == 1)   // lineage additive, not replaced
    }

    @Test("Close/reopen restores the exact undo/redo position")
    func closeReopenExactPointer() async throws {
        let f = try await seed()
        var rec = try await f.scenarios.createScenario(datasetID: f.datasetID, title: "S", actor: "u", at: t0)
        for v in ["A", "B", "C"] {
            rec = try await f.scenarios.applyOperation(scenarioID: rec.scenario.id, kind: .valueOverride, rowID: f.rowIDs[0], fieldID: f.amountFieldID, afterValue: v, reason: nil, expectedRevision: rec.scenario.revision, actor: "u", at: t0)
        }
        rec = try await f.scenarios.undo(scenarioID: rec.scenario.id, expectedRevision: rec.scenario.revision, actor: "u", at: t0)
        let reopened = try await f.scenarios.fetch(scenarioID: rec.scenario.id)!
        #expect(reopened.appliedOperations.count == 2)
        #expect(reopened.redoableOperations.count == 1)
        #expect(reopened.canUndo && reopened.canRedo)
    }

    @Test("A stale expected revision conflicts and writes nothing")
    func revisionConflict() async throws {
        let f = try await seed()
        let rec = try await f.scenarios.createScenario(datasetID: f.datasetID, title: "S", actor: "u", at: t0)
        await #expect(throws: WorkbenchScenarioError.self) {
            _ = try await f.scenarios.applyOperation(scenarioID: rec.scenario.id, kind: .valueOverride, rowID: f.rowIDs[0], fieldID: f.amountFieldID, afterValue: "1", reason: nil, expectedRevision: rec.scenario.revision + 5, actor: "u", at: t0)
        }
        #expect(try await f.scenarios.fetch(scenarioID: rec.scenario.id)!.operations.isEmpty)
    }

    // MARK: - Staleness + transform-over-scenario

    @Test("Staleness is surfaced when the base dataset revision changes (never silently rebased)")
    func staleness() async throws {
        let f = try await seed()
        let rec = try await f.scenarios.createScenario(datasetID: f.datasetID, title: "S", actor: "u", at: t0)
        // Mutate the base dataset after the scenario was created.
        _ = try await f.datasets.addField(datasetID: f.datasetID, name: "note", valueShape: .text, expectedRevision: f.datasetRevision, actor: "u", at: t0)
        let stale = try await f.scenarios.staleness(scenarioID: rec.scenario.id)
        #expect(stale.baseRevisionChanged)
        #expect(stale.isStale)
        #expect(!stale.reasons.isEmpty)
    }

    @Test("A transformation over the scenario projection reuses the engine without mutating canonical derivations")
    func transformOverScenario() async throws {
        let f = try await seed()
        var rec = try await f.scenarios.createScenario(datasetID: f.datasetID, title: "S", actor: "u", at: t0)
        rec = try await f.scenarios.applyOperation(scenarioID: rec.scenario.id, kind: .valueOverride, rowID: f.rowIDs[0], fieldID: f.amountFieldID, afterValue: "200", reason: nil, expectedRevision: rec.scenario.revision, actor: "u", at: t0)
        let outcome = try await f.scenarios.transformOverScenario(scenarioID: rec.scenario.id, spec: .aggregate(function: .sum, field: "amount", groupBy: ["cat"]))
        guard case .aggregate(let agg) = outcome else { Issue.record("expected aggregate"); return }
        let byKey = Dictionary(uniqueKeysWithValues: agg.groups.map { ($0.resultKey ?? "", $0.value.storedString) })
        #expect(byKey["A"] == "225")   // scenario: 200 + 25 (canonical would be 125)
        // No LAB-002 canonical transformation was persisted.
        #expect(try await f.transforms.transformations(datasetID: f.datasetID).isEmpty)
    }

    // MARK: - Promotion through review

    @Test("Promotion records a reviewed decision and never mutates canonical evidence")
    func promotionThroughReview() async throws {
        let f = try await seed()
        var rec = try await f.scenarios.createScenario(datasetID: f.datasetID, title: "S", actor: "u", at: t0)
        rec = try await f.scenarios.applyOperation(scenarioID: rec.scenario.id, kind: .proposedCorrection, rowID: f.rowIDs[0], fieldID: f.amountFieldID, afterValue: "120", reason: "corrected per source", expectedRevision: rec.scenario.revision, actor: "u", at: t0)
        let opID = rec.appliedOperations.first!.id
        rec = try await f.scenarios.promoteThroughReview(scenarioID: rec.scenario.id, operationID: opID, destination: .claimReview,
                                                         decision: .accepted, reviewer: "reviewer", reason: "verified", resultingReference: "claim-42",
                                                         expectedRevision: rec.scenario.revision, at: t0)
        #expect(rec.reviews.count == 1)
        #expect(rec.reviews.first?.decision == .accepted)
        #expect(rec.reviews.first?.resultingReference == "claim-42")
        // Canonical source cell unchanged by the promotion.
        let base = try await f.datasets.fetch(datasetID: f.datasetID)!
        #expect(base.cells.first { $0.id == f.amountCellIDs[0] }?.value == "100")
    }

    @Test("A rejected promotion is recorded and leaves canonical state unchanged")
    func promotionRejected() async throws {
        let f = try await seed()
        var rec = try await f.scenarios.createScenario(datasetID: f.datasetID, title: "S", actor: "u", at: t0)
        rec = try await f.scenarios.applyOperation(scenarioID: rec.scenario.id, kind: .valueOverride, rowID: f.rowIDs[0], fieldID: f.amountFieldID, afterValue: "999", reason: nil, expectedRevision: rec.scenario.revision, actor: "u", at: t0)
        let opID = rec.appliedOperations.first!.id
        rec = try await f.scenarios.promoteThroughReview(scenarioID: rec.scenario.id, operationID: opID, destination: .userCorrection,
                                                         decision: .rejected, reviewer: "reviewer", reason: "not supported", resultingReference: nil,
                                                         expectedRevision: rec.scenario.revision, at: t0)
        #expect(rec.reviews.first?.decision == .rejected)
        #expect(rec.reviews.first?.resultingReference == nil)
        #expect(rec.events.contains { $0.action == .promotionRejected })
    }

    @Test("A row inclusion/exclusion operation is not promotable")
    func rowOpNotPromotable() async throws {
        let f = try await seed()
        var rec = try await f.scenarios.createScenario(datasetID: f.datasetID, title: "S", actor: "u", at: t0)
        rec = try await f.scenarios.applyOperation(scenarioID: rec.scenario.id, kind: .rowExclusion, rowID: f.rowIDs[1], fieldID: nil, afterValue: nil, reason: nil, expectedRevision: rec.scenario.revision, actor: "u", at: t0)
        let opID = rec.appliedOperations.first!.id
        await #expect(throws: WorkbenchScenarioError.self) {
            _ = try await f.scenarios.promoteThroughReview(scenarioID: rec.scenario.id, operationID: opID, destination: .claimReview,
                                                           decision: .accepted, reviewer: "r", reason: nil, resultingReference: "x",
                                                           expectedRevision: rec.scenario.revision, at: t0)
        }
    }

    @Test("Row exclusion drops the row from the scenario projection")
    func rowExclusion() async throws {
        let f = try await seed()
        var rec = try await f.scenarios.createScenario(datasetID: f.datasetID, title: "S", actor: "u", at: t0)
        rec = try await f.scenarios.applyOperation(scenarioID: rec.scenario.id, kind: .rowExclusion, rowID: f.rowIDs[1], fieldID: nil, afterValue: nil, reason: nil, expectedRevision: rec.scenario.revision, actor: "u", at: t0)
        let projected = try await f.scenarios.projection(scenarioID: rec.scenario.id).projectedRecord()
        #expect(projected.rows.count == 2)
        #expect(!projected.rows.contains { $0.id == f.rowIDs[1] })
    }

    @Test("scopeTargets surfaces the canonical sources bound by the base dataset")
    func scopeTargets() async throws {
        let f = try await seed()
        let sv = UUID()
        try await f.db.exec("""
            INSERT INTO workbench_source_bindings (id, cell_id, target_kind, target_id, source_version_id, locator_json, ordinal, created_at)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(f.amountCellIDs[0]), .text("sourceVersion"), .text(sv.uuidString), .uuid(sv), .null, .integer(0), .real(1)])
        let rec = try await f.scenarios.createScenario(datasetID: f.datasetID, title: "S", actor: "u", at: t0)
        let targets = try await f.scenarios.scopeTargets(scenarioID: rec.scenario.id)
        #expect(targets.contains { $0.id == sv })
    }
}
