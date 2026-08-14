//
//  DatabasePragmaTests.swift
//  KalsmritikoshTests
//
//  PERF-1 — the connection is opened with the durability-safe read-tuning
//  pragmas (WAL + NORMAL unchanged; mmap/cache/temp_store added). These pin
//  that the tuning is actually applied on every connection and that the
//  durability posture is untouched. Pure; a throwaway temp DB.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("PERF-1 — connection pragmas")
struct DatabasePragmaTests {

    private func openTemp() async throws -> Database {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pragma-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try Database(url: dir.appendingPathComponent("db.sqlite"))
    }

    @Test("Durability posture is preserved: WAL + synchronous=NORMAL + foreign_keys + busy_timeout")
    func durabilityUnchanged() async throws {
        let db = try await openTemp()
        #expect((try await db.query("PRAGMA journal_mode;", []).first?.string(0))?.lowercased() == "wal")
        #expect(try await db.query("PRAGMA synchronous;", []).first?.int(0) == 1)      // NORMAL
        #expect(try await db.query("PRAGMA foreign_keys;", []).first?.int(0) == 1)
        #expect(try await db.query("PRAGMA busy_timeout;", []).first?.int(0) == 30000)
    }

    @Test("Read tuning is applied: mmap_size, cache_size, temp_store=MEMORY")
    func readTuningApplied() async throws {
        let db = try await openTemp()
        // mmap_size: SILENTLY capped by the platform, so assert it is enabled
        // (> 0) rather than an exact byte count.
        let mmap = try await db.query("PRAGMA mmap_size;", []).first?.int(0) ?? 0
        #expect(mmap > 0, "mmap_size not enabled (got \(mmap))")
        // cache_size stored as the negative-KiB form we set.
        #expect(try await db.query("PRAGMA cache_size;", []).first?.int(0) == -20000)
        // temp_store: 2 == MEMORY.
        #expect(try await db.query("PRAGMA temp_store;", []).first?.int(0) == 2)
    }
}
