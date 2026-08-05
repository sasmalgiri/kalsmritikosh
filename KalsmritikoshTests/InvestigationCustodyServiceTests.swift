//
//  InvestigationCustodyServiceTests.swift
//  KalsmritikoshTests
//
//  INV-18 — Evidence vault & custody. Proves the case custody manifest REUSES the shared append-only
//  CustodyRepository + the EvidenceStore per-version content hashes, bounded to the case's authorized source
//  versions: the manifest carries the exact custody hash per version and the file's custody chain; only
//  authorized versions appear; recording a custody entry is a case-scoped human decision that APPENDS to the
//  shared ledger (never overwrites — custody is never broken silently); an unauthorized version is refused;
//  and the manifest reopens. Plus the architecture boundary. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("INV-18 — evidence vault & custody", .serialized)
struct InvestigationCustodyServiceTests {

    private let t0 = Date(timeIntervalSince1970: 1_768_000_000)

    private struct Rig {
        let db: Database
        let custody: CustodyRepository
        let service: InvestigationCustodyService
        let caseID: UUID
        let vA: UUID, logicalA: UUID
        let vB: UUID
    }

    private func rig() async throws -> Rig {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);", [.uuid(ws), .text("Matter"), .real(1), .real(1)])
        let (vA, logicalA) = try await seedSourceVersion(db, hash: String(repeating: "a", count: 64))
        let (vB, _) = try await seedSourceVersion(db, hash: String(repeating: "b", count: 64))
        let cases = InvestigationCaseRepository(database: db)
        let evidence = EvidenceStore(database: db)
        let custody = CustodyRepository(database: db)
        var c = try await cases.createCase(workspaceID: ws, title: "Payment discrepancy", actor: "analyst", at: t0)
        c = try await cases.includeSource(caseID: c.id, expectedRevision: c.revision, sourceRef: vA.uuidString, sourceKind: .sourceVersion, actor: "analyst", at: t0)
        let service = InvestigationCustodyService(cases: cases, resolver: CaseRetrievalScopeResolver(evidence: evidence),
                                                  evidence: evidence, custody: custody, database: db)
        return Rig(db: db, custody: custody, service: service, caseID: c.id, vA: vA, logicalA: logicalA, vB: vB)
    }

    @Test("The manifest lists only authorized versions, each with its exact content hash and the file's custody chain")
    func manifestScopedWithHashAndChain() async throws {
        let rig = try await rig()
        // Seed a custody event on the authorized file through the SHARED repository.
        _ = try await rig.custody.record(CustodyEvent(fileID: rig.logicalA, kind: .acquired, actor: "system", at: t0))
        let manifest = try await rig.service.manifest(caseID: rig.caseID)
        #expect(manifest.map(\.sourceVersionID) == [rig.vA])                 // only the authorized version
        #expect(manifest.first?.contentHash == String(repeating: "a", count: 64))
        #expect(manifest.first?.custodyEvents.contains { $0.kind == .acquired } == true)
    }

    @Test("Recording a custody entry appends to the shared ledger (never overwrites); an unauthorized version is refused")
    func recordAppendsAndScopeEnforced() async throws {
        let rig = try await rig()
        _ = try await rig.service.recordCustodyEvent(caseID: rig.caseID, sourceVersionID: rig.vA, kind: .hashVerified, detail: "re-ingest", hash: String(repeating: "a", count: 64), actor: "lead", at: t0)
        _ = try await rig.service.recordCustodyEvent(caseID: rig.caseID, sourceVersionID: rig.vA, kind: .disclosed, detail: "to counsel", hash: nil, actor: "lead", at: t0)
        // Append-only: two distinct events on the file, nothing overwritten.
        #expect(try await rig.custody.history(forFile: rig.logicalA).count == 2)
        // An unauthorized source version cannot receive a custody entry in this case.
        await #expect(throws: InvestigationCustodyError.self) {
            _ = try await rig.service.recordCustodyEvent(caseID: rig.caseID, sourceVersionID: rig.vB, kind: .exported, detail: nil, hash: nil, actor: "lead", at: t0)
        }
    }

    @Test("The custody manifest reopens through a fresh service over the same database")
    func manifestReopens() async throws {
        let rig = try await rig()
        _ = try await rig.service.recordCustodyEvent(caseID: rig.caseID, sourceVersionID: rig.vA, kind: .acquired, detail: nil, hash: nil, actor: "lead", at: t0)
        let reopened = InvestigationCustodyService(cases: InvestigationCaseRepository(database: rig.db),
                                                   resolver: CaseRetrievalScopeResolver(evidence: EvidenceStore(database: rig.db)),
                                                   evidence: EvidenceStore(database: rig.db), custody: CustodyRepository(database: rig.db), database: rig.db)
        let manifest = try await reopened.manifest(caseID: rig.caseID)
        #expect(manifest.first?.custodyEvents.isEmpty == false)
        #expect(manifest.first?.contentHash == String(repeating: "a", count: 64))
    }

    @Test("The custody service reuses the shared CustodyRepository, forks no custody table, and names no models; AppState wires it")
    func boundary() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Kalsmritikosh/Personas/Investigator/InvestigationCustodyService.swift")
        let src = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        #expect(!src.isEmpty)
        for banned in ["CREATE TABLE", "INSERT INTO custody", "DELETE FROM custody"] {
            #expect(!src.contains(banned), "custody service forks/mutates the shared ledger: \(banned)")
        }
        #expect(src.contains("CustodyRepository"))
        let lower = src.lowercased()
        for m in ["qwen", "gemma", "deepseek", "mistral", "nomic", "llama", "gpt"] { #expect(!lower.contains(m)) }
        let app = (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Kalsmritikosh/App/AppState.swift"), encoding: .utf8)) ?? ""
        #expect(app.contains("InvestigationCustodyService(") && app.contains("investigationCustody"))
    }

    // MARK: - Seed helpers

    private func seedSourceVersion(_ db: Database, hash: String) async throws -> (version: UUID, logical: UUID) {
        let version = UUID(), logical = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                          [.uuid(logical), .text("file:///x/\(logical.uuidString)"), .text("txt"), .text("available")])
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(version), .uuid(logical), .text(hash), .real(100), .integer(1), .real(100),
                  .text("f.txt"), .text("txt"), .text("magicBytes"), .integer(1), .text("referenced"), .text("referenceRecorded"), .real(100)])
        return (version, logical)
    }
}
