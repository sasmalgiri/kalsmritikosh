//
//  InvestigationClosure.swift
//  Kalsmritikosh
//
//  INV-20 (Closure & export) — the durable human closure/reopen decision (schema v101). A case is CLOSED
//  only by a recorded human decision; closure is HONEST (the unresolved items known at closure are retained,
//  never erased); and a reopen is a NEW decision that never rewrites the closure it follows. Truth boundaries
//  this model preserves:
//    • closure ≠ absence of unresolved issues  (a case may be closed WITH known gaps / open contradictions)
//    • case complete ≠ professional correctness (a closure records a human decision, never asserts truth)
//    • export ≠ permission to widen scope       (the sealed receipt pins the reviewed scope, nothing wider)
//

import Foundation

public nonisolated enum ClosureDecisionKind: String, Codable, Sendable, Equatable, CaseIterable {
    case closed
    case reopened
}

/// One recorded closure/reopen decision. `unresolvedItems` are the limitations the human accepted at closure
/// (kept visible, not hidden). `workProductRunID` / `receiptSeal` reference the sealed findings work product
/// and its export receipt when one was produced; `scopeFingerprint` pins the case scope at the decision.
public nonisolated struct InvestigationClosureDecision: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    public let sequence: Int
    public let decision: ClosureDecisionKind
    public let rationale: String
    public let workProductRunID: UUID?
    public let scopeFingerprint: CaseScopeFingerprint
    public let unresolvedItems: [String]
    public let receiptSeal: String?
    public let actor: String
    public let createdAt: Date

    public nonisolated init(id: UUID, caseID: UUID, sequence: Int, decision: ClosureDecisionKind, rationale: String,
                            workProductRunID: UUID?, scopeFingerprint: CaseScopeFingerprint, unresolvedItems: [String],
                            receiptSeal: String?, actor: String, createdAt: Date) {
        self.id = id; self.caseID = caseID; self.sequence = sequence; self.decision = decision; self.rationale = rationale
        self.workProductRunID = workProductRunID; self.scopeFingerprint = scopeFingerprint; self.unresolvedItems = unresolvedItems
        self.receiptSeal = receiptSeal; self.actor = actor; self.createdAt = createdAt
    }
}

public nonisolated enum InvestigationClosureError: Error, Sendable, Equatable {
    case caseNotFound(UUID)
    case caseAlreadyClosed(UUID)
    case caseNotClosed(UUID)               // cannot reopen a case that is not closed
    case revisionConflict(expected: Int, actual: Int)
    case blankRationale
    case blankActor
}
