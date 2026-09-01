//
//  ProducerVersionTests.swift
//  KalsmritikoshTests
//
//  V1 registration — THE TRAP TEST (owner binding 2026-09-01): initial
//  declared producer versions ≡ NULL/v0, so the staleness predicate
//  (COALESCE(producer_version, 0) != current) must select NOTHING
//  post-registration, pre-V2. If it selected the archive, the honest
//  "older rules" line would invite a full drain that rewrites everything
//  with UNCHANGED logic — breaking V5's one-rewrite discipline before V2
//  opens. The line must be able to read zero the day it lands.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("V1 — producer versions: NULL ≡ declared ≡ current, staleness selects nothing")
@MainActor
struct ProducerVersionTests {

    @Test("Post-registration pre-V2: zero stale rows across facts/entities/events; new rows carry the declared version")
    func stalenessSelectsNothing() async throws {
        let gen = NoiseFixtureGenerator()
        let rig = try await FixtureRig.make(document: gen.noisyGrantLetter, name: "grant-letter.md")
        defer { try? FileManager.default.removeItem(at: rig.dir) }

        // A legacy row: NULL producer_version (pre-V1 archive shape).
        try await rig.db.exec("""
        INSERT INTO generic_facts (id, subject_id, subject_label, field, value, status, confidence, source_blocks_json, created_at)
        VALUES (?, NULL, 'legacy', 'patentnumber', 'Patent No. 111111', 'sourceAsserted', 0.5, '[]', 0);
        """, [.uuid(UUID())])

        func staleCount(_ table: String, current: Int) async throws -> Int {
            Int((try await rig.db.query(
                "SELECT COUNT(*) FROM \(table) WHERE COALESCE(producer_version, 0) != ?",
                [.integer(Int64(current))])).first?.int(0) ?? -1)
        }
        let staleFacts = try await staleCount("generic_facts", current: DerivedProducerVersions.facts)
        let staleEntities = try await staleCount("entities", current: DerivedProducerVersions.entities)
        let staleEvents = try await staleCount("events", current: DerivedProducerVersions.events)
        print("V1 TRAP TEST: stale facts=\(staleFacts) entities=\(staleEntities) events=\(staleEvents) (must all be 0)")
        #expect(staleFacts == 0, "the 'older rules' line would not read zero on day one")
        #expect(staleEntities == 0)
        #expect(staleEvents == 0)

        // New rows carry the declared version explicitly (V1 spec: new rows
        // stamped; legacy rows NULL; both ≡ current until a logic bump).
        let stamped = Int((try await rig.db.query(
            "SELECT COUNT(*) FROM generic_facts WHERE producer_version IS NOT NULL", [])).first?.int(0) ?? 0)
        #expect(stamped > 0, "ingest wrote no stamped facts")

        // And the FIRST BUMP behaves: at a hypothetical current=1, exactly
        // the whole legacy+v0 set becomes stale — the predicate is live.
        let futureStale = try await staleCount("generic_facts", current: 1)
        let total = Int((try await rig.db.query(
            "SELECT COUNT(*) FROM generic_facts", [])).first?.int(0) ?? 0)
        #expect(futureStale == total, "a version bump must select the full unrewritten set")
    }
}
