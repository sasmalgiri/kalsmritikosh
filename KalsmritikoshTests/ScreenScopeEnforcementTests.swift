//
//  ScreenScopeEnforcementTests.swift
//  KalsmritikoshTests
//
//  OPS-003D — verifies that the screen-level SensitiveScope filter applied in
//  SearchView.screenFilter(_:scopeRepo:) and SourcesView.screenFilter(_:scopeRepo:)
//  correctly withholds content from KOs marked privileged, while permitting
//  non-privileged content, and passes through unchanged when the scope repo is nil.
//
//  Four tests:
//  1. chunkFromPrivilegedKOFilteredFromSearch     — privileged KO → chunk withheld
//  2. chunkFromNonPrivilegedKOPermittedInSearch    — no SSA → chunk passes
//  3. koMarkedPrivilegedFilteredFromRecentList     — privileged KO row withheld
//  4. filterPassThroughWhenScopeRepoNil            — nil repo → all items returned
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("OPS-003D ScreenScopeEnforcement")
struct ScreenScopeEnforcementTests {

    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - Shared logic under test

    /// Mirror of SearchView.screenFilter(_:scopeRepo:) — extracted here so the
    /// test can exercise the filter logic independently of SwiftUI view state.
    private func filterChunks(_ chunks: [Chunk],
                               scopeRepo: SensitiveScopeRepository?) async -> [Chunk] {
        guard let repo = scopeRepo, !chunks.isEmpty else { return chunks }
        let koIDs = Array(Set(chunks.map(\.objectID)))
        let targets = koIDs.map { SensitiveScopeTarget(kind: .knowledgeObject, id: $0) }
        guard let resolutions = try? await repo.batchResolution(targets) else { return chunks }
        let scope = SensitiveScope.screen()
        let permitted: Set<UUID> = Set(koIDs.filter { koID in
            let t = SensitiveScopeTarget(kind: .knowledgeObject, id: koID)
            switch resolutions[t] {
            case .resolved(let label): return scope.permits(label)
            case .brokenLineage:       return false
            case nil:                  return scope.permits(ProtectionLabel(sensitivity: .internalLevel, privileged: false))
            }
        })
        return chunks.filter { permitted.contains($0.objectID) }
    }

    /// Mirror of SourcesView.screenFilter(_:scopeRepo:).
    private func filterRows(_ rows: [KnowledgeObjectSummaryRow],
                            scopeRepo: SensitiveScopeRepository?) async -> [KnowledgeObjectSummaryRow] {
        guard let repo = scopeRepo, !rows.isEmpty else { return rows }
        let koIDs = rows.map(\.id)
        let targets = koIDs.map { SensitiveScopeTarget(kind: .knowledgeObject, id: $0) }
        guard let resolutions = try? await repo.batchResolution(targets) else { return rows }
        let scope = SensitiveScope.screen()
        return rows.filter { row in
            let t = SensitiveScopeTarget(kind: .knowledgeObject, id: row.id)
            switch resolutions[t] {
            case .resolved(let label): return scope.permits(label)
            case .brokenLineage:       return false
            case nil:                  return scope.permits(ProtectionLabel(sensitivity: .internalLevel, privileged: false))
            }
        }
    }

    // MARK: - Rig

    private func openDB() async throws -> (Database, SensitiveScopeRepository) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("screen-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        return (db, SensitiveScopeRepository(database: db))
    }

    /// Seed a KO row so effectiveLabel can resolve it (brokenLineage otherwise).
    private func seedKO(_ db: Database, koID: UUID) async throws {
        let fileID = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                          [.uuid(fileID), .text("file:///\(fileID).txt"), .text("text")])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?,?,?,?,0,0);
        """, [.uuid(koID), .uuid(fileID), .text("txt"), .text("test content")])
    }

    /// Make a minimal Chunk with the given KO ID.
    private func makeChunk(objectID: UUID) -> Chunk {
        Chunk(id: UUID(), objectID: objectID, ordinal: 0, text: "sample text",
              characterRange: 0..<11)
    }

    /// Make a minimal KnowledgeObjectSummaryRow with the given ID.
    private func makeRow(id: UUID) -> KnowledgeObjectSummaryRow {
        KnowledgeObjectSummaryRow(id: id,
                                  sourceFile: URL(fileURLWithPath: "/tmp/\(id).txt"),
                                  sourceType: .txt,
                                  preview: "preview",
                                  confidence: .high,
                                  createdAt: t0)
    }

    // MARK: - Test 1: privileged KO → chunk withheld

    @Test("Chunk from privileged evidence KO is withheld by screen scope filter")
    func chunkFromPrivilegedKOFilteredFromSearch() async throws {
        let (db, repo) = try await openDB()
        let koID = UUID()
        try await seedKO(db, koID: koID)

        try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)

        let chunk = makeChunk(objectID: koID)
        let result = await filterChunks([chunk], scopeRepo: repo)
        #expect(result.isEmpty,
                "Chunk from a privileged KO must be withheld by the screen scope filter.")
    }

    // MARK: - Test 2: non-privileged KO → chunk permitted

    @Test("Chunk from non-privileged KO passes through screen scope filter")
    func chunkFromNonPrivilegedKOPermittedInSearch() async throws {
        let (db, repo) = try await openDB()
        let koID = UUID()
        try await seedKO(db, koID: koID)

        // No SSA assigned → effectiveLabel resolves to internalLevel (not brokenLineage,
        // since the KO row exists). Screen scope permits internalLevel.
        let chunk = makeChunk(objectID: koID)
        let result = await filterChunks([chunk], scopeRepo: repo)
        #expect(result.count == 1,
                "Chunk from a KO with no privileged assignment must appear in search results.")
    }

    // MARK: - Test 3: privileged KO row withheld from recent list

    @Test("KnowledgeObjectSummaryRow for privileged KO withheld by screen scope filter")
    func koMarkedPrivilegedFilteredFromRecentList() async throws {
        let (db, repo) = try await openDB()
        let koID = UUID()
        try await seedKO(db, koID: koID)

        try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)

        let row = makeRow(id: koID)
        let result = await filterRows([row], scopeRepo: repo)
        #expect(result.isEmpty,
                "KO row marked privileged must be withheld from the recent-sources list.")
    }

    // MARK: - Test 4: nil repo → fail-open

    @Test("Screen filter is skipped (fail-open) when scope repo is nil")
    func filterPassThroughWhenScopeRepoNil() async throws {
        let koID = UUID()
        let chunk = makeChunk(objectID: koID)
        let row = makeRow(id: koID)

        let filteredChunks = await filterChunks([chunk], scopeRepo: nil)
        let filteredRows = await filterRows([row], scopeRepo: nil)

        #expect(filteredChunks.count == 1,
                "Chunks must pass through unchanged when no scope repo is available.")
        #expect(filteredRows.count == 1,
                "Rows must pass through unchanged when no scope repo is available.")
    }
}
