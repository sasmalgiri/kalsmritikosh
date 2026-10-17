//
//  SQLiteAcquisitionTests.swift
//  KalsmritikoshTests
//
//  F03 (residual, 2026-09-29 review) — a live WAL database was captured as main file + sidecar, but
//  its identity was the MAIN hash, the vault kept only the main file, and the structural parser
//  re-materialised main bytes alone. A WAL-only commit was deduplicated as "unchanged", and every
//  downstream reader except the first loader pass lost the WAL rows. A live WAL database is now
//  acquired as ONE coherent logical derivative (SQLite online backup inside a read transaction);
//  its hash is the version identity, and loader, parser, vault and reopen all read that derivative.
//

import Foundation
import CryptoKit
import SQLite3
import Testing
@testable import Kalsmritikosh

@Suite("F03 — a live SQLite database is acquired as one coherent derivative", .serialized)
@MainActor
struct SQLiteAcquisitionTests {

    /// A WAL database whose table (and first row) is checkpointed into the main file, with
    /// `walRows` further rows committed ONLY to the WAL. The writer stays open.
    private final class LiveDB {
        let dir: URL, url: URL
        var writer: OpaquePointer?
        init(walRows: Int) throws {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("acq-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            url = dir.appendingPathComponent("live.db")
            guard sqlite3_open_v2(url.path, &writer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
                throw CocoaError(.fileWriteUnknown)
            }
            try exec("PRAGMA journal_mode=WAL;", "PRAGMA wal_autocheckpoint=0;",
                     "CREATE TABLE m(id INTEGER PRIMARY KEY, body TEXT);",
                     "INSERT INTO m(body) VALUES('main-row');", "PRAGMA wal_checkpoint(TRUNCATE);")
            try commit(walRows, from: 1)
        }
        func exec(_ sqls: String...) throws {
            for sql in sqls where sqlite3_exec(writer, sql, nil, nil, nil) != SQLITE_OK {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSDebugDescriptionErrorKey: sql])
            }
        }
        func commit(_ n: Int, from start: Int) throws {
            guard n > 0 else { return }
            try exec("BEGIN;")
            for i in start..<(start + n) { try exec("INSERT INTO m(body) VALUES('wal-row-\(i)');") }
            try exec("COMMIT;")
        }
        func mainHash() throws -> String {
            SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        deinit { sqlite3_close(writer); try? FileManager.default.removeItem(at: dir) }
    }

    private func rows(_ snapshot: URL) async throws -> String {
        try await SQLiteLoader().ingestMany(fileAt: snapshot, type: .sqlite).map(\.content).joined(separator: "\n")
    }

