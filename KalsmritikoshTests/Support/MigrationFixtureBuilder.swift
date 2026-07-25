//
//  MigrationFixtureBuilder.swift
//  KalsmritikoshTests · Support
//
//  MIG-001A — build GENUINE intermediate-version databases from the real migration history
//  (SchemaMigrations.migrate(_:through:)) and seed era-accurate preservation rows into them.
//
//  Two rules keep the fixtures honest and era-safe:
//   1. No committed opaque SQLite binaries — every synthetic fixture is reproduced from the
//      committed migration list at test time. (Committed DBs are reserved for a sanitized real
//      archive, handled in MIG-001B.)
//   2. Never insert into a table or column that did not exist at the selected version. Seeding is
//      COLUMN-AWARE: a row is written only when its table AND every target column already exist at
//      that version. So the same seed set degrades correctly on old schemas (e.g. claims + reviews
//      are simply skipped before v63) without a hand-maintained per-version matrix.
//

import Foundation
@testable import Kalsmritikosh

/// A recorded set of preservation checks captured at seed time and re-run after migration.
struct MigrationFixtureSnapshot {
    struct Check { let description: String; let sql: String; let params: [SQLValue]; let expected: Int }
    private(set) var checks: [Check] = []
    /// Tables that actually received at least one seeded row at the chosen version.
    private(set) var seededTables: [String] = []

    mutating func record(_ description: String, sql: String, params: [SQLValue], expected: Int, table: String) {
        checks.append(Check(description: description, sql: sql, params: params, expected: expected))
        if !seededTables.contains(table) { seededTables.append(table) }
    }

    /// Re-run every recorded check against `db`; return the descriptions of any that no longer hold.
    /// Empty result == every seeded row survived (counts unchanged).
    func failures(in db: Database) async throws -> [String] {
        var failed: [String] = []
        for c in checks {
            let rows = try await db.query(c.sql, c.params)
            let actual = Int(rows.first?.int(0) ?? -1)
            if actual != c.expected { failed.append("\(c.description): expected \(c.expected), got \(actual)") }
        }
        return failed
    }
}

enum MigrationFixtureBuilder {

    // MARK: - Database construction

