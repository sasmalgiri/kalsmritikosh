//
//  SummaryClassificationTests.swift
//  KalsmritikoshTests
//
//  U-3.5 (W-6) — CommunitySummarizer classification: a model-generated
//  summary is routing-only, never retrieval evidence. Pure, fast tier.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("U-3.5 summary classification")
struct SummaryClassificationTests {

    private func summary(modelID: String?) -> Summary {
        Summary(level: .knowledgeBase, length: .short, scope: .knowledgeBase,
                body: "…", modelID: modelID)
    }

    @Test func extractiveSummariesAreRetrievalEligible() {
        #expect(summary(modelID: nil).isRetrievalEligible)
        #expect(summary(modelID: "").isRetrievalEligible)
        #expect(summary(modelID: Summary.deterministicModelPrefix + "topic-v1").isRetrievalEligible)
    }

    @Test func modelGeneratedSummariesAreRoutingOnly() {
        #expect(!summary(modelID: "provider.apple.fm").isRetrievalEligible)
        #expect(!summary(modelID: "com.apple.foundationmodels").isRetrievalEligible)
    }
}
