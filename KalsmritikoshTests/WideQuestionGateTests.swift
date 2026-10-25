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

    @Test("A record's own field line answers what/yes-no questions about that field")
    func fieldLines() {
        let report = "FDA Enforcement Report — recall D-0561-2021 Recalling firm: Cardinal Health Inc. Location: Dublin, OH Status: Terminated Recall initiation date: 2021-03-15"
        let passage = Self.answer("FDA Enforcement Report — recall D-0561-2021 Recalling firm: Cardinal Health Inc. …")
        #expect(YesNoFieldGate.answerFieldQuestion(question: "What is the status for FDA recall D-0561-2021?", passage, sourceTexts: [report]).body
                == "Status: Terminated.")
        #expect(YesNoFieldGate.apply(question: "Is the status for FDA recall D-0561-2021 Terminated?", passage, sourceTexts: [report]).body.hasPrefix("Yes"))
        #expect(YesNoFieldGate.apply(question: "Is the recall initiation date for FDA recall D-0561-2021 2019-12-20?", passage, sourceTexts: [report]).body
                == "No — the documents give recall initiation date: 2021-03-15.")
        #expect(IdentityFieldResolver.questionFieldType("Is the distribution pattern for X nationwide to research organizations?") == nil)
    }

    @Test("A recall's company is its firm; what led to a recall is its reason")
    func kinWords() {
        let known: Set<String> = ["recallingfirm", "reasonforrecall", "recall"]
        #expect(SlotFieldResolver.resolve(in: "Name the company behind FDA recall F-3176-2017.", knownFields: known).map(\.fieldID) == ["recallingfirm"])
        #expect(SlotFieldResolver.resolve(in: "What problem led to FDA recall F-3176-2017?", knownFields: known).map(\.fieldID) == ["reasonforrecall"])
        #expect(IdentityFieldResolver.questionFieldType("Name the company behind FDA recall F-3176-2017.") == nil)
        #expect(IdentityFieldResolver.questionFieldType("What is the company name?") == .organizationName)
    }

    @Test("Which prison? needs a named prison, not the word")
    func whichInstitution() {
        let q = "Which prison is the defendant held in for the case \"X\"?"
        let generic = AbsentAttributeGate.apply(question: q, Self.answer("He faces up to 30 years in federal prison."))
        #expect(generic.refused)
        let named = AbsentAttributeGate.apply(question: q, Self.answer("He is held at the Taft Correctional Institution in California."))
        #expect(!named.refused)
        // Not an institution: a word on file is enough.
        #expect(!AbsentAttributeGate.apply(question: "Which component was investigated in NHTSA investigation PE10025?",
                                           Self.answer("Model years: 2003\nComponent: AIR BAGS:SIDE/WINDOW")).refused)
    }

    @Test("The office comes from this matter's release, not another one the search surfaced")
    func officeFromThisMatter() {
        let q = "Who announced the case Oxnard Man Indicted for Stealing Mail Truck from Kern County Post Office?"
        let mine = "Oxnard Man Indicted for Stealing Mail Truck from Kern County Post Office. FRESNO — A grand jury indicted Ryan Taylor of Oxnard for stealing a mail truck from the Kern County post office."
        let other = "Milwaukee Woman Sentenced. United States Attorney Gregory J. Haanstad of the Eastern District of Wisconsin announced the sentence."
        let out = IssuingOfficeGate.apply(question: q, Self.answer(mine), sourceTexts: [mine, other])
        #expect(out.body == "The release doesn't name the office that announced it.")
        #expect(DateQuestionGate.asksWhen("Give me the announcement date of the release \"X\"."))
    }
}

