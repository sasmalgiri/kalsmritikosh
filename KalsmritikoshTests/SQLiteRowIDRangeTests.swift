//
//  SQLiteRowIDRangeTests.swift
//  KalsmritikoshTests
//
//  F04 — the record loader reads EVERY row: negative and zero rowids, a table whose user
//  column is literally named "rowid", and WITHOUT ROWID tables paged in a stable order.
//

import Foundation
import SQLite3
import Testing
@testable import Kalsmritikosh

@Suite("F04 — SQLite loader reads the full row range")
struct SQLiteRowIDRangeTests {

    private func makeDB(_ statements: [String]) throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rowid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("probe.db")
        var h: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        defer { sqlite3_close(h) }
        for sql in statements { #expect(sqlite3_exec(h, sql, nil, nil, nil) == SQLITE_OK, "\(sql)") }
        return (url, dir)
    }

    private func text(_ url: URL) async throws -> String {
        try await SQLiteLoader().ingestMany(fileAt: url, type: .sqlite).map(\.content).joined(separator: "\n")
    }

    @Test("Rows with rowid -2, 0 and 1 are all imported")
    func nonPositiveRowIDs() async throws {
        let (url, dir) = try makeDB([
            "CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);",
            "INSERT INTO t VALUES(-2,'minus-two'),(0,'zero'),(1,'one');",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let all = try await text(url)
        for v in ["minus-two", "zero", "one"] { #expect(all.contains("v = \(v)"), "\(v) missing") }
    }

    @Test("A user column named rowid does not hijack paging")
    func shadowedRowIDColumn() async throws {
        var inserts: [String] = ["CREATE TABLE s(rowid TEXT, v TEXT);"]
        // 1,200 rows (> one 500-row page) whose "rowid" COLUMN is the same text everywhere.
        inserts.append("BEGIN;")
        for i in 1...1200 { inserts.append("INSERT INTO s VALUES('same','row-\(i)');") }
        inserts.append("COMMIT;")
        let (url, dir) = try makeDB(inserts)
        defer { try? FileManager.default.removeItem(at: dir) }
        let all = try await text(url)
        let lines = all.components(separatedBy: "\n")
        #expect(lines.contains { $0.hasSuffix("v = row-1") }, "first row missing")
        #expect(lines.contains { $0.hasSuffix("v = row-1200") }, "last row missing")
        // Every row exactly once — no page re-read, none skipped.
        let values = lines.compactMap { line in line.range(of: "v = row-").map { String(line[$0.upperBound...]) } }
        #expect(values.count == 1200)
        #expect(Set(values).count == 1200)
    }

    @Test("A WITHOUT ROWID table is read completely, in primary-key order")
    func withoutRowIDTable() async throws {
        var inserts: [String] = ["CREATE TABLE w(k INTEGER PRIMARY KEY, v TEXT) WITHOUT ROWID;", "BEGIN;"]
        for i in stride(from: 1100, through: 1, by: -1) { inserts.append("INSERT INTO w VALUES(\(i),'w-\(i)');") }
        inserts.append("COMMIT;")
        let (url, dir) = try makeDB(inserts)
        defer { try? FileManager.default.removeItem(at: dir) }
        let objects = try await SQLiteLoader().ingestMany(fileAt: url, type: .sqlite)
        let all = objects.map(\.content).joined(separator: "\n")
        #expect(all.components(separatedBy: "v = w-").count - 1 == 1100)
        #expect(objects.first?.content.contains("k = 1 |") == true)     // pages follow the key order
    }
}
