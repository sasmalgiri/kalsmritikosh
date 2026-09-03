//
//  EntityRegisterRefreshTests.swift
//  KalsmritikoshTests
//
//  GO2R U0-b (part 2) — the targeted register refresh, proven on a real
//  ledger before it ever touches the live one: dirty v1 person values
//  (the owner's witnessed strings) come out clean or merged, everything
//  stamps v2, NOTHING is deleted, and a second run scans zero.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("U0-b — entity register refresh (clean, merge, stamp, never delete)", .serialized)
@MainActor
struct EntityRegisterRefreshTests {

    private func makeDB() async throws -> (Database, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("regrefresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        return (db, dir)
    }

    private func insertRaw(_ db: Database, kind: String, value: String,
                           sourceObjectID: UUID, producerVersion: Int?) async throws -> UUID {
        let id = UUID()
        try await db.exec("""
        INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence, producer_version)
        VALUES (?, ?, ?, ?, ?, 0.9, ?);
        """, [.uuid(id), .text(kind), .text(value), .text(value.lowercased()),
              .uuid(sourceObjectID),
              producerVersion.map { .integer(Int64($0)) } ?? .null])
        return id
    }

    @Test("Dirty values clean in place; collisions soft-merge; all stamp v2; nothing deleted")
    func refreshCleansMergesStamps() async throws {
        let (db, dir) = try await makeDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = EntitiesRepository(database: db)
        let src = UUID(); let fileID = UUID()
        try await db.exec("""
        INSERT INTO files (id, url, source_type) VALUES (?, '/tmp/mail.eml', 'eml');
        """, [.uuid(fileID)])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?, ?, 'eml', 'seed', 0, 0);
        """, [.uuid(src), .uuid(fileID)])

        // The owner's witnessed strings, aged to v1 (below the current era).
        let dirtyLone   = try await insertRaw(db, kind: "person", value: ", Bill Delhi", sourceObjectID: src, producerVersion: 1)
        let dirtyQuoted = try await insertRaw(db, kind: "person", value: "'Arindam Das'", sourceObjectID: src, producerVersion: 1)
        // Collision pair: the clean canonical already exists.
        let cleanAkhil  = try await insertRaw(db, kind: "person", value: "Akhilesh Sharma", sourceObjectID: src, producerVersion: 1)
        let dirtyAkhil  = try await insertRaw(db, kind: "person", value: ", Akhilesh Sharma", sourceObjectID: src, producerVersion: 1)
        // Innocence: already-clean value just advances era.
        let vadhwa      = try await insertRaw(db, kind: "person", value: "Guruditsingh Vadhwa", sourceObjectID: src, producerVersion: 1)
        // Non-rewritable kind: stamp only, value untouched.
        let anchor      = try await insertRaw(db, kind: "identifier", value: "patentnumber|555489", sourceObjectID: src, producerVersion: 1)

        let refresh = EntityRegisterRefresh(database: db, entities: repo)
        let receipt = try await refresh.run()
        print(receipt.renderLines())

        #expect(receipt.scanned == 6)
        #expect(receipt.cleanedInPlace == 2, "Bill Delhi + Arindam Das clean in place")
        #expect(receipt.mergedIntoExisting == 1, "the dirty Akhilesh merges into the clean one")

        // Values after: cleaned, never deleted.
        let total = Int((try await db.query("SELECT COUNT(*) FROM entities;", [])).first?.int(0) ?? 0)
        #expect(total == 6, "nothing is ever deleted")
        func value(_ id: UUID) async throws -> (String?, Int?, String?) {
            let r = (try await db.query(
                "SELECT value, producer_version, merged_into FROM entities WHERE id = ?;",
                [.uuid(id)])).first
            return (r?.string(0), r?.int(1).map(Int.init), r?.string(2))
        }
        let (v1, p1, m1) = try await value(dirtyLone)
        #expect(v1 == "Bill Delhi" && p1 == 2 && m1 == nil)
        let (v2, p2, _) = try await value(dirtyQuoted)
        #expect(v2 == "Arindam Das" && p2 == 2)
        let (v3, p3, m3) = try await value(dirtyAkhil)
        #expect(v3 == ", Akhilesh Sharma" && p3 == 2, "the loser keeps its original value — reversible")
        #expect(m3 != nil, "the dirty Akhilesh is soft-merged, not rewritten")
        let (v4, p4, m4) = try await value(cleanAkhil)
        #expect(v4 == "Akhilesh Sharma" && p4 == 2 && m4 == nil)
        let (v5, p5, _) = try await value(vadhwa)
        #expect(v5 == "Guruditsingh Vadhwa" && p5 == 2, "innocence: untouched, era advanced")
        let (v6, p6, _) = try await value(anchor)
        #expect(v6 == "patentnumber|555489" && p6 == 2, "non-rewritable kind: stamp only")

        // The re-witness: zero dirty person/org values remain.
        #expect(try await refresh.dirtyRemainder() == 0)

        // Idempotence: a second run scans zero.
        let second = try await refresh.run()
        #expect(second.scanned == 0, "second run must find nothing below the era")
    }
}
