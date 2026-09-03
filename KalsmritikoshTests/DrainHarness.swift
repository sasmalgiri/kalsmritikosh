//
//  DrainHarness.swift
//  KalsmritikoshTests
//
//  V5 (F7) commit B — the LIVE drain runner. Tooling only, never the app
//  target; SKIPS (green) unless the operator sets TEST_RUNNER_DRAIN_LIVE=1,
//  so hosted CI passes through untouched.
//
//  This is the ONE sanctioned mutation of the live archive in the entire
//  program (Master Order F7). Guardrails, in order:
//    1. SNAPSHOT FIRST — VACUUM INTO the live ledger's own directory (the
//       owner's rollback copy; the path is announced in the log before
//       anything is written). Self-Ruling #1: the sandboxed test host cannot
//       open real ~/Downloads ("Operation not permitted", proven 2026-09-03,
//       failed AT the snapshot, ledger untouched) — the container directory
//       is the one guaranteed-writable same-volume destination; the operator
//       mirrors the file to ~/Downloads after the run.
//    2. Populated-ledger guard — never drain a phantom container.
//    3. Migrate to the current schema (v123 adds document_class; versioned,
//       SAVEPOINT-wrapped, exactly what the app does at boot).
//    4. LedgerDrainCoordinator.drain() — six passes, producer_version as the
//       resume marker, untouched-tables proof in the receipt.
//    5. The receipt is printed verbatim and the untouched proof is ASSERTED —
//       a violation fails the run (STOP), with the snapshot as the way back.
//
//  Run:
//    TEST_RUNNER_DRAIN_LIVE=1 xcodebuild test \
//      -only-testing:KalsmritikoshTests/DrainHarness -parallel-testing-enabled NO
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("V5 — live drain (operator-invoked only)", .serialized)
struct DrainHarness {

    @Test("Drain the live archive: snapshot → migrate → six passes → receipt")
    func drainLiveArchive() async throws {
        guard ProcessInfo.processInfo.environment["DRAIN_LIVE"] == "1" else {
            print("DRAIN: TEST_RUNNER_DRAIN_LIVE not set — skipping (operator-invoked only).")
            return
        }
        let liveURL = DatabaseLocations.defaultDatabaseURL
        guard FileManager.default.fileExists(atPath: liveURL.path) else {
            print("DRAIN: no live ledger at \(liveURL.path) — skipping.")
            return
        }

        // 1 — SNAPSHOT FIRST. The owner's study/rollback copy, path announced.
        // Written beside the live ledger (sandbox-writable, same volume);
        // mirrored to ~/Downloads by the operator after the run.
        let head = (try? await gitHeadShort()) ?? "unknown"
        let snapshotURL = liveURL.deletingLastPathComponent()
            .appendingPathComponent("kalsmritikosh-pre-drain-snapshot-\(head).sqlite")
        // A snapshot is a rollback copy — NEVER silently overwritten or deleted.
        // If one exists (aborted or prior run), the operator moves it aside first.
        guard !FileManager.default.fileExists(atPath: snapshotURL.path) else {
            Issue.record("DRAIN: a snapshot already exists at \(snapshotURL.path) — refusing to touch it. Move it aside, then re-run.")
            return
        }
        do {
            let src = try Database(url: liveURL)
            let escaped = snapshotURL.path.replacingOccurrences(of: "'", with: "''")
            try await src.exec("VACUUM main INTO '\(escaped)';", [])
            await src.close()
        }
        print("DRAIN: PRE-DRAIN SNAPSHOT WRITTEN → \(snapshotURL.path)")
        #expect(FileManager.default.fileExists(atPath: snapshotURL.path), "snapshot must exist before any write")

        // 2+3 — open the LIVE ledger, guard population, migrate to current.
        let db = try Database(url: liveURL)
        let koCount = Int((try await db.query("SELECT COUNT(*) FROM knowledge_objects;", [])).first?.int(0) ?? 0)
        guard koCount > 0 else {
            await db.close()
            Issue.record("DRAIN: live ledger reports 0 knowledge objects — refusing to drain a phantom.")
            return
        }
        print("DRAIN: live ledger ko=\(koCount) — migrating to v\(SchemaMigrations.latestVersion) then draining.")
        try await SchemaMigrations.migrate(db)

        // 4 — the six passes.
        let coordinator = LedgerDrainCoordinator(
            database: db,
            objects: KnowledgeObjectRepository(database: db),
            entities: EntitiesRepository(database: db),
            events: EventsRepository(database: db),
            facts: GenericFactRepository(database: db),
            evidence: EvidenceStore(database: db))
        let receipt = try await coordinator.drain()
        await db.close()

        // 5 — the receipt, verbatim, and the untouched proof asserted.
        print(receipt.renderLines())
        #expect(receipt.untouchedProven,
                "chunks/FTS/embeddings changed during the drain — STOP; snapshot at \(snapshotURL.path)")
    }

    private func gitHeadShort() async throws -> String {
        // Test bundles can't shell out reliably; derive a stable run label from
        // the schema version + date-free counter instead. (The snapshot name
        // needs uniqueness + traceability, not the literal commit.)
        "v\(SchemaMigrations.latestVersion)"
    }
}

// MARK: - GO2R U0-b: the register refresh, live (operator-invoked only)

@Suite("U0-b — live entity register refresh (operator-invoked only)", .serialized)
struct RegisterRefreshHarness {

    @Test("Refresh the live register: snapshot → refresh → receipt → zero dirty remainder")
    func refreshLiveRegister() async throws {
        guard ProcessInfo.processInfo.environment["REGISTER_REFRESH_LIVE"] == "1" else {
            print("REFRESH: TEST_RUNNER_REGISTER_REFRESH_LIVE not set — skipping (operator-invoked only).")
            return
        }
        let liveURL = DatabaseLocations.defaultDatabaseURL
        guard FileManager.default.fileExists(atPath: liveURL.path) else {
            print("REFRESH: no live ledger — skipping."); return
        }
        // Snapshot FIRST, beside the ledger (SR-01 law), refuse-if-exists.
        let snapshotURL = liveURL.deletingLastPathComponent()
            .appendingPathComponent("kalsmritikosh-pre-refresh-snapshot-entities-v2.sqlite")
        guard !FileManager.default.fileExists(atPath: snapshotURL.path) else {
            Issue.record("REFRESH: snapshot already exists at \(snapshotURL.path) — move it aside, then re-run.")
            return
        }
        do {
            let src = try Database(url: liveURL)
            let escaped = snapshotURL.path.replacingOccurrences(of: "'", with: "''")
            try await src.exec("VACUUM main INTO '\(escaped)';", [])
            await src.close()
        }
        print("REFRESH: PRE-REFRESH SNAPSHOT WRITTEN → \(snapshotURL.path)")
        #expect(FileManager.default.fileExists(atPath: snapshotURL.path))

        let db = try Database(url: liveURL)
        try await SchemaMigrations.migrate(db)
        let refresh = EntityRegisterRefresh(database: db, entities: EntitiesRepository(database: db))
        let receipt = try await refresh.run()
        print(receipt.renderLines())
        let dirty = try await refresh.dirtyRemainder()
        await db.close()
        print("REFRESH: dirty remainder after = \(dirty)")
        #expect(dirty == 0, "the register re-witness must read clean")
    }
}
