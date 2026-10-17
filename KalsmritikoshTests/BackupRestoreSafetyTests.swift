//
//  BackupRestoreSafetyTests.swift
//  KalsmritikoshTests
//
//  F19 — restore is contained and failure-atomic: symlinked or damaged entries are refused, an
//  unusable database is refused before anything is touched, and a failure part-way through
//  promotion puts every previous file back byte-for-byte.
//

import Foundation
import SQLite3
import Testing
@testable import Kalsmritikosh

@Suite("F19 — backup restore safety")
struct BackupRestoreSafetyTests {

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("bkr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A real, tiny SQLite database holding `marker`.
    private func realDB(at url: URL, marker: String) {
        var h: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        #expect(sqlite3_exec(h, "CREATE TABLE t(v TEXT); INSERT INTO t VALUES('\(marker)');", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(h)
    }

    /// A backup of (knowledge.sqlite = "NEW", grant.eml = "new letter") and a live target holding
    /// (knowledge.sqlite = "OLD", grant.eml = "old letter", knowledge.sqlite-wal = stale log).
    private func scenario() throws -> (backup: URL, target: URL, oldDB: Data, oldDoc: Data, oldWAL: Data) {
        let src = try tempDir()
        realDB(at: src.appendingPathComponent("knowledge.sqlite"), marker: "NEW")
        try Data("new letter".utf8).write(to: src.appendingPathComponent("grant.eml"))
        let backup = try tempDir()
        _ = try BackupService().createBackup(databaseURL: src.appendingPathComponent("knowledge.sqlite"),
                                             originalURLs: [src.appendingPathComponent("grant.eml")],
                                             destination: backup, schemaVersion: 1, nowEpoch: 1)
        let target = try tempDir().appendingPathComponent("profile")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        realDB(at: target.appendingPathComponent("knowledge.sqlite"), marker: "OLD")
        try Data("old letter".utf8).write(to: target.appendingPathComponent("grant.eml"))
        try Data("stale-wal".utf8).write(to: target.appendingPathComponent("knowledge.sqlite-wal"))
        return (backup, target,
                try Data(contentsOf: target.appendingPathComponent("knowledge.sqlite")),
                Data("old letter".utf8), Data("stale-wal".utf8))
    }

    private func assertOldDataIntact(_ s: (backup: URL, target: URL, oldDB: Data, oldDoc: Data, oldWAL: Data)) throws {
        #expect(try Data(contentsOf: s.target.appendingPathComponent("knowledge.sqlite")) == s.oldDB)
        #expect(try Data(contentsOf: s.target.appendingPathComponent("grant.eml")) == s.oldDoc)
        #expect(try Data(contentsOf: s.target.appendingPathComponent("knowledge.sqlite-wal")) == s.oldWAL)
    }

    @Test("A successful restore replaces the files and clears the outgoing database's stale log")
    func successfulRestore() throws {
        let s = try scenario()
        try BackupService().restore(backupFolder: s.backup, into: s.target)
        #expect(try Data(contentsOf: s.target.appendingPathComponent("grant.eml")) == Data("new letter".utf8))
        #expect(!FileManager.default.fileExists(atPath: s.target.appendingPathComponent("knowledge.sqlite-wal").path))
        #expect(Database.quickCheck(fileAt: s.target.appendingPathComponent("knowledge.sqlite")) == nil)
        // No staging / aside folders left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: s.target.deletingLastPathComponent().path)
        #expect(leftovers == ["profile"])
    }

    @Test("A failure part-way through promotion rolls back: every previous file survives byte-for-byte")
    func midPromotionFailureRollsBack() throws {
        let s = try scenario()
        #expect(throws: BackupService.BackupError.self) {
            try BackupService(failPromotionAfter: 1).restore(backupFolder: s.backup, into: s.target)
        }
        try assertOldDataIntact(s)
    }

    @Test("A backup whose database is not a usable SQLite file is refused before anything changes")
    func unusableDatabaseRefused() throws {
        let s = try scenario()
        // Forge a consistent manifest over garbage "database" bytes (checksums match, content is junk).
        let junk = Data("not a database".utf8)
        try junk.write(to: s.backup.appendingPathComponent("knowledge.sqlite"))
        var m = try JSONDecoder().decode(BackupManifest.self, from: Data(contentsOf: s.backup.appendingPathComponent(BackupService.manifestName)))
        let measured = try BackupService.measure(s.backup.appendingPathComponent("knowledge.sqlite"))
        m = BackupManifest(createdAtEpoch: m.createdAtEpoch, schemaVersion: m.schemaVersion, entries: m.entries.map {
            $0.kind == .database ? BackupEntry(relativePath: $0.relativePath, byteSize: measured.byteSize, sha256: measured.sha256, kind: .database) : $0
        }, coverage: m.coverage)
        try JSONEncoder().encode(m).write(to: s.backup.appendingPathComponent(BackupService.manifestName))
        #expect(throws: BackupService.BackupError.self) { try BackupService().restore(backupFolder: s.backup, into: s.target) }
        try assertOldDataIntact(s)
    }

    @Test("A symlinked entry and a damaged entry are refused; the target is untouched")
    func symlinkAndDamageRefused() throws {
        let s = try scenario()
        let doc = s.backup.appendingPathComponent("grant.eml")
        var bytes = try Data(contentsOf: doc); bytes[0] ^= 0x01; try bytes.write(to: doc)
        #expect(throws: BackupService.BackupError.self) { try BackupService().restore(backupFolder: s.backup, into: s.target) }
        try assertOldDataIntact(s)

        let s2 = try scenario()
        let link = s2.backup.appendingPathComponent("grant.eml")
        let outside = try tempDir().appendingPathComponent("secret.txt")
        try Data("new letter".utf8).write(to: outside)                       // same bytes, so checksums pass
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(throws: BackupService.BackupError.self) { try BackupService().restore(backupFolder: s2.backup, into: s2.target) }
        try assertOldDataIntact(s2)
    }
}
