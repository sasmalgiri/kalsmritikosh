//
//  ReviewVocabularies.swift
//  Kalsmritikosh
//
//  Persona features (F5). The contradiction- and gap-specific decision
//  vocabularies (§10.1 / §10.2). These are stored in the shared, append-only
//  review ledger (ReviewDecision, dimension `.reviewState`) as their raw
//  string, so history is complete and every decision is reversible by a
//  reversing row. Absence is NEVER labelled as proof (§10.4): a gap decision
//  can dismiss/reopen/plan-action, but the gap itself stays low-confidence
//  and reasoned.
//

import Foundation

/// How a human resolved (or declined to resolve) a surfaced conflict (§10.1).
public enum ContradictionReviewDecision: String, Sendable, CaseIterable, Codable {
    case unresolved
    case notActuallyConflict
    case sourceAPreferred
    case sourceBPreferred
    case bothContextuallyValid
    case needsMoreEvidence
    case resolvedByNewEvidence

    public var displayName: String {
        switch self {
        case .unresolved:            return "Unresolved"
        case .notActuallyConflict:   return "Not actually a conflict"
        case .sourceAPreferred:      return "Source A preferred"
        case .sourceBPreferred:      return "Source B preferred"
        case .bothContextuallyValid: return "Both contextually valid"
        case .needsMoreEvidence:     return "Needs more evidence"
        case .resolvedByNewEvidence: return "Resolved by new evidence"
        }
    }
}

/// Human action on a detected gap (§10.2). Absence is not proof — these
/// decisions manage the reporting/follow-up state, not a factual claim.
public enum GapReviewDecision: String, Sendable, CaseIterable, Codable {
    case open
    case dismissed
    case reopened
    case actionPlanned
    case resolvedByNewEvidence

    public var displayName: String {
        switch self {
        case .open:                  return "Open"
        case .dismissed:             return "Dismissed"
        case .reopened:              return "Reopened"
        case .actionPlanned:         return "Action planned"
        case .resolvedByNewEvidence: return "Resolved by new evidence"
        }
    }
}
