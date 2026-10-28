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
        for q in ["What were the charges brought against Christi Machala?", "What exact charges were brought against Christi Machala?",
                  "What were the actual charges filed against Christi Machala?", "What charges were filed against Christi Machala?",
                  "What were the charges against Christi Machala?"] {
            #expect(ProceedingAnswerer.parse(n(q)) == ProceedingAnswerer.Parsed(person: "Christi Machala", ask: .chargedWith), "\(q)")
        }
        // Lead-ins that are not part of the question.
        #expect(ProceedingAnswerer.parse(n("For the file, what was the sentencing date for Christi Machala?")) == .init(person: "Christi Machala", ask: .when(.sentenced)))
        for q in ["Do you know offhand how many press releases reference Christi Machala?", "Any idea how many press releases mention Christi Machala?",
                  "I'm trying to get a count — how many press releases exist that are about Christi Machala?"] {
            #expect(ProceedingAnswerer.parse(n(q)) == .init(person: "Christi Machala", ask: .documentCount), "\(q)")
        }
        // "Jr." inside the plea clause; "as a convicted felon" is the offence.
        let rhodes = "U.S. Department of Justice\nFOR IMMEDIATE RELEASE\nMonday, March 4, 2019\n\nGulfport, Miss. – Eddie James Rhodes, 62, of Stone County, pled guilty today before U.S. District Judge Louis Guirola, Jr., to possession of a firearm in furtherance of a drug trafficking crime, announced U.S. Attorney Mike Hurst."
        let rp = try #require(ProceedingAnswerer.parse("What was Eddie James Rhodes charged with?"))
        #expect(try #require(ProceedingAnswerer.answer(rp, sources: [.init(objectID: UUID(), text: rhodes)])).body.contains("possession of a firearm in furtherance"))
        #expect("possessing a firearm as a convicted felon".range(of: ProceedingAnswerer.priorRecord, options: .regularExpression) == nil)
        for q in ["I need to know when Christi Machala's sentencing took place.",
                  "I need to know when sentencing occurred for Christi Machala — do we have that on record?",
                  "I need to know when Christi Machala received her sentencing — do you have that date?",
                  "Can you tell me the exact date Christi Machala was sentenced?",
                  "What was the sentencing date for Christi Machala?",
                  "I need to confirm — when exactly was Christi Machala's sentencing handed down?",
                  "I need the sentencing date for Christi Machala — when was it?",
                  "I need the sentencing date for Christi Machala — do you have that on record?",
                  "Could you pull up the sentencing date for Christi Machala?"] {
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
        // Fully-private (rules-only) rewordings from the tuned reworded set.
        let shapes: [(String, ProceedingAnswerer.Ask)] = [
            ("What was the sentence handed down to Christi Machala?", .sentenceImposed),
            ("Could you specify the sentence that Christi Machala received?", .sentenceImposed),
            ("I'm trying to confirm — did Christi Machala plead guilty?", .whether(.pleaded)),
            ("I'm trying to confirm whether Christi Machala pled guilty — can you verify that?", .whether(.pleaded)),
            ("For the record, did Christi Machala plead guilty, yes or no?", .whether(.pleaded)),
            ("I need a chronological rundown of the case against Christi Machala — can you give me that?", .timeline),
            ("I'd like to know which prosecuting office was responsible for the case against Christi Machala.", .office),
            ("Can you identify the office that prosecuted Christi Machala?", .office),
            ("Who was the prosecuting office in the matter of Christi Machala?", .office),
            ("What's the charge date for Christi Machala?", .when(.charged)),
            ("I need the charging date for Christi Machala — when did that happen?", .when(.charged)),
            ("Do we have the sentencing date for Christi Machala on record?", .when(.sentenced)),
        ]
        for (q, want) in shapes { #expect(ProceedingAnswerer.parse(n(q))?.ask == want, "\(q) → \(n(q))") }
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
        // A term stated only in the headline is the sentence.
        let headline = "U.S. Department of Justice\nCriminal Division\nFOR IMMEDIATE RELEASE\nThursday, April 16, 2015\n\nOwner of Miami Home Health Company Sentenced to 113 Months in Prison for $32 Million Medicare Fraud Scheme\n\nAn owner of a Miami home health company, Felix Gonzalez, 48, of Miami, was sentenced today for his role in a Medicare fraud scheme."
        let fg = try #require(ProceedingAnswerer.parse("What sentence did Felix Gonzalez receive?"))
        let fgBody = try #require(ProceedingAnswerer.answer(fg, sources: [ProceedingAnswerer.Source(objectID: UUID(), text: headline)])).body
        #expect(fgBody.hasPrefix("Felix Gonzalez was sentenced to 113 Months in Prison"))
        // A different given name at the start of a sentence is someone else too.
        let lomax = "U.S. Department of Justice\nFOR IMMEDIATE RELEASE\nTuesday, August 12, 2025\n\nHurricane Man Sentenced\n\nCHARLESTON, W.Va. – James Lomax, 33, of Hurricane, was sentenced today to three years in prison for theft of public money. Gary Lomax was sentenced on November 19, 2024, to five years of federal probation."
        let jl = try #require(ProceedingAnswerer.parse("What sentence did James Lomax receive?"))
        let jlBody = try #require(ProceedingAnswerer.answer(jl, sources: [ProceedingAnswerer.Source(objectID: UUID(), text: lomax)])).body
        #expect(jlBody.hasPrefix("James Lomax was sentenced to three years") && !jlBody.contains("probation"))
        // "sentenced today" wins over a later date run into the same sentence; a hyphenated term is a term.
        let run = "U.S. Department of Justice\nFOR IMMEDIATE RELEASE\nFriday, September 13, 2024\n\nBeckley Man Sentenced\n\nBECKLEY, W.Va. – Leon Eugene Smith Jr., 43, of Beckley, was sentenced today to a 161-month prison term for distribution of fentanyl According to court documents, on December 15, 2023, Smith sold fentanyl."
        let ls = try #require(ProceedingAnswerer.parse("When was Leon Eugene Smith sentenced?"))
        let lsBody = try #require(ProceedingAnswerer.answer(ls, sources: [ProceedingAnswerer.Source(objectID: UUID(), text: run)])).body
        #expect(lsBody.hasPrefix("Leon Eugene Smith was sentenced on September 13, 2024"))
        let lt = try #require(ProceedingAnswerer.parse("What sentence did Leon Eugene Smith receive?"))
        #expect(try #require(ProceedingAnswerer.answer(lt, sources: [ProceedingAnswerer.Source(objectID: UUID(), text: run)])).body.contains("161-month"))
        #expect(ProceedingAnswerer.parse("Roughly how many press releases reference Leon Eugene Smith?")?.ask == .documentCount)
        // A descriptive lead with an occupation the list lacked ("A former deputy and helicopter pilot …").
        let deputy = "U.S. Department of Justice\nFOR IMMEDIATE RELEASE\nMonday, March 16, 2026\n\nFormer Deputy Sentenced\n\nLOS ANGELES – A former deputy and helicopter pilot with the Los Angeles County Sheriff’s Department was sentenced today to 63 months in federal prison for helping extort a rival. Michael David Coberg, 44, of Eastvale, was sentenced by United States District Judge Percy Anderson."
        let mc = try #require(ProceedingAnswerer.parse("What sentence did Michael David Coberg receive?"))
        #expect(try #require(ProceedingAnswerer.answer(mc, sources: [ProceedingAnswerer.Source(objectID: UUID(), text: deputy)])).body.contains("63 months"))
        // "pleaded guilty … to an information charging him" is the plea, not a charging event on that day.
        let plea = "U.S. Department of Justice\nFOR IMMEDIATE RELEASE\nTuesday, March 28, 2017\n\nStango Sentenced\n\nCharles Stango, 73, of Henderson, Nevada, previously pleaded guilty to an information charging him with one count of using an interstate facility with intent to murder."
        let cs = try #require(ProceedingAnswerer.parse("When was Charles Stango charged?"))
        let csAnswer = try #require(ProceedingAnswerer.answer(cs, sources: [ProceedingAnswerer.Source(objectID: UUID(), text: plea)]))
        #expect(csAnswer.refused)
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
        // A locality with commas; an arraignment "on an indictment charging" is not the charging.
        let scallion = """
            U.S. Department of Justice
            FOR IMMEDIATE RELEASE
            Tuesday, May 28, 2013
            Jackson County Man Charged With Methamphetamine Conspiracy
            A Jackson County, Illinois, man was indicted by a federal grand jury on May 9, 2013, for conspiracy to manufacture methamphetamine, the United States Attorney for the Southern District of Illinois, Stephen R. Wigginton, announced today. On May 24, 2013, Charles W. Scallion, 41, of Carbondale, was arraigned in United States District Court in Benton on an indictment charging conspiracy to manufacture methamphetamine.
            """
        let steps = ProceedingEventExtractor.findings(in: scallion, person: "Charles W. Scallion")
        #expect(steps.filter { $0.step == .charged }.compactMap(\.day).map(\.day) == [9])
        #expect(steps.contains { $0.step == .arraigned && $0.day?.day == 24 })
        // A plural lead is about each defendant the next sentences introduce.
        let rico = """
            U.S. Department of Justice
            FOR IMMEDIATE RELEASE
            Wednesday, July 20, 2022
            Two Florida Medical Study Coordinators Plead Guilty in Connection with Scheme to Falsify Clinical Trial Data
            Two Florida women pleaded guilty today in connection with their participation in a conspiracy to falsify clinical trial data. According to court documents, Analay Rico, 37, of Fort Lauderdale, and Daylen Diaz, 44, of Miami, worked as study coordinators.
            """
        let plea = ProceedingEventExtractor.findings(in: rico, person: "Analay Rico").first { $0.step == .pleaded }
        #expect(plea?.day?.month == 7 && plea?.day?.day == 20)
        // Two sentences run together: the date after the plea verb is the plea's, not the sentencing's.
        let parks = """
            U.S. Department of Justice
            FOR IMMEDIATE RELEASE
            Wednesday, October 7, 2015
            Parks Sentenced To 27 Months For Wire Fraud
            Christopher R. Thyer, United States Attorney for the Eastern District of Arkansas, announced today that, Stephen K. Parks, 62, of Little Rock, Arkansas, was sentenced to 27 months imprisonment and ordered to pay $845,000 in restitution to the IRS; Parks pled guilty to a Federal Information charging him with wire fraud on May 27, 2015.
            """
        // HTML text: one element per line, a lower-case headline straight above the dateline lead.
        let bartels = "U.S. Department of Justice\nSouthern District of Ohio\nFOR IMMEDIATE RELEASE\nWednesday, December 21, 2022\nFormer Gallia County 911 dispatcher charged federally for 24 arson fires in Wayne National Forest\nCOLUMBUS, Ohio – A fire department administrator and former 911 dispatcher has been charged federally with crimes related to at least 24 arson fires since spring 2022 in Wayne National Forest.\nJames A. Bartels, 50, of Patriot, Ohio, was arrested yesterday and appeared in federal court in Columbus."
        let bp = try #require(ProceedingAnswerer.parse("What exactly was James A. Bartels charged with?"))
        #expect(try #require(ProceedingAnswerer.answer(bp, sources: [.init(objectID: UUID(), text: bartels)])).body.contains("crimes related to at least 24 arson fires"))
        let parksSteps = ProceedingEventExtractor.findings(in: parks, person: "Stephen K. Parks")
        #expect(parksSteps.first { $0.step == .sentenced }?.day?.month == 10)
        #expect(parksSteps.first { $0.step == .pleaded }?.day?.month == 5)
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
        // A judge's initials and "U.S." inside the plea clause; "by a convicted felon" is the offence itself.
        func charged(_ name: String, _ body: String) throws -> String {
            let text = "U.S. Department of Justice\nFOR IMMEDIATE RELEASE\nTuesday, May 7, 2019\n\n" + body
            let parsed = try #require(ProceedingAnswerer.parse("What was \(name) charged with?"))
            return try #require(ProceedingAnswerer.answer(parsed, sources: [.init(objectID: UUID(), text: text)])).body
        }
        #expect(try charged("Benjamin James McGrigg", "Jackson, Miss. – Benjamin James McGrigg, 43, of Jackson, pled guilty today before Chief U.S. District Judge Daniel P. Jordan III to commercial driver’s license fraud, announced U.S. Attorney Mike Hurst.")
            .contains("commercial driver’s license fraud"))
        #expect(try charged("Robin Stephan", "CONCORD - Robin Stephan, 43, of Manchester, pleaded guilty in federal court to possession of ammunition by a convicted felon, Acting United States Attorney John J. Farley announced today.")
            .contains("possession of ammunition by a convicted felon"))
        // A prior record is still not the charge.
        #expect(try charged("Tom Reed", "Tom Reed, 30, a previously convicted felon, was arrested in March. Reed has prior felony convictions.")
            .hasPrefix("The documents that name Tom Reed don't state"))
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

    @Test("'Charged with': the sentence naming the person outranks a group lead that gives the case's charges")
    func chargeNamesThePerson() throws {
        let text = """
        U.S. Department of Justice
        FOR IMMEDIATE RELEASE
        Tuesday, March 2, 2021

        BOSTON - Two men pleaded guilty yesterday to conspiring to defraud the government in connection with the renovation of a post office.
        Wael Isreb, 51, of Quincy, pleaded guilty to conspiracy to commit mail fraud and to making false statements.
        """
        let parsed = try #require(ProceedingAnswerer.parse("What were the charges against Wael Isreb?"))
        let body = try #require(ProceedingAnswerer.answer(parsed, sources: [ProceedingAnswerer.Source(objectID: UUID(), text: text)])).body
        #expect(body.contains("conspiracy to commit mail fraud"), "\(body)")
        #expect(!body.contains("Two men"), "\(body)")
    }


    @Test("A yes/no question behind a courtesy wrapper parses as the same question; a trial verdict anywhere outranks a bare 'convicted' headline")
    func wrappedWhetherAndTrialVerdict() throws {
        for q in ["I'm trying to confirm: did Jason Lorel Minter plead guilty?",
                  "I need to know—did Jason Lorel Minter plead guilty?",
                  "For the record, can you confirm whether Jason Lorel Minter pleaded guilty?",
                  "I'm trying to verify whether Jason Lorel Minter pled guilty — can you confirm?"] {
            #expect(ProceedingAnswerer.parse(q) == ProceedingAnswerer.Parsed(person: "Jason Lorel Minter", ask: .whether(.pleaded)), "\(q)")
        }
        #expect(ProceedingAnswerer.parse("For the record, when was Jason Lorel Minter sentenced?")?.ask != .whether(.sentenced))
        let release = """
        U.S. Department of Justice
        District of Hawaii
        FOR IMMEDIATE RELEASE
        Friday, May 5, 2023

        Kapolei Man Convicted Of Methamphetamine Trafficking

        HONOLULU – Ernesto Hernandez, 41, of Kapolei, was convicted on May 4, 2023, after a four-day trial, when a federal jury found him guilty of possessing methamphetamine with intent to distribute it.
        """
        let parsed = try #require(ProceedingAnswerer.parse("Did Ernesto Hernandez plead guilty?"))
        let body = try #require(ProceedingAnswerer.answer(parsed, sources: [ProceedingAnswerer.Source(objectID: UUID(), text: release)])).body
        #expect(body.hasPrefix("No — "), "\(body)")
    }


    @Test("A courtesy wrapper before a when-, sentence- or date-question leaves the same question")
    func wrappedQuestions() {
        let p = { (q: String) in ProceedingAnswerer.parse(q) }
        #expect(p("I need to confirm: when did the sentencing of Kings Daniel Santy take place?")?.ask == .when(.sentenced))
        #expect(p("I need the sentencing date for Wael Isreb — do you have that on file?")?.ask == .when(.sentenced))
        #expect(p("I'm trying to confirm the sentence handed down to Nina Bourret — what was it?")?.ask == .sentenceImposed)
        #expect(p("For the record, when was Nina Bourret sentenced?")?.ask == .when(.sentenced))
        for q in ["Can you specify what Serhat Gumrukcu was charged with?", "Could you specify the charges filed against Serhat Gumrukcu?",
                  "I'm looking to find out exactly what Serhat Gumrukcu was charged with.", "I'd like to know what Serhat Gumrukcu was charged with.",
                  "Can you tell me exactly what Serhat Gumrukcu was charged with?", "Can you clarify what Serhat Gumrukcu was charged with?"] {
            #expect(p(q)?.ask == .chargedWith, "\(q)")
        }
        // Unwrapped questions are unchanged.
        #expect(p("When was Nina Bourret sentenced?")?.ask == .when(.sentenced))
        #expect(p("What was Nina Bourret charged with?")?.ask == .chargedWith)
    }


    @Test("'She pleaded guilty …' in a release about one defendant is that defendant's plea; sentence questions behind wrappers")
    func pronounLedStepAndSentenceWording() throws {
        let release = """
        U.S. Department of Justice
        District of Montana
        FOR IMMEDIATE RELEASE
        Tuesday, July 30, 2013

        Billings Woman Sentenced for Embezzlement

        BILLINGS – Sophia Beltz, 34, of Billings, was sentenced today to 18 months in prison for embezzling from her employer. She pleaded guilty on April 30, 2013.
        """
        let parsed = try #require(ProceedingAnswerer.parse("Did Sophia Beltz enter a guilty plea at any point?"))
        let body = try #require(ProceedingAnswerer.answer(parsed, sources: [ProceedingAnswerer.Source(objectID: UUID(), text: release)])).body
        #expect(body.hasPrefix("Yes"), "\(body)")
        let p = { (q: String) in ProceedingAnswerer.parse(q)?.ask }
        #expect(p("Could you clarify exactly what sentence Mike Marty Hernandez received?") == .sentenceImposed)
        #expect(p("Could you pull up the details on the sentence Susan M. Ruhe received?") == .sentenceImposed)
        #expect(p("Could you provide details on the sentence that Bobby Joseph Stallworth received?") == .sentenceImposed)
        #expect(p("I'm trying to find out exactly what sentence Sohaib Akhter received — can you pull that?") == .sentenceImposed)
    }

}
