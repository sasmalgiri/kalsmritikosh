//
//  DoubleBootZeroWriteTests.swift
//  KalsmritikoshTests
//
//  U-5 (implement-all) — the FIXED-POINT LAW made a test. Every producer
//  must be idempotent: a second run on an unchanged ledger writes ZERO
//  rows and leaves its frontier empty. The four A6 frontier fixes
//  (#145/#146/#148/#149/#150) proved this one straggler at a time; this
//  is the general guard — run each riggable producer to quiescence, then
//  run it AGAIN and assert it emits nothing new.
//
//  The full app double-boot (every producer, live archive copy) is the
//  harness's BASELINE_QUIESCE pass; this unit pins the property for the
//  producers a fixture DB can drive directly.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@MainActor
@Suite("U-5 Double-Boot Zero-Write (Fixed-Point Law)")
struct DoubleBootZeroWriteTests {

    static let gen = NoiseFixtureGenerator()

    /// CausalDiscoverer: run to quiescence, then a second pass on the
    /// unchanged ledger must emit 0 (the existing-triple set makes every
    /// candidate a no-op).
    @Test func causalDiscovererIsIdempotent() async throws {
        let rig = try await FixtureRig.make(document: "Fixed-point seed.", name: "seed.md")
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let db = rig.db
        let sourceID = try #require(
            (try await db.query("SELECT id FROM knowledge_objects LIMIT 1", []))
                .first?.string(0).flatMap(UUID.init(uuidString:)),
            "rig produced no knowledge object")

        let events = EventsRepository(database: db)
        try await events.insertBatch(
            Self.gen.threadEvents(count: 20, sourceObjectID: sourceID,
                                  baseDate: Date(timeIntervalSince1970: 1_750_000_000)))
        let discoverer = CausalDiscoverer(
            database: db, events: events,
            entities: EntitiesRepository(database: db),
            objects: KnowledgeObjectRepository(database: db),
            links: EventLinksRepository(database: db))

        // First run settles the frontier; second run must be a zero-write.
        _ = await discoverer.runOnce()
        let secondPass = await discoverer.runOnce()
        #expect(secondPass == 0, "second causal pass emitted \(secondPass) — not a fixed point")

        // Third run too — quiescence is stable, not a one-shot.
        let thirdPass = await discoverer.runOnce()
        #expect(thirdPass == 0)
    }

    /// The backfiller pending-count contract: a producer that has drained
    /// reports pending 0, and a producer with nothing to do never invents
    /// work. (An empty ledger has nothing pending for any of them.)
    @Test func backfillersReportZeroPendingOnAnEmptyLedger() async throws {
        let rig = try await FixtureRig.make(document: "Nothing to backfill.", name: "seed.md")
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let db = rig.db

        let ctx = ContextPrefixBackfiller(
            chunks: ChunksRepository(database: db),
            objects: KnowledgeObjectRepository(database: db),
            generator: HeuristicContextPrefixGenerator())
        let narr = NarrativeSlotBackfiller(
            database: db, events: EventsRepository(database: db),
            objects: KnowledgeObjectRepository(database: db),
            entities: EntitiesRepository(database: db),
            extractor: RuleNarrativeSlotExtractor())
        let tier = QualityTierBackfiller(database: db)

        // One short document produces no multi-chunk prefix work, no events,
        // and no T2 entities → all three are already at pending 0.
        #expect(await ctx.pendingCount() == 0)
        #expect(await narr.pendingCount() == 0)
        #expect(await tier.pendingCount() == 0)

        // And running them changes nothing (zero-write on an empty frontier).
        #expect(await ctx.runOnce() == 0)
        #expect(await narr.runOnce() == 0)
        #expect(await tier.runOnce() == 0)
    }
}
