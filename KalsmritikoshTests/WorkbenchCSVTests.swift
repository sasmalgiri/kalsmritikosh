//
//  WorkbenchCSVTests.swift
//  KalsmritikoshTests
//
//  DATALAB-UI — the CSV exporter behind DataLab's Export button: RFC-4180
//  escaping, deterministic field/row order, and scenario-projection
//  substitution (overrides shown, excluded rows dropped, base untouched).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("DATALAB — CSV export")
struct WorkbenchCSVTests {

    @Test("Escaping — commas, quotes and newlines are RFC-4180 quoted")
    func escaping() {
        #expect(WorkbenchCSV.escape("plain") == "plain")
        #expect(WorkbenchCSV.escape("a,b") == "\"a,b\"")
        #expect(WorkbenchCSV.escape("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(WorkbenchCSV.escape("two\nlines") == "\"two\nlines\"")
        #expect(WorkbenchCSV.escape("") == "")
    }

    @Test("Parsing — quotes, escaped quotes, CRLF, embedded newlines; render round-trips")
    func parsing() {
        #expect(WorkbenchCSV.parse("a,b\r\n1,2\r\n") == [["a", "b"], ["1", "2"]])
        #expect(WorkbenchCSV.parse("a,b\n1,2") == [["a", "b"], ["1", "2"]],
                "bare LF and no trailing newline both parse")
        #expect(WorkbenchCSV.parse("\"x,y\",\"say \"\"hi\"\"\"\r\n") == [["x,y", "say \"hi\""]])
        #expect(WorkbenchCSV.parse("\"two\nlines\",b\r\n") == [["two\nlines", "b"]])
        #expect(WorkbenchCSV.parse("") == [])
        // Round trip: values with every awkward character survive.
        let grid = [["Name", "Note"], ["Home, contents", "say \"hi\"\nnew line"]]
        let rendered = grid.map { row in row.map(WorkbenchCSV.escape).joined(separator: ",") }
            .joined(separator: "\r\n") + "\r\n"
        #expect(WorkbenchCSV.parse(rendered) == grid)
    }

    @Test("Report — table content, provenance counts, quality warnings, no reserved keys")
    func report() async throws {
        let url = MigrationFixtureBuilder.newTemporaryURL()
        let db = try await MigrationFixtureBuilder.database(atVersion: 0, at: url)
        try await SchemaMigrations.migrate(db)
        let workspaces = WorkspaceRepository(database: db)
        let ws = Workspace(title: "Test")
        try await workspaces.upsert(ws)
        let repo = WorkbenchDatasetRepository(database: db)
        var rec = try await repo.createDataset(workspaceID: ws.id, title: "Premiums",
                                               mode: .simple, actor: "T", at: Date())
        rec = try await repo.addField(datasetID: rec.dataset.id, name: "Policy", valueShape: .text,
                                      expectedRevision: rec.dataset.revision, actor: "T", at: Date())
        rec = try await repo.addRow(datasetID: rec.dataset.id,
                                    expectedRevision: rec.dataset.revision, actor: "T", at: Date())
        let row = try #require(rec.rows.first)
        let field = try #require(rec.fields.first)
        rec = try await repo.setCell(datasetID: rec.dataset.id, rowID: row.id, fieldID: field.id,
                                     kind: .userEntered, value: "Home", status: .humanConfirmed,
                                     expectedRevision: rec.dataset.revision, actor: "T", at: Date())
        let quality = WorkbenchDataQualityEvaluator.evaluate(record: rec)
        let text = WorkbenchReport.render(rec, quality: quality)
        #expect(text.contains("DATASET: Premiums"))
        #expect(text.contains("Fields: Policy"))
        #expect(text.contains("Rows: 1"))
        #expect(text.contains("Home"))
        #expect(text.contains("0 source-bound") && text.contains("1 entered"))
        #expect(text.contains("QUALITY"))
    }

    /// Build a real dataset through the repository, export it, and check the
    /// exact CSV — order comes from field/row ordinals, not insertion luck.
    @Test("A repository-built dataset renders in ordinal order with values")
    func datasetRenders() async throws {
        let url = MigrationFixtureBuilder.newTemporaryURL()
        let db = try await MigrationFixtureBuilder.database(atVersion: 0, at: url)
        try await SchemaMigrations.migrate(db)
        let workspaces = WorkspaceRepository(database: db)
        let ws = Workspace(title: "Test")
        try await workspaces.upsert(ws)
        let repo = WorkbenchDatasetRepository(database: db)

        var rec = try await repo.createDataset(workspaceID: ws.id, title: "Policies",
                                               mode: .simple, actor: "T", at: Date())
        rec = try await repo.addField(datasetID: rec.dataset.id, name: "Policy", valueShape: .text,
                                      expectedRevision: rec.dataset.revision, actor: "T", at: Date())
        rec = try await repo.addField(datasetID: rec.dataset.id, name: "Premium", valueShape: .number,
                                      expectedRevision: rec.dataset.revision, actor: "T", at: Date())
        rec = try await repo.addRow(datasetID: rec.dataset.id,
                                    expectedRevision: rec.dataset.revision, actor: "T", at: Date())
        let row = try #require(rec.rows.first)
        let policyField = try #require(rec.fields.first { $0.name == "Policy" })
        let premiumField = try #require(rec.fields.first { $0.name == "Premium" })
        rec = try await repo.setCell(datasetID: rec.dataset.id, rowID: row.id, fieldID: policyField.id,
                                     kind: .userEntered, value: "Home, contents", status: .humanConfirmed,
                                     expectedRevision: rec.dataset.revision, actor: "T", at: Date())
        rec = try await repo.setCell(datasetID: rec.dataset.id, rowID: row.id, fieldID: premiumField.id,
                                     kind: .userEntered, value: "1200", status: .humanConfirmed,
                                     expectedRevision: rec.dataset.revision, actor: "T", at: Date())

        let csv = WorkbenchCSV.render(rec)
        #expect(csv == "Policy,Premium\r\n\"Home, contents\",1200\r\n")
    }

    @Test("A scenario projection substitutes overrides and drops excluded rows — base untouched")
    func scenarioProjectionRenders() async throws {
        let url = MigrationFixtureBuilder.newTemporaryURL()
        let db = try await MigrationFixtureBuilder.database(atVersion: 0, at: url)
        try await SchemaMigrations.migrate(db)
        let workspaces = WorkspaceRepository(database: db)
        let ws = Workspace(title: "Test")
        try await workspaces.upsert(ws)
        let datasets = WorkbenchDatasetRepository(database: db)
        let scenarios = WorkbenchScenarioRepository(database: db)

        var rec = try await datasets.createDataset(workspaceID: ws.id, title: "Amounts",
                                                   mode: .advanced, actor: "T", at: Date())
        rec = try await datasets.addField(datasetID: rec.dataset.id, name: "Amount", valueShape: .number,
                                          expectedRevision: rec.dataset.revision, actor: "T", at: Date())
        let field = try #require(rec.fields.first)
        for value in ["10", "20"] {
            rec = try await datasets.addRow(datasetID: rec.dataset.id,
                                            expectedRevision: rec.dataset.revision, actor: "T", at: Date())
            let row = try #require(rec.rows.last)
            rec = try await datasets.setCell(datasetID: rec.dataset.id, rowID: row.id, fieldID: field.id,
                                             kind: .userEntered, value: value, status: .humanConfirmed,
                                             expectedRevision: rec.dataset.revision, actor: "T", at: Date())
        }
        let rows = rec.rows.sorted { $0.ordinal < $1.ordinal }

        var scenario = try await scenarios.createScenario(datasetID: rec.dataset.id, title: "What if",
                                                          actor: "T", at: Date())
        scenario = try await scenarios.applyOperation(scenarioID: scenario.scenario.id, kind: .valueOverride,
                                                      rowID: rows[0].id, fieldID: field.id,
                                                      afterValue: "99", reason: "test the ceiling",
                                                      expectedRevision: scenario.scenario.revision,
                                                      actor: "T", at: Date())
        scenario = try await scenarios.applyOperation(scenarioID: scenario.scenario.id, kind: .rowExclusion,
                                                      rowID: rows[1].id, fieldID: nil,
                                                      afterValue: nil, reason: "out of scope",
                                                      expectedRevision: scenario.scenario.revision,
                                                      actor: "T", at: Date())
        let projection = WorkbenchScenarioProjection.build(base: rec,
                                                           appliedOps: scenario.appliedOperations)

        #expect(WorkbenchCSV.render(rec, projection: projection) == "Amount\r\n99\r\n",
                "override substituted, excluded row dropped")
        #expect(WorkbenchCSV.render(rec) == "Amount\r\n10\r\n20\r\n",
                "the base export is untouched by the scenario")
    }
}
