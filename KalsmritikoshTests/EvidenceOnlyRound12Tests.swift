//
//  EvidenceOnlyRound12Tests.swift
//  KalsmritikoshTests
//
//  Case bench 2026-10-24, evidence-only round 12: the extraction and routing rules the round's
//  failures were traced to — caption parties, field-less where/why/happen questions, quoted
//  titles, issuing offices, labels whose value is on the next line, and datelines.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("Evidence-only round 12")
struct EvidenceOnlyRound12Tests {

    // MARK: Caption parties

    @Test("The caption's case name gives the parties; a reporter citation after it is cut off")
    func captionParties() {
        #expect(LegalCaseDomainPack.captionParties(in: "Sims v. Dallas Ry. & Terminal Co. 135 S.W.2d 142 SIMS et ux. v. DALLAS") == "Sims v. Dallas Ry. & Terminal Co.")
        #expect(LegalCaseDomainPack.captionParties(in: "In re Kindred 117 Cal. App. 3d 165 [Crim. No. 5335.") == "In re Kindred")
        #expect(LegalCaseDomainPack.captionParties(in: "City of Waco v. Witt\n126 S.W.2d 1002") == "City of Waco v. Witt")
        #expect(LegalCaseDomainPack.captionParties(in: "Texas & N. O. R. v. Stonecipher\n113 S.W.2d 264") == "Texas & N. O. R. v. Stonecipher")
        #expect(LegalCaseDomainPack.captionParties(in: "Minutes of the meeting.\nSee Smith v. Jones for that.") == nil)
    }

    @Test("A caption split across blocks files the parties beside the docket and court")
    func documentLevelParties() {
        let blocks: [(id: UUID, text: String)] = [
            (UUID(), "City of Waco v. Witt"), (UUID(), "126 S.W.2d 1002"), (UUID(), "No. 2042."),
            (UUID(), "Court of Civil Appeals of Texas. Waco."), (UUID(), "March 16, 1939."),
        ]
        let facts = LegalCaseDomainPack.documentLevelCaption(blocks: blocks, subjectLabel: "Witt", have: [])
        #expect(facts.first { $0.field == "parties" }?.value == "City of Waco v. Witt")
        #expect(facts.first { $0.field == "decisiondate" }?.value == "1939-03-16")
    }

    @Test("A court line names the district, or puts the seat before the date")
    func courtLineDates() {
        #expect(LegalCaseDomainPack.courtLineDate(in: "[Crim. No. 5335. Fifth Dist. Mar. 20, 1981.] In re") == "Mar. 20, 1981")
        #expect(LegalCaseDomainPack.courtLineDate(in: "No. 2042. Court of Civil Appeals of Texas. Waco. March 16, 1939.") == "March 16, 1939")
    }

    @Test("A long paragraph naming the court below does not become the deciding court")
    func courtBelowIsNotTheCourt() {
        let body = String(repeating: "The appellant argues the point at length. ", count: 12)
            + "This suit was filed in the District Court of Grayson County, Texas, by the appellee."
        let facts = LegalCaseDomainPack.extractFacts(fromText: body, subjectLabel: "x", blockID: UUID())
        #expect(!facts.contains { $0.field == "court" })
    }

    // MARK: Question routing

    @Test("Who were the parties in a case resolves to the parties; a contract's parties do not")
    func partiesQuestion() {
        #expect(SlotFieldResolver.resolve(in: "Who were the parties in Mayo v. United States, 139 F. Supp. 46?").map(\.fieldID) == ["parties"])
        #expect(SlotFieldResolver.resolve(in: "Who are the parties to the agreement?").isEmpty)
    }

    @Test("Field-less questions reach the field on file: happen → event date, why → reason, where → location")
    func fieldlessQuestions() {
        let known: Set<String> = ["dateandtime", "location", "reasonforrecall", "date"]
        #expect(SlotFieldResolver.resolve(in: "When did the accident in NTSB case ERA13CA130 happen?", knownFields: known).map(\.fieldID) == ["dateandtime"])
        #expect(SlotFieldResolver.resolve(in: "Why was FDA recall D-0775-2020 issued?", knownFields: known).map(\.fieldID) == ["reasonforrecall"])
        #expect(SlotFieldResolver.resolve(in: "Where did the NTSB SEA03LA084 accident happen?", knownFields: known).map(\.fieldID) == ["location"])
        // A why about something else never lands on a recall's reason.
        #expect(SlotFieldResolver.reasonField(in: "Why did the plane crash?", knownFields: known) == nil)
    }

    @Test("A quoted title never names the field asked for")
    func quotedTitles() {
        let known: Set<String> = ["sanfrancisco", "location"]
        #expect(SlotFieldResolver.resolve(in: "What happened in the case \"Oakland Resident Who Sold Fentanyl In San Francisco's Tenderloin\"?", knownFields: known).isEmpty)
        #expect(IdentityFieldResolver.questionFieldType("What happened in the case \"Shipping company fined $1.5M for oil record book offense\"?") == nil)
        #expect(IdentityFieldResolver.questionFieldType("What is the company name?") == .organizationName)
    }

    @Test("The not-found sentence names the field with the right article")
    func articles() {
        #expect(SlotAnswerComposer.withArticle("Grant date") == "a grant date")
        #expect(SlotAnswerComposer.withArticle("Invoice number") == "an invoice number")
        #expect(SlotAnswerComposer.withArticle("Parties") == "the parties")
        #expect(SlotAnswerComposer.withArticle("Status") == "a status")
    }

