//
//  ProducerVersionTests.swift
//  KalsmritikoshTests
//
//  V2 — THE BUMP FIRED (owner binding 2026-09-01): V1 registered the derived
//  producers at 0 (NULL ≡ 0 ≡ current), so pre-V2 the staleness predicate
//  (COALESCE(producer_version, 0) != current) selected NOTHING — the trap that
//  kept "N sources on older rules" reading zero on day one. V2 is the FIRST
//  LOGIC BUMP: DerivedProducerVersions.facts goes 0 → 1 (capture-group atoms,
//  ISO dates). Now the predicate LIGHTS: pre-capture-group (legacy NULL) rows
//  read stale — correctly, they are what the V5 drain will rewrite — while
//  freshly-ingested v1 rows read current. entities/events did NOT bump, so
//  they stay quiescent. This is the trap test inverted, exactly as designed.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("V2 — facts bumped to 1: legacy rows light stale, fresh v1 rows current")
@MainActor
struct ProducerVersionTests {

    @Test("Post-V2 bump: fresh rows carry facts=1 (current); the legacy NULL row is correctly stale; entities/events untouched")
    func stalenessAfterV2Bump() async throws {
        #expect(DerivedProducerVersions.facts == 1, "V2 is the first facts logic bump")
        let gen = NoiseFixtureGenerator()
        let rig = try await FixtureRig.make(document: gen.noisyGrantLetter, name: "grant-letter.md")
        defer { try? FileManager.default.removeItem(at: rig.dir) }

        // A legacy row: NULL producer_version (pre-V1 / pre-capture-group shape,
        // value still label-fused as v0 stored it).
        try await rig.db.exec("""
        INSERT INTO generic_facts (id, subject_id, subject_label, field, value, status, confidence, source_blocks_json, created_at)
        VALUES (?, NULL, 'legacy', 'patentnumber', 'Patent No. 111111', 'sourceAsserted', 0.5, '[]', 0);
        """, [.uuid(UUID())])

        func staleCount(_ table: String, current: Int) async throws -> Int {
            Int((try await rig.db.query(
                "SELECT COUNT(*) FROM \(table) WHERE COALESCE(producer_version, 0) != ?",
                [.integer(Int64(current))])).first?.int(0) ?? -1)
        }
        // Facts: the fresh ingest is stamped at the current era (1) — the
        // repository defaults a fact's version to the current era, so every
        // freshly-written row is current. Exactly the one legacy NULL row reads
        // stale: COALESCE(NULL, 0) = 0 != 1.
        let staleFacts = try await staleCount("generic_facts", current: DerivedProducerVersions.facts)
        let staleEntities = try await staleCount("entities", current: DerivedProducerVersions.entities)
        let staleEvents = try await staleCount("events", current: DerivedProducerVersions.events)
        print("V2 BUMP TEST: stale facts=\(staleFacts) (want 1) entities=\(staleEntities) events=\(staleEvents) (want 0)")
        #expect(staleFacts == 1, "exactly the one legacy NULL row should light stale post-V2; got \(staleFacts)")
        #expect(staleEntities == 0, "entities did not bump in V2")
        #expect(staleEvents == 0, "events did not bump in V2")

        // Every FRESH fact carries the declared current version (none NULL, none v0).
        let stampedCurrent = Int((try await rig.db.query(
            "SELECT COUNT(*) FROM generic_facts WHERE producer_version = ?",
            [.integer(Int64(DerivedProducerVersions.facts))])).first?.int(0) ?? 0)
        #expect(stampedCurrent > 0, "ingest wrote no facts stamped at the current version")

        // The predicate stays LIVE for the NEXT bump: at a hypothetical
        // current=2, the whole set (legacy + every v1 row) is stale — nothing
        // reads current, so a future logic change still selects everything.
        let futureStale = try await staleCount("generic_facts", current: 2)
        let total = Int((try await rig.db.query(
            "SELECT COUNT(*) FROM generic_facts", [])).first?.int(0) ?? 0)
        #expect(futureStale == total, "a future version bump must select the full unrewritten set")
    }
}
