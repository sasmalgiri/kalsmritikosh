//
//  SentenceQuoteWhyTests.swift
//  KalsmritikoshTests
//
//  Case bench 2026-10-21: "Why was FDA recall Z-2366-2021 issued?" was answered with the report's
//  title line, which repeats the recall number and says nothing about why. A why-question now
//  quotes the stated reason.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Why-questions quote the stated reason")
struct SentenceQuoteWhyTests {

    private func chunk(_ text: String) -> RetrievedChunk {
        RetrievedChunk(chunk: Chunk(objectID: UUID(), ordinal: 0, text: text, characterRange: 0..<text.count),
                       score: 1, viaLayer: .metadata)
    }

    @Test("The line under a reason label is the answer, not the title that repeats the reference")
    func reasonLabel() throws {
        let report = """
        FDA Enforcement Report — recall Z-2366-2021

        Recalling firm: Covidien, LP
        Classification: Class II
        Reason for recall:
        The repair kit's sterile barrier may be compromised, which could expose patients to infection.
        """
        let q = try #require(SentenceQuoteComposer.compose(question: "Why was FDA recall Z-2366-2021 issued?", chunks: [chunk(report)]))
        #expect(q.sentence.contains("sterile barrier"), "\(q.sentence)")
    }

    @Test("A non-why question is unchanged")
    func notWhy() {
        #expect(!SentenceQuoteComposer.asksWhy("When was FDA recall Z-2366-2021 initiated?"))
        #expect(SentenceQuoteComposer.asksWhy("Why was the recall issued?"))
    }
}
