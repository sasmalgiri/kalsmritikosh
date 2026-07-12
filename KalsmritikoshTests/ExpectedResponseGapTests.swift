//
//  ExpectedResponseGapTests.swift
//  KalsmritikoshTests
//
//  A5.7 — GapDetector.detectExpectedResponses: a message that explicitly
//  requests a reply but has none in the archive is an awaiting-reply gap.
//  Add to the test target to run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct ExpectedResponseGapTests {

    @Test func requestWithoutReplyIsAGap() {
        let gaps = GapDetector().detectExpectedResponses(messages: [
            (objectID: UUID(), subject: "Budget sign-off", body: "Please confirm the revised budget by Friday.", hasReply: false)
        ])
        #expect(gaps.count == 1)
        #expect(gaps.first?.kind == .expectedResponse)
        #expect(gaps.first?.description.contains("Budget sign-off") == true)
        #expect(gaps.first?.reason.contains("not proof it was ignored") == true)
    }

    @Test func requestWithReplyIsNotAGap() {
        let gaps = GapDetector().detectExpectedResponses(messages: [
            (objectID: UUID(), subject: "Budget", body: "Please confirm.", hasReply: true)
        ])
        #expect(gaps.isEmpty)
    }

    @Test func noRequestPhraseIsNotAGap() {
        let gaps = GapDetector().detectExpectedResponses(messages: [
            (objectID: UUID(), subject: "FYI", body: "Sharing the notes from today.", hasReply: false)
        ])
        #expect(gaps.isEmpty)
    }

    @Test func bareQuestionMarkDoesNotTrigger() {
        // Only explicit request phrases trigger — not any question.
        let gaps = GapDetector().detectExpectedResponses(messages: [
            (objectID: UUID(), subject: "Quick one", body: "Is the office open Monday?", hasReply: false)
        ])
        #expect(gaps.isEmpty)
    }
}
