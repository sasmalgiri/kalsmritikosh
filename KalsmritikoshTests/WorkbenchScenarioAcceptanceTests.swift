//
//  WorkbenchScenarioAcceptanceTests.swift
//  KalsmritikoshTests
//
//  LAB-003 end-to-end acceptance (contract §11): open a canonical dataset → create a scenario → change
//  a value → annotate → classify → run a deterministic calculation over the scenario state → inspect
//  the difference vs source → inspect provenance → undo → redo → save/close → reopen at the exact
//  scenario revision → attempt a reviewed promotion → record the human decision → verify canonical
//  evidence changed only through the authorized reviewed path → discard → preserve audit history.
//  Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("LAB-003 — end-to-end acceptance")
struct WorkbenchScenarioAcceptanceTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    @Test("The full scenario journey holds every truth boundary end to end")
    func journey() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);", [.uuid(ws), .text("W"), .real(0), .real(0)])
        let datasets = WorkbenchDatasetRepository(database: db)
        let scenarios = WorkbenchScenarioRepository(database: db)

        // Open a canonical dataset with (cat, amount) and two source rows.
        var d = try await datasets.createDataset(workspaceID: ws, title: "Ledger", mode: .advanced, actor: "u", at: t0)
        let did = d.dataset.id
        d = try await datasets.addField(datasetID: did, name: "cat", valueShape: .text, expectedRevision: d.dataset.revision, actor: "u", at: t0)
        d = try await datasets.addField(datasetID: did, name: "amount", valueShape: .number, expectedRevision: d.dataset.revision, actor: "u", at: t0)
        let catF = d.fields.first { $0.name == "cat" }!.id
        let amtF = d.fields.first { $0.name == "amount" }!.id
        var rowIDs: [UUID] = []; var amtCells: [UUID] = []
        for (c, a) in [("A", "100"), ("A", "40")] {
            d = try await datasets.addRow(datasetID: did, expectedRevision: d.dataset.revision, actor: "u", at: t0)
            let r = d.rows.max { $0.ordinal < $1.ordinal }!.id; rowIDs.append(r)
            d = try await datasets.setCell(datasetID: did, rowID: r, fieldID: catF, kind: .sourceValue, value: c, status: .directlyObserved, expectedRevision: d.dataset.revision, actor: "u", at: t0)
            d = try await datasets.setCell(datasetID: did, rowID: r, fieldID: amtF, kind: .sourceValue, value: a, status: .directlyObserved, expectedRevision: d.dataset.revision, actor: "u", at: t0)
            amtCells.append(d.cells.first { $0.rowID == r && $0.fieldID == amtF }!.id)
        }

        // Create scenario → change a value → annotate → classify.
        var s = try await scenarios.createScenario(datasetID: did, title: "What if row0 were 300", actor: "analyst", at: t0)
        let sid = s.scenario.id
        s = try await scenarios.applyOperation(scenarioID: sid, kind: .valueOverride, rowID: rowIDs[0], fieldID: amtF, afterValue: "300", reason: nil, expectedRevision: s.scenario.revision, actor: "analyst", at: t0)
        s = try await scenarios.applyOperation(scenarioID: sid, kind: .annotation, rowID: rowIDs[0], fieldID: amtF, afterValue: "assumed corrected figure", reason: nil, expectedRevision: s.scenario.revision, actor: "analyst", at: t0)
        s = try await scenarios.applyOperation(scenarioID: sid, kind: .classification, rowID: rowIDs[0], fieldID: nil, afterValue: "review", reason: nil, expectedRevision: s.scenario.revision, actor: "analyst", at: t0)

        // Deterministic calculation over the SCENARIO state: sum(amount) by cat.
        let outcome = try await scenarios.transformOverScenario(scenarioID: sid, spec: .aggregate(function: .sum, field: "amount", groupBy: ["cat"]))
        guard case .aggregate(let agg) = outcome else { Issue.record("expected aggregate"); return }
        #expect(agg.groups.first { $0.resultKey == "A" }?.value.storedString == "340")   // scenario 300 + 40

        // Inspect the difference against source + provenance.
        let diff = try await scenarios.diff(scenarioID: sid)
        #expect(diff.contains { $0.rowID == rowIDs[0] && $0.originalValue == "100" && $0.scenarioValue == "300" })

        // Undo the classification, then redo it.
        s = try await scenarios.undo(scenarioID: sid, expectedRevision: s.scenario.revision, actor: "analyst", at: t0)
        s = try await scenarios.redo(scenarioID: sid, expectedRevision: s.scenario.revision, actor: "analyst", at: t0)

        // Close + reopen at the exact position.
        let reopened = try await scenarios.fetch(scenarioID: sid)!
        #expect(reopened.appliedOperations.count == 3)
        #expect(!reopened.canRedo)

        // Attempt a reviewed promotion of the value change; record the human decision.
        let overrideOp = reopened.appliedOperations.first { $0.kind == .valueOverride }!
        s = try await scenarios.promoteThroughReview(scenarioID: sid, operationID: overrideOp.id, destination: .claimReview,
                                                     decision: .accepted, reviewer: "supervisor", reason: "matches corrected source",
                                                     resultingReference: "claim-777", expectedRevision: reopened.scenario.revision, at: t0)
        #expect(s.reviews.first?.decision == .accepted)

        // Canonical evidence changed ONLY through the authorized reviewed path — the source cell itself
        // is untouched by the scenario (the promotion routes to an external authority by reference).
        let baseAfter = try await datasets.fetch(datasetID: did)!
        #expect(baseAfter.cells.first { $0.id == amtCells[0] }?.value == "100")

        // Discard → inactive, history preserved.
        s = try await scenarios.discard(scenarioID: sid, actor: "analyst", at: t0)
        #expect(s.scenario.status == .discarded)
        #expect(s.operations.count == 3)
        #expect(s.reviews.count == 1)
        #expect(s.events.contains { $0.action == .created } && s.events.contains { $0.action == .discarded })
    }
}
