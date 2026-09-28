//
//  BackupServiceTests.swift
//  KalsmritikoshTests
//
//  G2/Stage-11 / AT-15 — backup then restore round-trips to a clean folder;
//  a tampered/incomplete backup is refused, not partially restored. Real
//  files in a temp directory.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("G2 backup service (round-trip)")
struct BackupServiceTests {

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("bk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func backupThenRestoreRoundTripsToACleanProfile() throws {
        let src = try tempDir()
        let db = src.appendingPathComponent("knowledge.sqlite")
        let doc = src.appendingPathComponent("grant.eml")
        try "DATABASE-BYTES".data(using: .utf8)!.write(to: db)
        try "From: office\nSubject: grant".data(using: .utf8)!.write(to: doc)

        let backup = try tempDir()
        let svc = BackupService()
        let manifest = try svc.createBackup(databaseURL: db, originalURLs: [doc],
                                            destination: backup, schemaVersion: 128, nowEpoch: 1_700_000_000)
        #expect(manifest.databaseEntry?.relativePath == "knowledge.sqlite")
        #expect(manifest.entries.count == 2)

        // Inspect: complete → ok.
        #expect(try svc.inspect(backupFolder: backup).verdict.ok == true)

        // Restore into a clean folder; files come back byte-identical.
        let restored = try tempDir()
        _ = try svc.restore(backupFolder: backup, into: restored)
        let backDB = try String(contentsOf: restored.appendingPathComponent("knowledge.sqlite"), encoding: .utf8)
        #expect(backDB == "DATABASE-BYTES")
        #expect(FileManager.default.fileExists(atPath: restored.appendingPathComponent("grant.eml").path))
    }

    @Test func incompleteBackupIsRefusedNotPartiallyRestored() throws {
        let src = try tempDir()
        let db = src.appendingPathComponent("knowledge.sqlite")
        let doc = src.appendingPathComponent("a.pdf")
        try "DB".data(using: .utf8)!.write(to: db)
        try "PDF".data(using: .utf8)!.write(to: doc)

        let backup = try tempDir()
        let svc = BackupService()
        _ = try svc.createBackup(databaseURL: db, originalURLs: [doc],
                                 destination: backup, schemaVersion: 128, nowEpoch: 1)
        // Tamper: delete the original from the backup folder.
        try FileManager.default.removeItem(at: backup.appendingPathComponent("a.pdf"))

        let restored = try tempDir()
        var threw = false
        do { _ = try svc.restore(backupFolder: backup, into: restored) }
        catch BackupService.BackupError.restoreIncomplete(let missing) {
            threw = true
            #expect(missing == ["a.pdf"])
        }
        #expect(threw, "an incomplete backup must be refused")
        // Nothing was copied into the clean folder.
        #expect(!FileManager.default.fileExists(atPath: restored.appendingPathComponent("knowledge.sqlite").path))
    }
}
