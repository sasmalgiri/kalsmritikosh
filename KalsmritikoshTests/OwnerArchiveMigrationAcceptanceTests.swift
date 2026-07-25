//
//  OwnerArchiveMigrationAcceptanceTests.swift
//  KalsmritikoshTests
//
//  MIG-001C — EXTERNAL sanitized-archive migration acceptance. Unlike RealArchiveMigrationTests
//  (which builds its own synthetic archive), this suite accepts an owner-supplied archive via
//  environment variables and runs the REAL application migration path on a disposable WORKING COPY
//  (never the original — ci/migrations/verify-real-archive.sh owns the original-hash guard and the
//  copy). Both tests are env-gated and SKIP in normal/CI runs — a skip is never verification.
//
//  Env (passed by the script as TEST_RUNNER_-prefixed xcodebuild vars):
//    KALS_OWNER_ARCHIVE          absolute path to the WORKING COPY sqlite file
//    KALS_OWNER_ARCHIVE_MANIFEST absolute path to the manifest JSON
//                                (schema: ci/migrations/real-archive-manifest.schema.json)
//    KALS_OWNER_ARCHIVE_REPORT   where to write the non-sensitive acceptance report JSON
//    KALS_GENERATE_SYNTHETIC_ARCHIVE / _MANIFEST — self-test generator outputs (developer use)
//

import Foundation
import Testing
@testable import Kalsmritikosh

/// The owner-archive manifest (see ci/migrations/real-archive-manifest.schema.json).
private struct OwnerArchiveManifest: Codable {
    struct Representative: Codable {
        var sourceVersionID: String?
        var contentHash: String?
        var fileID: String?
    }
    let fixtureID: String
    let originalSchemaVersion: Int
    let sanitizerVersion: String
    let containsPersonalData: Bool
    let sourceDatabaseSHA256: String
    let expectedEndVersion: Int
    let expectedCounts: [String: Int]
    let representative: Representative
}

/// Non-sensitive acceptance report — counts, versions and hashes only; never content.
private struct OwnerArchiveAcceptanceReport: Codable {
    let fixtureID: String
    let startVersion: Int
    let endVersion: Int
    let workingCopyHashBeforeMigration: String
    let workingCopyHashAfterMigration: String
    let counts: [String: Int]
    let stableIDSampleSize: Int
    let representativeReopened: String
    let integrityOK: Bool
    let foreignKeyViolations: Int
    let secondMigrationNoOp: Bool
    let freshReopenOK: Bool
}

@Suite("MIG-001C — owner-archive migration acceptance")
struct OwnerArchiveMigrationAcceptanceTests {

    private static let env = ProcessInfo.processInfo.environment

    /// Count-preserved tables (only those that exist at the archive's version are captured).
    private static let countTables = [
        "files", "knowledge_objects", "chunks", "source_versions", "evidence_blocks",
        "entities", "events", "workspaces", "workspace_sources", "workspace_entities",
        "claims", "claim_evidence_ref", "claim_reviews", "claim_usage",
    ]

    private func counts(_ db: Database) async throws -> [String: Int] {
        var out: [String: Int] = [:]
        for t in Self.countTables where try await MigrationFixtureBuilder.tableExists(db, t) {
            out[t] = Int(try await db.query("SELECT COUNT(*) FROM \(t);", []).first?.int(0) ?? -1)
        }
        return out
    }

    /// A sample of primary-key ids per table, captured pre-migration and required to survive.
    private func idSamples(_ db: Database) async throws -> [(table: String, id: String)] {
        var out: [(String, String)] = []
        for t in ["files", "knowledge_objects", "claims"] where try await MigrationFixtureBuilder.tableExists(db, t) {
            for row in try await db.query("SELECT id FROM \(t) ORDER BY id LIMIT 5;", []) {
                if let id = row.string(0) { out.append((t, id)) }
            }
        }
        return out
    }

    // MARK: - Acceptance (env-gated; SKIPPED unless an archive is supplied)

