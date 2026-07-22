//
//  EntityReconciliationAudit.swift
//  Kalsmritikosh
//
//  SEM-009 — reversible entity reconciliation with a complete audit trail. Merging two
//  fragmented "Sasmal" entities, or splitting a wrongly-merged one, must be RECORDED and
//  REVERSIBLE — a human decision can always be undone, and the audit shows who/what changed
//  (locked contract: "user corrections never mutate original evidence" and review is
//  reversible). This models the audit + the exact inverse operation; the repository applies it.
//
//  Deterministic, offline. Pure value types + a pure reversal function.
//

import Foundation

public enum ReconciliationOp: Sendable, Hashable {
    /// Merge loser entities into a canonical winner.
    case merge(winner: Entity.ID, losers: [Entity.ID])
    /// Split an entity into multiple resulting entities.
    case split(original: Entity.ID, results: [Entity.ID])
}

public struct ReconciliationEvent: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let op: ReconciliationOp
    /// Who initiated it (human review vs automatic reconciler) — audit provenance.
    public let initiatedByHuman: Bool
    /// Millis since epoch, supplied by the caller (no clock here).
    public let atMillis: Int64

    public nonisolated init(id: UUID = UUID(), op: ReconciliationOp, initiatedByHuman: Bool, atMillis: Int64) {
        self.id = id; self.op = op; self.initiatedByHuman = initiatedByHuman; self.atMillis = atMillis
    }
}

public struct EntityReconciliationAudit: Sendable {
    public private(set) var events: [ReconciliationEvent]
    public nonisolated init(events: [ReconciliationEvent] = []) { self.events = events }

    public nonisolated mutating func record(_ event: ReconciliationEvent) { events.append(event) }

    /// The exact inverse of an operation — merge⇄split. Applying reverse(op) after op
    /// restores the prior entity structure (evidence is never touched, only entity identity).
    public nonisolated static func reverse(_ op: ReconciliationOp) -> ReconciliationOp {
        switch op {
        case .merge(let winner, let losers):
            // Undo a merge = split the winner back into winner + the former losers.
            return .split(original: winner, results: [winner] + losers)
        case .split(let original, let results):
            // Undo a split = merge the results back into the original.
            let losers = results.filter { $0 != original }
            return .merge(winner: original, losers: losers)
        }
    }

    /// Reverse the most recent event, returning the inverse op to apply (or nil if empty).
    public nonisolated mutating func undoLast(atMillis: Int64, byHuman: Bool) -> ReconciliationEvent? {
        guard let last = events.last else { return nil }
        let inverse = ReconciliationEvent(op: Self.reverse(last.op), initiatedByHuman: byHuman, atMillis: atMillis)
        events.append(inverse)   // the undo is itself an audited event (never erased history)
        return inverse
    }

    /// Full, append-only history for the audit view (nothing is ever deleted).
    public var history: [ReconciliationEvent] { events }
}
