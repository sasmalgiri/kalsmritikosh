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

    // MARK: ho16 adjudication (docs/agent-reviews/accuracy-adjudication-ho16.md), answered wrongly on f0bb8bfd.

    @Test("ho16 B: 'announced today that X was sentenced yesterday afternoon' is yesterday; 'was sentenced March 16, 2017' is that day")
    func ho16Dates() {
        let nosack = "Friday, November 20, 2015\nStephen R. Wigginton, United States Attorney for the Southern District of Illinois, announced today that Patrick A. Nosack, 34, of Henderson, Nevada, was sentenced yesterday afternoon to thirty months in federal prison."
        #expect(day(X.findings(in: nosack, person: "Patrick A. Nosack").first { $0.step == .sentenced }) == "2015-11-19")
        let gray = "October 12, 2017\nAaron J. Gray, 40, of Mobile, was sentenced March 16, 2017, to 60 months in prison."
        #expect(day(X.findings(in: gray, person: "Aaron J. Gray").first { $0.step == .sentenced }) == "2017-03-16")
    }

    @Test("ho16 K: 'Today, a recidivist sex offender pled guilty' is the named defendant's plea; a component heading is not the headline")
    func ho16AnonymousLead() throws {
        let text = """
        U.S. Department of Justice
        Federal Bureau of Investigation (FBI)
        FOR IMMEDIATE RELEASE
        Monday, March 2, 2026

        Repeat Sex Offender Pleads Guilty to Sexual Exploitation of a Child

        Baltimore, Maryland – Today, a recidivist sex offender pled guilty in federal court to more child sex abuse crimes.
         Patrick Daniel McKernan, 45, of Pasadena, Maryland, is charged with the sexual exploitation of a child.
         In 2016, McKernan was convicted of possession of child sexual abuse material in the Circuit Court for Anne Arundel County, Maryland.
        """
        #expect(X.headline(of: text) == "Repeat Sex Offender Pleads Guilty to Sexual Exploitation of a Child")
        let plea = X.findings(in: text, person: "Patrick Daniel McKernan").first { $0.step == .pleaded }
        #expect(day(plea) == "2026-03-02")
        let a = try #require(ProceedingAnswerer.answer(.init(person: "Patrick Daniel McKernan", ask: .whether(.pleaded)), sources: [.init(objectID: UUID(), text: text)]))
        #expect(a.body.hasPrefix("Yes"), "\(a.body)")
    }

    @Test("ho16 K: 'An Allegheny County man was indicted … on charges of distribution …' answers what the named man was charged with")
    func ho16LeadCharge() throws {
        let text = """
        Thursday, July 3, 2014
        Glassport Man Charged With Distribution And Possession Of Child Pornography
        PITTSBURGH – An Allegheny County man was indicted on June 24, 2014, by a federal grand jury in Pittsburgh on charges of distribution and possession of material depicting the sexual exploitation of a minor, United States Attorney David J. Hickton announced today.
        The three-count indictment named Michael George Hadam, 59, of Glassport, Pa., as the sole defendant.
        """
        let a = try #require(ProceedingAnswerer.answer(.init(person: "Michael George Hadam", ask: .chargedWith), sources: [.init(objectID: UUID(), text: text)]))
        #expect(!a.refused && a.body.contains("distribution and possession"), "\(a.body)")
    }

    @Test("ho16 E: 'a charge stemming from a fatal shooting' and 'indicted on federal charges in July' name no offence")
    func ho16GenericCharge() throws {
        let franklin = """
        Friday, June 14, 2013
        WASHINGTON – Decordre Franklin, 25, of Washington, D.C., pled guilty today to a charge stemming from a fatal shooting that took place earlier this year in Northeast Washington.
        Franklin pled guilty in the Superior Court of the District of Columbia to voluntary manslaughter while armed in the slaying of Irving Jones.
        """
        let a = try #require(ProceedingAnswerer.answer(.init(person: "Decordre Franklin", ask: .chargedWith), sources: [.init(objectID: UUID(), text: franklin)]))
        #expect(a.body.contains("voluntary manslaughter"), "\(a.body)")
        let sisk = """
        Monday, August 21, 2023
        BRUNSWICK, GA: Todd Eric Sisk, 48, of Baxley, Ga., is charged via federal indictment with Attempted Production of Child Pornography, which carries a mandatory minimum sentence.
        Sisk was indicted on federal charges in July, and currently is in custody awaiting further court proceedings.
        """
        let b = try #require(ProceedingAnswerer.answer(.init(person: "Todd Eric Sisk", ask: .chargedWith), sources: [.init(objectID: UUID(), text: sisk)]))
        #expect(b.body.contains("Attempted Production"), "\(b.body)")
    }

    @Test("ho16 A: a separate case's sentence is not this case's; T: the quote keeps the person's own clause")
    func ho16SeparateCaseAndQuote() throws {
        let r1 = "January 7, 2013\nJohn David Farnell, 61, of Fulton, pleaded guilty today to bank robbery. In a separate case, Farnell was sentenced in the Eastern District of Missouri on March 9, 2012, to 13 years and six months in federal prison without parole."
        let r2 = "April 1, 2013\nJohn David Farnell, 61, of Fulton, was sentenced by U.S. District Judge Brian C. Wimes to five years and 10 months in federal prison without parole. In a separate case, Farnell was sentenced in the Eastern District of Missouri on March 9, 2012, to 13 years and six months in federal prison without parole."
        let sources: [ProceedingAnswerer.Source] = [.init(objectID: UUID(), text: r1), .init(objectID: UUID(), text: r2)]
        let a = try #require(ProceedingAnswerer.answer(.init(person: "John David Farnell", ask: .sentenceImposed), sources: sources))
        #expect(a.body.contains("five years and 10 months") && !a.body.contains("13 years and six months"), "\(a.body)")
        let long = "HUNTINGTON, W.Va. – Today, Talon Aaron McIntosh, also known as “Trey” and “T,” 28, and Mario Alonzo Pettway III, also known as “Mike,” 23, both of Detroit, Michigan, pleaded guilty to distribution of a quantity of methamphetamine and Ladonna Rae Abner, 49, of Nitro, pleaded guilty to distribution of a quantity of fentanyl, a Schedule II controlled substance."
        #expect(ProceedingAnswerer.quote(long, around: "abner").contains("distribution of a quantity of fentanyl"))
    }

    @Test("ho16 C: 'identify the office responsible for prosecuting', 'confirmation that', 'charge(s)' parse")
    func ho16Parsing() {
        let n = QuestionCanonicalizer.normalize
        #expect(ProceedingAnswerer.parse(n("Can you identify the office responsible for prosecuting Tajuana L. Sullivan?"))?.ask == .office)
        #expect(ProceedingAnswerer.parse(n("Do we have confirmation that Tyler Taylor pled guilty?"))?.ask == .whether(.pleaded))
        #expect(ProceedingAnswerer.parse(n("I'd like to know the specific charge(s) brought against John B. Hart."))?.ask == .chargedWith)
    }

    // MARK: ho17 adjudication (docs/agent-reviews/accuracy-adjudication-ho17.md), answered wrongly on b1022f77.

    @Test("ho17 A: 'also convicted previously in Minnesota federal court' is a prior case, not the charge; the jury's verdict states it")
    func ho17PriorConviction() throws {
        let text = """
        Wednesday, April 20, 2016
        Charlotte Pimp Convicted Of Sex Trafficking Of A Minor
        CHARLOTTE, N.C. – A federal jury delivered a guilty verdict yesterday against Kenwaniee Vontorian Tate, 40, of Charlotte, for sex trafficking of a minor by fraud, force and coercion and sex trafficking of a minor while being required to register as a sex offender under North Carolina law, announced Jill Westmoreland Rose, U.S. Attorney for the Western District of North Carolina.
        Tate was also convicted previously in Minnesota federal court for conspiracy to commit sex trafficking of a minor for his involvement in a sex trafficking ring that trafficked juvenile females from Minnesota to Las Vegas, Nevada, to engage in commercial sex acts.
        """
        let a = try #require(ProceedingAnswerer.answer(.init(person: "Kenwaniee Vontorian Tate", ask: .chargedWith), sources: [.init(objectID: UUID(), text: text)]))
        #expect(!a.body.contains("convicted previously"), "\(a.body)")
        #expect(a.body.contains("by fraud, force and coercion"), "\(a.body)")
    }

    @Test("ho17 C: six wordings that fell through to passage dumps parse to their ask")
    func ho17Parsing() {
        let n = QuestionCanonicalizer.normalize
        #expect(ProceedingAnswerer.parse(n("Is there any record of Jason Anthony Barrett pleading guilty?"))?.ask == .whether(.pleaded))
        #expect(ProceedingAnswerer.parse(n("I need to know specifically what Jodia Campbell was charged with."))?.ask == .chargedWith)
        #expect(ProceedingAnswerer.parse(n("I need to identify the office that prosecuted Raekwon Malik Harrod — can you confirm that?"))?.ask == .office)
        #expect(ProceedingAnswerer.parse(n("Please pull the record showing when Kraig Antonio Davis was sentenced."))?.ask == .when(.sentenced))
        #expect(ProceedingAnswerer.parse(n("I'm trying to find the date Kraig Antonio Davis was pardoned — can you confirm?"))?.ask == .when(.pardoned))
        #expect(ProceedingAnswerer.parse(n("Do you happen to know when Tony Newton was sentenced?"))?.ask == .when(.sentenced))
        // Not a step question: left to the normal pipeline.
        #expect(ProceedingAnswerer.parse(n("What did Tony Newton say after he was sentenced?")) == nil)
    }

    // MARK: ho18 adjudication (docs/agent-reviews/accuracy-adjudication-ho18.md), answered wrongly on 2e70e537.

    @Test("ho18 P: a possessive's conspirators, a co-defendant's headline and a wife's plea are not the person's steps")
    func ho18OtherPeople() throws {
        let tavares = "Wednesday, October 30, 2024\nNew Jersey Man Convicted for Stealing COVID-19 Unemployment Benefits\nJose Tavares, 45, of Perth Amboy, was convicted today of conspiracy. Tavares’ conspirators, Yanira Abreu, 43, of Keasby, New Jersey, and Christopher Valerio, 34, of Perth Amboy, New Jersey, have each previously pleaded guilty and were sentenced by Judge Kirsch in the same scheme."
        let tf = X.findings(in: tavares, person: "Jose Tavares")
        #expect(!tf.contains { $0.step == .sentenced } && !tf.contains { $0.step == .pleaded }, "\(tf.map(\.step))")
        let paul = """
        Wednesday, April 30, 2025
        Charlotte Man Sentenced To Prison For His Role In Multi-Million Dollar Bank Fraud Scheme
        CHARLOTTE, N.C. – A Charlotte man was sentenced to prison today for his role in a multi-million dollar bank fraud scheme. Bruce Howard Marko, 66, of Charlotte, was sentenced to 10 years in prison.
        Marko’s three co-defendants, Kotto Yaphet Paul, 50, of Waxhaw, N.C., Latoya Tamieka Ford, 50, of Covington, Georgia, and Love Norman, 50, of West Palm Beach, Florida, have each pleaded guilty to wire fraud and bank fraud conspiracy and are awaiting sentencing.
        """
        #expect(!X.findings(in: paul, person: "Kotto Yaphet Paul").contains { $0.step == .sentenced })
        let wife = """
        Tuesday, June 21, 2016
        Husband, Wife Plead Guilty to Meth Conspiracy
        Miguel Flores-Ramirez, 33, of Clark, pleaded guilty before U.S. Magistrate Judge Matt J. Whitworth today to the charge contained in an Oct. 1, 2014, federal indictment, conspiracy to distribute methamphetamine.
        His wife, Kena Marie Flores-Ramirez, pleaded guilty on May 19, 2016, to her role in the conspiracy.
        """
        let a = try #require(ProceedingAnswerer.answer(.init(person: "Miguel Flores-Ramirez", ask: .chargedWith), sources: [.init(objectID: UUID(), text: wife)]))
        #expect(!a.body.contains("His wife"), "\(a.body)")
    }

    @Test("ho18 B/H/A: a relative clause's plea date, an offence's date and a prior record are not the step's day")
    func ho18Dates() {
        let harris = "February 28, 2018\nPine Bluff Man Sentenced to Prison\nElbert Harris, 61, of Pine Bluff, was sentenced today. Judge Baker sentenced Harris, who pleaded guilty to conspiring to commit wire fraud on October 10, 2017, to 33 months’ imprisonment, to be followed by three years of supervised release."
        let hs = X.findings(in: harris, person: "Elbert Harris").filter { $0.step == .sentenced }
        #expect(!hs.contains { day($0) == "2017-10-10" }, "\(hs.map { day($0) ?? "-" })")
        let robbery = "June 24, 2022\nThree Men Indicted\nJohn Doe Smith, 30, of Mobile, and two others were indicted today for conspiring and attempting to commit a robbery of a jewelry store on March 14, 2022."
        #expect(X.findings(in: robbery, person: "John Doe Smith").first { $0.step == .charged }.map { day($0) } != "2022-03-14")
        let prior = "July 29, 2015\nAggravated felon pleads guilty\nTimoteo Gonzalez-Leiva, 42, of Honduras, pleaded guilty today to illegal reentry. He was arrested in March of 1998 for first degree robbery in Delaware and sentenced to two years in prison."
        #expect(!X.findings(in: prior, person: "Timoteo Gonzalez-Leiva").contains { $0.step == .sentenced })
    }

    @Test("ho18 O/C: the district office outranks an agency heading; two count wordings parse")
    func ho18OfficeAndCounts() {
        let text = "Bureau of Alcohol, Tobacco, Firearms and Explosives\nSeptember 2, 2020\nJackson Man Sentenced\nThis case was prosecuted as part of Project Safe Neighborhoods, an initiative by the U.S. Attorney’s Office for the Southern District of Mississippi."
        let offices = ProceedingAnswerer.offices(in: text)
        #expect(offices.contains { $0.contains("Southern District of Mississippi") } && !offices.contains { $0.hasPrefix("Bureau of Alcohol") }, "\(offices)")
        let n = QuestionCanonicalizer.normalize
        #expect(ProceedingAnswerer.parse(n("I need a count — how many press releases are about Craig Cinelli?"))?.ask == .documentCount)
        #expect(ProceedingAnswerer.parse(n("Could you count up the press releases that mention Jose Tavares?"))?.ask == .documentCount)
    }
}

