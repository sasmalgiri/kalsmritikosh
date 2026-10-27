//
//  CompleteBackupTests.swift
//  KalsmritikoshTests
//
//  Implementation brief §11: a complete backup carries the ledger AND the original files, with the
//  map that relinks them. Restored on another "Mac" (a fresh folder, the originals gone from their old
//  paths), every source the ledger names opens from the restored copy, byte for byte; what could not
//  be read is listed; a tampered original refuses the restore and leaves the target untouched.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Complete backup and restore")
struct CompleteBackupTests {

    func scratch(_ tag: String) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("cbk-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test("Originals travel with the ledger and are relinked on restore; unreadable ones are listed")
    func roundTrip() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let oldMac = try scratch("old")
        let letter = oldMac.appendingPathComponent("letter.txt"), memo = oldMac.appendingPathComponent("memo.txt")
        try Data("The approval letter.".utf8).write(to: letter)
        try Data("The internal memo.".utf8).write(to: memo)
        let letterID = UUID(), memoID = UUID()
        for (id, url) in [(letterID, letter), (memoID, memo)] {
            try await db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                              [.uuid(id), .text(url.absoluteString), .text("txt"), .text("available")])
        }
        let snapshotDir = try scratch("snap")
        let snapshot = snapshotDir.appendingPathComponent("knowledge.sqlite")
        try await db.backupSnapshot(to: snapshot)
        let backup = try scratch("backup")
        let manifest = try BackupService().createCompleteBackup(
            databaseSnapshot: snapshot, originals: [(letterID, letter), (memoID, memo)], notIncluded: ["/Volumes/Gone/scan.pdf"],
            destination: backup, schemaVersion: SchemaMigrations.latestVersion, nowEpoch: 1)
        // One original could not be read, so the backup is NOT labelled complete (final brief §3.8).
        #expect(manifest.coverage == .ledgerWithSomeOriginals)
        #expect(try BackupService().inspect(backupFolder: backup).verdict.note.contains("Ledger with some originals"))
        #expect(manifest.entries.filter { $0.kind == .originalSource }.count == 2)
        #expect(try BackupService().inspect(backupFolder: backup).verdict.ok)

        // The old Mac is gone.
        try FileManager.default.removeItem(at: oldMac)
        let newMac = try scratch("new")
        let map = try await BackupService().restoreComplete(backupFolder: backup, into: newMac, ledgerKey: nil)
        #expect(map.notIncluded == ["/Volumes/Gone/scan.pdf"])
        let restored = try Database(url: newMac.appendingPathComponent("knowledge.sqlite"))
        for (id, text) in [(letterID, "The approval letter."), (memoID, "The internal memo.")] {
            let url = try #require(try await restored.query("SELECT url FROM files WHERE id = ?;", [.uuid(id)]).first?.string(0).flatMap(URL.init(string:)))
            #expect(url.path.hasPrefix(newMac.standardizedFileURL.path))
            #expect(try String(contentsOf: url, encoding: .utf8) == text)
        }
        await restored.close()
    }

    @Test("A restore chosen in Settings runs at the next launch, keeps the replaced ledger, and runs once")
    func scheduledAtBoot() async throws {
        defer { PendingRestore.cancel() }
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let src = try scratch("psrc")
        let letter = src.appendingPathComponent("letter.txt")
        try Data("The approval letter.".utf8).write(to: letter)
        let id = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                          [.uuid(id), .text(letter.absoluteString), .text("txt"), .text("available")])
        let snap = try scratch("psnap").appendingPathComponent("knowledge.sqlite")
        try await db.backupSnapshot(to: snap)
        let backup = try scratch("pbackup")
        let full = try BackupService().createCompleteBackup(databaseSnapshot: snap, originals: [(id, letter)], notIncluded: [],
                                                 destination: backup, schemaVersion: SchemaMigrations.latestVersion, nowEpoch: 1)
        #expect(full.coverage == .complete)   // nothing left out
        #expect(PendingRestore.schedule(backupFolder: backup) == nil)
        #expect(PendingRestore.isScheduled)
        // This Mac's current ledger.
        let data = try scratch("pdata")
        let live = data.appendingPathComponent("knowledge.sqlite")
        try Data("the current ledger".utf8).write(to: live)
        let outcome = await PendingRestore.performIfScheduled(databaseURL: live, recoveryKey: nil, nowEpoch: 42)
        guard case .restored(let note) = outcome else { Issue.record("not restored: \(outcome)"); return }
        #expect(note.contains("1 original file(s)"))
        #expect(!PendingRestore.isScheduled)
        // The replaced ledger is kept, never deleted.
        #expect(try String(contentsOf: data.appendingPathComponent("Before restore 42/knowledge.sqlite"), encoding: .utf8) == "the current ledger")
        let restored = try Database(url: live)
        let url = try #require(try await restored.query("SELECT url FROM files WHERE id = ?;", [.uuid(id)]).first?.string(0).flatMap(URL.init(string:)))
        #expect(try String(contentsOf: url, encoding: .utf8) == "The approval letter.")
        await restored.close()
        // Nothing scheduled: boot does nothing.
        #expect(await PendingRestore.performIfScheduled(databaseURL: live, recoveryKey: nil) == .none)
        // A folder that is not a backup is not scheduled.
        #expect(PendingRestore.schedule(backupFolder: try scratch("empty")) != nil)
        #expect(!PendingRestore.isScheduled)
    }

    @Test("A tampered original refuses the restore and the target is left as it was")
    func tamperRefused() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let src = try scratch("src")
        let letter = src.appendingPathComponent("letter.txt")
        try Data("Original bytes.".utf8).write(to: letter)
        let id = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                          [.uuid(id), .text(letter.absoluteString), .text("txt"), .text("available")])
        let snap = try scratch("snap").appendingPathComponent("knowledge.sqlite")
        try await db.backupSnapshot(to: snap)
        let backup = try scratch("backup")
        try BackupService().createCompleteBackup(databaseSnapshot: snap, originals: [(id, letter)], notIncluded: [],
                                                 destination: backup, schemaVersion: SchemaMigrations.latestVersion, nowEpoch: 1)
        try Data("Altered bytes!!".utf8).write(to: backup.appendingPathComponent("originals/letter.txt"))
        let target = try scratch("target")
        try Data("existing ledger".utf8).write(to: target.appendingPathComponent("knowledge.sqlite"))
        await #expect(throws: BackupService.BackupError.self) {
            try await BackupService().restoreComplete(backupFolder: backup, into: target, ledgerKey: nil)
        }
        #expect(try String(contentsOf: target.appendingPathComponent("knowledge.sqlite"), encoding: .utf8) == "existing ledger")
    }
}
