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
