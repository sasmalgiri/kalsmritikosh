//
//  ProceedingAnswererTests.swift
//  KalsmritikoshTests
//
//  Closed-case simulation, 2026-10-26: one defendant followed across three Justice Department
//  releases (indicted → pleaded guilty → sentenced). Each step is read with its day, quoted and
//  cited; a step no document records is said to be unrecorded.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("Proceeding steps of a person, across documents")
struct ProceedingAnswererTests {

    static let indicted = """
        U.S. Department of Justice
        District of Rhode Island
        FOR IMMEDIATE RELEASE
        Wednesday, October 22, 2014

        Toy Manufacturer Employee Indicted, Arraigned On Federal Fraud Charges

        PROVIDENCE, R.I. –Christi Romano, aka Christi Machala, 35, of Smithfield, R.I., was arraigned in U.S. District Court in Providence today on a federal indictment. A federal indictment returned on October 15, 2014, charges Romano with seven counts of wire fraud. Wire fraud is punishable by up to 30 years in federal prison.
        """
    static let pleaded = """
        U.S. Department of Justice
        District of Rhode Island
        FOR IMMEDIATE RELEASE
        Wednesday, May 27, 2015

        Smithfield Woman Pleads Guilty

        PROVIDENCE, R.I. – Christi Romano, aka Christi Machala, 35, of Smithfield, R.I., pleaded guilty in federal court in Providence today to stealing more than $274,000. Romano is scheduled to be sentenced on August 25, 2015.
        """
    static let sentenced = """
        U.S. Department of Justice
        District of Rhode Island
        FOR IMMEDIATE RELEASE
        Thursday, September 24, 2015

        Smithfield Woman Sentenced

        PROVIDENCE, R.I. – Christi Romano, aka Christi Machala, 36, of Smithfield, R.I., was sentenced today to four years in federal prison for embezzling more than $274,000 from her employer, announced United States Attorney Peter F. Neronha.
        """
    static let unrelated = """
        U.S. Department of Justice
        FOR IMMEDIATE RELEASE
        Monday, June 1, 2015

        John Doe, 40, of Warwick, was sentenced today to 10 years in prison.
        """

    let sources = [indicted, pleaded, sentenced, unrelated].map { ProceedingAnswerer.Source(objectID: UUID(), text: $0) }

    func ask(_ q: String) throws -> VerifiedAnswer {
        let parsed = try #require(ProceedingAnswerer.parse(q))
        return try #require(ProceedingAnswerer.answer(parsed, sources: sources))
    }

    @Test("When: the day the document gives the step, from 'today' against the printed date or a stated date")
    func when() throws {
        #expect(try ask("When was Christi Machala sentenced?").body.hasPrefix("Christi Machala was sentenced on September 24, 2015."))
        #expect(try ask("When was Christi Machala charged?").body.hasPrefix("Christi Machala was charged on October 15, 2014."))
        // "is scheduled to be sentenced on August 25" is not a sentencing.
        #expect(try !ask("When was Christi Machala sentenced?").body.contains("August 25"))
    }

    @Test("Whether, the sentence imposed, the timeline in order, and the documents that name the person")
    func others() throws {
        #expect(try ask("Did Christi Machala plead guilty?").body.hasPrefix("Yes"))
        #expect(try ask("What sentence did Christi Machala receive?").body.hasPrefix("Christi Machala was sentenced to four years in federal prison for embezzling more than $274,000 from her employer."))
        let timeline = try ask("Give me the timeline of the case against Christi Machala.").body
        let days = ["October 15, 2014", "May 27, 2015", "September 24, 2015"].compactMap { timeline.range(of: $0)?.lowerBound }
        #expect(days.count == 3 && days == days.sorted())
        let count = try ask("How many press releases are about Christi Machala?")
        #expect(count.body.hasPrefix("3 of the documents found name Christi Machala"))
        #expect(count.citations.count == 3)
        // A capped document search gives a floor, never a total.
        let parsed = try #require(ProceedingAnswerer.parse("How many press releases are about Christi Machala?"))
        let floor = try #require(ProceedingAnswerer.answer(parsed, sources: sources, complete: false))
        #expect(floor.body.hasPrefix("At least 3 of the documents found name Christi Machala") && floor.body.contains("there may be more"))
    }

