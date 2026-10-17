//
//  SQLiteBlockOwnershipTests.swift
//  KalsmritikoshTests
//
//  F05 — a multi-object SQLite source links each page object to EXACTLY its own row blocks,
//  through a parser-native record key both the loader and the structural parser emit. Before,
//  ownership only understood mailbox indices, so every SQLite page object got no blocks.
//

import Foundation
import SQLite3
import Testing
@testable import Kalsmritikosh

@Suite("F05 — SQLite page objects own their exact row blocks")
struct SQLiteBlockOwnershipTests {

    private func makeDB(_ statements: [String]) throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("own-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("store.db")
        var h: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        defer { sqlite3_close(h) }
        for sql in statements { #expect(sqlite3_exec(h, sql, nil, nil, nil) == SQLITE_OK, "\(sql)") }
        return (url, dir)
    }

    private func rowText(_ block: EvidenceBlock) -> String? {
        block.kind == .tableRow ? block.rawText : nil
    }

    @Test("Each page object's blocks are exactly its rows — first, a middle-page row and the last")
    func pagesOwnTheirRows() async throws {
        var sql = ["CREATE TABLE m(id INTEGER PRIMARY KEY, body TEXT);", "BEGIN;",
                   "INSERT INTO m VALUES(-5,'row-neg');"]
        for i in 1...1100 { sql.append("INSERT INTO m VALUES(\(i),'row-\(i)');") }
        sql.append("COMMIT;")
        let (url, dir) = try makeDB(sql)
        defer { try? FileManager.default.removeItem(at: dir) }

        let objects = try await SQLiteLoader().ingestMany(fileAt: url, type: .sqlite)
        let doc = try await SQLiteStructuralParser().parse(
            data: try Data(contentsOf: url), filename: "store.db", type: .sqlite,
            logicalSourceID: UUID(), sourceVersionID: UUID())
        #expect(objects.count == 3)                                   // 1,101 rows / 500 per page

        var claimed = Set<UUID>()
        for ko in objects {
            let owned = IngestCoordinator.blocks(for: ko, from: doc.blocks, singleKO: false)
            let rows = owned.compactMap(rowText)
            #expect(rows.count == ko.content.components(separatedBy: "\n").count - 1, "every row of the page has its block")
            for b in owned { #expect(claimed.insert(b.id).inserted, "a block was owned by two pages") }
            for line in rows { #expect(ko.content.contains(line.replacingOccurrences(of: "=", with: " = "))) }
        }
        let first = IngestCoordinator.blocks(for: objects[0], from: doc.blocks, singleKO: false).compactMap(rowText)
        #expect(first.first?.contains("body=row-neg") == true)        // a non-positive rowid is owned too
        let middle = IngestCoordinator.blocks(for: objects[1], from: doc.blocks, singleKO: false).compactMap(rowText)
        #expect(middle.contains { $0.contains("body=row-600") })
        let last = IngestCoordinator.blocks(for: objects[2], from: doc.blocks, singleKO: false).compactMap(rowText)
        #expect(last.last?.contains("body=row-1100") == true)
    }

    @Test("A WITHOUT ROWID table links by primary-key position")
    func withoutRowIDOwnership() async throws {
        var sql = ["CREATE TABLE w(k TEXT PRIMARY KEY, v TEXT) WITHOUT ROWID;", "BEGIN;"]
        for i in 1...700 { sql.append("INSERT INTO w VALUES('k\(String(format: "%04d", i))','v-\(i)');") }
        sql.append("COMMIT;")
        let (url, dir) = try makeDB(sql)
        defer { try? FileManager.default.removeItem(at: dir) }
        let objects = try await SQLiteLoader().ingestMany(fileAt: url, type: .sqlite)
        let doc = try await SQLiteStructuralParser().parse(
            data: try Data(contentsOf: url), filename: "store.db", type: .sqlite,
            logicalSourceID: UUID(), sourceVersionID: UUID())
        let second = IngestCoordinator.blocks(for: objects[1], from: doc.blocks, singleKO: false).compactMap(rowText)
        #expect(second.count == 200)
        #expect(second.first?.contains("v=v-501") == true)
    }
}
