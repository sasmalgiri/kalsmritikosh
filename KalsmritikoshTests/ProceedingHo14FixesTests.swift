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
}
