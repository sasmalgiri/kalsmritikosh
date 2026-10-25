//
//  CaseRecordGatesTests.swift
//  KalsmritikoshTests
//
//  Conclusion-withheld closed-case simulation, 2026-10-26: real NTSB investigations held without
//  their probable-cause finding.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("Record lines and withheld conclusions")
struct CaseRecordGatesTests {

    static func answer(_ body: String) -> VerifiedAnswer {
        VerifiedAnswer(body: body, citations: [VerifiedAnswer.Citation(objectID: UUID(), snippet: body)], confidence: Confidence(0.8))
    }

    static let record = """
        NTSB CEN10CA077 — aviation investigation, factual record

        Location: Ames, IA
        Date: December 18, 2009
        Aircraft: Cessna 172P, registration N99930, damage SUBS
        Injuries: 4 fatal, 0 serious, 0 minor
        """
    static let narrative = "NTSB CEN10CA077 — factual narrative\n\nThe accident occurred during a night flight. An FAA publication dated May 14, 2008, suggests that pilots make frequent position reports."

    @Test("The record's labeled line answers when and how many were killed")
    func recordLines() {
        let dump = Self.answer(Self.record + "\n" + Self.narrative)
        #expect(RecordLineGate.apply(question: "When did the accident in NTSB case CEN10CA077 happen?", dump, sourceTexts: [Self.record, Self.narrative]).body
                == "Date: December 18, 2009.")
        #expect(RecordLineGate.apply(question: "How many people were killed in NTSB case CEN10CA077?", dump, sourceTexts: [Self.record]).body
                == "4 killed — the record gives Injuries: 4 fatal, 0 serious, 0 minor.")
        // Another record's line is never used: the question's identifier must be in the text.
        let other = Self.answer("…")
        #expect(RecordLineGate.apply(question: "When did the accident in NTSB case ERA13CA130 happen?", other, sourceTexts: [Self.record]).body == "…")
    }

    @Test("A conclusion is answered only from text labeled as one")
    func conclusions() {
        let narrativeQuote = Self.answer("The document states: “The accident occurred during a night flight.”")
        let out = ConclusionGate.apply(question: "What did the NTSB conclude caused the accident in case CEN10CA077?", narrativeQuote,
                                       sourceTexts: [Self.narrative])
        #expect(out.refused)
        #expect(out.body.hasPrefix("None of the documents on file states the investigators' conclusion"))
        // Under a probable-cause heading, the same kind of quote is the finding.
        let labeled = "NTSB CEN10CA077 — probable cause\nThe pilot's failure to maintain clearance from terrain."
        let kept = ConclusionGate.apply(question: "What did the NTSB conclude caused the accident in case CEN10CA077?",
                                        Self.answer("The document states: “The pilot's failure to maintain clearance from terrain.”"), sourceTexts: [labeled])
        #expect(!kept.refused)
        #expect(!ConclusionGate.asksConclusion("What happened in NTSB case CEN10CA077?"))
        #expect(ConclusionGate.asksConclusion("What did investigators determine caused NTSB case ERA13CA130?"))
    }
}
