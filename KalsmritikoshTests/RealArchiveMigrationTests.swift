//
//  RealArchiveMigrationTests.swift
//  KalsmritikoshTests
//
//  MIG-001B — real-archive migration METHODOLOGY, proven on a genuine on-disk archive built from
//  the committed migration history (a v66 database with seeded rows). It establishes the correct
//  hash semantics the reviewer specified:
//    • the ORIGINAL archive is never touched (its hash before == after);
//    • a working COPY equals the original before migration (copied-hash == original-hash);
//    • the working copy's bytes DIFFER after migration (a real migration rewrites the file);
//  plus logical-count preservation, integrity/foreign-key checks, no-op repeat migration, and a
//  fresh-instance reopen.
//
//  A sanitized REAL owner archive is NOT committed (no private data); running this methodology
//  against such a fixture is an owner step (see ci/migrations/verify-real-archive.sh) and is marked
//  Planned in MIGRATION_MATRIX.md until that run is recorded.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("MIG-001B — real-archive migration methodology")
struct RealArchiveMigrationTests {

    /// Fold any WAL back into the main file so the on-disk bytes are authoritative for hashing/copy.
    private func checkpoint(_ db: Database) async throws {
        _ = try? await db.exec("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    @Test("A genuine archive migrates with the correct hash semantics and full preservation")
    func archiveMigrationPreservesAndRehashes() async throws {
        let originalURL = MigrationFixtureBuilder.newTemporaryURL()
        let workingURL = MigrationFixtureBuilder.newTemporaryURL()
        defer { for u in [originalURL, workingURL] { try? FileManager.default.removeItem(at: u) } }

        // Build the "original archive": a genuine v66 database with seeded rows, checkpointed so the
        // main file holds everything.
        let original = try await MigrationFixtureBuilder.database(atVersion: 66, at: originalURL)
        let snap = try await MigrationFixtureBuilder.seedPreservationRows(into: original, forVersion: 66)
        try await checkpoint(original)
        let originalHashBefore = try MigrationFaultHarness.sha256OfFile(originalURL)

        // Work only on a COPY (never the original).
        try FileManager.default.copyItem(at: originalURL, to: workingURL)
        let workingHashBeforeMigration = try MigrationFaultHarness.sha256OfFile(workingURL)
        #expect(workingHashBeforeMigration == originalHashBefore, "the working copy must equal the original before migration")

        // Migrate the working copy.
        let working = try Database(url: workingURL)
        #expect(try await working.currentUserVersion() == 66)
        try await SchemaMigrations.migrate(working)
        try await checkpoint(working)

        // Correct hash semantics: a real migration CHANGES the copy's bytes; the original is untouched.
        let workingHashAfterMigration = try MigrationFaultHarness.sha256OfFile(workingURL)
        #expect(workingHashAfterMigration != originalHashBefore, "a real migration must change the file bytes")
        let originalHashAfter = try MigrationFaultHarness.sha256OfFile(originalURL)
        #expect(originalHashAfter == originalHashBefore, "the original archive was modified")

        // Full preservation on the migrated copy.
        #expect(try await working.currentUserVersion() == SchemaMigrations.latestVersion)
        #expect(try await MigrationFaultHarness.integrityOK(working))
        #expect(try await MigrationFaultHarness.foreignKeyViolationCount(working) == 0)
        #expect(try await MigrationFixtureBuilder.columns(working, "claims").isSuperset(of: ["scope_kind", "scope_id"]))
        #expect((try await snap.failures(in: working)).isEmpty, "logical counts / stable ids not preserved")

        // Repeated migration is a no-op, and a fresh Database instance still passes.
        try await SchemaMigrations.migrate(working)
        #expect(try await working.currentUserVersion() == SchemaMigrations.latestVersion)
        let reopened = try MigrationFixtureBuilder.reopen(at: workingURL)
        #expect(try await reopened.currentUserVersion() == SchemaMigrations.latestVersion)
        #expect((try await snap.failures(in: reopened)).isEmpty)
    }
}