    @Test("A WAL-only commit is a NEW acquisition although the main file's bytes never change; no change is the same identity")
    func walOnlyChangeIsNewAcquisition() async throws {
        let live = try LiveDB(walRows: 3)
        let main0 = try live.mainHash()
        let a = try SourceByteCapture.captureToSnapshot(live.url, snapshotDirectory: live.dir.appendingPathComponent("s1"))
        let again = try SourceByteCapture.captureToSnapshot(live.url, snapshotDirectory: live.dir.appendingPathComponent("s2"))
        #expect(a.captured.contentHash == again.captured.contentHash, "an unchanged database must keep its identity")
        try live.commit(1, from: 4)
        #expect(try live.mainHash() == main0, "fixture: the new row lives only in the WAL")
        let b = try SourceByteCapture.captureToSnapshot(live.url, snapshotDirectory: live.dir.appendingPathComponent("s3"))
        #expect(a.captured.contentHash != b.captured.contentHash, "a WAL-only commit was deduplicated as unchanged")
        // The snapshot is ONE self-contained file carrying every committed row.
        #expect(!FileManager.default.fileExists(atPath: b.snapshotURL.path + "-wal"))
        let text = try await rows(b.snapshotURL)
        for i in 1...4 { #expect(text.contains("wal-row-\(i)"), "row \(i) lost") }
        #expect(a.captured.sqliteAcquisition?.method == "sqliteOnlineBackup")
        #expect(a.captured.sqliteAcquisition?.members.map(\.role) == ["main", "wal"])
    }

    private struct Rig { let c: IngestCoordinator; let db: Database; let vault: EvidenceVault; let dir: URL }

    private func rig(_ dir: URL) async throws -> Rig {
        let db = try Database(url: dir.appendingPathComponent("ledger.sqlite"))
        try await SchemaMigrations.migrate(db); try await db.exec("PRAGMA foreign_keys = ON;")
        let vault = EvidenceVault(root: dir.appendingPathComponent("vault", isDirectory: true))
        let intake = UniversalSourceIntakeCoordinator(repository: CanonicalSourceIntakeRepository(database: db, vault: vault))
        let c = IngestCoordinator(
            universalRegistry: try UniversalParserRegistryBuilder.standard(ocr: VisionOCR()),
            entityExtractor: NLEntityExtractor(), entityLinker: EntityLinker(), eventExtractor: RuleEventExtractor(),
            files: FilesRepository(database: db), objects: KnowledgeObjectRepository(database: db),
            chunks: ChunksRepository(database: db), evidenceStore: EvidenceStore(database: db),
            ingestAttempts: IngestAttemptsRepository(database: db), sourceRelations: SourceRelationsRepository(database: db),
            evidenceVault: vault, readiness: SourceReadinessRepository(database: db),
            containerInspection: ContainerInspectionRepository(database: db), intakeCoordinator: intake,
            custodyModeOverride: .managed)
        await c.configureUpgrades(database: db, jobs: SourceUpgradeJobRepository(database: db))
        return Rig(c: c, db: db, vault: vault, dir: dir)
    }

    @Test("Structure, the managed vault copy and re-intake all carry the WAL rows; an earlier version reopens to its own state")
    func pipelineKeepsAcquiredState() async throws {
        let live = try LiveDB(walRows: 3)
        let ledgerDir = live.dir.appendingPathComponent("ledger", isDirectory: true)
        try FileManager.default.createDirectory(at: ledgerDir, withIntermediateDirectories: true)
        let r = try await rig(ledgerDir)
        let v1 = try #require(try await r.c.ingest(fileAt: live.url).sourceVersionID)

        let blocks = try await EvidenceStore(database: r.db).blocks(forVersion: v1).map(\.rawText).joined(separator: "\n")
        for i in 1...3 { #expect(blocks.contains("wal-row-\(i)"), "structural row \(i) lost") }

        let resolver = SourceVersionByteResolver(database: r.db, vault: r.vault)
        let reopened = try await resolver.resolve(sourceVersionID: v1, at: Date())
        defer { try? FileManager.default.removeItem(at: reopened.cleanupDirectory) }
        let reopenedText = try await rows(reopened.snapshotURL)
        for i in 1...3 { #expect(reopenedText.contains("wal-row-\(i)"), "vault copy lost row \(i)") }

        try live.commit(1, from: 4)
        let v2 = try #require(try await r.c.ingest(fileAt: live.url).sourceVersionID)
        #expect(v2 != v1, "a WAL-only commit must create a new version")
        let blocks2 = try await EvidenceStore(database: r.db).blocks(forVersion: v2).map(\.rawText).joined(separator: "\n")
        #expect(blocks2.contains("wal-row-4"))

        // Reprocessing the EARLIER version uses its own acquired state — three WAL rows, not four.
        let earlier = try await resolver.resolve(sourceVersionID: v1, at: Date())
        defer { try? FileManager.default.removeItem(at: earlier.cleanupDirectory) }
        let earlierText = try await rows(earlier.snapshotURL)
        #expect(earlierText.contains("wal-row-3") && !earlierText.contains("wal-row-4"))
    }

    @Test("Captures taken while a writer commits and checkpoints are coherent or refused — never a mixed state")
    func concurrentWritesNeverMix() async throws {
        let live = try LiveDB(walRows: 0)
        let writerURL = live.url
        let stop = Atomic()
        let writer = Thread {
            var h: OpaquePointer?
            guard sqlite3_open_v2(writerURL.path, &h, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return }
            sqlite3_busy_timeout(h, 2_000)
            var n = 100
            while !stop.isSet {
                n += 1
                sqlite3_exec(h, "INSERT INTO m(body) VALUES('w-\(n)');", nil, nil, nil)
                if n.isMultiple(of: 7) { sqlite3_exec(h, "PRAGMA wal_checkpoint(PASSIVE);", nil, nil, nil) }
            }
            sqlite3_close(h)
        }
        writer.start()
        defer { stop.set() }
        var coherent = 0
        for i in 0..<12 {
            do {
                let c = try SourceByteCapture.captureToSnapshot(live.url, snapshotDirectory: live.dir.appendingPathComponent("c\(i)"))
                // Every row id from 1 to the maximum is present exactly once: a mixed main/WAL pair
                // would lose checkpointed rows or show gaps.
                let src = try ExternalSQLiteSource(originalPath: c.snapshotURL)
                let stats = try src.query("SELECT COUNT(*), MAX(id), MIN(id) FROM m;").first?.cells
                #expect(stats?[0].int64 == stats?[1].int64 && stats?[2].int64 == 1, "capture \(i) is not a coherent state")
                #expect(DatabaseQuickCheck.passes(c.snapshotURL))
                coherent += 1
            } catch SourceIntakeError.sourceChangedDuringCapture {
                // An explicit refusal is allowed; a silent mixed success is not.
            }
        }
        #expect(coherent > 0, "the live backup path should succeed while a writer is active")
    }

    @Test("A version captured before logical acquisition (WAL not preserved) is refused on reopen, never re-read from main bytes")
    func legacyIncompleteAcquisitionRefused() async throws {
        let live = try LiveDB(walRows: 2)
        let ledgerDir = live.dir.appendingPathComponent("ledger", isDirectory: true)
        try FileManager.default.createDirectory(at: ledgerDir, withIntermediateDirectories: true)
        let r = try await rig(ledgerDir)
        let v1 = try #require(try await r.c.ingest(fileAt: live.url).sourceVersionID)
        // Simulate the pre-v136 shape, then re-run the v136 marking statement over it.
        try await r.db.exec("UPDATE source_intake_receipts SET detail = '{\"sqliteSidecars\":[]}' WHERE source_version_id = ?;", [.uuid(v1)])
        try await r.db.exec("""
            UPDATE source_versions SET acquisition_limitation = 'walNotPreserved'
             WHERE id IN (SELECT source_version_id FROM source_intake_receipts WHERE detail LIKE '%"sqliteSidecars"%');
            """)
        let resolver = SourceVersionByteResolver(database: r.db, vault: r.vault)
        await #expect(throws: SourceUpgradeError.acquisitionIncomplete(v1)) {
            _ = try await resolver.resolve(sourceVersionID: v1, at: Date())
        }
        // The historical evidence is untouched.
        #expect(!(try await EvidenceStore(database: r.db).blocks(forVersion: v1)).isEmpty)
    }

    @Test("A plain SQLite file without a WAL keeps its exact bytes (no derivative)")
    func plainSQLiteKeepsExactBytes() throws {
        let live = try LiveDB(walRows: 0)
        try live.exec("PRAGMA wal_checkpoint(TRUNCATE);", "PRAGMA journal_mode=DELETE;")
        let c = try SourceByteCapture.captureToSnapshot(live.url, snapshotDirectory: live.dir.appendingPathComponent("p"))
        #expect(c.captured.contentHash == (try live.mainHash()))
        #expect(c.captured.sqliteAcquisition == nil)
    }
}

/// A tiny thread-safe flag for the writer thread.
private final class Atomic: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

private enum DatabaseQuickCheck {
    static func passes(_ url: URL) -> Bool { Database.quickCheck(fileAt: url) == nil }
}
