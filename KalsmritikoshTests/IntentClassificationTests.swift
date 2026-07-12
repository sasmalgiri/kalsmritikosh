//
//  IntentClassificationTests.swift
//  KalsmritikoshTests
//
//  P1.5 — exact-lookup questions must NOT classify as reconstruction (which
//  would spend a 3-call budget on a 1-call question). Add to the test target.
//

import Testing
@testable import Kalsmritikosh

struct IntentClassificationTests {

    private func kind(_ q: String) async throws -> UserIntent.Kind {
        try await IntentDetector().detect(question: q).kind
    }

    // Exact lookups → NOT reconstruction (spec P1.5 counter-examples).
    @Test func exactLookupsAreNotReconstruction() async throws {
        for q in [
            "Tell me about invoice 14",
            "When was the email sent?",
            "How much was paid?",
            "Explain clause 7",
            "Who signed the contract?"
        ] {
            let k = try await kind(q)
            #expect(k != .reconstructTimeline)
            #expect(k != .reconstructProject)
            #expect(k != .reconstructRelationship)
        }
    }

    // Genuine reconstruction phrasing still routes to reconstruction.
    @Test func strongSignalsStayReconstruction() async throws {
        for q in [
            "Reconstruct the history of Project Delta",
            "How did the contract status evolve over time?",
            "Trace the chain from contract signing through to amendment 7",
            "Show me the timeline of the project"
        ] {
            let k = try await kind(q)
            #expect(k == .reconstructTimeline || k == .reconstructProject || k == .reconstructRelationship)
        }
    }
}