    @Test("Claude-reworded sentencing dates and document counts parse to the same ask")
    func rewordings() throws {
        let n = QuestionCanonicalizer.normalize
        for q in ["I need to know when Christi Machala's sentencing took place.",
                  "I need to know when sentencing occurred for Christi Machala — do we have that on record?",
                  "I need to know when Christi Machala received her sentencing — do you have that date?",
                  "Can you tell me the exact date Christi Machala was sentenced?",
                  "What was the sentencing date for Christi Machala?"] {
            #expect(ProceedingAnswerer.parse(n(q))?.ask == .when(.sentenced), "\(q)")
        }
        #expect(try ask(n("I need to know when Christi Machala's sentencing took place.")).body.hasPrefix("Christi Machala was sentenced on September 24, 2015."))
        #expect(ProceedingAnswerer.parse(n("I need to know when charges were filed against Christi Machala — do you have that date?"))?.ask == .when(.charged))
        for q in ["Do you know the total count of press releases concerning Christi Machala?",
                  "I need a count of the press releases that mention Christi Machala.",
                  "Can you check the count of press releases that mention Christi Machala?",
                  "How many separate press releases have been issued concerning Christi Machala?",
                  "What's the total count of press releases concerning Christi Machala?"] {
            #expect(ProceedingAnswerer.parse(n(q))?.ask == .documentCount, "\(q)")
        }
        #expect(try ask(n("Do you know the total count of press releases concerning Christi Machala?")).body.hasPrefix("3 of the documents found name Christi Machala"))
    }

    @Test("No guilty plea on file is not 'No'; only a verdict at trial says the person did not plead; a plea is not 'not convicted'")
    func pleaSemantics() throws {
        func release(_ body: String) -> ProceedingAnswerer.Source {
            ProceedingAnswerer.Source(objectID: UUID(), text: "U.S. Department of Justice\nFOR IMMEDIATE RELEASE\nThursday, March 18, 2021\n\n" + body)
        }
        func answer(_ q: String, _ body: String) throws -> String {
            let parsed = try #require(ProceedingAnswerer.parse(q))
            return try #require(ProceedingAnswerer.answer(parsed, sources: [release(body)])).body
        }
        let trial = try answer("Did Tywan Sykes plead guilty?", "On March 17, 2021, a federal jury convicted Tywan Sykes, 45, of Louisville, of child exploitation charges.")
        #expect(trial.hasPrefix("No — the documents say Tywan Sykes was found guilty at trial"))
        let bare = try answer("Did Austin Campbell plead guilty?", "Austin Campbell, 46, of Smyrna, Delaware, was convicted of interstate travel with intent to engage in illicit sexual conduct.")
        #expect(bare.hasPrefix("The documents that name Austin Campbell don't record a guilty plea. They say Austin Campbell was convicted"))
        #expect(!bare.hasPrefix("No"))
        let plea = try answer("Was Christi Machala convicted?", "Christi Machala, 35, of Smithfield, R.I., pleaded guilty in federal court in Providence today to stealing more than $274,000.")
        #expect(plea.hasPrefix("The documents that name Christi Machala don't report a verdict. They say Christi Machala pleaded guilty"))
    }

    @Test("A relative with the same surname is someone else; the person's own sentence is found")
    func sameSurnameRelative() throws {
        let text = """
            U.S. Department of Justice
            FOR IMMEDIATE RELEASE
            Wednesday, June 22, 2022

            Brothers Sentenced for Destroying Energy Facility

            CHARLESTON, W.Va. – David Stanley, 50, of Shady Spring, was sentenced today to three years in prison for destruction of an energy facility. The brother, Charles Stanley, 52, of Shady Spring, pleaded guilty to aiding and abetting the destruction of an energy facility and was sentenced to two years and six months in prison. Yesterday Stanley's lawyer declined to comment.
            """
        let src = [ProceedingAnswerer.Source(objectID: UUID(), text: text)]
        let parsed = try #require(ProceedingAnswerer.parse("What sentence did David Stanley receive?"))
        let body = try #require(ProceedingAnswerer.answer(parsed, sources: src)).body
        #expect(body.hasPrefix("David Stanley was sentenced to three years in prison"))
        #expect(!body.contains("two years and six months"))
        // The brother's own question gets the brother's sentence.
        let brotherAsk = try #require(ProceedingAnswerer.parse("What sentence did Charles Stanley receive?"))
        let brother = try #require(ProceedingAnswerer.answer(brotherAsk, sources: src)).body
        #expect(brother.contains("two years and six months"))
    }

