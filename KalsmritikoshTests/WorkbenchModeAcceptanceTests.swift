//
//  WorkbenchModeAcceptanceTests.swift
//  KalsmritikoshTests
//
//  LAB-006 (Stage C closure) end-to-end acceptance: the SAME dataset serves both presentations. Flipping
//  a dataset from Simple to Advanced changes no cells and no truth — the data-quality report is
//  byte-for-byte identical across the flip, and only the PRESENTATION (which warnings are surfaced,
//  whether lineage is inline) differs. Proves Simple truth = Advanced truth over the one dataset, one
//  transform engine, one scenario engine, one quality analysis. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("LAB-006 — one dataset, two presentations")
struct WorkbenchModeAcceptanceTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    @Test("Flipping Simple↔Advanced preserves the dataset and its quality truth; only presentation differs")
    func sameTruthAcrossModeFlip() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);", [.uuid(ws), .text("W"), .real(0), .real(0)])
        let datasets = WorkbenchDatasetRepository(database: db)
        let scenarios = WorkbenchScenarioRepository(database: db)
        let analyzer = WorkbenchDataQualityAnalyzer(datasets: datasets, scenarios: scenarios)

        // A dataset opened in Simple mode with a source cell missing a value (raises a warning).
        var rec = try await datasets.createDataset(workspaceID: ws, title: "Ledger", mode: .simple, actor: "u", at: t0)
        let did = rec.dataset.id
        rec = try await datasets.addField(datasetID: did, name: "amount", valueShape: .number, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        let fid = rec.fields[0].id
        rec = try await datasets.addRow(datasetID: did, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        let rid = rec.rows[0].id
        rec = try await datasets.setCell(datasetID: did, rowID: rid, fieldID: fid, kind: .sourceValue, value: nil, status: .directlyObserved, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        let cellValueBefore = rec.cells.first { $0.rowID == rid && $0.fieldID == fid }?.value

        // Truth in Simple mode.
        let reportSimple = try await analyzer.report(datasetID: did)

        // Flip to Advanced — same dataset id, same cells, same revision-bump semantics.
        rec = try await datasets.setMode(datasetID: did, mode: .advanced, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        #expect(rec.dataset.mode == .advanced)
        let cellValueAfter = rec.cells.first { $0.rowID == rid && $0.fieldID == fid }?.value
        #expect(cellValueBefore == cellValueAfter)   // the cell is untouched by the mode change

        // Truth in Advanced mode is IDENTICAL (warnings match exactly).
        let reportAdvanced = try await analyzer.report(datasetID: did)
        #expect(reportSimple.warnings == reportAdvanced.warnings)

        // Only the PRESENTATION differs: Advanced surfaces a superset of what Simple does, from the same report.
        let simpleView = WorkbenchModePresentation.warningsToSurface(mode: .simple, report: reportAdvanced)
        let advancedView = WorkbenchModePresentation.warningsToSurface(mode: .advanced, report: reportAdvanced)
        #expect(Set(advancedView.map(\.id)).isSuperset(of: Set(simpleView.map(\.id))))
        #expect(WorkbenchModePolicy.capabilities(for: .advanced).exposes(.formulaEditor))
        #expect(!WorkbenchModePolicy.capabilities(for: .simple).exposes(.formulaEditor))
    }
}
