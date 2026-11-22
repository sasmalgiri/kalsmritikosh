//
//  ShardLedger.swift
//  Kalsmritikosh
//
//  Unified-path program (owner, 2026-11-22), PERF-16 — one import worker's OWN ledger. A shard is a
//  separate SQLite file beside the main ledger, `<ledger folder>/Shards/<run id>/<index>.sqlite`,
//  encrypted with the SAME key as the main ledger (so the main connection can ATTACH it for the merge)
//  and migrated to the current schema (`SchemaMigrations.latestVersion`). The worker runs the full
//  ingest pipeline against it through its own repositories and its own IngestCoordinator
//  (IngestStackBuilder), so workers never contend for the main ledger's write lock; each document is
//  still committed in the coordinator's normal small per-file transactions.
//
//  Right after migration the shard records, per table, the highest rowid the migration itself wrote
//  (seed rows), in `<index>.seed.json` beside the shard. The merge copies only rows above that mark, so
//  rows a migration seeds in every ledger are never copied twice.
//
//  Not tested yet (owner 2026-11-22: implement now, test later).
//

import Foundation
import os

public nonisolated struct ShardLedger: Sendable {
    public let runID: UUID
    public let index: Int
    public let url: URL
    public let database: Database

    /// `<ledger folder>/Shards`.
    public static func root(besideLedgerAt ledgerURL: URL) -> URL {
        ledgerURL.deletingLastPathComponent().appendingPathComponent("Shards", isDirectory: true)
    }

    /// `<ledger folder>/Shards/<run id>`.
    public static func folder(runID: UUID, besideLedgerAt ledgerURL: URL) -> URL {
        root(besideLedgerAt: ledgerURL).appendingPathComponent(runID.uuidString, isDirectory: true)
    }

    /// `<ledger folder>/Shards/<run id>/<index>.sqlite`.
    public static func fileURL(runID: UUID, index: Int, besideLedgerAt ledgerURL: URL) -> URL {
        folder(runID: runID, besideLedgerAt: ledgerURL).appendingPathComponent("\(index).sqlite", isDirectory: false)
    }

    /// The seed-mark file beside a shard.
    public static func seedURL(for shardURL: URL) -> URL {
        shardURL.deletingPathExtension().appendingPathExtension("seed.json")
    }

    /// Create (or reopen) shard `index` of `runID`, keyed with `key` (the main ledger's key; nil only
    /// when the main ledger itself is unencrypted), migrated to the current schema.
    public static func open(runID: UUID, index: Int, besideLedgerAt ledgerURL: URL, key: LedgerKey?) async throws -> ShardLedger {
        let url = fileURL(runID: runID, index: index, besideLedgerAt: ledgerURL)
        let fresh = !FileManager.default.fileExists(atPath: url.path)
        let db = try Database(url: url, key: key)
        try await SchemaMigrations.migrate(db)
        await db.tuneForStaging()
        let seedURL = seedURL(for: url)
        if fresh || !FileManager.default.fileExists(atPath: seedURL.path) {
            let marks = try await seedMarks(db)
            do {
                let data = try JSONEncoder().encode(marks)
                try data.write(to: seedURL, options: .atomic)
            } catch {
                KalsmritikoshLog.storage.error("ShardLedger: seed marks for shard \(index, privacy: .public) not written: \(error.localizedDescription, privacy: .private)")
                throw error
            }
        }
        return ShardLedger(runID: runID, index: index, url: url, database: db)
    }

    /// Fold the shard's write-ahead log into its file and close it, so the main connection can attach a
    /// self-contained file.
    public func close() async {
        do { _ = try await database.checkpointWAL() } catch {
            KalsmritikoshLog.storage.error("ShardLedger: checkpoint of shard \(index, privacy: .public) failed: \(error.localizedDescription, privacy: .private)")
        }
        await database.close()
    }

    /// Per table, the highest rowid present right after migration (WITHOUT ROWID and virtual tables
    /// are left out: the merge copies those by their natural keys).
    static func seedMarks(_ db: Database) async throws -> [String: Int64] {
        let tables = try await db.query(
            "SELECT name, COALESCE(sql, '') FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%';", [])
        var marks: [String: Int64] = [:]
        for row in tables {
            guard let name = row.string(0) else { continue }
            let sql = (row.string(1) ?? "").uppercased()
            if sql.hasPrefix("CREATE VIRTUAL TABLE") || sql.contains("WITHOUT ROWID") { continue }
            let quoted = ShardSQL.quoteIdent(name)
            marks[name] = try await db.query("SELECT COALESCE(MAX(rowid), 0) FROM \(quoted);", []).first?.int(0) ?? 0
        }
        return marks
    }

    /// The seed marks recorded beside `shardURL` (empty when the file is missing or unreadable — the
    /// merge then copies every row by its natural key).
    public static func loadSeedMarks(for shardURL: URL) -> [String: Int64] {
        let url = seedURL(for: shardURL)
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([String: Int64].self, from: data)
        } catch {
            KalsmritikoshLog.storage.error("ShardLedger: seed marks unreadable at \(url.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .private)")
            return [:]
        }
    }

    // MARK: Unified path PERF-20 (owner 2026-11-22, round 2) — not tested yet: sidecars that survive a quit

    /// The receipts of a shard's files, written when its worker finishes, so a shard merged at the NEXT
    /// launch still gets its intake receipts.
    public static func receiptsURL(for shardURL: URL) -> URL {
        shardURL.deletingPathExtension().appendingPathExtension("receipts.json")
    }

    /// Per integer-keyed table, the id offset its rows took in the main ledger (so a resumed merge can
    /// rebuild the id map of a table an interrupted merge already committed).
    public static func offsetsURL(for shardURL: URL) -> URL {
        shardURL.deletingPathExtension().appendingPathExtension("offsets.json")
    }

    public static func writeReceipts(_ lines: [ShardReceiptLine], for shardURL: URL) {
        do {
            try JSONEncoder().encode(lines).write(to: receiptsURL(for: shardURL), options: .atomic)
        } catch {
            KalsmritikoshLog.storage.error("ShardLedger: receipts of \(shardURL.lastPathComponent, privacy: .private) not written: \(error.localizedDescription, privacy: .private)")
        }
    }

    public static func loadReceipts(for shardURL: URL) -> [ShardReceiptLine] {
        let url = receiptsURL(for: shardURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do { return try JSONDecoder().decode([ShardReceiptLine].self, from: Data(contentsOf: url)) } catch {
            KalsmritikoshLog.storage.error("ShardLedger: receipts of \(shardURL.lastPathComponent, privacy: .private) unreadable: \(error.localizedDescription, privacy: .private)")
            return []
        }
    }

    public static func loadOffsets(for shardURL: URL) -> [String: Int64] {
        let url = offsetsURL(for: shardURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do { return try JSONDecoder().decode([String: Int64].self, from: Data(contentsOf: url)) } catch {
            KalsmritikoshLog.storage.error("ShardLedger: id offsets of \(shardURL.lastPathComponent, privacy: .private) unreadable: \(error.localizedDescription, privacy: .private)")
            return [:]
        }
    }

    public static func writeOffsets(_ offsets: [String: Int64], for shardURL: URL) {
        do {
            try JSONEncoder().encode(offsets).write(to: offsetsURL(for: shardURL), options: .atomic)
        } catch {
            KalsmritikoshLog.storage.error("ShardLedger: id offsets of \(shardURL.lastPathComponent, privacy: .private) not written: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Remove a merged shard: its file, its write-ahead-log sidecars and its seed marks; the run folder
    /// too once it is empty.
    public static func removeFiles(at shardURL: URL) {
        let fm = FileManager.default
        for u in [shardURL, URL(fileURLWithPath: shardURL.path + "-wal"), URL(fileURLWithPath: shardURL.path + "-shm"),
                  seedURL(for: shardURL), receiptsURL(for: shardURL), offsetsURL(for: shardURL)] where fm.fileExists(atPath: u.path) {
            do { try fm.removeItem(at: u) } catch {
                KalsmritikoshLog.storage.error("ShardLedger: could not remove \(u.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .private)")
            }
        }
        let folder = shardURL.deletingLastPathComponent()
        do {
            if try fm.contentsOfDirectory(atPath: folder.path).isEmpty { try fm.removeItem(at: folder) }
        } catch {
            KalsmritikoshLog.storage.error("ShardLedger: run folder not tidied: \(error.localizedDescription, privacy: .private)")
        }
    }
}

/// One intake receipt a shard owes once it is merged (PERF-20).
public nonisolated struct ShardReceiptLine: Codable, Sendable {
    public let run: UUID
    public let path: String
    public let channel: IntakeChannel
    public let sourceVersionID: UUID?
    public let intakeOutcome: SourceIntakeOutcome?
    public init(run: UUID, path: String, channel: IntakeChannel, sourceVersionID: UUID?, intakeOutcome: SourceIntakeOutcome?) {
        self.run = run; self.path = path; self.channel = channel
        self.sourceVersionID = sourceVersionID; self.intakeOutcome = intakeOutcome
    }
}

extension Database {
    /// Unified path PERF-19 (owner 2026-11-22, round 2) — not tested yet: a SHARD connection only (staging, merged
    /// and deleted afterwards): a larger page cache, temp tables in memory and a rarer automatic checkpoint, so
    /// a worker's many small commits stay cheap. The shard keeps WAL + synchronous=NORMAL from the common
    /// open; the main ledger's settings are not touched.
    func tuneForStaging() {
        for pragma in ["PRAGMA cache_size=-65536;", "PRAGMA temp_store=MEMORY;", "PRAGMA wal_autocheckpoint=8000;",
                       "PRAGMA synchronous=NORMAL;"] {
            do { try execRaw(pragma) } catch {
                KalsmritikoshLog.storage.error("ShardLedger: \(pragma, privacy: .public) not applied: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

/// Small SQL text helpers shared by the shard ledger and the merge.
nonisolated enum ShardSQL {
    static func quoteIdent(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    static func quoteLiteral(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }
}
