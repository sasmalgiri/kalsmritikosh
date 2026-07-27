//
//  ScreenScopeEnforcementTests.swift
//  KalsmritikoshTests
//
//  OPS-003D.1 — verifies the production ScreenScopeAuthorizer (not mirrored view logic).
//  Ten tests covering filterChunks, filterRows, and authorize across nil-repo,
//  privileged-KO, unassigned-KO, and broken-lineage scenarios.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("OPS-003D.1 ScreenScopeEnforcement")
struct ScreenScopeEnforcementTests {

    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - Rig

    private func openDB() async throws -> (Database, SensitiveScopeRepository) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("screen-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        return (db, SensitiveScopeRepository(database: db))
    }

    /// Seed a KO row so effectiveLabel resolves to internalLevel (not brokenLineage).
    private func seedKO(_ db: Database, koID: UUID) async throws {
        let fileID = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                          [.uuid(fileID), .text("file:///\(fileID).txt"), .text("text")])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?,?,?,?,0,0);
        """, [.uuid(koID), .uuid(fileID), .text("txt"), .text("test content")])
    }

    private func makeChunk(objectID: UUID) -> Chunk {
        Chunk(id: UUID(), objectID: objectID, ordinal: 0, text: "sample text",
              characterRange: 0..<11)
    }

    private func makeRow(id: UUID) -> KnowledgeObjectSummaryRow {
        KnowledgeObjectSummaryRow(id: id,
                                  sourceFile: URL(fileURLWithPath: "/tmp/\(id).txt"),
                                  sourceType: .txt,
                                  preview: "preview",
                                  confidence: .high,
                                  createdAt: t0)
    }

    // MARK: - filterChunks tests

    @Test("filterChunks: nil repo returns empty (fail-closed, not fail-open)")
    func filterChunks_nilRepo_returnsEmpty() async throws {
        let auth = ScreenScopeAuthorizer(repository: nil)
        let koID = UUID()
        let result = await auth.filterChunks([makeChunk(objectID: koID)], boundary: .globalOwner)
        #expect(result.isEmpty,
                "Nil repository must return [] — never the original list (fail-closed, not fail-open).")
    }

    @Test("filterChunks: privileged KO is withheld")
    func filterChunks_privilegedKO_withheld() async throws {
        let (db, repo) = try await openDB()
        let koID = UUID()
        try await seedKO(db, koID: koID)
        try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)
        let auth = ScreenScopeAuthorizer(repository: repo)
        let result = await auth.filterChunks([makeChunk(objectID: koID)], boundary: .globalOwner)
        #expect(result.isEmpty,
                "Chunk from a privileged KO must be withheld by ScreenScopeAuthorizer.")
    }

    @Test("filterChunks: unassigned KO passes (internalLevel is within restricted ceiling)")
    func filterChunks_unassignedKO_permitted() async throws {
        let (db, repo) = try await openDB()
        let koID = UUID()
        try await seedKO(db, koID: koID)
        // No SSA → effectiveLabel resolves to internalLevel, which is within the .restricted ceiling.
        let auth = ScreenScopeAuthorizer(repository: repo)
        let result = await auth.filterChunks([makeChunk(objectID: koID)], boundary: .globalOwner)
        #expect(result.count == 1,
                "Chunk from an unassigned KO (internalLevel) must pass the screen scope filter.")
    }

    @Test("filterChunks: KO absent from knowledge_objects (brokenLineage) is withheld")
    func filterChunks_brokenLineage_withheld() async throws {
        let (_, repo) = try await openDB()
        let ghostKO = UUID()
        // Deliberately NOT seeded — batchResolution returns .brokenLineage.
        let auth = ScreenScopeAuthorizer(repository: repo)
        let result = await auth.filterChunks([makeChunk(objectID: ghostKO)], boundary: .globalOwner)
        #expect(result.isEmpty,
                "Chunk whose KO does not exist in knowledge_objects (brokenLineage) must be withheld.")
    }

    // MARK: - filterRows tests

    @Test("filterRows: nil repo returns empty (fail-closed)")
    func filterRows_nilRepo_returnsEmpty() async throws {
        let auth = ScreenScopeAuthorizer(repository: nil)
        let result = await auth.filterRows([makeRow(id: UUID())], boundary: .globalOwner)
        #expect(result.isEmpty,
                "Nil repository must return [] for filterRows — fail-closed, not fail-open.")
    }

    @Test("filterRows: privileged KO row is withheld")
    func filterRows_privilegedKO_withheld() async throws {
        let (db, repo) = try await openDB()
        let koID = UUID()
        try await seedKO(db, koID: koID)
        try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)
        let auth = ScreenScopeAuthorizer(repository: repo)
        let result = await auth.filterRows([makeRow(id: koID)], boundary: .globalOwner)
        #expect(result.isEmpty,
                "KnowledgeObjectSummaryRow for a privileged KO must be withheld.")
    }

    @Test("filterRows: unassigned KO row passes")
    func filterRows_unassignedKO_permitted() async throws {
        let (db, repo) = try await openDB()
        let koID = UUID()
        try await seedKO(db, koID: koID)
        let auth = ScreenScopeAuthorizer(repository: repo)
        let result = await auth.filterRows([makeRow(id: koID)], boundary: .globalOwner)
        #expect(result.count == 1,
                "KnowledgeObjectSummaryRow for an unassigned KO (internalLevel) must pass.")
    }

    // MARK: - authorize tests

    @Test("authorize: nil repo returns false (fail-closed)")
    func authorize_nilRepo_returnsFalse() async throws {
        let auth = ScreenScopeAuthorizer(repository: nil)
        let result = await auth.authorize(UUID(), boundary: .globalOwner)
        #expect(result == false,
                "Nil repository must return false for authorize — fail-closed.")
    }

    @Test("authorize: privileged KO returns false")
    func authorize_privilegedKO_returnsFalse() async throws {
        let (db, repo) = try await openDB()
        let koID = UUID()
        try await seedKO(db, koID: koID)
        try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)
        let auth = ScreenScopeAuthorizer(repository: repo)
        let result = await auth.authorize(koID, boundary: .globalOwner)
        #expect(result == false,
                "authorize must return false for a privileged KO (permitsPrivilegedMaterial is false).")
    }

    @Test("authorize: unassigned seeded KO returns true")
    func authorize_unassignedKO_returnsTrue() async throws {
        let (db, repo) = try await openDB()
        let koID = UUID()
        try await seedKO(db, koID: koID)
        let auth = ScreenScopeAuthorizer(repository: repo)
        let result = await auth.authorize(koID, boundary: .globalOwner)
        #expect(result == true,
                "authorize must return true for an unassigned KO (resolves to internalLevel, within .restricted ceiling).")
    }
}
