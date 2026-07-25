//
//  MigrationFaultHarness.swift
//  KalsmritikoshTests · Support
//
//  MIG-001B — shared helpers for migration fault-injection + real-archive verification. The fault
//  hooks are passed EXPLICITLY into SchemaMigrations.migrate(_:through:fault:) (never a global), so
//  concurrent tests are independent; production always passes nil.
//

import Foundation
import CryptoKit
@testable import Kalsmritikosh

/// A deterministic injected failure, distinct from a genuine SQLite error.
struct InjectedMigrationFault: Error, Equatable {}

enum MigrationFaultHarness {

    /// A hook that throws `InjectedMigrationFault` exactly at `point` and is a no-op elsewhere.
    static func hook(throwingAt point: MigrationFaultPoint) -> MigrationFaultHook {
        { firing in if firing == point { throw InjectedMigrationFault() } }
    }

    // MARK: - Synthetic migration batches (genuine SQLite failures, not injected throws)

    /// A batch whose EARLIER statements are valid DDL and whose FINAL statement is a genuine SQLite
    /// error (query of a missing table) — so the failure occurs AFTER real DDL ran in the SAVEPOINT.
    static let ddlFaultBatch = """
    CREATE TABLE mig_fault_probe (id TEXT PRIMARY KEY NOT NULL);
    CREATE INDEX idx_mig_fault_probe ON mig_fault_probe(id);
    SELECT * FROM definitely_missing_table;
    """

    /// The valid retry of the DDL batch (no failing trailing statement).
    static let ddlValidBatch = """
    CREATE TABLE mig_fault_probe (id TEXT PRIMARY KEY NOT NULL);
    CREATE INDEX idx_mig_fault_probe ON mig_fault_probe(id);
    """

    /// A batch that MUTATES existing rows and then hits a genuine SQLite failure — so the backfill
    /// must roll back to the original values.
    static func backfillFaultBatch(newURL: String) -> String {
        """
        UPDATE files SET url = '\(newURL)';
        SELECT * FROM definitely_missing_table;
        """
    }

    static func backfillValidBatch(newURL: String) -> String {
        "UPDATE files SET url = '\(newURL)';"
    }

    // MARK: - Integrity helpers

    static func integrityOK(_ db: Database) async throws -> Bool {
        try await db.query("PRAGMA integrity_check;", []).first?.string(0) == "ok"
    }

    static func foreignKeyViolationCount(_ db: Database) async throws -> Int {
        try await db.query("PRAGMA foreign_key_check;", []).count
    }

    static func pageCount(_ db: Database) async throws -> Int {
        Int(try await db.query("PRAGMA page_count;", []).first?.int(0) ?? 0)
    }

    // MARK: - File hashing (real-archive methodology)

    /// SHA-256 of a database file's bytes. Used to prove the ORIGINAL archive is untouched and that
    /// a migrated working copy's bytes differ (a real migration changes the file).
    static func sha256OfFile(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
