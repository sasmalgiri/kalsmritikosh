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

    @Test("What happened in a matter named by its title: the account, not the headline")
    func whatHappenedSkipsTitle() throws {
        let release = """
        Former White House Advisor Convicted of Contempt of Congress
        Former White House advisor Peter K. Navarro, 72, of Washington, D.C., was found guilty today by a U.S. District Court jury of two counts of contempt of Congress stemming from his failure to comply with a subpoena issued by the House Select Committee.
        """
        let cover = "Please find attached the records for Former White House Advisor Convicted of Contempt of Congress."
        let q = try #require(SentenceQuoteComposer.compose(
            question: "What happened in the case \"Former White House Advisor Convicted of Contempt of Congress\"?",
            chunks: [chunk(cover), chunk(release)]))
        #expect(q.sentence.contains("Navarro"), "\(q.sentence)")
    }

    @Test("A non-why question is unchanged")
    func notWhy() {
        #expect(!SentenceQuoteComposer.asksWhy("When was FDA recall Z-2366-2021 initiated?"))
        #expect(SentenceQuoteComposer.asksWhy("Why was the recall issued?"))
    }
}

@Suite("A when-question names the dated field its verb points to")
struct NamedDateFieldTests {
    @Test("initiated → recall initiation date; opened → date opened; no match → nil")
    func named() {
        let fields: Set<String> = ["date", "recallinitiationdate", "dateopened", "recallingfirm"]
        #expect(SlotFieldResolver.namedDateField(in: "When was FDA recall D-0227-2026 initiated?", knownFields: fields)?.fieldID == "recallinitiationdate")
        #expect(SlotFieldResolver.namedDateField(in: "When did NHTSA open investigation PE08001?", knownFields: ["dateopened"]) == nil)
        #expect(SlotFieldResolver.namedDateField(in: "When was it opened?", knownFields: fields)?.fieldID == "dateopened")
        #expect(SlotFieldResolver.namedDateField(in: "Which firm initiated recall D-1?", knownFields: fields) == nil)
    }
}
