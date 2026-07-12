//
//  FinalVersionGapTests.swift
//  KalsmritikoshTests
//
//  A5.7 — GapDetector.detectMissingFinalVersion: a draft document with no
//  final/signed counterpart sharing its name is a draft-only gap. Add to the
//  test target to run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct FinalVersionGapTests {

    @Test func draftWithoutFinalIsAGap() {
        let gaps = GapDetector().detectMissingFinalVersion(documents: [
            (objectID: UUID(), filename: "ServiceAgreement-draft.docx")
        ])
        #expect(gaps.count == 1)
        #expect(gaps.first?.kind == .finalVersion)
        #expect(gaps.first?.description.contains("draft") == true)
    }

    @Test func draftWithMatchingFinalIsNotAGap() {
        let gaps = GapDetector().detectMissingFinalVersion(documents: [
            (objectID: UUID(), filename: "ServiceAgreement-draft.docx"),
            (objectID: UUID(), filename: "ServiceAgreement-final.pdf")
        ])
        #expect(gaps.isEmpty)
    }

    @Test func signedCounterpartAlsoClears() {
        let gaps = GapDetector().detectMissingFinalVersion(documents: [
            (objectID: UUID(), filename: "Contract draft.docx"),
            (objectID: UUID(), filename: "Contract signed.pdf")
        ])
        #expect(gaps.isEmpty)
    }

    @Test func unrelatedFinalDoesNotClear() {
        let gaps = GapDetector().detectMissingFinalVersion(documents: [
            (objectID: UUID(), filename: "Budget draft.xlsx"),
            (objectID: UUID(), filename: "Roadmap final.pptx")
        ])
        #expect(gaps.count == 1)
    }

    @Test func significantTokensDropMarkersAndStopwords() {
        let tokens = GapDetector.significantTokens("ServiceAgreement-draft-v2.docx")
        #expect(tokens.contains("serviceagreement"))
        #expect(!tokens.contains("draft"))
    }
}
