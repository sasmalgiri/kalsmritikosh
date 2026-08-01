//
//  SourceReadinessLedgerInspector.swift
//  Kalsmritikosh
//
//  USF-002 — read-only view over the append-only readiness event ledger. Ordinary readiness
//  operations never update or delete events; this surfaces the full history for a source version
//  (audit, tests, later reprocessing UX in USF-010). It writes nothing.
//

import Foundation

public struct SourceReadinessLedgerInspector: Sendable {

    private let database: Database
    public init(database: Database) { self.database = database }

    public nonisolated struct EventRow: Sendable, Hashable {
        public let sourceVersionID: UUID
        public let sequence: Int
        public let aggregateRevision: Int
        public let dimension: SourceReadinessDimension
        public let action: SourceReadinessAction
        public let fromState: SourceReadinessDimensionState?
        public let toState: SourceReadinessDimensionState
        public let occurredAt: Date
    }

    /// Every event for a source version, in contiguous sequence order.
    public func events(sourceVersionID: UUID) async throws -> [EventRow] {
        let rows = try await database.query("""
            SELECT sequence, aggregate_revision, dimension, action, from_state, to_state, occurred_at
              FROM source_readiness_events WHERE source_version_id = ? ORDER BY sequence ASC;
            """, [.uuid(sourceVersionID)])
        return rows.compactMap { r in
            guard let seq = r.int(0), let rev = r.int(1),
                  let dim = r.string(2).flatMap(SourceReadinessDimension.init(rawValue:)),
                  let action = r.string(3).flatMap(SourceReadinessAction.init(rawValue:)),
                  let to = r.string(5).flatMap(SourceReadinessDimensionState.init(rawValue:)) else { return nil }
            return EventRow(
                sourceVersionID: sourceVersionID, sequence: Int(seq), aggregateRevision: Int(rev), dimension: dim,
                action: action, fromState: r.string(4).flatMap(SourceReadinessDimensionState.init(rawValue:)),
                toState: to, occurredAt: r.date(6) ?? Date(timeIntervalSince1970: 0))
        }
    }

    /// The count of events for a source version (a cheap invariant check in tests).
    public func eventCount(sourceVersionID: UUID) async throws -> Int {
        Int(try await database.query("SELECT COUNT(*) FROM source_readiness_events WHERE source_version_id = ?;",
                                     [.uuid(sourceVersionID)]).first?.int(0) ?? 0)
    }
}
