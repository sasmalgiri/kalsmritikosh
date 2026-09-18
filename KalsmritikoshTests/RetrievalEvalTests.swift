//
//  RetrievalEvalTests.swift
//  KalsmritikoshTests
//
//  Plan B1 — the metrics harness computes recall@k / precision@k / unanswerable
//  handling / answerable coverage separately and deterministically over an
//  injected retriever. This is the yardstick later retrieval changes must beat.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("Plan B1 — retrieval metrics harness")
struct RetrievalEvalTests {

    private let a = UUID(), b = UUID(), c = UUID(), noise = UUID()

    @Test func perfectRetrievalScoresHigh() {
        let cases = [RetrievalGoldCase(question: "q1", relevantObjectIDs: [a, b])]
        let m = RetrievalEval.score(cases: cases, k: 10) { _ in [a, b] }
        #expect(m.meanRecallAtK == 1.0)
        #expect(m.answerableCovered == 1.0)
    }

    @Test func missedRelevantLowersRecall() {
        let cases = [RetrievalGoldCase(question: "q", relevantObjectIDs: [a, b])]
        let m = RetrievalEval.score(cases: cases, k: 10) { _ in [a, noise] }   // got 1 of 2
        #expect(m.meanRecallAtK == 0.5)
        #expect(m.answerableCovered == 1.0)                                     // ≥1 hit
    }

    @Test func noiseLowersPrecision() {
        let cases = [RetrievalGoldCase(question: "q", relevantObjectIDs: [a])]
        let m = RetrievalEval.score(cases: cases, k: 4) { _ in [a, noise, noise, noise] }
        #expect(m.meanRecallAtK == 1.0)
        #expect(m.meanPrecisionAtK == 0.25)
    }

    @Test func unanswerableHandledWhenNoRelevantReturned() {
        let cases = [RetrievalGoldCase(question: "who signed the lease?",
                                       relevantObjectIDs: [], shouldAbstain: true)]
        let m = RetrievalEval.score(cases: cases, k: 10) { _ in [noise] }   // noise only → handled
        #expect(m.unanswerableHandled == 1.0)
    }

    @Test func kTruncationApplies() {
        let cases = [RetrievalGoldCase(question: "q", relevantObjectIDs: [c])]
        // c is at rank 5 but k=3 → not retrieved.
        let m = RetrievalEval.score(cases: cases, k: 3) { _ in [noise, noise, noise, noise, c] }
        #expect(m.meanRecallAtK == 0.0)
        #expect(m.answerableCovered == 0.0)
    }
}