    // MARK: Issuing office

    @Test("The office in the announcing sentence wins; an attorney's name may sit before the district")
    func issuingOffice() {
        #expect(IssuingOfficeGate.office(in: "United States Attorney Gregory J. Haanstad of the Eastern District of Wisconsin announced that on March 7, 2017, a grand jury returned an indictment.")
                == "the U.S. Attorney's Office for the Eastern District of Wisconsin")
        let text = "The case was investigated with the U.S. Attorney's Office for the Southern District of California. "
            + "The Justice Department's Tax Division announced the indictment today."
        #expect(IssuingOfficeGate.office(in: text) == "the Justice Department's Tax Division")
        // A joint announcement names both offices.
        #expect(IssuingOfficeGate.office(in: "Herrell was sentenced, U.S. Attorney McGregor W. Scott for the Eastern District of California and Acting Assistant Attorney General Brian C. Rabbitt of the Justice Department's Criminal Division announced.")
                == "the U.S. Attorney's Office for the Eastern District of California and the Justice Department's Criminal Division")
        #expect(IssuingOfficeGate.office(in: "The Office of the United States Attorney for the District of Vermont announced charges.")
                == "the U.S. Attorney's Office for the District of Vermont")
    }

    // MARK: Open fields

    @Test("A label on its own line takes the next line as its value, within a block and across blocks")
    func danglingLabels() {
        let within = OpenFieldExtractor.fields(in: "Reason for recall:\ncGMP Deviations: Potential product contamination.", kind: .paragraph)
        #expect(within.first?.fieldID == "reasonforrecall")
        #expect(within.first?.value == "cGMP Deviations: Potential product contamination.")
        #expect(OpenFieldExtractor.danglingLabel("Reason for recall:") == "Reason for recall")
        #expect(OpenFieldExtractor.danglingLabel("He said: ") == nil)
    }

    @Test("A news dateline is not a field")
    func datelines() {
        #expect(OpenFieldExtractor.split("SAN FRANCISCO – Jose Alvarado was sentenced today.") == nil)
        #expect(OpenFieldExtractor.split("Status — Active")?.label == "Status")
    }

    @Test("A district office never takes the attorney's first name; without an announcing sentence a U.S. Attorney's office outranks a helping division")
    func districtBoundaries() {
        #expect(IssuingOfficeGate.office(in: "the U.S. Attorney's Office for the Southern District of California Laura E. Duffy said.")
                == "the U.S. Attorney's Office for the Southern District of California")
        #expect(IssuingOfficeGate.office(in: "Help came from the Criminal Division's Computer Crime Section. The U.S. Attorney's Office for the Eastern District of California prosecuted the case.")
                == "the U.S. Attorney's Office for the Eastern District of California")
        #expect(IssuingOfficeGate.office(in: "The U.S. Attorney's Office for the District of New Jersey said so.")
                == "the U.S. Attorney's Office for the District of New Jersey")
    }

    // MARK: Q-4 — the account keeps the names

    @Test("An announcer roll is not the account; a lead that hides the person takes the sentence naming them")
    func leadKeepsNames() {
        #expect(SentenceQuoteComposer.isAnnouncerRoll("Benjamin G. Greenberg, Acting United States Attorney for the Southern District of Florida, and Rafiq Ahmad, Special Agent in Charge, announced the verdict."))
        #expect(!SentenceQuoteComposer.isAnnouncerRoll("A letter carrier was convicted at trial of access device fraud, the U.S. Attorney announced."))
        #expect(!SentenceQuoteComposer.isAnnouncerRoll("FRESNO, Calif. — Bryan Connor Herrell, 26, of Aurora, Colorado, was sentenced today by United States District Court Judge Dale A. Drozd to 11 years in prison, U.S. Attorney McGregor W. Scott for the Eastern District of California and Acting Assistant Attorney General Brian C. Rabbitt of the Justice Department's Criminal Division announced."))
        #expect(!SentenceQuoteComposer.isAnnouncerRoll("United States Attorney Martin Estrada, the United States Attorney for the Central District of California, today announced the establishment of the Environmental Crimes and Consumer Protection Section."))
        #expect(SentenceQuoteComposer.hidesThePerson("U.S. District Judge Sarah E. Pitlyk on Friday sentenced a man to 18 years in prison."))
        #expect(!SentenceQuoteComposer.hidesThePerson("Joshua Thomas was sentenced to 18 years in prison."))
        #expect(SentenceQuoteComposer.namesAPerson("Joshua Thomas was armed with an AR-15-style firearm."))
    }

    // MARK: Announcement dates

    @Test("A date after \"announced that\" or after a dateline's place dates the event, not the announcement")
    func announcementDates() {
        #expect(!DateQuestionGate.hasPublicationAnchoredDate("Matthew D. Krueger, the United States Attorney, announced that on May 2, 2019, Marcus Hutchins pleaded guilty."))
        #expect(!DateQuestionGate.hasPublicationAnchoredDate("NEW ORLEANS, LOUISIANA – DARVIN MORADEL-VELASQUEZ, age 40, plead guilty on April 9, 2026, to illegal reentry."))
        #expect(DateQuestionGate.hasPublicationAnchoredDate("WASHINGTON, June 10, 2014 — A man was sentenced today."))
        #expect(DateQuestionGate.hasPublicationAnchoredDate("The release was issued on March 3, 2009."))
    }
}

