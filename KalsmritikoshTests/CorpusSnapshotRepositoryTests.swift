//
//  CorpusSnapshotRepositoryTests.swift
//  KalsmritikoshTests
//
//  EV-004 — migration v58 (ALTER corpus_snapshots + snapshot_sources) applies on a fresh
//  DB, and a snapshot round-trips WITH its processing versions and pinned source versions
//  so an old output can replay its exact scope.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("CorpusSnapshot EV-004 (v58)")
struct CorpusSnapshotRepositoryTests {

    private func freshDB() async throws -> Database {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("snap-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        return db
    }

    @Test("Migration reaches v58 (ALTER + snapshot_sources) on a fresh DB")
    func migration() async throws {
        let db = try await freshDB()
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
    }

    @Test("Snapshot round-trips with processing versions and pinned sources")
    func roundTrip() async throws {
        let repo = CorpusSnapshotRepository(database: try await freshDB())
        let sv1 = UUID(), sv2 = UUID()
        let snap = CorpusSnapshot(
            schemaVersion: 58, fileCount: 10, parsedCount: 9, indexedCount: 8,
            ledgeredCount: 7, failedCount: 1,
            scope: "matter-42", embeddingModel: "bge-small-v1",
            retrievalConfigVersion: "ret-3", personaPolicyVersion: "persona-2",
            parserVersions: ["pdf": "1.4", "email": "2.0"],
            sources: [SnapshotSource(sourceVersionID: sv1, contentHash: "h1"),
                      SnapshotSource(sourceVersionID: sv2, contentHash: nil)],
            readiness: 0.8)
        try await repo.insert(snap)

        let got = try #require(try await repo.snapshot(id: snap.id))
        #expect(got.scope == "matter-42")
        #expect(got.embeddingModel == "bge-small-v1")
        #expect(got.parserVersions["pdf"] == "1.4")
        #expect(got.readiness == 0.8)
        #expect(Set(got.sources.map(\.sourceVersionID)) == [sv1, sv2])
        #expect(got.sources.first(where: { $0.sourceVersionID == sv1 })?.contentHash == "h1")
    }

    @Test("The v28 census insert path still works after the ALTER")
    func censusStillWorks() async throws {
        let repo = CorpusSnapshotRepository(database: try await freshDB())
        try await repo.insert(CorpusSnapshot(
            schemaVersion: 58, fileCount: 3, parsedCount: 3, indexedCount: 3,
            ledgeredCount: 3, failedCount: 0))
        let latest = try #require(try await repo.latest())
        #expect(latest.fileCount == 3)
        #expect(try await repo.count() == 1)
    }
}
