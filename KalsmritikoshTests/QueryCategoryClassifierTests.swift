//
//  QueryCategoryClassifierTests.swift
//

import Testing
@testable import Kalsmritikosh

@Suite("QueryCategoryClassifier — Vol 09 §Query Categories")
struct QueryCategoryClassifierTests {
    let classifier = QueryCategoryClassifier()

    @Test("counterfactual phrasing wins on priority")
    func counterfactualBeatsFact() {
        let q = "what if the contract hadn't been signed?"
        #expect(classifier.classify(question: q) == .counterfactual)
    }

    @Test("root-cause keywords")
    func rootCausePattern() {
        #expect(classifier.classify(question: "why did the invoice arrive late?") == .rootCause)
        #expect(classifier.classify(question: "what caused the delivery delay?") == .rootCause)
    }

    @Test("risk patterns")
    func riskPatterns() {
        #expect(classifier.classify(question: "what compliance risk exists with Supplier ABC?") == .risk)
    }

    @Test("comparison patterns")
    func comparisonPatterns() {
        #expect(classifier.classify(question: "compare 2024 and 2025 invoice totals") == .comparison)
    }

    @Test("trend patterns")
    func trendPatterns() {
        #expect(classifier.classify(question: "what changed over time with Project Delta?") == .trend)
    }

    @Test("timeline patterns")
    func timelinePatterns() {
        #expect(classifier.classify(question: "when did the contract get signed?") == .timeline)
    }

    @Test("narrative patterns")
    func narrativePatterns() {
        #expect(classifier.classify(question: "tell me the story of Project Delta") == .narrative)
    }

    @Test("default to .fact when nothing matches")
    func defaultsToFact() {
        #expect(classifier.classify(question: "asdf zxcv qwer") == .fact)
    }
}
