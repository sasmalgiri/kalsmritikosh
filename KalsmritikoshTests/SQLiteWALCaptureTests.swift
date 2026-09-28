//
//  SQLiteWALCaptureTests.swift
//  KalsmritikoshTests
//
//  F03 — a live WAL-mode database's committed-but-uncheckpointed rows live in its `-wal`
//  sidecar. The intake snapshot must capture the WAL with the main file (hashed, as one
//  acquisition set), or every one of those rows is silently absent from the ledger.
//

import Foundation
import SQLite3
import Testing
@testable import Kalsmritikosh

@Suite("F03 — SQLite intake captures the WAL sidecar")
struct SQLiteWALCaptureTests {

    /// A WAL database with `rows` committed rows still in the WAL. The writer handle is returned
    /// OPEN — closing the last connection would checkpoint and delete the WAL.
    private func liveWALDatabase(rows: Int) throws -> (url: URL, dir: URL, writer: OpaquePointer?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("live.db")
        var h: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        for sql in ["PRAGMA journal_mode=WAL;", "PRAGMA wal_autocheckpoint=0;",
                    "CREATE TABLE m(id INTEGER PRIMARY KEY, body TEXT);", "BEGIN;"]
            + (1...rows).map({ "INSERT INTO m(body) VALUES('wal-row-\($0)');" }) + ["COMMIT;"] {
            #expect(sqlite3_exec(h, sql, nil, nil, nil) == SQLITE_OK, "\(sql)")
        }
        #expect(FileManager.default.fileExists(atPath: url.path + "-wal"))
        return (url, dir, h)
    }

    @Test("Committed WAL rows survive intake: the snapshot set carries the WAL and every row is read")
    func walRowsSurviveSnapshot() async throws {
        let db = try liveWALDatabase(rows: 3)
        defer { sqlite3_close(db.writer); try? FileManager.default.removeItem(at: db.dir) }
        let snapDir = db.dir.appendingPathComponent("snapshot")
        let (captured, snapshotURL) = try SourceByteCapture.captureToSnapshot(db.url, snapshotDirectory: snapDir)

        #expect(FileManager.default.fileExists(atPath: snapshotURL.path + "-wal"))
        #expect(captured.sqliteSidecars.map(\.suffix) == ["-wal"])
        #expect(captured.sqliteSidecars.first?.contentHash.count == 64)
        let text = try await SQLiteLoader().ingestMany(fileAt: snapshotURL, type: .sqlite)
            .map(\.content).joined(separator: "\n")
        for i in 1...3 { #expect(text.contains("body = wal-row-\(i)"), "row \(i) lost") }
    }

    @Test("A plain (non-WAL) file captures no sidecars")
    func noSidecarsForPlainFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: url)
        try Data("not a wal".utf8).write(to: URL(fileURLWithPath: url.path + "-wal"))   // a stray file, not SQLite
        let (captured, snapshotURL) = try SourceByteCapture.captureToSnapshot(url, snapshotDirectory: dir.appendingPathComponent("s"))
        #expect(captured.sqliteSidecars.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: snapshotURL.path + "-wal"))
    }
}
