//
//  ProceedingHo14FixesTests.swift
//  KalsmritikoshTests
//
//  The true wrongs of the ho14 agent adjudication (docs/agent-reviews/accuracy-adjudication-ho14.md),
//  reduced to their sentences. Every case here was answered wrongly on 81cf335f.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("Proceedings: ho14 adjudication fixes (dates, charges, parsing, pleas)")
struct ProceedingHo14FixesTests {
    typealias X = ProceedingEventExtractor

    func day(_ f: X.Finding?) -> String? {
        guard let d = f?.day, let y = d.year, let m = d.month, let dd = d.day else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, dd)
    }

    @Test("B1: 'Kansas City, Mo. Today's indictment …' is two sentences — the state abbreviation is not an initial")
    func stateAbbreviationEndsSentence() {
        let s = X.sentencesOfLine("Agents arrested him at his home in Kansas City, Mo. Today's indictment alleges that Bagley stole a car on June 22, 2014.")
        #expect(s.count == 2 && s[1].hasPrefix("Today's indictment"))
        // An initial or "St." still does not end a sentence.
        #expect(X.sentencesOfLine("He was sentenced by U.S. District Judge John A. Ross in St. Louis to 5 years in prison.").count == 1)
    }

    @Test("B2: a date inside a reported statement or the conduct is not the step's day — 'today' governs")
    func attributionDate() {
        let text = """
        October 18, 2018
        KANSAS CITY – United States Attorney Tim Garrison announced today that Jay Neal, 35, of Kansas City, was sentenced in federal court to 10 years in prison, and stated that on October 20, 2015, Neal sold methamphetamine to an undercover officer.
        """
        let f = X.findings(in: text, person: "Jay Neal").first { $0.step == .sentenced }
        #expect(day(f) == "2018-10-18", "the sentencing is the release's 'today', not the 2015 sale")
    }

    @Test("B3: 'indicted in April 2016' stays undated rather than borrowing 'yesterday'")
    func monthOnly() {
        let text = """
        May 10, 2019
        Robert Klein, 44, of Tulsa, who was indicted in April 2016, was arrested yesterday in Denver.
        """
        let found = X.findings(in: text, person: "Robert Klein")
        #expect(found.first { $0.step == .charged }.map { day($0) } ?? nil == nil)
        #expect(day(found.first { $0.step == .arrested }) == "2019-05-09")
    }

    @Test("D: 'after pleading guilty' and 'plead guilty' are pleas; the participle is not dated by the sentencing")
    func participlePlea() {
        let text = """
        March 3, 2021
        John Ross, 50, of Akron, was sentenced today to five years in prison after pleading guilty to wire fraud.
        """
        let found = X.findings(in: text, person: "John Ross")
        let plea = found.first { $0.step == .pleaded }
        #expect(plea != nil && plea?.day == nil)
        #expect(day(found.first { $0.step == .sentenced }) == "2021-03-03")
        let typo = "June 1, 2024\nRavi Patel, 40, of Edison, plead guilty today to bank fraud."
        #expect(X.findings(in: typo, person: "Ravi Patel").contains { $0.step == .pleaded })
    }

    @Test("C: 'Do we have a sentencing date for X?' is a when-question")
    func articleBeforeDate() {
        let n = QuestionCanonicalizer.normalize
        #expect(ProceedingAnswerer.parse(n("Do we have a sentencing date for John Ross?")) == .init(person: "John Ross", ask: .when(.sentenced)))
    }

    @Test("A: the charge is never a prior conviction, a co-defendant's clause or a separate state case")
    func chargeSelection() throws {
        func charge(_ text: String, _ person: String) throws -> String {
            let a = try #require(ProceedingAnswerer.answer(.init(person: person, ask: .chargedWith), sources: [.init(objectID: UUID(), text: text)]))
            return a.body
        }
        let underwood = """
        May 2, 2018
        Lee Underwood, 61, of Atlanta, was sentenced today for failing to register as a sex offender. In 1999, Underwood was convicted in Georgia of rape and was required to register. Underwood pleaded guilty in January 2018 to failing to register as a sex offender.
        """
        let u = try charge(underwood, "Lee Underwood")
        #expect(u.contains("failing to register") && !u.contains("of rape"), "\(u)")
        let byrd = """
        June 4, 2019
        Kevin Byrd, 33, of Mobile, was convicted today of armed bank robbery. Byrd committed the robbery with Charles Sanders, who pleaded guilty previously to conspiracy to distribute heroin.
        """
        let b = try charge(byrd, "Kevin Byrd")
        #expect(b.contains("armed bank robbery") && !b.contains("heroin"), "\(b)")
    }

    @Test("C: the last-resort fallback reads the person a question names, so it keeps only that person's passages")
    func fallbackPerson() {
        #expect(DeterministicEvidenceFallback.personSurname(in: "Do we have a sentencing date for John Ross?") == "Ross")
        #expect(DeterministicEvidenceFallback.personSurname(in: "When was John A. Ross sentenced?") == "Ross")
        #expect(DeterministicEvidenceFallback.personSurname(in: "Who signed the master supply agreement?") == nil)
        #expect(DeterministicEvidenceFallback.personSurname(in: "What does the Board Minutes say about Q3?") != "Ross")
    }

    // MARK: ho15 adjudication (docs/agent-reviews/accuracy-adjudication-ho15.md)

    @Test("ho15 B: the step's own weekday beats the announcement's 'today'; a gerund conduct clause keeps its date; 'by a grand jury in July 2013' is month-only")
    func ho15Dates() {
        let campbell = "November 16, 2020\nMark Campbell, 40, of Joplin, was sentenced to five years in prison on Friday, United States Attorney John Smith announced today."
        #expect(day(X.findings(in: campbell, person: "Mark Campbell").first { $0.step == .sentenced }) == "2020-11-13")
        let clark = "March 2, 2014\nJoe Clark, 51, of Ada, was charged by a federal grand jury in July 2013 with possessing pseudoephedrine on June 25, 2013, and was sentenced today to three years."
        let f = X.findings(in: clark, person: "Joe Clark")
        #expect(f.first { $0.step == .charged }.map { day($0) } ?? nil == nil, "not the offence day")
        #expect(day(f.first { $0.step == .sentenced }) == "2014-03-02")
    }

    @Test("ho15 H: a year-less date is never after its release; a day range keeps its year; a plea after the sentencing loses its day")
    func ho15Years() {
        let clark = "January 16, 2014\nJoe Clark, 51, of Ada, was sentenced today to three years in prison. Clark pleaded guilty on October 11th to possessing pseudoephedrine."
        let f = X.findings(in: clark, person: "Joe Clark")
        #expect(day(f.first { $0.step == .pleaded }) == "2013-10-11")
        let torrez = "May 4, 2018\nAnna Torrez, 33, of Taos, was sentenced today to 10 years. A jury convicted Torrez on Oct. 21 and 22, 2015 of fraud."
        #expect(day(X.findings(in: torrez, person: "Anna Torrez").first { $0.step == .convicted }) == "2015-10-21")
        let late = "March 1, 2019\nLee Park, 29, of Reno, was sentenced on February 2, 2019. Park pleaded guilty on February 20, 2019 to fraud."
        #expect(X.findings(in: late, person: "Lee Park").first { $0.step == .pleaded }.map { day($0) } ?? nil == nil)
    }

    @Test("ho15 E: a charge answer names an offence — 'one count in a federal indictment' loses to the sentence that states it")
    func ho15ChargeNamesOffence() throws {
        let text = """
        June 4, 2019
        Kevin Brown, 45, of Ogden, pleaded guilty to one count in a federal indictment. Brown was indicted on methamphetamine related charges and admitted that he conspired to manufacture methamphetamine.
        """
        let a = try #require(ProceedingAnswerer.answer(.init(person: "Kevin Brown", ask: .chargedWith), sources: [.init(objectID: UUID(), text: text)]))
        #expect(a.body.contains("methamphetamine"), "\(a.body)")
    }

    @Test("ho15 C: 'a date on record for when X was pardoned' and 'I'm looking for the sentence that X received' parse")
    func ho15Parsing() {
        let n = QuestionCanonicalizer.normalize
        #expect(ProceedingAnswerer.parse(n("Is there a date on record for when John Ross was pardoned?"))?.ask == .when(.pardoned))
        #expect(ProceedingAnswerer.parse(n("I'm looking for the sentence that John Ross received — what was it?")) != nil)
    }
}

