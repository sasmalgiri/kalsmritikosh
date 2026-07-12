//
//  StatementExtractorTests.swift
//  KalsmritikoshTests
//
//  A5 extraction — StatementExtractor finds attributed statements ("X confirmed
//  that …") for the source-asserted assertion path. Add to the test target to
//  run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct StatementExtractorTests {

    @Test func extractsSpeakerVerbAndClaim() {
        let s = StatementExtractor().statements(
            in: "Alice Martin confirmed that the shipment left on Monday. Unrelated text."
        )
        #expect(s.count == 1)
        #expect(s.first?.speaker == "Alice Martin")
        #expect(s.first?.verb == "confirmed")
        #expect(s.first?.claim.contains("shipment left on Monday") == true)
    }

    @Test func multipleAttributions() {
        let text = "Bob denied any wrongdoing in the matter. Carol Reyes stated the invoice was paid in full."
        let s = StatementExtractor().statements(in: text)
        #expect(s.count == 2)
        #expect(s.contains { $0.verb == "denied" })
        #expect(s.contains { $0.speaker == "Carol Reyes" && $0.verb == "stated" })
    }

    @Test func pronounSpeakersAreSkipped() {
        // "He said …" isn't a named source — skip it.
        #expect(StatementExtractor().statements(in: "He said the meeting was cancelled.").isEmpty)
    }

    @Test func narrationVerbsDoNotTrigger() {
        // "arrived", "went" are not attribution verbs.
        #expect(StatementExtractor().statements(in: "Alice Martin arrived at the office early.").isEmpty)
    }

    @Test func tooShortClaimIsIgnored() {
        #expect(StatementExtractor().statements(in: "Alice said no.").isEmpty)
    }
}