    @Test("A step no document records is said to be unrecorded; a person no document names is left to the pipeline")
    func absent() throws {
        let pardon = try ask("When was Christi Machala pardoned?")
        #expect(pardon.refused)
        #expect(pardon.body == "The documents that name Christi Machala don't record Christi Machala being pardoned.")
        let parsed = try #require(ProceedingAnswerer.parse("When was Mary Unknown sentenced?"))
        #expect(ProceedingAnswerer.answer(parsed, sources: sources) == nil)
        // Not a person question: a quoted release title, or no proceeding step.
        #expect(ProceedingAnswerer.parse("When was \"Smithfield Woman Sentenced\" published?") == nil)
        #expect(ProceedingAnswerer.parse("Who wrote the opinion in Pinching v. Wurdeman?") == nil)
    }

    @Test("PDF line wraps, a judge's sentencing clause, and a headline that states the step")
    func layouts() throws {
        let wrapped = """
            U.S. Department of Justice
            Southern District of West Virginia
            FOR IMMEDIATE RELEASE
            Wednesday, February 18, 2015
            Felon sentenced for concealing illegal firearm
            CHARLESTON, W.Va. – United States Attorney Booth Goodwin announced today that Reginald Bennett, 41, of
            Cedar Grove, West Virginia, was sentenced to 30 months in federal prison, followed by three years of supervised
            release.
            """
        let arrest = """
            U.S. Department of Justice
            District of Virgin Islands
            FOR IMMEDIATE RELEASE
            Wednesday, August 16, 2017
            Man Arrested for Possession with Intent to Distribute Cocaine
            St. Thomas, USVI- Kenneth James, 51, of Dominica, made his initial appearance today before the court.
            """
        let src = [wrapped, arrest].map { ProceedingAnswerer.Source(objectID: UUID(), text: $0) }
        func answer(_ q: String) throws -> VerifiedAnswer {
            let parsed = try #require(ProceedingAnswerer.parse(q))
            return try #require(ProceedingAnswerer.answer(parsed, sources: src))
        }
        #expect(try answer("What sentence did Reginald Bennett receive?").body.hasPrefix("Reginald Bennett was sentenced to 30 months in federal prison"))
        #expect(try answer("When was Reginald Bennett sentenced?").body.contains("February 18, 2015"))
        #expect(try answer("Give me the timeline of the case against Kenneth James.").body.contains("August 16, 2017 (date of the report) — arrested"))
        #expect(IssuingOfficeGate.office(in: arrest)?.contains("Virgin Islands") == true)
        let charged = try #require(ProceedingAnswerer.parse("What was Christi Machala charged with?"))
        #expect(charged.ask == .chargedWith)
        #expect(try ask("What was Christi Machala charged with?").body.contains("seven counts of wire fraud"))
    }

    @Test("A descriptive lead ('A Florida man was sentenced …') is about the one defendant the release names")
    func descriptiveLead() throws {
        let release = """
            U.S. Department of Justice
            Criminal Division
            FOR IMMEDIATE RELEASE
            Friday, April 19, 2024
            Hedge Fund Manager Sentenced for Operating Multimillion-Dollar Ponzi Scheme
            A Florida man was sentenced today to one year and one day in prison for using his hedge fund management company to defraud investors.
            According to court documents, Michael Wayne Williams, 63, of Fort Lauderdale, operated the fund.
            """
        let parsed = try #require(ProceedingAnswerer.parse("What sentence did Michael Wayne Williams receive?"))
        let a = try #require(ProceedingAnswerer.answer(parsed, sources: [.init(objectID: UUID(), text: release)]))
        #expect(a.body.hasPrefix("Michael Wayne Williams was sentenced to one year and one day in prison"))
    }

    @Test("A headline in AP style and a 'The leader of …' lead")
    func headlineStyles() throws {
        let duncan = """
            FOR IMMEDIATE RELEASE
            Tuesday, May 9, 2023
            District Man Sentenced to 18 Months’ Imprisonment for Assault on a Member of the LGBTQ+ Community
            WASHINGTON – Anthony Duncan, 42, of Washington, D.C., was sentenced to 18 months’ imprisonment and 3
            years of supervised release today for assaulting a pedestrian.
            """
        let resnik = """
            FOR IMMEDIATE RELEASE
            Tuesday, July 10, 2018
            Long Beach Man Sentenced to Over 26 Years in Prison for Leading Counterfeit Opioid Scheme that Distributed
            Fentanyl Analogue
            LOS ANGELES – The leader of a narcotics distribution ring that imported a powerful fentanyl analogue from
            China and produced hundreds of thousands of opioid pills was
            sentenced yesterday to 320 months in federal prison.
            Gary Resnik, 33, of Long Beach, led a conspiracy that imported acetylfentanyl.
            """
        func sentence(_ name: String, _ text: String) throws -> String {
            let parsed = try #require(ProceedingAnswerer.parse("What sentence did \(name) receive?"))
            return try #require(ProceedingAnswerer.answer(parsed, sources: [.init(objectID: UUID(), text: text)])).body
        }
        #expect(try sentence("Anthony Duncan", duncan).hasPrefix("Anthony Duncan was sentenced to 18 months’ imprisonment"))
        #expect(try sentence("Gary Resnik", resnik).hasPrefix("Gary Resnik was sentenced to 320 months in federal prison"))
    }

