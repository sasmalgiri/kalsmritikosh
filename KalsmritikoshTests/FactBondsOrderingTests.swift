//
//  FactBondsOrderingTests.swift
//  KalsmritikoshTests
//
//  Regression guard for the retrieval-determinism fix (commit f788301).
//  FactBondsRepository.outgoing/incoming used `LIMIT ?` with NO `ORDER BY`, so
//  SQLite returned an arbitrary neighbour subset each run — the bond walk then
//  explored a different subgraph every time (measured: gold-eval walk-step count
//  swung 40↔66, temporal recall bounced 0↔1.0). The queries now carry
//  `ORDER BY confidence DESC, weight DESC, id`. These tests lock that in: the
//  LIMIT must keep the HIGHEST-confidence bonds, and repeated calls must return
//  the identical order. If someone drops the ORDER BY, these fail.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("FactBonds neighbour ordering is deterministic (P6.1 guard)")
struct FactBondsOrderingTests {

    private func freshRepo() async throws -> FactBondsRepository {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fb-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        // This suite tests ONLY the neighbour ORDER BY, not referential
        // integrity, so we don't build the knowledge_objects parent rows the
        // source_object_id FK would otherwise require.
        try await db.exec("PRAGMA foreign_keys=OFF;")
        return FactBondsRepository(database: db)
    }

    private func edge(_ from: UUID, _ to: UUID) -> FactBondsRepository.BondUpsert {
        .init(bondName: "relates_to", fromKind: .entity, fromID: from, toKind: .entity, toID: to)
    }

    @Test("outgoing LIMIT keeps the highest-confidence bonds, in a stable order")
    func outgoingOrderedByConfidence() async throws {
        let repo = try await freshRepo()
        let from = UUID()
        let low = UUID(), mid = UUID(), high = UUID()
        // Insert deliberately out of confidence order.
        try await repo.upsertBond(edge(from, low),  sourceObjectID: UUID(), confidence: Confidence(0.20))
        try await repo.upsertBond(edge(from, high), sourceObjectID: UUID(), confidence: Confidence(0.95))
        try await repo.upsertBond(edge(from, mid),  sourceObjectID: UUID(), confidence: Confidence(0.55))

        // A LIMIT below the row count must keep the two STRONGEST bonds — never
        // an arbitrary subset. Order is confidence-descending.
        let top2 = try await repo.outgoing(from: from, limit: 2)
        #expect(top2.count == 2)
        #expect(top2.map(\.toID) == [high, mid])

        // Determinism: a second identical query returns the identical order.
        let again = try await repo.outgoing(from: from, limit: 2)
        #expect(again.map(\.id) == top2.map(\.id))

        // Full fetch is also confidence-descending, stable.
        let all = try await repo.outgoing(from: from, limit: 10)
        #expect(all.map(\.toID) == [high, mid, low])
    }

    @Test("incoming LIMIT keeps the highest-confidence bonds, in a stable order")
    func incomingOrderedByConfidence() async throws {
        let repo = try await freshRepo()
        let to = UUID()
        let a = UUID(), b = UUID(), c = UUID()
        try await repo.upsertBond(edge(a, to), sourceObjectID: UUID(), confidence: Confidence(0.30))
        try await repo.upsertBond(edge(b, to), sourceObjectID: UUID(), confidence: Confidence(0.90))
        try await repo.upsertBond(edge(c, to), sourceObjectID: UUID(), confidence: Confidence(0.60))

        let top2 = try await repo.incoming(to: to, limit: 2)
        #expect(top2.count == 2)
        #expect(top2.map(\.fromID) == [b, c])
        let again = try await repo.incoming(to: to, limit: 2)
        #expect(again.map(\.id) == top2.map(\.id))
    }
}
