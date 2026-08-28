//
//  EventModalityGuardTests.swift
//  KalsmritikoshTests
//
//  Port-review item 7b — the body-text event rules fire on completed-form
//  markers, but the surrounding words can flip the meaning: "will be
//  delivered on Friday" is a plan, "no payment received" is the OPPOSITE
//  fact, "if payment received" is a condition. The guard checks a short
//  same-sentence window before each occurrence; one clean occurrence
//  anywhere in the document is enough to keep the event.
//
//  Inputs are lowercase — the extractor lowercases content before matching.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Event modality guard (7b)")
struct EventModalityGuardTests {

    @Test("Future-tense phrasing does not become a completed event")
    func futureBlocked() {
        #expect(!RuleEventExtractor.hasCompletedOccurrence(
            of: "delivered on", in: "the goods will be delivered on friday"))
        #expect(!RuleEventExtractor.hasCompletedOccurrence(
            of: "payment received", in: "we expect to see the payment received by month end"))
    }

    @Test("Negation does not become the opposite fact")
    func negationBlocked() {
        #expect(!RuleEventExtractor.hasCompletedOccurrence(
            of: "payment received", in: "there was no payment received to date"))
        #expect(!RuleEventExtractor.hasCompletedOccurrence(
            of: "delivery completed", in: "there has been no delivery completed this week"))
    }

    @Test("Conditional phrasing is not a fact")
    func conditionalBlocked() {
        #expect(!RuleEventExtractor.hasCompletedOccurrence(
            of: "payment received", in: "if payment received, we will release the shipment"))
    }

    @Test("Completed form fires; a clean occurrence outweighs a blocked one")
    func completedFires() {
        #expect(RuleEventExtractor.hasCompletedOccurrence(
            of: "payment received", in: "payment received with thanks on 12 march"))
        #expect(RuleEventExtractor.hasCompletedOccurrence(
            of: "delivered on", in: "it will be delivered on friday they said. in fact it was delivered on tuesday"))
    }

    @Test("The window stops at a sentence boundary — an earlier sentence's 'not' cannot suppress")
    func sentenceBoundary() {
        #expect(RuleEventExtractor.hasCompletedOccurrence(
            of: "payment received", in: "we will not delay. payment received in full"))
    }
}
