//
//  IsolatedSavepointConcurrencyTests.swift
//  KalsmritikoshTests
//
//  F28 — a read-then-write that awaited between its statements was not isolated: two concurrent
//  callers could both read MAX(version) and write the same number. Converted repositories run the
//  whole unit in `Database.withSavepoint`, so concurrent callers serialize.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("F28 — isolated savepoints under concurrency")
struct IsolatedSavepointConcurrencyTests {

    private func seedEvent() async throws -> (Database, Event) {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let file = UUID(), ko = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                          [.uuid(file), .text("file:///f28-\(file)"), .text("txt")])
        try await db.exec("""
            INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);
            """, [.uuid(ko), .uuid(file), .text("txt"), .text("c"), .real(0), .real(0)])
        let event = Event(kind: .other, date: Date(timeIntervalSince1970: 1_700_000_000), title: "Contract signed",
                          entityIDs: [], sourceObjectID: ko, datePrecision: .day)
        try await EventsRepository(database: db).insertBatch([event])
        return (db, event)
    }

    @Test("Concurrent versions of one event get distinct, contiguous numbers and exactly one current row")
    func concurrentEventVersions() async throws {
        let (db, event) = try await seedEvent()
        let repo = EventVersionsRepository(database: db)
        let numbers = try await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0..<24 {
                group.addTask { try await repo.recordVersion(event: event, agent: "test.\(i)") }
            }
            var out: [Int] = []
            for try await n in group { out.append(n) }
            return out
        }
        #expect(numbers.sorted() == Array(1...24), "every version number claimed exactly once")
        let current = try await db.query("SELECT COUNT(*) FROM event_versions WHERE event_id = ? AND valid_to IS NULL;",
                                         [.uuid(event.id)]).first?.int(0)
        #expect(current == 1)
    }
}
