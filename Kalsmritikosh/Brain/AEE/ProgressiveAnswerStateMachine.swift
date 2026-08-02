//
//  ProgressiveAnswerStateMachine.swift
//  Kalsmritikosh
//
//  AEE-M2 — the legal ORDER of the seven answer-lifecycle states. It validates transitions
//  and terminality; it does NOT decide whether a content change is a correction (that is the
//  content-fingerprint rule enforced in the ledger). Deterministic and pure.
//
//  Legal order:
//    (initial) → immediateFinding | groundedWorkingResult | analysisProgress | incomplete
//    immediateFinding      → groundedWorkingResult | analysisProgress | reviewReady | corrected | incomplete
//    groundedWorkingResult → analysisProgress | reviewReady | corrected | incomplete
//    analysisProgress      → groundedWorkingResult | analysisProgress | reviewReady | corrected | incomplete
//    corrected             → analysisProgress | reviewReady | corrected | incomplete
//    reviewReady           → verifiedFinal | corrected | analysisProgress | incomplete
//    verifiedFinal         → (terminal)
//    incomplete            → (terminal)
//

import Foundation

public nonisolated struct ProgressiveAnswerStateMachine: Sendable {
    public init() {}

    /// The states a brand-new answer may START in.
    public static let initialStates: Set<ProgressiveAnswerState> =
        [.immediateFinding, .groundedWorkingResult, .analysisProgress, .incomplete]

    public func isInitial(_ state: ProgressiveAnswerState) -> Bool {
        Self.initialStates.contains(state)
    }

    /// Whether `to` may legally follow `from` (nil `from` = the first event).
    public func canTransition(from: ProgressiveAnswerState?, to: ProgressiveAnswerState) -> Bool {
        guard let from else { return isInitial(to) }
        if from.isTerminal { return false }
        return Self.allowed(from).contains(to)
    }

    /// Validate a transition, throwing the specific illegal-transition error.
    public func validate(from: ProgressiveAnswerState?, to: ProgressiveAnswerState) throws {
        guard canTransition(from: from, to: to) else {
            throw ProgressiveAnswerError.illegalTransition(from: from, to: to)
        }
    }

    static func allowed(_ from: ProgressiveAnswerState) -> Set<ProgressiveAnswerState> {
        switch from {
        case .immediateFinding:
            return [.groundedWorkingResult, .analysisProgress, .reviewReady, .corrected, .incomplete]
        case .groundedWorkingResult:
            return [.analysisProgress, .reviewReady, .corrected, .incomplete]
        case .analysisProgress:
            return [.groundedWorkingResult, .analysisProgress, .reviewReady, .corrected, .incomplete]
        case .corrected:
            return [.analysisProgress, .reviewReady, .corrected, .incomplete]
        case .reviewReady:
            return [.verifiedFinal, .corrected, .analysisProgress, .incomplete]
        case .verifiedFinal, .incomplete:
            return []
        }
    }
}
