//
//  EntityReconciliationAuditRepository.swift
//  Kalsmritikosh
//
//  Unified path IN-18 (owner 2026-11-22) — not tested yet. Persists EntityReconciliationAudit events
//  (v200 entity_reconciliation_events, append-only): every automatic or human merge/split, so a merge
//  made after an import can be audited and its exact inverse derived (EntityReconciliationAudit.reverse).
//

import Foundation

public actor EntityReconciliationAuditRepository {
    private let database: Database

    public init(database: Database) { self.database = database }

    /// Record one event. `origin` names what made it ("registerRefresh", "ocrVariant", "review").
    public func record(_ event: ReconciliationEvent, origin: String) async throws {
        let (op, primary, others): (String, Entity.ID, [Entity.ID]) = {
            switch event.op {
            case .merge(let winner, let losers): return ("merge", winner, losers)
            case .split(let original, let results): return ("split", original, results)
            }
        }()
        try await database.exec("""
        INSERT INTO entity_reconciliation_events
            (id, op, primary_entity_id, other_entity_ids, initiated_by_human, origin, at_millis)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """, [.uuid(event.id), .text(op), .uuid(primary), .text(others.map(\.uuidString).joined(separator: ",")),
              .integer(event.initiatedByHuman ? 1 : 0), .text(origin), .integer(event.atMillis)])
    }

    /// The audit, oldest first (append-only history; an undo is its own event).
    public func audit(limit: Int = 5_000) async throws -> EntityReconciliationAudit {
        let rows = try await database.query("""
        SELECT id, op, primary_entity_id, other_entity_ids, initiated_by_human, at_millis
        FROM entity_reconciliation_events ORDER BY at_millis ASC, rowid ASC LIMIT ?;
        """, [.integer(Int64(limit))])
        var audit = EntityReconciliationAudit()
        for r in rows {
            guard let id = r.uuid(0), let op = r.string(1), let primary = r.uuid(2) else { continue }
            let others = (r.string(3) ?? "").split(separator: ",").compactMap { UUID(uuidString: String($0)) }
            let o: ReconciliationOp = op == "merge" ? .merge(winner: primary, losers: others) : .split(original: primary, results: others)
            audit.record(ReconciliationEvent(id: id, op: o, initiatedByHuman: (r.int(4) ?? 0) != 0, atMillis: r.int(5) ?? 0))
        }
        return audit
    }

    /// Unified path IN-18 (owner 2026-11-22, round 2) — not tested yet. One automatic merge still in force (no later
    /// split of the same winner and losers), for the undo screen.
    public struct OpenMerge: Sendable, Identifiable, Hashable {
        public let id: UUID
        public let winner: Entity.ID
        public let losers: [Entity.ID]
        public let origin: String
        public let at: Date
        public let byHuman: Bool
    }

    /// Unified path IN-18 (owner 2026-11-22, round 2) — not tested yet. Merges not yet undone, newest first.
    public func openMerges(limit: Int = 500) async throws -> [OpenMerge] {
        let rows = try await database.query("""
        SELECT id, op, primary_entity_id, other_entity_ids, initiated_by_human, origin, at_millis
        FROM entity_reconciliation_events ORDER BY at_millis ASC, rowid ASC;
        """, [])
        var open: [String: OpenMerge] = [:]
        var order: [String] = []
        for r in rows {
            guard let id = r.uuid(0), let op = r.string(1), let primary = r.uuid(2) else { continue }
            let others = (r.string(3) ?? "").split(separator: ",").compactMap { UUID(uuidString: String($0)) }
            if op == "merge" {
                let key = primary.uuidString + "|" + others.map(\.uuidString).sorted().joined(separator: ",")
                open[key] = OpenMerge(id: id, winner: primary, losers: others, origin: r.string(5) ?? "",
                                      at: Date(timeIntervalSince1970: Double(r.int(6) ?? 0) / 1000), byHuman: (r.int(4) ?? 0) != 0)
                order.append(key)
            } else {
                // A split of the winner into itself + losers undoes the matching merge.
                let losers = others.filter { $0 != primary }
                open[primary.uuidString + "|" + losers.map(\.uuidString).sorted().joined(separator: ",")] = nil
            }
        }
        var seen = Set<String>()
        return order.reversed().compactMap { k in seen.insert(k).inserted ? open[k] : nil }.prefix(limit).map { $0 }
    }
}
