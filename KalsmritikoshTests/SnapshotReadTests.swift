//
//  SnapshotReadTests.swift
//  KalsmritikoshTests
//
//  UNIT C-ii — snapshot-per-ask, under the owner's four bindings:
//  the red is a NON-EXHAUST mid-ask write (a plain row from the write
//  connection — an exhaust canary would prove nothing, C-i already masks
//  those at candidacy); the stamp is read on the snapshot connection at
//  begin; release is unconditional and WAL checkpointing proceeds after;
//  savepoint/transaction-scoped reads stay live (read-your-own-writes).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Unit C-ii — ask snapshot: evidence reads see a stable world", .serialized)
struct SnapshotReadTests {

    private func makeDB() async throws -> (Database, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("snap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await db.exec("CREATE TABLE probe (id INTEGER PRIMARY KEY, note TEXT);")
        try await db.exec("INSERT INTO probe (note) VALUES ('pre-existing');")
        return (db, dir)
    }

    @Test("RED/GREEN in one: a plain mid-ask write is visible WITHOUT the snapshot, invisible WITH it")
    func midAskWriteInvisibility() async throws {
        let (db, dir) = try await makeDB()
        defer { try? FileManager.default.removeItem(at: dir) }

        func count() async throws -> Int {
            Int((try await db.query("SELECT COUNT(*) FROM probe", [])).first?.int(0) ?? -1)
        }

        // CONTROL (the pre-fix world): no snapshot → the mid-"ask" write is
        // immediately visible to the next evidence read.
        try await db.exec("INSERT INTO probe (note) VALUES ('mid-ask control');")
        #expect(try await count() == 2, "control: live reads see writes immediately (the defect this unit closes)")

        // TREATMENT: begin the ask snapshot (stamp read on the snapshot
        // connection at that instant), write a NON-EXHAUST row from the
        // live connection mid-ask, and assert the evidence read does NOT
        // see it — then release and assert it appears.
        let stamp = await db.beginAskSnapshot()
        #expect(stamp != nil, "stamp must be read on the snapshot connection at begin")
        #expect(await db.isAskSnapshotActive)
        try await db.exec("INSERT INTO probe (note) VALUES ('mid-ask treatment');")
        let during = try await count()
        print("C-ii fixture: during-snapshot count=\(during) (2 = invisible, 3 = LEAK)")
        #expect(during == 2, "a non-exhaust mid-ask write leaked into the evidence read")
        // Savepoint-scoped reads are read-your-own-writes: they see it.
        let inSP = try await db.withSavepoint("rr") { d in
            Int((try d.query("SELECT COUNT(*) FROM probe", [])).first?.int(0) ?? -1)
        }
        #expect(inSP == 3, "savepoint reads must stay live (commit read-back)")
        await db.endAskSnapshot()
        #expect(!(await db.isAskSnapshotActive), "release must be unconditional")
        #expect(try await count() == 3, "writes land between asks, never during")

        // Lifecycle (binding #3): no lingering transaction — a WAL
        // checkpoint must proceed after the ask.
        let ck = try await db.query("PRAGMA wal_checkpoint(PASSIVE);", [])
        #expect(Int(ck.first?.int(0) ?? -1) == 0, "WAL checkpoint blocked — a read transaction lingers")

        // Completeness audit (binding #4): no unsanctioned live reads
        // occurred during the snapshot in this scenario.
        #expect(await db.liveReadsDuringSnapshot == 0)
        await db.close()
    }
}
