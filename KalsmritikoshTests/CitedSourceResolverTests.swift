//
//  CitedSourceResolverTests.swift
//  KalsmritikoshTests
//
//  SRC-01 / SRC-08 — a citation opens the version it cites. The file on disk is opened only when its
//  bytes are the cited version; a superseded version opens its kept copy labelled "A newer version
//  exists", or is reported unavailable; a changed, missing or erased version is reported with its reason.
//  Never a silent fallback to the newer document.
//

import Foundation
import CryptoKit
import Testing
@testable import Kalsmritikosh

@Suite("Cited source version (SRC-01/SRC-08)")
struct CitedSourceResolverTests {

    struct Fixture { let db: Database; let dir: URL; let ledger: URL }

    static func fixture() async throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("src08-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ledger = dir.appendingPathComponent("knowledge.sqlite")
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion, at: ledger)
        return Fixture(db: db, dir: dir, ledger: ledger)
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    @discardableResult
    static func version(_ f: Fixture, logical: UUID, bytes: Data, current: Bool, url: URL?) async throws -> UUID {
        let id = UUID()
        try await f.db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, original_url, created_at, filename,
                                         custody_mode, preservation_status)
            VALUES (?,?,?,?,?,?,?,?,'referenced','referenceRecorded');
            """, [.uuid(id), .uuid(logical), .text(hash(bytes)), .real(1), .integer(current ? 1 : 0),
                  url.map { .text($0.absoluteString) } ?? .null, .real(1), .text("contract.txt")])
        return id
    }

    @Test("The current file opens only when its bytes are the cited version; edited since → 'cited version unavailable', not the edited file")
    func currentFileVerifiedByHash() async throws {
        let f = try await Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let file = f.dir.appendingPathComponent("contract.txt")
        let cited = Data("The fee is 10,000.".utf8)
        try cited.write(to: file)
        let v = try await Self.version(f, logical: UUID(), bytes: cited, current: true, url: file)
        #expect(try await CitedSourceResolver.resolve(sourceVersionID: v, objectID: nil, database: f.db, ledgerURL: f.ledger) == .open(file, note: nil))
        // The file is edited on disk after it was cited (not yet re-read): it is NOT opened under the citation.
        try Data("The fee is 90,000.".utf8).write(to: file)
        #expect(try await CitedSourceResolver.resolve(sourceVersionID: v, objectID: nil, database: f.db, ledgerURL: f.ledger) == .unavailable(.changedOnDisk))
        #expect(CitedSourceResolver.Unavailable.changedOnDisk.label.hasPrefix("Cited version unavailable"))
        // Gone from disk.
        try FileManager.default.removeItem(at: file)
        #expect(try await CitedSourceResolver.resolve(sourceVersionID: v, objectID: nil, database: f.db, ledgerURL: f.ledger) == .unavailable(.missingOriginal))
    }

    @Test("A superseded cited version opens its kept copy labelled 'A newer version exists'; without a copy it is unavailable — never the newer file")
    func supersededVersion() async throws {
        let f = try await Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let logical = UUID()
        let file = f.dir.appendingPathComponent("contract.txt")
        let old = Data("Version 1: the fee is 10,000.".utf8), new = Data("Version 2: the fee is 12,000.".utf8)
        try new.write(to: file)                              // the file on disk is now the newer version
        let v1 = try await Self.version(f, logical: logical, bytes: old, current: false, url: file)
        let v2 = try await Self.version(f, logical: logical, bytes: new, current: true, url: file)
        // No kept copy of v1: unavailable (superseded) — the newer file at the same path is not substituted.
        #expect(try await CitedSourceResolver.resolve(sourceVersionID: v1, objectID: nil, database: f.db, ledgerURL: f.ledger) == .unavailable(.superseded))
        #expect(CitedSourceResolver.Unavailable.superseded.label.contains("a newer version of this document exists"))
        // The newer version itself opens the file normally.
        #expect(try await CitedSourceResolver.resolve(sourceVersionID: v2, objectID: nil, database: f.db, ledgerURL: f.ledger) == .open(file, note: nil))
        // With v1's bytes kept in the vault: the kept copy opens, labelled.
        let h = Self.hash(old)
        let shard = f.dir.appendingPathComponent("EvidenceVault/\(h.prefix(2))", isDirectory: true)
        try FileManager.default.createDirectory(at: shard, withIntermediateDirectories: true)
        let kept = shard.appendingPathComponent(h)
        try old.write(to: kept)
        guard case .open(let url, let note) = try await CitedSourceResolver.resolve(sourceVersionID: v1, objectID: nil, database: f.db, ledgerURL: f.ledger) else {
            Issue.record("the kept copy was not opened"); return
        }
        // S2 — opened under the version's own file name (so a viewer sees its name and type), same bytes.
        #expect(url.lastPathComponent == "contract.txt" && note == CitedSourceResolver.newerVersionNote)
        #expect(try Data(contentsOf: url) == old, "the cited words, not the newer document")
    }

    @Test("An erased version is unavailable; a citation with no version says it shows the current file")
    func erasedAndUnpinned() async throws {
        let f = try await Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        #expect(try await CitedSourceResolver.resolve(sourceVersionID: UUID(), objectID: nil, database: f.db, ledgerURL: f.ledger) == .unavailable(.erased))
        #expect(try await CitedSourceResolver.resolve(sourceVersionID: nil, objectID: UUID(), database: f.db, ledgerURL: f.ledger) == .unavailable(.missingOriginal))
    }
}
