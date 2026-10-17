//
//  LiveBackupSnapshotTests.swift
//  KalsmritikoshTests
//
//  F18 — a backup taken WHILE writes continue is a consistent, self-contained snapshot: it passes
//  SQLite's integrity check, needs no sidecars, and holds a coherent row set (every committed
//  transaction wholly present or wholly absent).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("F18 — consistent live backup snapshot")
struct LiveBackupSnapshotTests {

    @Test("A snapshot taken during concurrent writes opens clean and holds whole transactions only")
    func snapshotDuringWrites() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("live.sqlite"))
        try await db.exec("PRAGMA journal_mode=WAL;")
        try await db.exec("CREATE TABLE pairs(batch INTEGER, side TEXT);")

        // Writer: each batch inserts TWO rows in one savepoint — a consistent copy must never
        // contain half a batch.
        let writer = Task {
            for batch in 0..<300 {
                try await db.withSavepoint("w\(batch)") { d in
                    try d.exec("INSERT INTO pairs VALUES(?, 'a');", [.integer(Int64(batch))])
                    try d.exec("INSERT INTO pairs VALUES(?, 'b');", [.integer(Int64(batch))])
                }
            }
        }
        var snapshots: [URL] = []
        for i in 0..<5 {
            let url = dir.appendingPathComponent("snap-\(i).sqlite")
            try await db.backupSnapshot(to: url)
            snapshots.append(url)
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        try await writer.value

        for url in snapshots {
            #expect(Database.quickCheck(fileAt: url) == nil)
            #expect(!FileManager.default.fileExists(atPath: url.path + "-wal"))   // self-contained
            let copy = try Database(url: url)
            let total = try await copy.query("SELECT COUNT(*) FROM pairs;").first?.int(0) ?? -1
            let halves = try await copy.query(
                "SELECT COUNT(*) FROM (SELECT batch FROM pairs GROUP BY batch HAVING COUNT(*) <> 2);").first?.int(0) ?? -1
            #expect(total % 2 == 0)
            #expect(halves == 0, "a snapshot held half a transaction")
        }
    }
}
