//
//  ProducerVersionTests.swift
//  KalsmritikoshTests
//
//  V3 3c — THE SECOND BUMP FIRED. V2 advanced facts 0→1 (capture-group atoms).
//  V3's writer binding advances all three eras together, COHERENTLY — each bump
//  rides WITH the logic that changes what its rows contain (version = what the
//  row contains; a bump ahead of the logic would be the writer-revert trap):
//    facts    1→2  a fact now carries a canonical anchor subject (subjectID)
//    entities 0→1  the gate-hardened population + identifier anchor entities
//    events   0→1  milestones thread onto the anchor subject
//  The staleness predicate (COALESCE(producer_version, 0) != current) therefore
//  lights every unrewritten legacy row until the V5 drain rewrites the archive.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("V3 3c — facts→2, entities→1, events→1: the coherent triple bump")
@MainActor
struct ProducerVersionTests {

    @Test("Post-V3 bump: fresh rows carry the current era; the legacy NULL fact is stale; the predicate stays live for the next era")
    func stalenessAfterV3Bump() async throws {
        #expect(DerivedProducerVersions.facts == 4, "A1.1 is the fourth facts bump (the role table: applicant/inventor extraction)")
        #expect(DerivedProducerVersions.entities == 2, "U0-b is the second entities bump (RFC display-name splitter; register refresh executed live 2026-09-03)")
        #expect(DerivedProducerVersions.events == 1, "V3 3c is the first events bump (milestone→anchor threading)")

        let gen = NoiseFixtureGenerator()
        let rig = try await FixtureRig.make(document: gen.noisyGrantLetter, name: "grant-letter.md")
        defer { try? FileManager.default.removeItem(at: rig.dir) }

        // A legacy row: NULL producer_version (pre-V1 shape, value label-fused).
        try await rig.db.exec("""
        INSERT INTO generic_facts (id, subject_id, subject_label, field, value, status, confidence, source_blocks_json, created_at)
        VALUES (?, NULL, 'legacy', 'patentnumber', 'Patent No. 111111', 'sourceAsserted', 0.5, '[]', 0);
        """, [.uuid(UUID())])

        func staleCount(_ table: String, current: Int) async throws -> Int {
            Int((try await rig.db.query(
                "SELECT COUNT(*) FROM \(table) WHERE COALESCE(producer_version, 0) != ?",
                [.integer(Int64(current))])).first?.int(0) ?? -1)
        }
        func stampedCount(_ table: String, era: Int) async throws -> Int {
            Int((try await rig.db.query(
                "SELECT COUNT(*) FROM \(table) WHERE producer_version = ?",
                [.integer(Int64(era))])).first?.int(0) ?? -1)
        }

        // Exactly the one legacy NULL fact reads stale at the current facts
        // era (COALESCE(NULL,0)=0 != current); every freshly-ingested fact is
        // stamped current.
        let staleFacts = try await staleCount("generic_facts", current: DerivedProducerVersions.facts)
        print("V3 BUMP TEST: stale facts=\(staleFacts) (want 1)")
        #expect(staleFacts == 1, "exactly the one legacy NULL row should light stale post-V3; got \(staleFacts)")

        // Fresh facts are stamped at the current era.
        #expect(try await stampedCount("generic_facts", era: DerivedProducerVersions.facts) > 0,
                "ingest wrote no facts stamped at the current era")

        // Fresh entities/events carry their current era: none read stale. (Holds
        // whether or not this single grant letter produces any event row — the
        // point is that nothing fresh is stamped at a stale era.)
        #expect(try await staleCount("entities", current: DerivedProducerVersions.entities) == 0,
                "fresh entities must all read current at the entities era")
        #expect(try await staleCount("events", current: DerivedProducerVersions.events) == 0,
                "fresh events must all read current at the events era")

        // The predicate stays LIVE for the NEXT bump: at a hypothetical future era
        // the whole set (legacy + every current row) is stale — a future logic
        // change still selects everything to rewrite.
        let futureStale = try await staleCount("generic_facts", current: DerivedProducerVersions.facts + 1)
        let total = Int((try await rig.db.query("SELECT COUNT(*) FROM generic_facts", [])).first?.int(0) ?? 0)
        #expect(futureStale == total, "a future era bump must select the full unrewritten set")
    }
}
