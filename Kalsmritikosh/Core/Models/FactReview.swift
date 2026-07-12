//
//  FactReview.swift
//  Kalsmritikosh
//
//  T17 — a single human-review action over a reconstructed fact. Append-only:
//  accepting, rejecting, or correcting a fact records a NEW row; the prior
//  value is preserved in `priorValue`, never overwritten (§11 rule 11, §12.9,
//  §3.8). A rejected fact stays in the ledger (preserve-everything directive)
//  and is shown as rejected, not deleted.
//

import Foundation

public nonisolated struct FactReview: Identifiable, Sendable, Hashable, Codable {
    public typealias ID = UUID

    /// A5.8 — the full reversible human-review vocabulary. Every action is an
    /// append-only row; a `.reverse` row (carrying `reversalOf`) undoes a prior
    /// review without deleting it, so the history — including the undo — stays
    /// intact. Older rows only ever used accept/reject/correct; those decode
    /// unchanged.
    public enum Action: String, Codable, Sendable, CaseIterable, Hashable {
        case accept
        case reject
        case correct
        /// Merge two entities/events judged to be the same (newValue = target id).
        case merge
        /// Split a conflated entity/event back apart.
        case split
        /// Change a date/precision without rejecting the fact.
        case precisionChange
        /// Mark a contradiction resolved (which side, in reason/newValue).
        case resolveContradiction
        /// Dismiss a gap as not-actually-missing.
        case dismissGap
        /// Reopen a previously-dismissed gap.
        case reopenGap
        /// Mark a source as authoritative for a claim.
        case markAuthority
        /// Undo a prior review (see `reversalOf`). Append-only reversibility.
        case reverse
    }

    public let id: ID
    /// What the review targets — mirrors FactStatusItem.sourceKind so a
    /// verdict can be matched back to its item.
    public let subjectKind: FactSourceKind
    /// The underlying ledger id (event/assertion/contradiction/gap id),
    /// which equals the FactStatusItem.id it reviews.
    public let subjectID: UUID
    public let action: Action
    /// The value before this review (e.g. the item title / prior status).
    public let priorValue: String?
    /// The corrected value, for `.correct`.
    public let newValue: String?
    public let reviewer: String
    /// Required for reject/correct; optional for accept.
    public let reason: String?
    /// A5.8 — for a `.reverse` action, the id of the review row being undone.
    /// nil for all non-reversal actions.
    public let reversalOf: UUID?
    public let reviewedAt: Date

    public nonisolated init(
        id: ID = UUID(),
        subjectKind: FactSourceKind,
        subjectID: UUID,
        action: Action,
        priorValue: String? = nil,
        newValue: String? = nil,
        reviewer: String = "user",
        reason: String? = nil,
        reversalOf: UUID? = nil,
        reviewedAt: Date = Date()
    ) {
        self.id = id
        self.subjectKind = subjectKind
        self.subjectID = subjectID
        self.action = action
        self.priorValue = priorValue
        self.newValue = newValue
        self.reviewer = reviewer
        self.reason = reason
        self.reversalOf = reversalOf
        self.reviewedAt = reviewedAt
    }
}
