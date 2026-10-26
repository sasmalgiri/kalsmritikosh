//
//  VerifiedRecordExtractorTests.swift
//  KalsmritikoshTests
//
//  A model's proposed answer about a person's proceeding is shown only when it verifies against the
//  documents: the quote verbatim in the cited document, about the person asked, the date stated or
//  given by "today" against the printed date, a term in the quote, a charge that states an offence,
//  "No" to a plea only with a verdict at trial. Anything else is dropped (the rules answer stands).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Verified record extraction")
struct VerifiedRecordExtractorTests {

    static let release = """
        U.S. Department of Justice
        FOR IMMEDIATE RELEASE
        Friday, September 13, 2024

        Beckley Man Sentenced

        BECKLEY, W.Va. – Leon Eugene Smith Jr., 43, of Beckley, was sentenced today to 13 years and five months in prison for distribution of fentanyl. Smith pleaded guilty on May 1, 2024, to distribution of fentanyl. Gary Smith was sentenced on November 19, 2024, to five years of probation.
        """
    let sources = [ProceedingAnswerer.Source(objectID: UUID(), text: release)]

    func verify(_ q: String, _ json: String) throws -> VerifiedAnswer? {
        let parsed = try #require(ProceedingAnswerer.parse(q))
        let p = try #require(VerifiedRecordExtractor.parse(json))
        return VerifiedRecordExtractor.verify(p, parsed: parsed, sources: sources, docs: sources.map(\.text))
    }

    @Test("A verbatim, person-specific, date-consistent proposal is shown")
    func accepts() throws {
        let when = try #require(try verify("When was Leon Eugene Smith sentenced?",
            #"{"answer":"September 13, 2024","quote":"BECKLEY, W.Va. – Leon Eugene Smith Jr., 43, of Beckley, was sentenced today to 13 years and five months in prison for distribution of fentanyl.","doc":1,"value":"2024-09-13"}"#))
        #expect(when.body.hasPrefix("Leon Eugene Smith was sentenced on September 13, 2024."))
        #expect(when.intentKind == VerifiedAnswer.recordAnswerKind)
        let plea = try #require(try verify("When did Leon Eugene Smith plead guilty?",
            #"{"answer":"May 1, 2024","quote":"Smith pleaded guilty on May 1, 2024, to distribution of fentanyl.","doc":1,"value":"2024-05-01"}"#))
        #expect(plea.body.hasPrefix("Leon Eugene Smith pleaded guilty on May 1, 2024."))
        let term = try #require(try verify("What sentence did Leon Eugene Smith receive?",
            #"{"answer":"13 years and five months","quote":"BECKLEY, W.Va. – Leon Eugene Smith Jr., 43, of Beckley, was sentenced today to 13 years and five months in prison for distribution of fentanyl.","doc":1,"value":"13 years and five months in prison"}"#))
        #expect(term.body.hasPrefix("Leon Eugene Smith was sentenced to 13 years and five months in prison."))
    }

    @Test("A paraphrased quote, another person's sentence, a wrong date or an unsupported No is dropped")
    func rejects() throws {
        // Not verbatim.
        #expect(try verify("When was Leon Eugene Smith sentenced?",
            #"{"answer":"x","quote":"Leon Smith received his sentence on September 13, 2024 in Beckley court.","doc":1,"value":"2024-09-13"}"#) == nil)
        // Another person with the same surname.
        #expect(try verify("What sentence did Leon Eugene Smith receive?",
            #"{"answer":"five years","quote":"Gary Smith was sentenced on November 19, 2024, to five years of probation.","doc":1,"value":"five years of probation"}"#) == nil)
        // The date is not the one the quote gives.
        #expect(try verify("When did Leon Eugene Smith plead guilty?",
            #"{"answer":"May 2","quote":"Smith pleaded guilty on May 1, 2024, to distribution of fentanyl.","doc":1,"value":"2024-05-02"}"#) == nil)
        // "No" to a plea without a trial verdict in the quote.
        #expect(try verify("Did Leon Eugene Smith plead guilty?",
            #"{"answer":"No","quote":"Smith pleaded guilty on May 1, 2024, to distribution of fentanyl.","doc":1}"#) == nil)
        // A scheduled step is not a step taken.
        let scheduled = [ProceedingAnswerer.Source(objectID: UUID(), text: "U.S. Department of Justice\nFOR IMMEDIATE RELEASE\nMonday, June 3, 2019\n\nAtif Ullah, 30, pleaded guilty today. Sentencing is scheduled for October 4, 2019, before Judge Vilardo.")]
        let au = try #require(ProceedingAnswerer.parse("When was Atif Ullah sentenced?"))
        let sp = try #require(VerifiedRecordExtractor.parse(#"{"answer":"October 4, 2019","quote":"Sentencing is scheduled for October 4, 2019, before Judge Vilardo.","doc":1,"value":"2019-10-04"}"#))
        #expect(VerifiedRecordExtractor.verify(sp, parsed: au, sources: scheduled, docs: scheduled.map(\.text)) == nil)
        // A document number out of range, or nothing found.
        #expect(try verify("When was Leon Eugene Smith sentenced?", #"{"answer":"x","quote":"Smith pleaded guilty on May 1, 2024, to distribution of fentanyl.","doc":3,"value":"2024-05-01"}"#) == nil)
        #expect(try verify("When was Leon Eugene Smith sentenced?", #"{"answer":null}"#) == nil)
    }
}
