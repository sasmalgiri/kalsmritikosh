//
//  ProgressiveAnswer.swift
//  Kalsmritikosh
//
//  AEE-M2 — the progressive answer LIFECYCLE vocabulary. This describes where an answer is
//  in its life (provisional → working → review-ready → verified/incomplete, with explicit
//  corrections), NOT whether the corpus supports it. The corpus-support judgement stays in
//  the separate `AnswerState` (supported/partiallySupported/contradicted/…). The two systems
//  are never merged.
//

import Foundation

/// The seven closed AEE-M2 answer-lifecycle states. Answer lifecycle — not evidence truth.
public nonisolated enum ProgressiveAnswerState: String, Sendable, Codable, CaseIterable, Hashable {
    /// A cited deterministic/source-grounded finding, explicitly provisional.
    case immediateFinding
    /// The first answer-shaped result with citations; evidence-grounded but not final.
    case groundedWorkingResult
    /// Status/progress only — must NOT introduce uncited factual claims (revision-less).
    case analysisProgress
    /// The current answer content satisfies the mission's evidence obligations and is ready
    /// for final verification.
    case reviewReady
    /// The locked answer, after verification AND a durable answer-ledger commit.
    case verifiedFinal
    /// An explicit replacement of previously visible answer content; the previous revision
    /// remains preserved.
    case corrected
    /// The mission could not be completed honestly — evidence/readiness/support/budget was
    /// insufficient.
    case incomplete

    /// A content-bearing state MUST reference a revision. `analysisProgress` is status-only,
    /// and `incomplete` may be revision-less (a mission interrupted/failed before any content)
    /// OR carry a partial revision (what was found) — so it does not strictly require one.
    public var isContentBearing: Bool { self != .analysisProgress && self != .incomplete }

    /// Terminal lifecycle states — nothing follows them for this answer.
    public var isTerminal: Bool { self == .verifiedFinal || self == .incomplete }
}

/// The closed kinds of reason a correction may carry. `.other` requires a nonblank detail.
public nonisolated enum CorrectionReasonKind: String, Sendable, Codable, CaseIterable, Hashable {
    case additionalEvidence
    case contradictionDiscovered
    case sourceUpgradeChangedEvidence
    case verificationDowngrade
    case evidenceWithdrawn
    case userCorrection
    case processingCorrection
    case other

    /// `.other` must be accompanied by a nonblank free-text detail.
    public var requiresDetail: Bool { self == .other }

    /// A user correction stays USER-ATTRIBUTED — it never becomes an independently verified
    /// fact on its own.
    public var isUserAttributed: Bool { self == .userCorrection }
}

/// Errors from the progressive-answer state machine / correction engine / ledger.
public nonisolated enum ProgressiveAnswerError: Error, Sendable, Equatable, Hashable {
    case illegalTransition(from: ProgressiveAnswerState?, to: ProgressiveAnswerState)
    case correctionRequiresPriorRevision
    case correctionReasonRequired
    case correctionReasonDetailRequired
    case correctionCrossAnswer
    case contentUnchanged
    case answerNotFound
    case revisionNotFound
    case answerAlreadyTerminal
    case noContentRevisionToReview
    case notReviewReady
}
