//
//  FactReviewReversalTests.swift
//  KalsmritikoshTests
//
//  A5.8 — FactReviewsRepository.effectiveVerdicts: reversible append-only
//  review resolution. A `.reverse` row undoes the review it targets without
//  deleting anything. Add to the test target to run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct FactReviewReversalTests {

    private func review(_ action: FactReview.Action, subject: UUID, id: UUID = UUID(), reversalOf: UUID? = nil, at: TimeInterval) -> FactReview {
        FactReview(
            id: id, subjectKind: .event, subjectID: subject, action: action,
            reversalOf: reversalOf, reviewedAt: Date(timeIntervalSince1970: at)
        )
    }

    @Test func latestActiveVerdictWins() {
        let s = UUID()
        let verdicts = FactReviewsRepository.effectiveVerdicts([
            review(.accept, subject: s, at: 1),
            review(.reject, subject: s, at: 2)
        ])
        #expect(verdicts[s]?.action == .reject)
    }

    @Test func reversalUndoesTargetedReview() {
        let s = UUID()
        let accept = UUID()
        let verdicts = FactReviewsRepository.effectiveVerdicts([
            review(.accept, subject: s, id: accept, at: 1),
            review(.reverse, subject: s, reversalOf: accept, at: 2)
        ])
        // The accept was reversed and there is no other verdict → none effective.
        #expect(verdicts[s] == nil)
    }

    @Test func reversalRevealsThePriorActiveVerdict() {
        let s = UUID()
        let reject = UUID()
        let verdicts = FactReviewsRepository.effectiveVerdicts([
            review(.accept, subject: s, at: 1),
            review(.reject, subject: s, id: reject, at: 2),
            review(.reverse, subject: s, reversalOf: reject, at: 3)
        ])
        // The reject was undone → the earlier accept is the effective verdict.
        #expect(verdicts[s]?.action == .accept)
    }

    @Test func reverseRowIsNeverItselfAVerdict() {
        let s = UUID()
        let accept = UUID()
        let verdicts = FactReviewsRepository.effectiveVerdicts([
            review(.accept, subject: s, id: accept, at: 1),
            review(.correct, subject: s, at: 2),
            review(.reverse, subject: s, reversalOf: accept, at: 3)
        ])
        // Reversing the (already-superseded) accept leaves correct standing.
        #expect(verdicts[s]?.action == .correct)
    }
}
