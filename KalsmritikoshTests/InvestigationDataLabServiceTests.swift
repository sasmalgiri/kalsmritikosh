//
//  InvestigationDataLabServiceTests.swift
//  KalsmritikoshTests
//
//  INV-01-C3 — Investigator DataLab presets over the shared Workbench. Proves the preset catalog is
//  well-formed (shared Workbench value shapes; no Investigator dataset type); that Source Inventory
//  preparation includes ONLY case-authorized sources with exact `.sourceVersion` drill-through lineage;
//  that an unauthorized workspace source never enters the dataset (no workspace fallback); that a case
//  with no in-scope sources yields an empty-but-valid dataset; that two cases in one workspace stay
//  disjoint; and that the dataset persists + reopens through the shared repository. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("INV-01-C3 — Investigator DataLab presets + authorized-only datasets", .serialized)
struct InvestigationDataLabServiceTests {

    private let t0 = Date(timeIntervalSince1970: 1_766_500_000)

    private struct Rig {
        let db: Database
        let cases: InvestigationCaseRepository
        let datasets: WorkbenchDatasetRepository
        let service: InvestigationDataLabService
        let ws: UUID
    }

    private func rig() async throws -> Rig {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(ws), .text("Matter"), .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
        let cases = InvestigationCaseRepository(database: db)
        let datasets = WorkbenchDatasetRepository(database: db)
        let service = InvestigationDataLabService(cases: cases, resolver: CaseRetrievalScopeResolver(evidence: EvidenceStore(database: db)),
                                                  datasets: datasets, scopes: SensitiveScopeRepository(database: db))
        return Rig(db: db, cases: cases, datasets: datasets, service: service, ws: ws)
    }

