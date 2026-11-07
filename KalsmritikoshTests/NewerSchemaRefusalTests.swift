//
//  NewerSchemaRefusalTests.swift
//  KalsmritikoshTests
//
//  T2 — an older build never opens or restores a ledger written by a newer one: the ledger is left
//  exactly as it was and the person is told to update the app.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Newer-schema refusal (T2)")
struct NewerSchemaRefusalTests {

    @Test("Opening a ledger from a newer schema is refused and the ledger is not changed")
    func openRefused() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("CREATE TABLE future_feature (x TEXT); INSERT INTO future_feature VALUES ('kept');")
        try await db.setUserVersion(SchemaMigrations.latestVersion + 1)
        do {
            try await SchemaMigrations.migrate(db)
            Issue.record("a newer ledger was opened")
        } catch let DatabaseError.migrationFailed(version, message) {
            #expect(version == SchemaMigrations.latestVersion + 1)
            #expect(message.contains("Update the app") && message.contains("not changed"))
        }
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion + 1, "the stamp is not lowered")
        #expect(try await db.query("SELECT x FROM future_feature;", []).first?.string(0) == "kept")
    }

    @Test("A backup from a newer schema is refused before anything is staged or replaced")
    func restoreRefused() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("t2-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let src = root.appendingPathComponent("src", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        let ledger = src.appendingPathComponent("knowledge.sqlite")
        try Data("SQLite format 3\u{0}".utf8).write(to: ledger)
        let backup = root.appendingPathComponent("backup", isDirectory: true)
        try BackupService().createBackup(databaseURL: ledger, originalURLs: [], destination: backup,
                                         schemaVersion: SchemaMigrations.latestVersion + 1, nowEpoch: 1)
        let target = root.appendingPathComponent("live", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("current ledger".utf8).write(to: target.appendingPathComponent("knowledge.sqlite"))
        #expect(throws: BackupService.BackupError.self) {
            try BackupService().restore(backupFolder: backup, into: target, ledgerKey: nil)
        }
        #expect(try String(contentsOf: target.appendingPathComponent("knowledge.sqlite"), encoding: .utf8) == "current ledger")
    }

    @Test("T2: a backup write that fails part-way leaves the backup already there intact, and no half-written folder")
    func failedWriteKeepsPrevious() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("t2w-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let ledger = root.appendingPathComponent("knowledge.sqlite")
        try Data("SQLite format 3\u{0} good ledger".utf8).write(to: ledger)
        let original = root.appendingPathComponent("letter.txt")
        try Data("the letter".utf8).write(to: original)
        let dest = root.appendingPathComponent("Backup", isDirectory: true)
        let first = try BackupService().createBackup(databaseURL: ledger, originalURLs: [original], destination: dest,
                                                     schemaVersion: SchemaMigrations.latestVersion, nowEpoch: 1)
        // A second write fails part-way (an input that cannot be read, as a full disk would fail a copy).
        try Data("SQLite format 3\u{0} newer ledger".utf8).write(to: ledger)
        #expect(throws: (any Error).self) {
            try BackupService().createBackup(databaseURL: ledger, originalURLs: [original, root.appendingPathComponent("gone.txt")],
                                             destination: dest, schemaVersion: SchemaMigrations.latestVersion, nowEpoch: 2)
        }
        let (manifest, verdict) = try BackupService().inspect(backupFolder: dest)
        #expect(verdict.ok, "the earlier backup still verifies")
        #expect(manifest.createdAtEpoch == first.createdAtEpoch, "it is the earlier backup, untouched")
        #expect(try fm.contentsOfDirectory(atPath: root.path).filter { $0.contains(".writing-") || $0.contains(".replaced-") }.isEmpty)
        // A successful rewrite replaces it as a whole.
        let second = try BackupService().createBackup(databaseURL: ledger, originalURLs: [original], destination: dest,
                                                      schemaVersion: SchemaMigrations.latestVersion, nowEpoch: 3)
        #expect(try BackupService().inspect(backupFolder: dest).manifest.createdAtEpoch == second.createdAtEpoch)
    }

    @Test("T2: a destination without room is refused before anything is written")
    func insufficientSpaceRefused() {
        #expect(throws: BackupService.BackupError.self) { try BackupService.requireSpace(needed: 10 << 30, available: 1 << 30) }
        #expect(throws: Never.self) { try BackupService.requireSpace(needed: 1 << 20, available: 1 << 30) }
    }
}
