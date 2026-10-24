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

    @Test("What an investigation found: the finding, not the line that names the investigation")
    func whatFoundSkipsReferenceLine() throws {
        let report = """
        NHTSA defect investigation PE86068

        Subject: STEER AXLE HUB FAILURE
        Manufacturer: PACCAR Incorporated
        Component: STEERING

        Summary:
        SUMMARY OF INFORMATION FROM MANUFACTURER:IN THEIR RESPONSE TO THIS OFFICE, PACCAR STATED THAT TESTING INDICATED A PROJECTED LIFE OF OVER ONE MILLION MILES.ANALYSIS:THE HUB APPEARS TO BE SUSCEPTIBLE TO FATIGUE FAILURE
        """
        let q = try #require(SentenceQuoteComposer.compose(question: "What did NHTSA find in investigation PE86068?", chunks: [chunk(report)]))
        #expect(q.sentence.contains("FATIGUE FAILURE"), "\(q.sentence)")
    }

    @Test("A record's account is the text under its Summary heading, not its label block")
    func accountUnderSummaryHeading() throws {
        // Evidence-only round 2026-10-24: the label block (normalized onto one line) was quoted.
        let record = "NHTSA defect investigation EA09005 Subject: Non-deployment of Side Thorax Air Bags Manufacturer: Nissan North America, Inc. Make: INFINITI Models: M45, Q45 Model years: 2003, 2004, 2005 Component: AIR BAGS:SIDE/WINDOW Date opened: 2009-04-01 Summary: The subject vehicles are equipped with seat-mounted, side thorax air bags for the driver and front passenger. This investigation revealed that faulty connectors can interrupt the circuit."
        let q = try #require(SentenceQuoteComposer.compose(question: "What did NHTSA find in investigation EA09005?", chunks: [chunk(record)]))
        #expect(q.sentence.hasPrefix("Non-deployment of Side Thorax Air Bags. The subject vehicles are equipped with seat-mounted"))
        #expect(!q.sentence.contains("Manufacturer:"))
    }

    @Test("A record's title line leads its account")
    func headlineLeadsAccount() {
        let osha = "OSHA accident investigation summary 221257512 Event: Employee crushes hand between equipment and suspended load Event date: February 11, 2020 Inspection number(s): 344714464 Abstract: At 4:30 p.m. on February 11, 2020, an employee working as a machine operator was moving a suspended load when his hand was crushed."
        #expect(SentenceQuoteComposer.recordHeadline(osha) == "Employee crushes hand between equipment and suspended load")
        #expect(SentenceQuoteComposer.recordHeadline("No labels here at all.") == nil)
    }

    @Test("A headline that runs into the lead comes off; the lead stands")
    func headlineRunsIntoLead() throws {
        let release = "Leader of meth trafficking ring operating in Houston sentenced to 30 years in prison HOUSTON – A 37-year-old Mexican citizen has been ordered to federal prison following his involvement in a conspiracy to possess meth. Today, U.S. District Judge David Hittner handed Carrasco-Garcia a 360-month term of imprisonment."
        let q = try #require(SentenceQuoteComposer.compose(
            question: "What happened in the case \"Leader of meth trafficking ring operating in Houston sentenced to 30 years in prison\"?",
            chunks: [chunk(release)]))
        #expect(q.sentence.hasPrefix("HOUSTON – A 37-year-old Mexican citizen"), "\(q.sentence)")
    }

    @Test("A non-why question is unchanged")
    func notWhy() {
        #expect(!SentenceQuoteComposer.asksWhy("When was FDA recall Z-2366-2021 initiated?"))
        #expect(SentenceQuoteComposer.asksWhy("Why was the recall issued?"))
    }
}

@Suite("A question reaches the field on file it names")
struct InventoryFieldTests {
    let fields: Set<String> = ["recallingfirm", "classification", "recallinitiationdate", "productquantity", "distributionpattern"]

    @Test("A field's whole name, or its last word when only one field ends so")
    func wholeNameOrLastWord() {
        #expect(SlotFieldResolver.resolve(in: "what is the classification of fda recall d-1381-2019?", knownFields: fields).first?.fieldID == "classification")
        #expect(SlotFieldResolver.resolve(in: "which firm initiated fda recall d-1381-2019?", knownFields: fields).first?.fieldID == "recallingfirm")
    }

    @Test("A four-letter verb names its dated field")
    func fourLetterVerb() {
        #expect(SlotFieldResolver.resolve(in: "when did nhtsa open investigation pe86068?", knownFields: ["dateopened", "date", "component"]).first?.fieldID == "dateopened")
    }

