//
//  WorkbenchDatasetRepositoryTests.swift
//  KalsmritikoshTests
//
//  LAB-001 (Stage C) — the canonical Workbench dataset repository end to end: create/fields/rows/
//  cells, stable identity, deterministic order, revision CAS + stale rejection, atomic rollback,
//  ownership validation, exact source-binding drill-through (Gate 4) + SourceVersion-mismatch
//  rejection, SensitiveScope propagation over the shared authority (Gate 5), stale-source detection
//  that preserves the durable dataset (Gate 6), close/reopen fidelity (Gate 7), and legacy
//  EvidenceDataset conversion delegating into Workbench* (Gate 8). Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("LAB-001 — WorkbenchDatasetRepository", .serialized)
struct WorkbenchDatasetRepositoryTests {

    private let t0 = Date(timeIntervalSince1970: 1_766_000_000)

    private struct Rig {
        let db: Database
        let repo: WorkbenchDatasetRepository
        let scopes: SensitiveScopeRepository
        let ws: UUID
    }

    private func rig() async throws -> Rig {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(ws), .text("WS"), .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
        return Rig(db: db, repo: WorkbenchDatasetRepository(database: db), scopes: SensitiveScopeRepository(database: db), ws: ws)
    }

    /// Seed a source version (optionally current) for a logical source, returning the version id.
    @discardableResult
    private func seedSourceVersion(_ db: Database, logical: UUID, id: UUID = UUID(), current: Bool = true, at: Double = 100) async throws -> UUID {
        // A files row is only needed once per logical source.
        if try await db.query("SELECT COUNT(*) FROM files WHERE id = ?;", [.uuid(logical)]).first?.int(0) == 0 {
            try await db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                              [.uuid(logical), .text("file:///x/\(logical.uuidString)"), .text("txt"), .text("available")])
        }
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(logical), .text(String(repeating: "a", count: 64)), .real(at), .integer(current ? 1 : 0), .real(at),
                  .text("f.txt"), .text("txt"), .text("magicBytes"), .integer(1), .text("referenced"), .text("referenceRecorded"), .real(at)])
        return id
    }

    @discardableResult
    private func seedBlock(_ db: Database, sourceVersion: UUID, id: UUID = UUID()) async throws -> UUID {
        try await db.exec("""
            INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text, extraction_method, extraction_confidence)
            VALUES (?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(UUID()), .uuid(sourceVersion), .integer(0), .text("paragraph"), .text("t"), .text("t"), .text("native"), .real(1.0)])
        return id
    }

    /// Build a dataset with one field, one row, one source cell bound to a real block. Returns
    /// (datasetID, cellID, blockID) and leaves the record fetchable.
    @discardableResult
    private func boundDataset(_ rig: Rig) async throws -> (dataset: UUID, cell: UUID, block: UUID, sv: UUID) {
        let sv = try await seedSourceVersion(rig.db, logical: UUID())
        let block = try await seedBlock(rig.db, sourceVersion: sv)
        var rec = try await rig.repo.createDataset(workspaceID: rig.ws, title: "Payments", mode: .advanced, actor: "u", at: t0)
        let d = rec.dataset.id
        rec = try await rig.repo.addField(datasetID: d, name: "amount", valueShape: .number, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        let field = rec.fields[0].id
        rec = try await rig.repo.addRow(datasetID: d, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        let row = rec.rows[0].id
        rec = try await rig.repo.setCell(datasetID: d, rowID: row, fieldID: field, kind: .sourceValue, value: "100", status: .directlyObserved,
                                         expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        let cell = rec.cells[0].id
        _ = try await rig.repo.bindSource(cellID: cell, targetKind: .evidenceBlock, targetID: block.uuidString,
                                          sourceVersionID: sv, locator: SourceLocator(page: 1), expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        return (d, cell, block, sv)
    }

    // MARK: - Create / structure / identity / order

    @Test("Create → field → row → cell persists and fetches with a created event")
    func createAndFetch() async throws {
        let rig = try await rig()
        var rec = try await rig.repo.createDataset(workspaceID: rig.ws, title: "T", mode: .simple, actor: "u", at: t0)
        #expect(rec.dataset.mode == .simple)
        #expect(rec.events.first?.action == .created)
        rec = try await rig.repo.addField(datasetID: rec.dataset.id, name: "amount", valueShape: .money, expectedRevision: 1, actor: "u", at: t0)
        rec = try await rig.repo.addRow(datasetID: rec.dataset.id, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        rec = try await rig.repo.setCell(datasetID: rec.dataset.id, rowID: rec.rows[0].id, fieldID: rec.fields[0].id,
                                         kind: .userEntered, value: "42", status: .humanConfirmed, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        #expect(rec.fields[0].valueShape == .money)
        #expect(rec.cells[0].kind == .userEntered)
        #expect(rec.cells[0].value == "42")
        #expect(rec.cells[0].status == .humanConfirmed)
    }

    @Test("Blank title / actor / unknown workspace are rejected")
    func createValidation() async throws {
        let rig = try await rig()
        await #expect(throws: WorkbenchError.self) { _ = try await rig.repo.createDataset(workspaceID: rig.ws, title: "  ", mode: .simple, actor: "u", at: t0) }
        await #expect(throws: WorkbenchError.self) { _ = try await rig.repo.createDataset(workspaceID: rig.ws, title: "T", mode: .simple, actor: " ", at: t0) }
        await #expect(throws: WorkbenchError.self) { _ = try await rig.repo.createDataset(workspaceID: UUID(), title: "T", mode: .simple, actor: "u", at: t0) }
    }

    @Test("Row and field identities are stable and order is deterministic across later edits")
    func stableIdentityAndOrder() async throws {
        let rig = try await rig()
        var rec = try await rig.repo.createDataset(workspaceID: rig.ws, title: "T", mode: .advanced, actor: "u", at: t0)
        let d = rec.dataset.id
        rec = try await rig.repo.addRow(datasetID: d, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        let firstRow = rec.rows[0].id
        rec = try await rig.repo.addField(datasetID: d, name: "a", valueShape: .text, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        rec = try await rig.repo.addRow(datasetID: d, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        rec = try await rig.repo.addField(datasetID: d, name: "b", valueShape: .text, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        #expect(rec.rows.first?.id == firstRow)                 // stable id
        #expect(rec.rows.map(\.ordinal) == [0, 1])              // deterministic order
        #expect(rec.fields.map(\.name) == ["a", "b"])
    }

    // MARK: - Revision CAS + rollback + ownership

    @Test("A stale expected revision is a CAS conflict")
    func revisionCAS() async throws {
        let rig = try await rig()
        let rec = try await rig.repo.createDataset(workspaceID: rig.ws, title: "T", mode: .advanced, actor: "u", at: t0)
        await #expect(throws: WorkbenchError.self) {
            _ = try await rig.repo.addField(datasetID: rec.dataset.id, name: "x", valueShape: .text, expectedRevision: 99, actor: "u", at: t0)
        }
    }

    @Test("A binding to a nonexistent target rolls back atomically (revision unchanged, no binding)")
    func atomicRollback() async throws {
        let rig = try await rig()
        var rec = try await rig.repo.createDataset(workspaceID: rig.ws, title: "T", mode: .advanced, actor: "u", at: t0)
        let d = rec.dataset.id
        rec = try await rig.repo.addField(datasetID: d, name: "a", valueShape: .text, expectedRevision: 1, actor: "u", at: t0)
        rec = try await rig.repo.addRow(datasetID: d, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        rec = try await rig.repo.setCell(datasetID: d, rowID: rec.rows[0].id, fieldID: rec.fields[0].id, kind: .sourceValue,
                                         value: "v", status: .sourceAsserted, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        let revBefore = rec.dataset.revision
        await #expect(throws: WorkbenchError.self) {
            _ = try await rig.repo.bindSource(cellID: rec.cells[0].id, targetKind: .evidenceBlock, targetID: UUID().uuidString,
                                              sourceVersionID: nil, locator: nil, expectedRevision: revBefore, actor: "u", at: self.t0)
        }
        let after = try #require(try await rig.repo.fetch(datasetID: d))
        #expect(after.dataset.revision == revBefore)
        #expect(after.bindings.isEmpty)
    }

    @Test("Cross-dataset row/field ownership is rejected")
    func ownershipRejection() async throws {
        let rig = try await rig()
        let a = try await rig.repo.createDataset(workspaceID: rig.ws, title: "A", mode: .advanced, actor: "u", at: t0)
        var b = try await rig.repo.createDataset(workspaceID: rig.ws, title: "B", mode: .advanced, actor: "u", at: t0)
        b = try await rig.repo.addField(datasetID: b.dataset.id, name: "a", valueShape: .text, expectedRevision: 1, actor: "u", at: t0)
        let aRow = try await rig.repo.addRow(datasetID: a.dataset.id, expectedRevision: 1, actor: "u", at: t0).rows[0].id
        await #expect(throws: WorkbenchError.self) {
            _ = try await rig.repo.setCell(datasetID: b.dataset.id, rowID: aRow, fieldID: b.fields[0].id, kind: .userEntered,
                                           value: "x", status: .humanConfirmed, expectedRevision: b.dataset.revision, actor: "u", at: self.t0)
        }
    }

    // MARK: - Gate 4: drill-through

    @Test("A source cell binds to its exact canonical evidence block and drills through")
    func drillThrough() async throws {
        let rig = try await rig()
        let b = try await boundDataset(rig)
        let rec = try #require(try await rig.repo.fetch(datasetID: b.dataset))
        let binding = try #require(rec.bindings(forCell: b.cell).first)
        #expect(binding.targetKind == .evidenceBlock)
        #expect(binding.targetUUID == b.block)
        #expect(binding.sourceVersionID == b.sv)
        #expect(binding.locator?.page == 1)
        #expect(rec.isFullyProvenanced)
    }

    @Test("A binding whose SourceVersion does not match the evidence block is rejected")
    func sourceVersionMismatch() async throws {
        let rig = try await rig()
        let sv = try await seedSourceVersion(rig.db, logical: UUID())
        let otherSV = try await seedSourceVersion(rig.db, logical: UUID())
        let block = try await seedBlock(rig.db, sourceVersion: sv)
        var rec = try await rig.repo.createDataset(workspaceID: rig.ws, title: "T", mode: .advanced, actor: "u", at: t0)
        let d = rec.dataset.id
        rec = try await rig.repo.addField(datasetID: d, name: "a", valueShape: .text, expectedRevision: 1, actor: "u", at: t0)
        rec = try await rig.repo.addRow(datasetID: d, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        rec = try await rig.repo.setCell(datasetID: d, rowID: rec.rows[0].id, fieldID: rec.fields[0].id, kind: .sourceValue,
                                         value: "v", status: .directlyObserved, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        await #expect(throws: WorkbenchError.self) {
            _ = try await rig.repo.bindSource(cellID: rec.cells[0].id, targetKind: .evidenceBlock, targetID: block.uuidString,
                                              sourceVersionID: otherSV, locator: nil, expectedRevision: rec.dataset.revision, actor: "u", at: self.t0)
        }
    }

    // MARK: - Gate 5: SensitiveScope propagation

    @Test("A restricted bound source restricts the dataset under a lower-scope access")
    func sensitiveScopePropagation() async throws {
        let rig = try await rig()
        let b = try await boundDataset(rig)
        let sensitivity = WorkbenchSensitivity(datasets: rig.repo, scopes: rig.scopes)
        // A permissive scope permits everything.
        let permissive = SensitiveScope(workspaceID: rig.ws, maximumSensitivity: .restricted, permitsPrivilegedMaterial: true, purpose: .retrieval)
        #expect(try await sensitivity.isPermitted(datasetID: b.dataset, under: permissive))
        // Restrict the bound source; a lower-scope access must be refused.
        _ = try await rig.scopes.assign(target: SensitiveScopeTarget(kind: .sourceVersion, id: b.sv),
                                        sensitivity: .restricted,
                                        authority: .userConfirmed(actorID: "officer", confirmationID: UUID(), privileged: false),
                                        reason: "restricted source", at: t0)
        let limited = SensitiveScope(workspaceID: rig.ws, maximumSensitivity: .internalLevel, permitsPrivilegedMaterial: false, purpose: .retrieval)
        #expect(try await sensitivity.isPermitted(datasetID: b.dataset, under: limited) == false)
    }

    // MARK: - Gate 6: stale-source detection

    @Test("Stale-source detection flags a superseded SourceVersion without erasing the dataset")
    func staleSourceDetection() async throws {
        let rig = try await rig()
        let logical = UUID()
        let oldSV = try await seedSourceVersion(rig.db, logical: logical, current: false, at: 100)
        let block = try await seedBlock(rig.db, sourceVersion: oldSV)
        var rec = try await rig.repo.createDataset(workspaceID: rig.ws, title: "T", mode: .advanced, actor: "u", at: t0)
        let d = rec.dataset.id
        rec = try await rig.repo.addField(datasetID: d, name: "a", valueShape: .text, expectedRevision: 1, actor: "u", at: t0)
        rec = try await rig.repo.addRow(datasetID: d, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        rec = try await rig.repo.setCell(datasetID: d, rowID: rec.rows[0].id, fieldID: rec.fields[0].id, kind: .sourceValue,
                                         value: "v", status: .directlyObserved, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        rec = try await rig.repo.bindSource(cellID: rec.cells[0].id, targetKind: .evidenceBlock, targetID: block.uuidString,
                                            sourceVersionID: oldSV, locator: nil, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        // Not yet stale (oldSV is the only version and is current-for-its-logical? it was seeded current:false with no current) —
        // introduce a NEWER current version of the same logical source.
        _ = try await seedSourceVersion(rig.db, logical: logical, current: true, at: 200)
        let stale = try await rig.repo.staleBindings(datasetID: d)
        #expect(stale.count == 1)
        #expect(stale.first?.sourceVersionID == oldSV)
        // The dataset itself is untouched.
        #expect(try await rig.repo.fetch(datasetID: d)?.bindings.count == 1)
    }

    // MARK: - Gate 7: close/reopen fidelity

    @Test("A dataset reconstructs identically from a fresh repository over the same store")
    func closeReopenFidelity() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wbds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("db.sqlite")
        let db1 = try Database(url: url); try await SchemaMigrations.migrate(db1); try await db1.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID()
        try await db1.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                           [.uuid(ws), .text("WS"), .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
        let sv = try await seedSourceVersion(db1, logical: UUID())
        let block = try await seedBlock(db1, sourceVersion: sv)
        let repo1 = WorkbenchDatasetRepository(database: db1)
        var rec = try await repo1.createDataset(workspaceID: ws, title: "Case data", mode: .advanced, actor: "u", at: t0)
        let d = rec.dataset.id
        rec = try await repo1.addField(datasetID: d, name: "amount", valueShape: .number, expectedRevision: 1, actor: "u", at: t0)
        rec = try await repo1.addRow(datasetID: d, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        rec = try await repo1.setCell(datasetID: d, rowID: rec.rows[0].id, fieldID: rec.fields[0].id, kind: .sourceValue,
                                      value: "500", status: .directlyObserved, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        rec = try await repo1.bindSource(cellID: rec.cells[0].id, targetKind: .evidenceBlock, targetID: block.uuidString,
                                         sourceVersionID: sv, locator: SourceLocator(page: 3), expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        rec = try await repo1.saveView(datasetID: d, name: "By month", projectionJSON: "{\"group\":\"month\"}", expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        let before = rec

        let db2 = try Database(url: url); try await SchemaMigrations.migrate(db2)
        let reopened = try #require(try await WorkbenchDatasetRepository(database: db2).fetch(datasetID: d))
        #expect(reopened.dataset == before.dataset)
        #expect(reopened.fields == before.fields)
        #expect(reopened.rows == before.rows)
        #expect(reopened.cells == before.cells)
        #expect(reopened.bindings == before.bindings)
        #expect(reopened.savedViews == before.savedViews)
        #expect(reopened.events.map(\.sequence) == Array(1...reopened.events.count))
        #expect(reopened.isFullyProvenanced)
    }

    // MARK: - Gate 8: legacy conversion

    @Test("A legacy EvidenceDataset converts into the canonical form, delegating into Workbench*")
    func legacyConversion() async throws {
        let rig = try await rig()
        let sv = try await seedSourceVersion(rig.db, logical: UUID())
        let block = try await seedBlock(rig.db, sourceVersion: sv)
        let column = DatasetColumn(name: "amount", shape: .number)
        let cell = DatasetCell(value: "100", sourceBlockIDs: [block], status: .directlyObserved)
        let derived = DatasetCell(value: "200", sourceBlockIDs: [], status: .deterministicallyDerived)
        let legacy = EvidenceDataset(name: "legacy payments", columns: [column, DatasetColumn(name: "net", shape: .number)],
                                     rows: [DatasetRow(cells: [cell, derived])])
        let rec = try await rig.repo.convertLegacy(legacy, workspaceID: rig.ws, actor: "u", at: t0)
        #expect(rec.dataset.title == "legacy payments")
        #expect(rec.fields.count == 2)
        #expect(rec.cells.count == 2)
        #expect(rec.cells.contains { $0.kind == .sourceValue && $0.value == "100" })
        #expect(rec.cells.contains { $0.kind == .deterministicCalculation && $0.value == "200" })
        #expect(rec.bindings.contains { $0.targetUUID == block })          // source cell drilled through
        #expect(rec.events.contains { $0.action == .converted })
    }

    @Test("Legacy status maps deterministically to the canonical cell kind")
    func legacyKindMapping() {
        #expect(WorkbenchLegacyConversion.cellKind(for: .directlyObserved) == .sourceValue)
        #expect(WorkbenchLegacyConversion.cellKind(for: .sourceAsserted) == .sourceValue)
        #expect(WorkbenchLegacyConversion.cellKind(for: .deterministicallyDerived) == .deterministicCalculation)
        #expect(WorkbenchLegacyConversion.cellKind(for: .inferred) == .modelProposal)
        #expect(WorkbenchLegacyConversion.cellKind(for: .humanCorrected) == .userCorrected)
        #expect(WorkbenchLegacyConversion.cellKind(for: .humanConfirmed) == .reviewed)
        #expect(WorkbenchLegacyConversion.cellKind(for: .humanRejected) == .reviewed)
    }

    // MARK: - Event history

    @Test("Dataset events form a contiguous per-dataset sequence")
    func eventHistory() async throws {
        let rig = try await rig()
        var rec = try await rig.repo.createDataset(workspaceID: rig.ws, title: "T", mode: .advanced, actor: "u", at: t0)
        rec = try await rig.repo.addField(datasetID: rec.dataset.id, name: "a", valueShape: .text, expectedRevision: 1, actor: "u", at: t0)
        rec = try await rig.repo.addRow(datasetID: rec.dataset.id, expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        rec = try await rig.repo.saveView(datasetID: rec.dataset.id, name: "v", projectionJSON: "{}", expectedRevision: rec.dataset.revision, actor: "u", at: t0)
        #expect(rec.events.map(\.sequence) == Array(1...rec.events.count))
        #expect(rec.events.map(\.action) == [.created, .fieldAdded, .rowAdded, .viewSaved])
    }
}
