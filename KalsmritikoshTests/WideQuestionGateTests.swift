//
//  WideQuestionGateTests.swift
//  KalsmritikoshTests
//
//  Wide case bench 2026-10-25: yes/no questions are answered yes or no against the value the
//  documents give; a question about something the documents never mention is answered "not
//  mentioned" instead of with another field or a passage.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("Wide question gates")
struct WideQuestionGateTests {

    static func answer(_ body: String, snippets: [String] = []) -> VerifiedAnswer {
        VerifiedAnswer(body: body, citations: snippets.map { VerifiedAnswer.Citation(objectID: UUID(), chunkID: nil, eventID: nil, snippet: $0) },
                       confidence: Confidence(0.8))
    }

    @Test("A yes/no question about a field gets yes or no against the documents' value")
    func yesNo() {
        let a = Self.answer("Recalling firm: Attix Pharmaceuticals.")
        #expect(YesNoFieldGate.apply(question: "Is the recalling firm for FDA recall D-769-2015 Attix Pharmaceuticals?", a).body
                == "Yes — Recalling firm: Attix Pharmaceuticals.")
        #expect(YesNoFieldGate.apply(question: "Is the recalling firm for FDA recall D-769-2015 Medline Industries?", a).body
                == "No — the documents give recalling firm: Attix Pharmaceuticals.")
        // "Class II" is not "Class III".
        #expect(YesNoFieldGate.apply(question: "Is the classification for FDA recall X Class III?", Self.answer("Classification: Class II.")).body.hasPrefix("No"))
        // Dates match however they are written.
        #expect(YesNoFieldGate.apply(question: "Is the date opened for NHTSA investigation PE04074 2004-11-02?",
                                     Self.answer("Date opened: November 2, 2004.")).body.hasPrefix("Yes"))
        // Not a yes/no question, or not a labeled value: untouched.
        #expect(YesNoFieldGate.apply(question: "Which firm initiated FDA recall X?", a).body == a.body)
        #expect(YesNoFieldGate.apply(question: "Is the recall still ongoing?", Self.answer("The document states: “…”")).body == "The document states: “…”")
    }

    @Test("A question about something the documents never mention is answered 'not mentioned'")
    func absent() {
        let wrongField = Self.answer("Reason for recall: Lack of sterility assurance.")
        let out = AbsentAttributeGate.apply(question: "Who was the FDA investigator assigned to FDA recall D-0775-2020?", wrongField,
                                            sourceTexts: ["Recalling firm: Assurance Infusion. Reason for recall: Lack of sterility assurance."])
        #expect(out.refused)
        #expect(out.body == "The documents searched don't mention the investigator.")
        // The thing asked for is in the documents: kept.
        let kept = AbsentAttributeGate.apply(question: "Who was the pilot in NTSB case ERA13CA130?", Self.answer("The pilot, John Smith, reported …"))
        #expect(!kept.refused)
        // A field named for the thing asked: kept.
        #expect(!AbsentAttributeGate.apply(question: "Which firm initiated FDA recall X?", Self.answer("Recalling firm: Acme.")).refused)
        // Generic words never refuse.
        #expect(AbsentAttributeGate.askedFor("What is the docket number in Goudeau v. Daigle?") == nil)
        #expect(AbsentAttributeGate.askedFor("What happened in the case \"X\"?") == nil)
    }

    @Test("Reworded questions reach the same field")
    func rephrasings() {
        #expect(SlotFieldResolver.resolve(in: "Who authored the opinion in Hughes v. Life Insurance Co.?").map(\.fieldID) == ["opinionauthor"])
        #expect(SlotFieldResolver.resolve(in: "Which judge wrote the opinion in In re Kindred?").map(\.fieldID) == ["opinionauthor"])
        #expect(SlotFieldResolver.resolve(in: "What was the outcome of Pinching v. Wurdeman?").map(\.fieldID) == ["disposition"])
        #expect(SlotFieldResolver.resolve(in: "How was Pinching v. Wurdeman decided?").map(\.fieldID) == ["disposition"])
        #expect(SlotFieldResolver.resolve(in: "Name the court that decided Pinching v. Wurdeman.").map(\.fieldID) == ["court"])
        #expect(SlotFieldResolver.resolve(in: "Give me the date for Pinching v. Wurdeman.").map(\.fieldID) == ["decisiondate"])
        let known: Set<String> = ["classification", "manufacturer", "probablecause", "recallingfirm", "recallinitiationdate", "recall"]
        #expect(SlotFieldResolver.resolve(in: "How was FDA recall D-0561-2021 classified?", knownFields: known).map(\.fieldID) == ["classification"])
        #expect(SlotFieldResolver.resolve(in: "Who manufactured the vehicles in NHTSA investigation PE04074?", knownFields: known).map(\.fieldID) == ["manufacturer"])
        #expect(SlotFieldResolver.resolve(in: "What caused the accident in NTSB case FTW96LA098?", knownFields: known).map(\.fieldID) == ["probablecause"])
        #expect(IssuingOfficeGate.asksIssuingOffice("Who announced the case \"X\"?"))
        #expect(LegalCaseDomainPack.opensWithReportedCaption("Pinching v. Wurdeman\n12 F.2d 164\nPINCHING v. WURDEMAN."))
        #expect(!LegalCaseDomainPack.opensWithReportedCaption("Minutes of the meeting\nSee Smith v. Jones."))
    }
}