    @Test("Which office prosecuted X, from X's own releases; Mc-names; a co-defendant's step is not X's")
    func officeAndNames() throws {
        let release = """
            U.S. Department of Justice
            Eastern District of Pennsylvania
            FOR IMMEDIATE RELEASE
            Monday, March 2, 2020
            PHILADELPHIA – Matthew McKinney, 39, of Philadelphia, was sentenced today to 10 years in prison.
            McKinney's co-defendant Arthur Upchurch was sentenced to 20 years.
            The case was prosecuted by Assistant U.S. Attorney Jane Roe.
            """
        let src = [ProceedingAnswerer.Source(objectID: UUID(), text: release)]
        func answer(_ q: String) throws -> String {
            let parsed = try #require(ProceedingAnswerer.parse(q))
            return try #require(ProceedingAnswerer.answer(parsed, sources: src)).body
        }
        #expect(try answer("Which office prosecuted Matthew McKinney?").contains("Eastern District of Pennsylvania"))
        #expect(try answer("What sentence did Matthew McKinney receive?").hasPrefix("Matthew McKinney was sentenced to 10 years in prison"))
    }

    @Test("A middle initial is part of the name; the offence-stating sentence answers 'charged with'")
    func initialsAndOffence() throws {
        let release = """
            U.S. Department of Justice
            FOR IMMEDIATE RELEASE
            Thursday, March 12, 2015
            PHILADELPHIA - Nathaniel E. Robinson, 45, of Philadelphia, was sentenced today to 18 months in prison.
            After Robinson was charged, investigators found more records.
            An indictment unsealed in 2014 charged Robinson with theft from a program receiving federal funds.
            """
        let src = [ProceedingAnswerer.Source(objectID: UUID(), text: release)]
        let sentence = try #require(ProceedingAnswerer.parse("What sentence did Nathaniel E. Robinson receive?"))
        #expect(try #require(ProceedingAnswerer.answer(sentence, sources: src)).body.hasPrefix("Nathaniel E. Robinson was sentenced to 18 months in prison"))
        let charge = try #require(ProceedingAnswerer.parse("What was Nathaniel E. Robinson charged with?"))
        #expect(try #require(ProceedingAnswerer.answer(charge, sources: src)).body.contains("theft from a program receiving federal funds"))
    }

    @Test("Steps become ledger events only when the document gives the day")
    func events() {
        let events = ProceedingEventExtractor.extract(text: Self.sentenced, sourceObjectID: UUID(),
                                                      people: [(name: "Christi Machala", entityID: UUID()), (name: "Peter F. Neronha", entityID: UUID())])
        #expect(events.count == 1)
        #expect(events.first?.title == "Christi Machala sentenced")
        #expect(ProceedingEventExtractor.extract(text: "Christi Machala was sentenced to four years.", sourceObjectID: UUID(),
                                                 people: [(name: "Christi Machala", entityID: UUID())]).isEmpty)
    }
}

@Suite("Proceeding gaps")
struct ProceedingGapTests {
    @Test("Sentenced with no plea or verdict on file, and no charging document on file, are gaps")
    func gaps() {
        let sentencing = "FOR IMMEDIATE RELEASE\nThursday, September 24, 2015\nPROVIDENCE – Christi Romano, 36, of Smithfield, was sentenced today to four years in federal prison."
        let found = GapDetector().detectProceedingGaps(texts: [(objectID: UUID(), text: sentencing)])
        #expect(found.count == 2)
        #expect(found.allSatisfy { $0.kind == .proceedingStep && $0.nearEntity == "Christi Romano" })
        let plea = "FOR IMMEDIATE RELEASE\nWednesday, May 27, 2015\nPROVIDENCE – Christi Romano, 35, of Smithfield, pleaded guilty today to wire fraud. A federal indictment returned on October 15, 2014, charged Romano with wire fraud."
        // With the plea and the charge on file, the sentencing has its steps.
        #expect(GapDetector().detectProceedingGaps(texts: [(objectID: UUID(), text: sentencing), (objectID: UUID(), text: plea)]).isEmpty)
    }
}
