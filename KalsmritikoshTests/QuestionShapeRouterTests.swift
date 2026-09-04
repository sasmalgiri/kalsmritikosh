//
//  QuestionShapeRouterTests.swift
//  KalsmritikoshTests
//
//  P3-U1 — the shape router's laws: Q0 is high-precision (the deadly sin is
//  refusing an answerable question), the twin is a genuinely disjoint check,
//  disagreement takes the SAFEST shape, and the live seven route exactly as
//  the sealed world expects.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("P3-U1 — question shapes + the route twin")
@MainActor
struct QuestionShapeRouterTests {

    @Test("THE LIVE SEVEN route exactly: France is out of scope, everything else stays in the pipeline")
    func liveSevenRouting() {
        // Q7 — the 84-second refusal becomes an instant one.
        let q7 = QuestionShapeRouter.route("what is the capital of France")
        #expect(q7.shape == .outOfScope && q7.twinAgreed)

        // Q1–Q6 keep their lanes (never Q0; existence/count where shaped so).
        #expect(QuestionShapeRouter.route("what is the granted patent number").shape == .unresolved)
        #expect(QuestionShapeRouter.route("what is the application number").shape == .unresolved)
        #expect(QuestionShapeRouter.route("on which date was the patent granted").shape == .unresolved)
        #expect(QuestionShapeRouter.route("who is Shirshendu Sasmal").shape == .unresolved)
        #expect(QuestionShapeRouter.route("how many hearings were there").shape == .count)
        let q6 = QuestionShapeRouter.route("is there any invoice from Khurana and Khurana")
        #expect(q6.shape == .existence, "a yes/no about the archive is an existence question")
    }

    @Test("THE OWNER'S QUESTION is existence — and can never be refused as out of scope")
    func ownersQuestion() {
        let r = QuestionShapeRouter.route("is the patent granted?")
        #expect(r.shape == .existence, "got \(r.shape)")
        #expect(r.shape != .outOfScope)
    }

    @Test("Q0 innocence: an archive referent vetoes the world-knowledge pattern")
    func q0Innocence() {
        // "capital of" pattern + an identifier → the archive wins, Q0 never fires.
        #expect(QuestionShapeRouter.detect("what is the capital of the company in invoice 7741") != .outOfScope)
        // Field vocabulary anchors the question to the archive.
        #expect(QuestionShapeRouter.detect("who is the president of the patent office that granted it") != .outOfScope)
        // Pure world knowledge with no referent refuses.
        #expect(QuestionShapeRouter.detect("what is the population of Japan") == .outOfScope)
    }

    @Test("Twin disagreement takes the SAFEST shape and says so in the receipt")
    func twinSafety() {
        // Construct a disagreement: "is it true the weather was discussed" —
        // primary sees existence ("is it true" opener); the twin's token set
        // sees "weather" → outOfScope BUT hasArchiveReferent? no referent →
        // twin says outOfScope, primary says existence → safest = existence
        // (earlier in safestOrder). The pipeline runs; nothing is refused.
        let r = QuestionShapeRouter.route("is it true the weather was discussed")
        if !r.twinAgreed {
            #expect(r.shape != .outOfScope, "disagreement must never resolve TO a refusal")
            #expect(r.receiptLine.contains("safer"), "the receipt names the safety choice")
        } else {
            #expect(r.shape != .outOfScope, "either way, an ambiguous question is never refused")
        }
        // The safest order itself is pinned: unresolved first, refusal last.
        #expect(QuestionShapeRouter.safestOrder.first == .unresolved)
        #expect(QuestionShapeRouter.safestOrder.last == .outOfScope)
    }

    @Test("Routing is deterministic and the refusal text is fixed, plain, model-free")
    func determinismAndRefusal() {
        let a = QuestionShapeRouter.route("what is the capital of France")
        let b = QuestionShapeRouter.route("what is the capital of France")
        #expect(a == b)
        #expect(QuestionShapeRouter.outOfScopeRefusal.contains("your ingested documents"))
        #expect(!QuestionShapeRouter.outOfScopeRefusal.lowercased().contains("llm"),
                "RC-8: no jargon in a user-facing sentence")
    }
}