    @Test("A last word shared by two fields, or a generic word, names none")
    func ambiguousOrGeneric() {
        #expect(SlotFieldResolver.resolveAgainstInventory("which firm was it?", knownFields: ["recallingfirm", "manufacturingfirm"]) == nil)
        #expect(SlotFieldResolver.resolveAgainstInventory("what is the date?", knownFields: ["recallinitiationdate"]) == nil)
    }
}

@Suite("A when-question names the dated field its verb points to")
struct NamedDateFieldTests {
    @Test("initiated → recall initiation date; opened → date opened; no match → nil")
    func named() {
        let fields: Set<String> = ["date", "recallinitiationdate", "dateopened", "recallingfirm"]
        #expect(SlotFieldResolver.namedDateField(in: "When was FDA recall D-0227-2026 initiated?", knownFields: fields)?.fieldID == "recallinitiationdate")
        // Four-letter verbs name their field too (case bench 2026-10-22: "open" → dateopened).
        #expect(SlotFieldResolver.namedDateField(in: "When did NHTSA open investigation PE08001?", knownFields: ["dateopened"])?.fieldID == "dateopened")
        #expect(SlotFieldResolver.namedDateField(in: "When was it opened?", knownFields: fields)?.fieldID == "dateopened")
        #expect(SlotFieldResolver.namedDateField(in: "Which firm initiated recall D-1?", knownFields: fields) == nil)
    }
}

@Suite("A count over numbered entries counts them")
struct NumberedEntryCountTests {
    private func chunk(_ text: String) -> RetrievedChunk {
        RetrievedChunk(chunk: Chunk(objectID: UUID(), ordinal: 0, text: text, characterRange: 0..<text.count),
                       score: 1, viaLayer: .metadata)
    }

    @Test("Employee #1 and #2 are two employees; a repeated entry counts once")
    func counts() throws {
        let record = "OSHA accident 220850044 — injured employees\n\nEmployee #1: fatality, age 31\nEmployee #2: hospitalized injury, age 40\nEmployee #1: fatality, age 31"
        let c = try #require(NumberedEntryCount.compose(question: "How many employees were hurt in OSHA investigation 220850044?", chunks: [chunk(record)]))
        #expect(c.count == 2)
        #expect(c.render().hasPrefix("2 employees are listed"))
    }

    @Test("Nothing numbered, or a unit question, counts nothing")
    func none() {
        #expect(NumberedEntryCount.compose(question: "How many employees were hurt?", chunks: [chunk("Two employees were hurt.")]) == nil)
        #expect(NumberedEntryCount.countedNoun(in: "How many days did it take?") == nil)
    }

    @Test("A title that only repeats the question's number is not a value")
    func referenceIsNotValue() {
        #expect(SentenceQuoteComposer.numbersOnlyFromQuestion("OSHA accident 220850044 — injured employees", question: "How many employees were hurt in OSHA investigation 220850044?"))
        #expect(!SentenceQuoteComposer.numbersOnlyFromQuestion("Employee #1: fatality, age 31", question: "How many employees were hurt in OSHA investigation 220850044?"))
    }
}

@Suite("Headings and places")
struct HeadingAndPlaceTests {
    private func chunk(_ text: String) -> RetrievedChunk {
        RetrievedChunk(chunk: Chunk(objectID: UUID(), ordinal: 0, text: text, characterRange: 0..<text.count),
                       score: 1, viaLayer: .metadata)
    }

    @Test("A heading that only repeats the question gives way to what it heads")
    func headingBody() throws {
        let doc = "NTSB SEA03LA084 — probable cause\nThe pilot did not attain the proper touchdown point during landing."
        let q = try #require(SentenceQuoteComposer.compose(question: "What was the probable cause of NTSB case SEA03LA084?", chunks: [chunk(doc)]))
        #expect(q.sentence.hasPrefix("The pilot did not attain"), "\(q.sentence)")
    }

    @Test("A where-question reaches a place field on file, and only a where-question")
    func whereToLocation() {
        #expect(SlotFieldResolver.resolve(in: "where did the ntsb era25la118 accident happen?", knownFields: ["location", "dateandtime"]).first?.fieldID == "location")
        #expect(SlotFieldResolver.resolve(in: "where did the ntsb era25la118 accident happen?", knownFields: ["dateandtime"]).isEmpty)
        #expect(SlotFieldResolver.placeField(in: "what happened at the site?", knownFields: ["location"]) == nil)
    }

    @Test("A Location label is read as a field")
    func locationNotReserved() {
        #expect(!OpenFieldExtractor.reservedFields.contains("location"))
    }
}
