//
//  WorkbenchDataQualityAnalyzerTests.swift
//  KalsmritikoshTests
//
//  LAB-005 — the analyzer composing the dataset + scenario read paths over a real ledger. Proves it
//  reports a record-derivable warning (missing value) for a real dataset and correctly collects the
//  reviewed-scenario facts (an unreviewed overlay is flagged; once promoted through an accepted review
//  it is not). Canonical evidence is read-only throughout. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("LAB-005 — data-quality analyzer")
struct WorkbenchDataQualityAnalyzerTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private struct Fixture {
        let datasets: WorkbenchDatasetRepository
        let scenarios: WorkbenchScenarioRepository
        let analyzer: WorkbenchDataQualityAnalyzer
        let datasetID: UUID
        let fieldID: UUID
        let rowID: UUID
        var revision: Int
    }

    private func seed(cellValue: String?) async throws -> Fixture {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);", [.uuid(ws), .text("W"), .real(0), .real(0)])
        let datasets = WorkbenchDatasetRepository(database: db)
        let scenarios = WorkbenchScenarioRepository(database: db)
        var rec = try await datasets.createDataset(workspaceID: ws, title: "D", mode: .advanced, actor: "u", at: t0)
        let did = rec.dataset.id
        rec = try await datasets.addField(datasetID: did, name: "amount", valueShape: .number, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        let fid = rec.fields.first { $0.name == "amount" }!.id
        rec = try await datasets.addRow(datasetID: did, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        let rid = rec.rows[0].id
        rec = try await datasets.setCell(datasetID: did, rowID: rid, fieldID: fid, kind: .sourceValue, value: cellValue, status: .directlyObserved, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        return Fixture(datasets: datasets, scenarios: scenarios,
                       analyzer: WorkbenchDataQualityAnalyzer(datasets: datasets, scenarios: scenarios),
                       datasetID: did, fieldID: fid, rowID: rid, revision: rec.dataset.revision)
    }

    @Test("The analyzer reports a record-derivable warning for a real dataset")
    func recordDerivable() async throws {
        let f = try await seed(cellValue: nil)   // missing value + no custody
        let report = try await f.analyzer.report(datasetID: f.datasetID)
        #expect(report.datasetID == f.datasetID)
        #expect(report.kinds.contains(.missingValue))
        #expect(report.kinds.contains(.missingCustodyHash))
    }

    @Test("An unreviewed scenario overlay is flagged; after an accepted review it is not")
    func unreviewedThenReviewed() async throws {
        let f = try await seed(cellValue: "100")
        var s = try await f.scenarios.createScenario(datasetID: f.datasetID, title: "S", actor: "u", at: t0)
        s = try await f.scenarios.applyOperation(scenarioID: s.scenario.id, kind: .valueOverride, rowID: f.rowID, fieldID: f.fieldID,
                                                 afterValue: "300", reason: nil, expectedRevision: s.scenario.revision, actor: "u", at: t0)
        let before = try await f.analyzer.report(datasetID: f.datasetID, scenarioID: s.scenario.id)
        #expect(before.kinds.contains(.unreviewedScenarioValue))

        let opID = s.appliedOperations.first!.id
        s = try await f.scenarios.promoteThroughReview(scenarioID: s.scenario.id, operationID: opID, destination: .claimReview,
                                                       decision: .accepted, reviewer: "r", reason: "ok", resultingReference: "claim-1",
                                                       expectedRevision: s.scenario.revision, at: t0)
        let after = try await f.analyzer.report(datasetID: f.datasetID, scenarioID: s.scenario.id)
        #expect(!after.kinds.contains(.unreviewedScenarioValue))
    }

    @Test("Reporting on an unknown dataset throws")
    func unknownDataset() async throws {
        let f = try await seed(cellValue: "1")
        await #expect(throws: (any Error).self) { _ = try await f.analyzer.report(datasetID: UUID()) }
    }
}