    @Test("An external sanitized archive migrates through the real path with full preservation",
          .enabled(if: env["KALS_OWNER_ARCHIVE"] != nil))
    func ownerArchiveMigrationAcceptance() async throws {
        let archivePath = try #require(Self.env["KALS_OWNER_ARCHIVE"])
        let manifestPath = try #require(Self.env["KALS_OWNER_ARCHIVE_MANIFEST"],
                                        "KALS_OWNER_ARCHIVE_MANIFEST is required alongside the archive")
        let archiveURL = URL(fileURLWithPath: archivePath)
        let manifest = try JSONDecoder().decode(OwnerArchiveManifest.self,
                                                from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
        // Privacy gate: a fixture flagged as containing personal data is refused outright.
        #expect(manifest.containsPersonalData == false, "fixture must be sanitized (containsPersonalData=false)")

        // The working copy must BE the manifested archive (hash pins the exact bytes).
        let hashBefore = try MigrationFaultHarness.sha256OfFile(archiveURL)
        #expect(hashBefore == manifest.sourceDatabaseSHA256.lowercased(),
                "working copy hash does not match manifest.sourceDatabaseSHA256")

        // Open the WORKING COPY and capture the pre-migration truth.
        let db = try Database(url: archiveURL)
        let startVersion = try await db.currentUserVersion()
        if manifest.originalSchemaVersion > 0 {
            #expect(startVersion == manifest.originalSchemaVersion,
                    "archive user_version \(startVersion) != manifest originalSchemaVersion \(manifest.originalSchemaVersion)")
        }
        let preCounts = try await counts(db)
        let samples = try await idSamples(db)
        #expect(!preCounts.isEmpty, "archive has none of the known tables — not a Kalsmritikosh database?")

        // ── The REAL application migration path ──
        try await SchemaMigrations.migrate(db)

        let endVersion = try await db.currentUserVersion()
        #expect(endVersion == manifest.expectedEndVersion)
        #expect(endVersion == SchemaMigrations.latestVersion)
        let integrityOK = try await MigrationFaultHarness.integrityOK(db)
        #expect(integrityOK, "PRAGMA integrity_check not ok")
        let fkViolations = try await MigrationFaultHarness.foreignKeyViolationCount(db)
        #expect(fkViolations == 0, "PRAGMA foreign_key_check reported violations")

        // Counts preserved (pre == post), and match the manifest where it states expectations.
        let postCounts = try await counts(db)
        for (t, pre) in preCounts {
            #expect(postCounts[t] == pre, "count changed for \(t): \(pre) → \(postCounts[t] ?? -1)")
        }
        for (t, expected) in manifest.expectedCounts {
            #expect(postCounts[t] == expected, "manifest expects \(t)=\(expected), archive has \(postCounts[t] ?? -1)")
        }
        // Stable IDs survive.
        for (t, id) in samples {
            let n = Int(try await db.query("SELECT COUNT(*) FROM \(t) WHERE id = ?;", [.text(id)]).first?.int(0) ?? 0)
            #expect(n == 1, "stable id lost from \(t): \(id)")
        }

        // At least one EXACT evidence/source reopening from the manifest's representative.
        var reopened = "none"
        let store = EvidenceStore(database: db)
        if let svRaw = manifest.representative.sourceVersionID, let sv = UUID(uuidString: svRaw),
           let expectedHash = manifest.representative.contentHash {
            let hashes = try await store.contentHashes(forSourceVersionIDs: [sv])
            #expect(hashes[sv]?.lowercased() == expectedHash.lowercased(),
                    "representative source version did not reopen with its exact content hash")
            reopened = "sourceVersion \(svRaw)"
        } else if let fRaw = manifest.representative.fileID {
            let rows = try await db.query("SELECT url FROM files WHERE id = ?;", [.text(fRaw)])
            #expect(rows.first?.string(0)?.isEmpty == false, "representative file did not reopen")
            reopened = "file \(fRaw)"
        }
        #expect(reopened != "none", "manifest.representative must name a sourceVersionID+contentHash or a fileID")

        // Second migration is a no-op; a fresh Database instance still passes.
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
        let secondCounts = try await counts(db)
        let secondNoOp = secondCounts == postCounts
        #expect(secondNoOp, "second migration changed row counts")
        let reopenedDB = try MigrationFixtureBuilder.reopen(at: archiveURL)
        let freshOK = (try await reopenedDB.currentUserVersion()) == SchemaMigrations.latestVersion
        #expect(freshOK)

        // Non-sensitive acceptance report (counts/versions/hashes only). Checkpoint the WAL first
        // so the after-hash reflects the MIGRATED main file (in WAL mode the migration writes live
        // in the -wal sidecar and the main file's bytes would misleadingly equal the before-hash).
        _ = try? await db.exec("PRAGMA wal_checkpoint(TRUNCATE);")
        let hashAfter = try MigrationFaultHarness.sha256OfFile(archiveURL)
        #expect(hashAfter != hashBefore, "a real migration must change the checkpointed file bytes")
        let report = OwnerArchiveAcceptanceReport(
            fixtureID: manifest.fixtureID, startVersion: startVersion, endVersion: endVersion,
            workingCopyHashBeforeMigration: hashBefore, workingCopyHashAfterMigration: hashAfter,
            counts: postCounts, stableIDSampleSize: samples.count, representativeReopened: reopened,
            integrityOK: integrityOK, foreignKeyViolations: fkViolations,
            secondMigrationNoOp: secondNoOp, freshReopenOK: freshOK)
        let reportURL = URL(fileURLWithPath: Self.env["KALS_OWNER_ARCHIVE_REPORT"]
                            ?? archiveURL.deletingLastPathComponent().appendingPathComponent("acceptance-report.json").path)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(report).write(to: reportURL)
    }

    // MARK: - Self-test generator (developer use; env-gated; SKIPPED normally)

    /// Build a GENUINE v66 on-disk archive + matching manifest so the whole
    /// verify-real-archive.sh → acceptance-test pipeline can be proven end-to-end WITHOUT owner
    /// data. Also documents the exact manifest format an owner must supply.
    @Test("Generate a synthetic owner-like archive + manifest (self-test aid)",
          .enabled(if: env["KALS_GENERATE_SYNTHETIC_ARCHIVE"] != nil))
    func generateSyntheticArchive() async throws {
        let archiveURL = URL(fileURLWithPath: try #require(Self.env["KALS_GENERATE_SYNTHETIC_ARCHIVE"]))
        let manifestURL = URL(fileURLWithPath: try #require(Self.env["KALS_GENERATE_SYNTHETIC_MANIFEST"]))

        let db = try await MigrationFixtureBuilder.database(atVersion: 66, at: archiveURL)
        _ = try await MigrationFixtureBuilder.seedPreservationRows(into: db, forVersion: 66)
        // A reopenable file → source_version → evidence_block → block-ownership chain with a REAL
        // 64-hex content hash, so the representative reopening check is exercised.
        let fileID = UUID(), svID = UUID(), blockID = UUID(), docID = UUID(), koID = UUID()
        let contentHash = String(repeating: "ab", count: 32)
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                          [.uuid(fileID), .text("file:///synthetic/\(fileID)"), .text("txt")])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);
        """, [.uuid(koID), .uuid(fileID), .text("txt"), .text("c"), .real(0), .real(0)])
        try await db.exec("""
        INSERT INTO source_versions (id, logical_source_id, document_id, content_hash, valid_from, is_current, created_at)
        VALUES (?,?,?,?,?,1,?);
        """, [.uuid(svID), .uuid(fileID), .uuid(docID), .text(contentHash), .real(0), .real(0)])
        try await db.exec("""
        INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text, extraction_method, extraction_confidence)
        VALUES (?,?,?,?,?,?,?,?,?);
        """, [.uuid(blockID), .uuid(docID), .uuid(svID), .integer(0), .text("paragraph"), .text("t"), .text("t"), .text("native"), .real(1.0)])
        try await db.exec("INSERT INTO evidence_block_objects (evidence_block_id, knowledge_object_id, linked_at) VALUES (?,?,?);",
                          [.uuid(blockID), .uuid(koID), .real(0)])
        _ = try? await db.exec("PRAGMA wal_checkpoint(TRUNCATE);")

        var counts: [String: Int] = [:]
        for t in Self.countTables where try await MigrationFixtureBuilder.tableExists(db, t) {
            counts[t] = Int(try await db.query("SELECT COUNT(*) FROM \(t);", []).first?.int(0) ?? -1)
        }
        let manifest = OwnerArchiveManifest(
            fixtureID: "synthetic-selftest-001", originalSchemaVersion: 66, sanitizerVersion: "selftest",
            containsPersonalData: false,
            sourceDatabaseSHA256: try MigrationFaultHarness.sha256OfFile(archiveURL),
            expectedEndVersion: SchemaMigrations.latestVersion, expectedCounts: counts,
            representative: .init(sourceVersionID: svID.uuidString, contentHash: contentHash, fileID: fileID.uuidString))
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(manifest).write(to: manifestURL)
    }
}
