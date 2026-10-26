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