    /// Seed a real source version (files + source_versions) so a `.sourceVersion` binding validates.
    @discardableResult
    private func seedSourceVersion(_ db: Database, id: UUID) async throws -> UUID {
        let logical = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                          [.uuid(logical), .text("file:///x/\(logical.uuidString)"), .text("txt"), .text("available")])
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(logical), .text(String(repeating: "a", count: 64)), .real(100), .integer(1), .real(100),
                  .text("f.txt"), .text("txt"), .text("magicBytes"), .integer(1), .text("referenced"), .text("referenceRecorded"), .real(100)])
        return id
    }

    private func makeCase(_ rig: Rig, authorizing versions: [UUID]) async throws -> UUID {
        var c = try await rig.cases.createCase(workspaceID: rig.ws, title: "Payment discrepancy", actor: "analyst", at: t0)
        for v in versions {
            c = try await rig.cases.includeSource(caseID: c.id, expectedRevision: c.revision,
                                                  sourceRef: v.uuidString, sourceKind: .sourceVersion, actor: "analyst", at: t0)
        }
        return c.id
    }

    // MARK: - Preset catalog

    @Test("The preset catalog is well-formed: nine presets, unique ids, shared value shapes, resolvable")
    func presetCatalog() async throws {
        let presets = InvestigationDataLabPresetCatalog.all
        #expect(presets.count == 9)
        #expect(Set(presets.map(\.id)).count == 9)
        for p in presets {
            #expect(!p.fields.isEmpty, "\(p.id) has no fields")
            #expect(p.id.hasPrefix("inv.datalab."))
            #expect(InvestigationDataLabPresetCatalog.preset(id: p.id) == p)
        }
        #expect(InvestigationDataLabPresetCatalog.sourceInventory.fieldNames.contains("sourceVersion"))
        #expect(InvestigationDataLabPresetCatalog.preset(id: "nope") == nil)
    }

    // MARK: - Authorized-only preparation

    @Test("Source Inventory includes only the case-authorized source; the unauthorized workspace source is absent")
    func authorizedOnlySourceInventory() async throws {
        let rig = try await rig()
        let vA = try await seedSourceVersion(rig.db, id: UUID())
        let vB = try await seedSourceVersion(rig.db, id: UUID())   // a real workspace source, NOT authorized
        let caseID = try await makeCase(rig, authorizing: [vA])
        let prepared = try await rig.service.prepareSourceInventory(caseID: caseID, access: .testUnrestricted(), actor: "analyst", at: t0)

        #expect(prepared.includedSourceVersionIDs == [vA])
        #expect(prepared.withheldBySensitivity == 0)
        let bindings = try await rig.datasets.bindings(datasetID: prepared.dataset.dataset.id)
        #expect(bindings.count == 1)
        #expect(bindings.first?.sourceVersionID == vA)
        #expect(bindings.first?.targetKind == .sourceVersion)
        #expect(!bindings.contains { $0.sourceVersionID == vB })   // B never enters the dataset
        #expect(try await rig.datasets.rows(datasetID: prepared.dataset.dataset.id).count == 1)
    }

    @Test("Exact drill-through lineage: the bound source version + target id resolve to the authorized source")
    func lineageExactness() async throws {
        let rig = try await rig()
        let vA = try await seedSourceVersion(rig.db, id: UUID())
        let caseID = try await makeCase(rig, authorizing: [vA])
        let prepared = try await rig.service.prepareSourceInventory(caseID: caseID, access: .testUnrestricted(), actor: "analyst", at: t0)
        let binding = try await rig.datasets.bindings(datasetID: prepared.dataset.dataset.id).first
        #expect(binding?.targetKind == .sourceVersion)
        #expect(binding?.targetID == vA.uuidString)
        #expect(binding?.sourceVersionID == vA)
    }

    @Test("A case with no in-scope sources yields an empty-but-valid dataset — never a workspace fallback")
    func emptyButValid() async throws {
        let rig = try await rig()
        _ = try await seedSourceVersion(rig.db, id: UUID())   // a workspace source exists…
        let caseID = try await makeCase(rig, authorizing: [])  // …but the case authorizes nothing
        let prepared = try await rig.service.prepareSourceInventory(caseID: caseID, access: .testUnrestricted(), actor: "analyst", at: t0)
        #expect(prepared.includedSourceVersionIDs.isEmpty)
        #expect(try await rig.datasets.rows(datasetID: prepared.dataset.dataset.id).isEmpty)
        #expect(try await rig.datasets.bindings(datasetID: prepared.dataset.dataset.id).isEmpty)
        #expect(!prepared.dataset.fields.isEmpty)   // a valid dataset: fields present, zero rows
    }

    @Test("Two cases in one workspace stay disjoint — each dataset sees only its own authorized source")
    func differentCasesDisjoint() async throws {
        let rig = try await rig()
        let vA = try await seedSourceVersion(rig.db, id: UUID())
        let vB = try await seedSourceVersion(rig.db, id: UUID())
        let case1 = try await makeCase(rig, authorizing: [vA])
        let case2 = try await makeCase(rig, authorizing: [vB])
        let p1 = try await rig.service.prepareSourceInventory(caseID: case1, access: .testUnrestricted(), actor: "u", at: t0)
        let p2 = try await rig.service.prepareSourceInventory(caseID: case2, access: .testUnrestricted(), actor: "u", at: t0)
        #expect(p1.includedSourceVersionIDs == [vA])
        #expect(p2.includedSourceVersionIDs == [vB])
    }

    @Test("The prepared dataset persists through the shared repo and reopens by id with the same binding")
    func persistsAndReopens() async throws {
        let rig = try await rig()
        let vA = try await seedSourceVersion(rig.db, id: UUID())
        let caseID = try await makeCase(rig, authorizing: [vA])
        let prepared = try await rig.service.prepareSourceInventory(caseID: caseID, access: .testUnrestricted(), actor: "u", at: t0)
        let datasetID = prepared.dataset.dataset.id
        // Reopen with a brand-new repository over the same database.
        let reopened = WorkbenchDatasetRepository(database: rig.db)
        #expect(try await reopened.dataset(id: datasetID)?.id == datasetID)
        #expect(try await reopened.bindings(datasetID: datasetID).first?.sourceVersionID == vA)
    }

    @Test("An unknown case fails closed")
    func unknownCaseFailsClosed() async throws {
        let rig = try await rig()
        await #expect(throws: InvestigationDataLabError.self) {
            _ = try await rig.service.prepareSourceInventory(caseID: UUID(), access: .testUnrestricted(), actor: "u", at: t0)
        }
    }
}