    static func newTemporaryURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mig-\(UUID().uuidString).sqlite")
    }

    /// A GENUINE database at exactly `version`, built by replaying the committed migration list
    /// `1...version` (version 0 = a fresh, unmigrated database). Uses a fresh temp file.
    @discardableResult
    static func database(atVersion version: Int) async throws -> Database {
        try await database(atVersion: version, at: newTemporaryURL())
    }

    /// Same, at an explicit URL — so a test can reopen the SAME file with a new `Database` instance.
    static func database(atVersion version: Int, at url: URL) async throws -> Database {
        let db = try Database(url: url)
        if version >= 1 { try await SchemaMigrations.migrate(db, through: version) }
        return db
    }

    /// Reopen an already-migrated database file with a fresh `Database` instance (no migration).
    static func reopen(at url: URL) throws -> Database { try Database(url: url) }

    // MARK: - Schema introspection

    static func tableExists(_ db: Database, _ table: String) async throws -> Bool {
        let rows = try await db.query("PRAGMA table_info(\(table));", [])
        return !rows.isEmpty
    }

    static func columns(_ db: Database, _ table: String) async throws -> Set<String> {
        let rows = try await db.query("PRAGMA table_info(\(table));", [])
        return Set(rows.compactMap { $0.string(1) })
    }

    // MARK: - Era-accurate seeding

    /// Seed a small, FK-consistent set of preservation-critical rows into `db`, inserting each row
    /// ONLY when its table + all target columns exist at `version`. Returns a snapshot of checks
    /// that must still hold after migrating to the latest version. FK-safe insert order:
    /// files → workspaces → knowledge_objects → workspace_sources → claims → claim_evidence_ref
    /// → claim_reviews → claim_usage → claim_projection_progress.
    static func seedPreservationRows(into db: Database, forVersion version: Int) async throws -> MigrationFixtureSnapshot {
        var snap = MigrationFixtureSnapshot()
        let fileID = UUID().uuidString
        let koID = UUID().uuidString
        let wsID = UUID().uuidString
        let claimID = UUID().uuidString
        let subjectID = UUID().uuidString
        let reviewID = UUID().uuidString
        let usageID = UUID().uuidString

        // files (FK-free; present from the earliest schema)
        try await insertIfShaped(db, table: "files",
            values: ["id": .text(fileID), "url": .text("file:///mig/\(fileID)"), "source_type": .text("txt")],
            idCheck: ("files row", "SELECT COUNT(*) FROM files WHERE id=?;", [.text(fileID)]), into: &snap)

        // workspaces (FK-free; column is template_type, not template; created_at/updated_at are
        // NOT NULL without a default, so they must be provided).
        try await insertIfShaped(db, table: "workspaces",
            values: ["id": .text(wsID), "title": .text("Mig WS"), "template_type": .text("general"),
                     "created_at": .real(0), "updated_at": .real(0)],
            idCheck: ("workspaces row", "SELECT COUNT(*) FROM workspaces WHERE id=?;", [.text(wsID)]), into: &snap)

        // knowledge_objects (FK file_id→files ✓ — file seeded above)
        try await insertIfShaped(db, table: "knowledge_objects",
            values: ["id": .text(koID), "file_id": .text(fileID), "source_type": .text("txt"),
                     "content": .text("c"), "created_at": .real(0), "updated_at": .real(0)],
            idCheck: ("knowledge_objects row", "SELECT COUNT(*) FROM knowledge_objects WHERE id=?;", [.text(koID)]), into: &snap)

        // workspace_sources (FK workspace+file ✓ — both seeded above)
        try await insertIfShaped(db, table: "workspace_sources",
            values: ["workspace_id": .text(wsID), "file_id": .text(fileID), "added_at": .real(0)],
            idCheck: ("workspace_sources row", "SELECT COUNT(*) FROM workspace_sources WHERE workspace_id=? AND file_id=?;",
                      [.text(wsID), .text(fileID)]), into: &snap)

        // claims (FK-free; v63+). Seeded WITHOUT scope columns even at v67 — the migration must
        // never invent scope, so scope_kind/scope_id stay NULL for a row that predates reprojection.
        try await insertIfShaped(db, table: "claims",
            values: ["id": .text(claimID), "subject_id": .text(subjectID), "subject_label": .text("S"),
                     "statement": .text("employer: Orchid"), "confidence": .real(0.8), "created_at": .real(1000),
                     "evidence_basis": .text("directlyObserved"), "review_disposition": .text("unreviewed"),
                     "proposal_origin": .text("sourceExtraction"), "availability_status": .text("available"),
                     "conflict_status": .text("none")],
            idCheck: ("claims row", "SELECT COUNT(*) FROM claims WHERE id=?;", [.text(claimID)]), into: &snap)

        // claim_evidence_ref (FK-free). At v63 there is NO `ordinal` column (added v64); the
        // column-aware insert omits it, and the v64 rebuild assigns one via ROW_NUMBER — the
        // seeded reference must survive that table rebuild.
        try await insertIfShaped(db, table: "claim_evidence_ref",
            values: ["claim_id": .text(claimID), "ordinal": .integer(0), "knowledge_object_id": .text(koID),
                     "evidence_role": .text("supports")],
            idCheck: ("claim_evidence_ref row", "SELECT COUNT(*) FROM claim_evidence_ref WHERE claim_id=?;", [.text(claimID)]),
            into: &snap)

        // claim_reviews (FK-free; v63+)
        try await insertIfShaped(db, table: "claim_reviews",
            values: ["id": .text(reviewID), "claim_id": .text(claimID), "disposition": .text("confirmed"),
                     "reviewer": .text("u"), "reviewed_at": .real(1001)],
            idCheck: ("claim_reviews row", "SELECT COUNT(*) FROM claim_reviews WHERE id=?;", [.text(reviewID)]), into: &snap)

        // claim_usage (FK-free; v63+)
        try await insertIfShaped(db, table: "claim_usage",
            values: ["id": .text(usageID), "claim_id": .text(claimID), "context": .text("workProduct"),
                     "used_at": .real(1002)],
            idCheck: ("claim_usage row", "SELECT COUNT(*) FROM claim_usage WHERE id=?;", [.text(usageID)]), into: &snap)

        // claim_projection_progress (FK-free; v65+)
        try await insertIfShaped(db, table: "claim_projection_progress",
            values: ["producer_version": .text("claim-producer-3"), "source_kind": .text("event"),
                     "last_source_id": .text(UUID().uuidString), "complete": .integer(1), "updated_at": .real(1003)],
            idCheck: ("claim_projection_progress row",
                      "SELECT COUNT(*) FROM claim_projection_progress WHERE producer_version=? AND source_kind=?;",
                      [.text("claim-producer-3"), .text("event")]), into: &snap)

        return snap
    }

    /// Insert one row into `table` ONLY when the table and every named column exist at this version;
    /// otherwise skip silently (era-safe). On a successful insert, record the preservation check.
    private static func insertIfShaped(_ db: Database, table: String, values: [String: SQLValue],
                                       idCheck: (String, String, [SQLValue]), into snap: inout MigrationFixtureSnapshot) async throws {
        guard try await tableExists(db, table) else { return }
        let present = try await columns(db, table)
        // Deterministic column order for a stable statement.
        let cols = values.keys.sorted()
        guard present.isSuperset(of: cols) else { return }
        let placeholders = cols.map { _ in "?" }.joined(separator: ",")
        let params = cols.map { values[$0]! }
        try await db.exec("INSERT INTO \(table) (\(cols.joined(separator: ","))) VALUES (\(placeholders));", params)
        snap.record(idCheck.0, sql: idCheck.1, params: idCheck.2, expected: 1, table: table)
    }
}
