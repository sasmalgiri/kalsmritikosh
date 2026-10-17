//
//  BackupIntegrityTests.swift
//  KalsmritikoshTests
//
//  F17 — a backup is verified by CONTENT, not presence: every entry's size and SHA-256 must
//  match; same-named originals get distinct paths; unsafe or duplicate manifest paths are
//  rejected; and the manifest states whether the evidence vault is included.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("F17 — backup integrity")
struct BackupIntegrityTests {

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("bki-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func sampleBackup() throws -> (backup: URL, manifest: BackupManifest) {
        let src = try tempDir()
        let db = src.appendingPathComponent("knowledge.sqlite")
        try Data("DATABASE-BYTES".utf8).write(to: db)
        let doc = src.appendingPathComponent("grant.eml")
        try Data("From: office\nSubject: grant".utf8).write(to: doc)
        let backup = try tempDir()
        let manifest = try BackupService().createBackup(databaseURL: db, originalURLs: [doc], destination: backup,
                                                        schemaVersion: 128, nowEpoch: 1)
        return (backup, manifest)
    }

    @Test("One flipped byte with the size unchanged is caught")
    func flippedByteRejected() throws {
        let (backup, _) = try sampleBackup()
        let url = backup.appendingPathComponent("grant.eml")
        var bytes = try Data(contentsOf: url)
        bytes[0] ^= 0x01
        try bytes.write(to: url)
        let verdict = try BackupService().inspect(backupFolder: backup).verdict
        #expect(!verdict.ok)
        #expect(verdict.corrupt == ["grant.eml"])
        #expect(verdict.missing.isEmpty)
    }

    @Test("Two originals with the same file name are both kept, under distinct paths")
    func sameNameOriginalsKept() throws {
        let a = try tempDir(), b = try tempDir()
        let db = a.appendingPathComponent("knowledge.sqlite")
        try Data("DB".utf8).write(to: db)
        try Data("first letter".utf8).write(to: a.appendingPathComponent("letter.txt"))
        try Data("second letter".utf8).write(to: b.appendingPathComponent("letter.txt"))
        let backup = try tempDir()
        let svc = BackupService()
        let manifest = try svc.createBackup(databaseURL: db,
                                            originalURLs: [a.appendingPathComponent("letter.txt"), b.appendingPathComponent("letter.txt")],
                                            destination: backup, schemaVersion: 128, nowEpoch: 1)
        let originals = manifest.entries.filter { $0.kind == .originalSource }
        #expect(originals.count == 2)
        #expect(Set(originals.map(\.relativePath)).count == 2)
        #expect(Set(originals.map(\.sha256)).count == 2)                      // neither overwrote the other
        #expect(try svc.inspect(backupFolder: backup).verdict.ok)
    }

    @Test("Unsafe and duplicate manifest paths are rejected before anything is trusted")
    func unsafeAndDuplicatePathsRejected() throws {
        let (backup, manifest) = try sampleBackup()
        let db = try #require(manifest.databaseEntry)
        for bad in ["../escape.txt", "/etc/passwd", "a/../../b"] {
            let forged = BackupManifest(createdAtEpoch: 1, schemaVersion: 128, entries: manifest.entries + [
                BackupEntry(relativePath: bad, byteSize: 1, sha256: String(repeating: "0", count: 64), kind: .originalSource)])
            try JSONEncoder().encode(forged).write(to: backup.appendingPathComponent(BackupService.manifestName))
            let verdict = try BackupService().inspect(backupFolder: backup).verdict
            #expect(!verdict.ok, "\(bad) accepted")
            #expect(verdict.unsafe == [bad])
        }
        let dup = BackupManifest(createdAtEpoch: 1, schemaVersion: 128, entries: manifest.entries + [db])
        try JSONEncoder().encode(dup).write(to: backup.appendingPathComponent(BackupService.manifestName))
        #expect(!(try BackupService().inspect(backupFolder: backup).verdict.ok))
    }

    @Test("A ledger-only backup says so; the vault is not silently implied")
    func coverageIsStated() throws {
        let (backup, manifest) = try sampleBackup()
        #expect(manifest.coverage == .ledgerOnly)
        let verdict = try BackupService().inspect(backupFolder: backup).verdict
        #expect(verdict.ok)
        #expect(verdict.note.localizedCaseInsensitiveContains("vault"))
    }
}
