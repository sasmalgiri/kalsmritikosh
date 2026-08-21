//
//  DataLabStarterTemplatesTests.swift
//  KalsmritikoshTests
//
//  Validates the persona starter-template catalog and proves a template applies
//  (idempotently) to a real dataset through the Workbench repository.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("DataLab starter templates")
struct DataLabStarterTemplatesTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Catalog integrity

    @Test("Catalog covers all ten personas with unique ids and clean columns")
    func catalogIntegrity() {
        let all = DataLabStarterTemplates.all
        #expect(all.count >= 10)

        // Unique template ids.
        #expect(Set(all.map(\.id)).count == all.count)

        // Every persona profession is represented.
        let professions = Set(all.map(\.profession))
        for p in ["Lawyer", "Investigator", "SIU / Insurance", "Forensic Accountant",
                  "HR / Compliance", "Researcher", "Journalist", "Genealogist",
                  "Individual", "Content Creator"] {
            #expect(professions.contains(p), "missing template for \(p)")
        }

        for t in all {
            #expect(!t.displayName.isEmpty)
            #expect(!t.purpose.isEmpty)
            #expect(!t.note.isEmpty)
            #expect(t.columns.count >= 4, "\(t.id) has too few columns")
            // Column names unique within a template.
            let names = t.columns.map(\.name)
            #expect(Set(names).count == names.count, "\(t.id) has duplicate column names")
            // Derived columns carry a non-blank formula.
            for c in t.columns where c.formula != nil {
                #expect(!(c.formula ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    @Test("Suggested-for-workspace filtering returns relevant templates, never empty")
    func suggestedFiltering() {
        #expect(DataLabStarterTemplates.suggested(for: .legalMatter).contains { $0.profession == "Lawyer" })
        #expect(DataLabStarterTemplates.suggested(for: .journalism).contains { $0.profession == "Journalist" })
        // .general has no specific profession → falls back to all.
        #expect(DataLabStarterTemplates.suggested(for: .general).count == DataLabStarterTemplates.all.count)
        // Never empty for any workspace template.
        for wt in WorkspaceTemplate.allCases {
            #expect(!DataLabStarterTemplates.suggested(for: wt).isEmpty)
        }
    }

    // MARK: - Applying a template to a real dataset (idempotent)

    @Test("A template's columns apply to a real dataset and re-applying is idempotent")
    func applyTemplateIdempotent() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db)

        // Seed a workspace row (matches WorkspaceRepository.upsert columns).
        let wsID = UUID()
        try await db.exec("""
        INSERT INTO workspaces
            (id, title, template_type, description, status, default_date_start,
             default_date_end, default_scope_json, created_at, updated_at, archived_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?);
        """, [
            .uuid(wsID), .text("Test matter"), .text("general"), .null, .text("active"),
            .null, .null, .text("{}"),
            .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970), .null
        ])

        let repo = WorkbenchDatasetRepository(database: db)
        var rec = try await repo.createDataset(workspaceID: wsID, title: "Privilege log",
                                               mode: .advanced, actor: "Tester", at: t0)

        let template = DataLabStarterTemplates.all.first { $0.id == "law.datalab.privilege-log" }!

        // First application — add each input column.
        for col in template.inputColumns where !rec.fields.contains(where: { $0.name == col.name }) {
            rec = try await repo.addField(datasetID: rec.dataset.id, name: col.name, valueShape: col.shape,
                                          expectedRevision: rec.dataset.revision, actor: "Tester", at: t0)
        }
        #expect(rec.fields.count == template.inputColumns.count)
        #expect(Set(rec.fields.map(\.name)) == Set(template.inputColumns.map(\.name)))

        // Second application — nothing new should be added.
        var added = 0
        for col in template.inputColumns where !rec.fields.contains(where: { $0.name == col.name }) {
            rec = try await repo.addField(datasetID: rec.dataset.id, name: col.name, valueShape: col.shape,
                                          expectedRevision: rec.dataset.revision, actor: "Tester", at: t0)
            added += 1
        }
        #expect(added == 0, "re-applying a template must not duplicate columns")
        #expect(rec.fields.count == template.inputColumns.count)
    }

    // MARK: - Persona-scoped analyses

    @Test("Every template curates a non-empty, valid analysis set")
    func templateAnalyses() {
        let valid = Set(DataLabStarterTemplates.allAnalysesOrdered)
        for t in DataLabStarterTemplates.all {
            #expect(!t.analyses.isEmpty, "\(t.id) has no analyses")
            #expect(t.analyses.allSatisfy { valid.contains($0) }, "\(t.id) has an unknown analysis")
        }
    }

    @Test("Analyses are scoped per persona; General gets the full set; never empty")
    func analysesForPersona() {
        let all = DataLabStarterTemplates.allAnalysesOrdered

        // General → everything.
        #expect(DataLabStarterTemplates.analyses(for: .general).count == all.count)

        // Lawyer (legalMatter): count/sort/dedupe, and NOT running total.
        let legal = DataLabStarterTemplates.analyses(for: .legalMatter)
        #expect(legal.contains(.countByCategory))
        #expect(legal.contains(.removeDuplicates))
        #expect(!legal.contains(.runningTotal))
        // Curated, not the whole menu.
        #expect(legal.count < all.count)

        // Forensic (investigation union) includes running total (a ledger balance).
        let invUnion = DataLabStarterTemplates.analyses(for: .investigation)
        #expect(invUnion.contains(.runningTotal))
        #expect(invUnion.contains(.totalByCategory))

        // Canonical ordering preserved (subset of the ordered list).
        for wt in WorkspaceTemplate.allCases {
            let a = DataLabStarterTemplates.analyses(for: wt)
            #expect(!a.isEmpty)
            let indices = a.compactMap { all.firstIndex(of: $0) }
            #expect(indices == indices.sorted(), "\(wt) analyses not in canonical order")
        }
    }

    // MARK: - Paste parsing (modern data entry)

    @Test("Paste parser handles tab-separated Excel blocks with CRLF line endings")
    func pasteParserTabs() {
        let raw = "Alice\t100\t2024-01-01\r\nBob\t250\t2024-02-15\r\n"
        let table = DataLabPasteParser.parse(raw)
        #expect(table.count == 2)
        #expect(table[0] == ["Alice", "100", "2024-01-01"])
        #expect(table[1] == ["Bob", "250", "2024-02-15"])
    }

    @Test("Paste parser falls back to commas and trims whitespace")
    func pasteParserCommas() {
        let raw = "Item A, 10 ,  Bank\nItem B,20,Broker"
        let table = DataLabPasteParser.parse(raw)
        #expect(table.count == 2)
        #expect(table[0] == ["Item A", "10", "Bank"])
        #expect(table[1] == ["Item B", "20", "Broker"])
    }

    @Test("Paste parser returns empty for blank input")
    func pasteParserEmpty() {
        #expect(DataLabPasteParser.parse("").isEmpty)
        #expect(DataLabPasteParser.parse("\n\n").isEmpty)
    }

    @Test("A money/date-heavy template (inventory) applies with correct value shapes")
    func applyMoneyDateTemplate() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db)
        let wsID = UUID()
        try await db.exec("""
        INSERT INTO workspaces (id, title, template_type, description, status, default_date_start,
                                default_date_end, default_scope_json, created_at, updated_at, archived_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?);
        """, [.uuid(wsID), .text("Personal"), .text("personalMatter"), .null, .text("active"),
              .null, .null, .text("{}"), .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970), .null])

        let repo = WorkbenchDatasetRepository(database: db)
        var rec = try await repo.createDataset(workspaceID: wsID, title: "Inventory",
                                               mode: .simple, actor: "Tester", at: t0)
        let template = DataLabStarterTemplates.all.first { $0.id == "ind.datalab.inventory" }!
        for col in template.inputColumns {
            rec = try await repo.addField(datasetID: rec.dataset.id, name: col.name, valueShape: col.shape,
                                          expectedRevision: rec.dataset.revision, actor: "Tester", at: t0)
        }
        // The Value column must carry the money shape end-to-end.
        let valueField = rec.fields.first { $0.name == "Value" }
        #expect(valueField?.valueShape == .money)
        #expect(rec.fields.contains { $0.name == "Who can access" })
    }
}
