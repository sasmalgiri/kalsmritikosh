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
        // The app writes dates day first ("03/05/2019" is 3 May 2019).
        #expect(YesNoFieldGate.apply(question: "Is the recall initiation date for FDA recall Z-2066-2019 2019-05-03?",
                                     Self.answer("Recall initiation date: 03/05/2019.")).body.hasPrefix("Yes"))
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

    @Test("An unquoted headline is a title; account questions ask for no field")
    func unquotedTitles() {
        #expect(IdentifierAnchoredRetriever.quotedTitles(in: "Summarize the case Alabama Woman Pleads Guilty to Stealing Over $700,000 From Her Employer.")
                == ["alabama woman pleads guilty to stealing over $700,000 from her employer"])
        #expect(IdentifierAnchoredRetriever.quotedTitles(in: "Summarize the case files for me.").isEmpty)
        let known: Set<String> = ["component", "classification"]
        #expect(SlotFieldResolver.resolve(in: "What part of the vehicle is NHTSA investigation PE10025 about?", knownFields: known).map(\.fieldID) == ["component"])
        #expect(SlotFieldResolver.resolve(in: "Which class is FDA recall Z-0049-2018?", knownFields: known).map(\.fieldID) == ["classification"])
    }

    @Test("Held-out wordings: who issued a recall is its firm; litigants are parties; what the court ruled is its decision")
    func heldOutFixes() {
        #expect(!IssuingOfficeGate.asksIssuingOffice("Who issued FDA recall Z-2066-2019?"))
        #expect(IssuingOfficeGate.asksIssuingOffice("Who issued the release about the case X?"))
        #expect(!AbsentAttributeGate.apply(question: "What airplane was involved in NTSB case ERA13CA130?",
                                           Self.answer("Aircraft: Cessna 172, registration N662DA.")).refused)
        #expect(SlotFieldResolver.resolve(in: "What did the court rule in Pinching v. Wurdeman?").map(\.fieldID) == ["disposition"])
        #expect(SentenceQuoteComposer.reasonWeight("NTSB SEA03LA084 — probable cause The pilot did not attain the proper touchdown point.", previous: "") == 6)
    }

    @Test("Untouched-wording fixes: modifier nouns, justices, who is credited, what led to")
    func untouchedWordings() {
        let known: Set<String> = ["classification", "reasonforrecall", "recallingfirm"]
        #expect(SlotFieldResolver.resolve(in: "What recall class was assigned to FDA recall Z-2066-2019?", knownFields: known).map(\.fieldID) == ["classification"])
        #expect(SlotFieldResolver.resolve(in: "Which justice authored the ruling in Pinching v. Wurdeman?").first?.fieldID == "opinionauthor")
        #expect(IssuingOfficeGate.asksIssuingOffice("Who is credited with announcing \"X\"?"))
        #expect(SentenceQuoteComposer.asksWhy("What led to the accident in NTSB case ERA13CA130?"))
    }

    @Test("A release's publication date is asked many ways")
    func publicationDates() {
        #expect(DateQuestionGate.asksPublicationDate("When was the press release about \"X\" issued?"))
        #expect(DateQuestionGate.asksPublicationDate("What's the publication date of \"X\"?"))
        #expect(!DateQuestionGate.asksPublicationDate("When was Pinching v. Wurdeman decided?"))
    }

    @Test("Held-out wording set 4: outcomes, tribunals, handed down, offices, counts, parts")
    func heldOutSetFour() {
        let court: Set<String> = ["disposition", "court", "opinionauthor", "decisiondate", "casenumber", "parties", "date"]
        func f(_ q: String, _ k: Set<String>) -> String? { SlotFieldResolver.resolve(in: q, knownFields: k).first?.fieldID }
        #expect(f("What was the court's decision in Mayo v. United States?", court) == "disposition")
        #expect(f("Was Mayo v. United States affirmed or reversed?", court) == "disposition")
        #expect(f("When was the court's decision in Mayo v. United States issued?", court) == "decisiondate")
        #expect(f("Which tribunal decided Mayo v. United States?", court) == "court")
        #expect(f("On what date did the court rule in Mayo v. United States?", court) == "decisiondate")
        #expect(f("What day was Mayo v. United States handed down?", court) == "decisiondate")
        #expect(f("Who were the two sides in Mayo v. United States?", court) == "parties")
        // A party's name is not a field, even when the ledger minted one from it.
        let minted = court.union(["missouri"])
        #expect(f("Which justice or judge penned Missouri-Kansas-Texas Railroad v. National Railroad Adjustment Board?", minted) == "opinionauthor")
        #expect(f("How did Missouri-Kansas-Texas Railroad v. National Railroad Adjustment Board come out?", minted) == "disposition")
        #expect(!YesNoFieldGate.asksYesNo("Was Mayo v. United States affirmed or reversed?"))
        #expect(YesNoFieldGate.asksYesNo("Was Mayo v. United States affirmed or not?"))
        #expect(IdentityFieldResolver.questionFieldType("What is the name of the court in Mayo v. United States?") == nil)
        #expect(IdentityFieldResolver.questionFieldType("What is the name of the holder?") == .personName)
        #expect(f("What recall class applies to FDA recall Z-2066-2019?", ["classification", "reasonforrecall", "recallingfirm"]) == "classification")
        #expect(f("What vehicle system does NHTSA investigation EQ08013 concern?", ["component", "subject", "manufacturer"]) == "component")
        #expect(IssuingOfficeGate.asksIssuingOffice("Which office put out \"X\"?"))
        #expect(IssuingOfficeGate.asksIssuingOffice("Who released \"X\"?"))
        #expect(!IssuingOfficeGate.asksIssuingOffice("Who issued FDA recall Z-2066-2019?"))
        #expect(DateQuestionGate.asksPublicationDate("When did \"X\" come out?"))
        #expect(CountQuestionGate.asksCount("What number of employees were injured in OSHA investigation 1?"))
        #expect(SentenceQuoteComposer.asksWhy("What did investigators determine caused NTSB case ERA13CA130?"))
    }

    @Test("A body paragraph citing another decision gives no decision date")
    func citedDecisionDateIgnored() {
        let body = String(repeating: "The controlling facts are stipulated by the parties. ", count: 14)
            + "This ruling was made upon the authority of the decision in Acacia Park Cemetery Ass'n v. Commissioner, supra, decided January 11, 1934, which dealt with the plaintiff's deduction."
        let facts = LegalCaseDomainPack.extractFacts(fromText: body, subjectLabel: "M", blockID: UUID())
        #expect(!facts.contains { $0.field.lowercased() == "decisiondate" })
        let caption = "Memphis Memorial Park v. McCann\nCiv. A. Nos. 1675-1677.\nUnited States District Court M. D. Tennessee, Nashville Division.\nJuly 28, 1955.\nBenjamin Goodman for plaintiff."
        #expect(LegalCaseDomainPack.extractFacts(fromText: caption, subjectLabel: "M", blockID: UUID())
            .first { $0.field.lowercased() == "decisiondate" }?.value == "1955-07-28")
    }
}

