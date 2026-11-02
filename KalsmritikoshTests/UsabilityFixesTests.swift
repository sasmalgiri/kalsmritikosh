//
//  UsabilityFixesTests.swift
//  KalsmritikoshTests
//
//  Findings of the agent user evaluation of 2026-11-02 (docs/agent-reviews/user-evaluation-2026-11-02.md)
//  that can be checked without driving the UI.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("Usability evaluation 2026-11-02 fixes")
struct UsabilityFixesTests {

    @Test("M2: a copied answer is plain text and names its sources by file name")
    func copiedAnswer() {
        let body = "## Agreement\n**Effective Date:** March 1, 2024\n\n"
        let one = AnswerCopyText.make(body: body, sourceNames: ["contract.md"])
        #expect(!one.contains("**") && !one.contains("##"))
        #expect(one.hasPrefix("Agreement\nEffective Date: March 1, 2024"))
        #expect(one.hasSuffix("Source: contract.md"))
        let two = AnswerCopyText.make(body: "Yes.", sourceNames: ["b.pdf", "a.pdf", "b.pdf"])
        #expect(two == "Yes.\n\nSources:\n• a.pdf\n• b.pdf")
        #expect(AnswerCopyText.make(body: "Yes.", sourceNames: []) == "Yes.")
    }
}
