//
//  BackupManifestTests.swift
//  KalsmritikoshTests
//
//  G2/Stage-11 / AT-15 — the backup/restore core is deterministic and
//  honest: a db copy with missing originals is reported incomplete. Pure.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("G2 backup manifest")
struct BackupManifestTests {

    private func entry(_ path: String, _ kind: BackupEntry.Kind, _ size: Int64 = 1) -> BackupEntry {
        BackupEntry(relativePath: path, byteSize: size, sha256: "hash-\(path)", kind: kind)
    }

    @Test func entriesAreDeterministicallyOrderedAndTotalled() {
        let m = BackupPlanner.manifest(schemaVersion: 128, createdAtEpoch: 1_700_000_000, entries: [
            entry("z-original.pdf", .originalSource, 10),
            entry("knowledge.sqlite", .database, 100),
            entry("a-original.eml", .originalSource, 5),
        ])
        #expect(m.entries.map(\.relativePath) == ["a-original.eml", "knowledge.sqlite", "z-original.pdf"])
        #expect(m.totalBytes == 115)
        #expect(m.databaseEntry?.relativePath == "knowledge.sqlite")
    }

    @Test func restoreIncompleteWhenAnOriginalIsMissing() {
        let m = BackupPlanner.manifest(schemaVersion: 128, createdAtEpoch: 1, entries: [
            entry("knowledge.sqlite", .database), entry("a.eml", .originalSource), entry("b.pdf", .originalSource),
        ])
        let v = RestoreValidator.validate(manifest: m, presentPaths: ["knowledge.sqlite", "a.eml"])
        #expect(v.ok == false, "a db copy with a missing original is not a valid restore")
        #expect(v.missing == ["b.pdf"])
    }

    @Test func restoreOKWhenEverythingPresent() {
        let m = BackupPlanner.manifest(schemaVersion: 128, createdAtEpoch: 1, entries: [
            entry("knowledge.sqlite", .database), entry("a.eml", .originalSource),
        ])
        let v = RestoreValidator.validate(manifest: m, presentPaths: ["knowledge.sqlite", "a.eml"])
        #expect(v.ok == true)
        #expect(v.missing.isEmpty)
    }

    @Test func restoreFailsWithoutADatabase() {
        let m = BackupPlanner.manifest(schemaVersion: 128, createdAtEpoch: 1, entries: [entry("a.eml", .originalSource)])
        #expect(RestoreValidator.validate(manifest: m, presentPaths: ["a.eml"]).ok == false)
    }

    @Test func manifestCodableRoundTrips() throws {
        let m = BackupPlanner.manifest(schemaVersion: 128, createdAtEpoch: 42, entries: [
            entry("knowledge.sqlite", .database), entry("a.eml", .originalSource),
        ])
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(BackupManifest.self, from: data)
        #expect(back == m)
    }
}
