//
//  DataHealthCheckProbeTests.swift
//  KalsmritikoshTests
//
//  The audit must not be quietest when it is most broken.
//
//  Every detector in DataHealthCheck has the shape "if count > 0 then report
//  an issue", and the probe used to return 0 when its query THREW. So a probe
//  broken by schema drift reported no problem — and because several counts
//  gate whole sections (`if koCount > 0 { … }`), one failed query switched
//  those checks off while the report still said "Issues found (0)".
//
//  This pins the distinction the fix rests on: a failed probe is nil, never 0.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Data-health probes distinguish failure from zero")
struct DataHealthCheckProbeTests {

    private func freshDatabase() throws -> (Database, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dhc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try Database(url: dir.appendingPathComponent("db.sqlite")), dir)
    }

    @Test("A probe against a table that does not exist returns nil, not zero")
    func missingTableIsNilNotZero() async throws {
        // This is the schema-drift case: a renamed or dropped table. It used to
        // read as "zero rows", which every detector then treated as healthy.
        let (db, dir) = try freshDatabase()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = await DataHealthCheck.scalarCount(
            db, "SELECT COUNT(*) FROM a_table_that_does_not_exist;")
        #expect(result == nil)
    }

    @Test("A syntactically broken probe returns nil, not zero")
    func brokenSQLIsNilNotZero() async throws {
        let (db, dir) = try freshDatabase()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await DataHealthCheck.scalarCount(db, "SELECT COUNT(*) FRM nonsense;") == nil)
    }

    @Test("A genuinely empty table returns 0 — a real measurement")
    func emptyTableIsZeroNotNil() async throws {
        // The other half of the contract: zero must still be reported as zero,
        // or the fix would turn every empty ledger into a failed audit.
        // The table is created here rather than relying on the migrated schema,
        // so the test measures the probe and nothing else.
        let (db, dir) = try freshDatabase()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await db.exec("CREATE TABLE empty_fixture (id INTEGER PRIMARY KEY);")
        let result = await DataHealthCheck.scalarCount(db, "SELECT COUNT(*) FROM empty_fixture;")
        #expect(result == 0)
    }

    @Test("A populated table returns its real count")
    func populatedTableCounts() async throws {
        let (db, dir) = try freshDatabase()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await db.exec("CREATE TABLE probe_fixture (id INTEGER PRIMARY KEY);")
        for _ in 0..<7 {
            try await db.exec("INSERT INTO probe_fixture (id) VALUES (NULL);")
        }
        #expect(await DataHealthCheck.scalarCount(db, "SELECT COUNT(*) FROM probe_fixture;") == 7)
    }
}
