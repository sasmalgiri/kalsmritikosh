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

    @Test("Held-out chronology 9 (2026-10-29): a count behind 'do you have', a date behind 'do we have', a 'prosecutorial office', a component-issued release, a mis-titled release")
    func heldOut9() throws {
        let n = QuestionCanonicalizer.normalize
        for q in ["Do you have a count of how many press releases reference Christi Machala?",
                  "Do you have a count of how many press releases mention Christi Machala?"] {
            #expect(ProceedingAnswerer.parse(n(q))?.ask == .documentCount, "\(q) → \(n(q))")
        }
        for q in ["Which prosecutorial office handled the case against Christi Machala?",
                  "Which office handled the prosecution of Christi Machala?"] {
            #expect(ProceedingAnswerer.parse(n(q))?.ask == .office, "\(q) → \(n(q))")
        }
        for q in ["Do we have a date for when Christi Machala was pardoned?", "Is there a date for when Christi Machala was pardoned?"] {
            #expect(ProceedingAnswerer.parse(n(q))?.ask == .when(.pardoned), "\(q) → \(n(q))")
        }
        // A step no document records stays unrecorded, not a passage dump.
        #expect(try ask(n("Do we have a date for when Christi Machala was pardoned?")).refused)
        // A release issued by a component: the heading names it when no district is named anywhere.
        let fbi = "U.S. Department of Justice\nFederal Bureau of Investigation (FBI)\nFOR IMMEDIATE RELEASE\nTuesday, September 30, 2025\nChester County Man Pleads Guilty to Stealing Valuable Coins From Bank Safe Deposit Box\nPHILADELPHIA – United States Attorney David Metcalf announced that Richard DiStefano, 65, of Paoli, Pennsylvania, entered a plea of guilty today before United States District Judge Timothy J. Savage on one count of bank larceny."
        #expect(ProceedingAnswerer.offices(in: fbi) == ["Federal Bureau of Investigation (FBI)"])
        let office = try #require(ProceedingAnswerer.parse("Which office handled the prosecution of Richard DiStefano?"))
        #expect(try #require(ProceedingAnswerer.answer(office, sources: [.init(objectID: UUID(), text: fbi)])).body.contains("Federal Bureau of Investigation (FBI)"))
        // A mis-titled release ("… Man Sentenced …" over a body that reports yesterday's plea): the
        // title adds no sentencing step; the timeline has the plea and the later sentence only.
        let mistitled = "U.S. Department of Justice\nEastern District of Virginia\nFOR IMMEDIATE RELEASE\nFriday, September 19, 2014\n\nWashington, D.C. Man Sentenced For Role In 2013 String Of Armed Bank Robberies\n\nALEXANDRIA, Va. – Tayron Tyree Weeks, 24, of Alexandria, pleaded guilty yesterday to engaging in the sex trafficking of a child.\n\nWeeks faces a maximum penalty of life in prison when he is sentenced on Dec. 12, 2014."
        let sentenced = "U.S. Department of Justice\nEastern District of Virginia\nFOR IMMEDIATE RELEASE\nFriday, December 12, 2014\n\nAlexandria Man Sentenced\n\nALEXANDRIA, Va. – Tayron Tyree Weeks, 24, of Alexandria, was sentenced today to 132 months in prison for sex trafficking of a child.\n\nWeeks pleaded guilty on September 18, 2014."
        let steps = ProceedingEventExtractor.findings(in: mistitled, person: "Tayron Tyree Weeks").map(\.step)
        #expect(steps == [.pleaded], "\(steps)")
        let tl = try #require(ProceedingAnswerer.parse("Give me the timeline of the case against Tayron Tyree Weeks"))
        let body = try #require(ProceedingAnswerer.answer(tl, sources: [.init(objectID: UUID(), text: mistitled), .init(objectID: UUID(), text: sentenced)])).body
        #expect(body.contains("September 18, 2014 (release dated September 19, 2014) — pleaded guilty") && body.contains("December 12, 2014 — sentenced")
                && !body.contains("— sentenced: “Washington"), "\(body)")
    }

    @Test("Held-out chronology 10 (2026-10-29): more courtesy wrappers, 'entered a guilty plea', 'The defendant', a jury that found X guilty, a trial named elsewhere in the release, two sentencings, an offence sentence over a date or a co-defendant list, a weekday")
    func heldOut10() throws {
        let n = QuestionCanonicalizer.normalize
        let shapes: [(String, ProceedingAnswerer.Ask)] = [
            ("For my count, how many press releases were issued about Christi Machala?", .documentCount),
            ("Please pull up when Christi Machala was sentenced.", .when(.sentenced)),
            ("I need to pin down when charges were filed against Christi Machala — do we have that date?", .when(.charged)),
            ("Is there any indication that Christi Machala entered a guilty plea?", .whether(.pleaded)),
            ("I need to know which prosecutor's office took on the case against Christi Machala.", .office),
        ]
        for (q, want) in shapes { #expect(ProceedingAnswerer.parse(n(q))?.ask == want, "\(q) → \(n(q))") }
        func release(_ date: String, _ body: String) -> String { "U.S. Department of Justice\nDistrict of Nevada\nFOR IMMEDIATE RELEASE\n\(date)\n\n" + body }
        // "entered a guilty plea", "The defendant pleaded guilty" are pleas.
        let entered = release("Tuesday, December 1, 2020", "St. Thomas, USVI – Rakem Hendrickson, 28, of St. Croix, appeared before Magistrate Judge George W. Cannon, Jr., in District Court and entered a guilty plea to the charge of Use of a Firearm During a Drug Trafficking Crime.")
        #expect(ProceedingEventExtractor.findings(in: entered, person: "Rakem Hendrickson").map(\.step) == [.pleaded])
        let defendant = release("Tuesday, February 9, 2021", "PHILADELPHIA – Steven G. Dubin, 66, of Holland, PA, was sentenced to 18 months in prison. In June 2018, the defendant pleaded guilty to wire fraud.")
        #expect(ProceedingEventExtractor.findings(in: defendant, person: "Steven G. Dubin").map(\.step).contains(.pleaded))
        // A jury that "found X guilty" is a verdict at trial: "did X plead guilty?" is No.
        let jury = release("Friday, November 17, 2017", "FRESNO, Calif. — A federal jury in Fresno today found Adam Alan Henry, 39, of Turlock, guilty of conspiring to sexually exploit a minor.")
        let henry = try #require(ProceedingAnswerer.parse("Did Adam Alan Henry enter a guilty plea?"))
        #expect(try #require(ProceedingAnswerer.answer(henry, sources: [.init(objectID: UUID(), text: jury)])).body.hasPrefix("No — the documents say Adam Alan Henry was found guilty at trial"))
        // The trial is named in another sentence of the same release.
        let bench = release("Monday, December 17, 2018", "Izmir Koch, 33, of Huber Heights, Ohio, was convicted in U.S. District Court today for assaulting a man. The verdict was announced by Judge Susan J. Dlott after a bench trial that occurred between Nov. 13 to 15.")
        let koch = try #require(ProceedingAnswerer.parse("Did Izmir Koch enter a guilty plea?"))
        #expect(try #require(ProceedingAnswerer.answer(koch, sources: [.init(objectID: UUID(), text: bench)])).body.hasPrefix("No — the documents say Izmir Koch was found guilty at trial"))
        // Two sentencings: both given, in order.
        let first = release("Wednesday, April 5, 2017", "ROCHESTER, N.Y. -- Hoeub Chan, 35, of Rochester, NY, who was convicted of smuggling narcotics into jail, was sentenced to 18 months in prison by Chief U.S. District Judge Frank P. Geraci. Chan was sentenced to federal prison on January 6, 2016 following his conviction for conspiracy to commit mail fraud.")
        let chan = try #require(ProceedingAnswerer.parse("What was the sentencing date for Hoeub Chan?"))
        let chanBody = try #require(ProceedingAnswerer.answer(chan, sources: [.init(objectID: UUID(), text: first)])).body
        #expect(chanBody.hasPrefix("Hoeub Chan was sentenced on January 6, 2016 and again on April 5, 2017") && chanBody.count < 600, "\(chanBody)")
        // A step every release re-reports on its own printed day is one step, not several.
        let again = release("Friday, April 26, 2024", "Estes Carter Thompson III, 36, of Charlotte, N.C., was charged with one count of attempted sexual exploitation of children.")
        let again2 = release("Thursday, January 18, 2024", "Estes Carter Thompson III, 36, of Charlotte, N.C., was charged with one count of attempted sexual exploitation of children.")
        let ect = try #require(ProceedingAnswerer.parse("When was Estes Carter Thompson III charged?"))
        #expect(try #require(ProceedingAnswerer.answer(ect, sources: [.init(objectID: UUID(), text: again), .init(objectID: UUID(), text: again2)])).body.hasPrefix("The document dated January 18, 2024 reports"))
        // "… agents of Innospec Inc. On March 18, 2010, Innospec pleaded guilty …" is Innospec's plea, not Naaman's charge.
        let innospec = release("Thursday, December 22, 2011", "Naaman and his companies were the Iraqi agents of Innospec Inc. On March 18, 2010, Innospec pleaded guilty to a 12-count indictment charging wire fraud in connection with its payment of kickbacks. Ousama Naaman, 62, of Abu Dhabi, is charged with one count of conspiracy to commit wire fraud.")
        let onInnospec = try #require(ProceedingAnswerer.parse("What exact charges were filed against Ousama Naaman?"))
        #expect(try #require(ProceedingAnswerer.answer(onInnospec, sources: [.init(objectID: UUID(), text: innospec)])).body.contains("conspiracy to commit wire fraud"))
        // Two documents stating offences with no word in common: two prosecutions (or two people of one name) — both given.
        let meth = release("Thursday, January 8, 2026", "United States Attorney Lesley A. Woods announced that Andrew Juarez, 38, of Hastings, Nebraska, was sentenced on January 8, 2026, for one count of conspiracy to distribute more than 50 grams of methamphetamine.")
        let travel = release("Tuesday, March 3, 2020", "Andrew Juarez, 29, of El Paso, Texas, pleaded guilty today to traveling with the intent to engage in illicit sexual conduct with a nine-year-old girl.")
        let aj = try #require(ProceedingAnswerer.parse("What were the specific charges brought against Andrew Juarez?"))
        let ajBody = try #require(ProceedingAnswerer.answer(aj, sources: [.init(objectID: UUID(), text: meth), .init(objectID: UUID(), text: travel)])).body
        #expect(ajBody.hasPrefix("The documents state more than one charge for Andrew Juarez") && ajBody.contains("methamphetamine") && ajBody.contains("illicit sexual conduct"), "\(ajBody)")
        // The offence sentence wins over "indicted on <date>" and over "charged … with <co-defendants>".
        let naaman = release("Friday, July 31, 2009", "Ousama Naaman, 60, of Abu Dhabi, United Arab Emirates, was indicted on Aug. 7, 2008, in U.S. District Court for the District of Columbia. Naaman is charged with one count of conspiracy to commit wire fraud and to violate the Foreign Corrupt Practices Act.")
        let on = try #require(ProceedingAnswerer.parse("What exact charges were filed against Ousama Naaman?"))
        #expect(try #require(ProceedingAnswerer.answer(on, sources: [.init(objectID: UUID(), text: naaman)])).body.contains("conspiracy to commit wire fraud"))
        let mendes = release("Wednesday, October 5, 2016", "BOSTON – Sharik Mendes, 39, of New Bedford, pleaded guilty to one count of conspiracy to distribute and possess with the intent to distribute heroin. Mendes had been previously charged by criminal complaint in June 2016 with Tyson Depina and Eric Desousa, both of whom have pleaded not guilty.")
        let sm = try #require(ProceedingAnswerer.parse("What were the charges filed against Sharik Mendes?"))
        #expect(try #require(ProceedingAnswerer.answer(sm, sources: [.init(objectID: UUID(), text: mendes)])).body.contains("conspiracy to distribute"))
        // "In addition, the indictment charges X with …" loses to the main charging sentence.
        let arrick = release("Wednesday, May 21, 2014", "COLUMBUS, Ohio – A federal grand jury has indicted Keith A. Arrick Sr., 46, of Ft. Mitchell, Kentucky and his son charging them with conspiracy to commit sex trafficking, sex trafficking of a minor and sex trafficking by force, fraud or coercion. In addition, the indictment charges Keith Arrick Sr. with two counts of violating the Mann Act.")
        let ka = try #require(ProceedingAnswerer.parse("What charges were filed against Keith A. Arrick Sr.?"))
        #expect(try #require(ProceedingAnswerer.answer(ka, sources: [.init(objectID: UUID(), text: arrick)])).body.contains("conspiracy to commit sex trafficking"))
        // A weekday against the printed date; an initial appearance answers "when charged" honestly.
        let west = release("Tuesday, March 24, 2020", "Employee Of Drug Testing Facility Charged With Accepting Bribes\n\nLAS VEGAS, Nev. — Billy Joe West, 57, of Las Vegas, made his initial appearance Monday on a federal charge alleging that he misused his position.")
        let steps = ProceedingEventExtractor.findings(in: west, person: "Billy Joe West")
        #expect(steps.contains { $0.step == .arraigned && $0.day == DateComponents(year: 2020, month: 3, day: 23) }, "\(steps)")
        let bw = try #require(ProceedingAnswerer.parse("Can you tell me the date on which Billy Joe West was formally charged?"))
        let bwBody = try #require(ProceedingAnswerer.answer(bw, sources: [.init(objectID: UUID(), text: west)])).body
        #expect(bwBody.contains("March 2") && !bwBody.contains("don't record"), "\(bwBody)")
    }

    @Test("Held-out chronology 11 (2026-10-30): 'plead guilty to the charges', 'any record indicating', 'exactly when', 'punishment or sentence', 'public statements or press releases', a Section heading, a prior conviction, two sentences, a hyphenated surname, the release date beside a weekday")
    func heldOut11() throws {
        let n = QuestionCanonicalizer.normalize
        let shapes: [(String, ProceedingAnswerer.Ask)] = [
            ("For the record, did Christi Machala plead guilty to the charges?", .whether(.pleaded)),
            ("Is there any record indicating that Christi Machala entered a guilty plea?", .whether(.pleaded)),
            ("Could you confirm exactly when Christi Machala was sentenced?", .when(.sentenced)),
            ("Do you know exactly when Christi Machala was sentenced?", .when(.sentenced)),
            ("Could you specify the punishment or sentence that Christi Machala received?", .sentenceImposed),
            ("Could you confirm the sentence that Christi Machala ended up getting?", .sentenceImposed),
            ("How many public statements or press releases have been issued about Christi Machala?", .documentCount),
            ("I need to know—what office was responsible for prosecuting Christi Machala?", .office),
        ]
        for (q, want) in shapes { #expect(ProceedingAnswerer.parse(n(q))?.ask == want, "\(q) → \(n(q))") }
        func release(_ date: String, _ body: String, heading: String = "District of Kansas") -> String { "U.S. Department of Justice\n\(heading)\nFOR IMMEDIATE RELEASE\n\(date)\n\n" + body }
        // A component section as the heading line.
        let section = release("Friday, February 16, 2018", "United States Attorney Trent Shores announced today that Noel McFadden, 71, of Broken Arrow, pleaded guilty to one count of sexual exploitation of a child.", heading: "Criminal - Child Exploitation and Obscenity Section")
        #expect(ProceedingAnswerer.offices(in: section) == ["Criminal - Child Exploitation and Obscenity Section"])
        // The body's charge over the headline's.
        let tilcock = release("Friday, January 3, 2025", "Two people from Wichita charged with robbing Kansas banks\n\nWICHITA, KAN. – A man and woman from Kansas have been charged through criminal complaint in Wichita on charges related to a series of bank robberies involving a firearm. According to court documents, Zane Tilcock, 20, of Wichita is charged with three counts of bank robbery. Emily Wise, 18, of Wichita is charged with one count of bank robbery.")
        let zt = try #require(ProceedingAnswerer.parse("What were the specific charges filed against Zane Tilcock?"))
        #expect(try #require(ProceedingAnswerer.answer(zt, sources: [.init(objectID: UUID(), text: tilcock)])).body.contains("three counts of bank robbery"))
        // A prior conviction is not this case's sentencing; the sentencing release answers.
        let plea = release("Friday, November 27, 2015", "Jarrod Ty Foxworthy, 29, of Lafayette, pleaded guilty before U.S. District Judge Richard T. Haik to one count of possession of a firearm by convicted felon. The defendant had been previously convicted in March of 2007 in North Carolina state court of common law robbery, for which he was sentenced to 12 to 15 months in prison.")
        let sentencing = release("Friday, February 26, 2016", "Jarrod Ty Foxworthy, 29, of Lafayette, was sentenced by U.S. District Judge Patricia Minaldi on one count of possession of a firearm by a convicted felon.")
        let jf = try #require(ProceedingAnswerer.parse("Can you tell me the exact date Jarrod Ty Foxworthy was sentenced?"))
        let jfBody = try #require(ProceedingAnswerer.answer(jf, sources: [.init(objectID: UUID(), text: plea), .init(objectID: UUID(), text: sentencing)])).body
        #expect(jfBody.contains("February 26, 2016") && !jfBody.contains("2007"), "\(jfBody)")
        // Two sentences in two prosecutions: both given; "U." is not part of a term.
        let first = release("Monday, March 10, 2014", "Huntington, W.Va. – A Illinois felon who illegally possessed four firearms in February of 2013 was sentenced today to six years and six months in federal prison, U.S. Attorney Booth Goodwin announced. Thomas Ray III, 44, of Will County, Illinois, previously pleaded guilty in December 2013 to possessing a firearm after having been convicted of a felony offense.")
        let second = release("Monday, December 18, 2023", "HUNTINGTON, W.Va. – Thomas Ray III, 54, of Huntington, was sentenced today to 12 years in prison, to be followed by five years of supervised release, for being a felon in possession of a firearm.")
        let tr = try #require(ProceedingAnswerer.parse("What sentence was handed down to Thomas Ray III?"))
        let trBody = try #require(ProceedingAnswerer.answer(tr, sources: [.init(objectID: UUID(), text: first), .init(objectID: UUID(), text: second)])).body
        #expect(trBody.contains("12 years") && trBody.contains("six years and six months") && !trBody.contains("prison, U"), "\(trBody)")
        // A hyphenated surname written with a space in one release still names the person.
        let hyphen = release("Monday, December 11, 2017", "BUFFALO, N.Y. - U.S. Attorney James P. Kennedy, Jr. announced today that Armando Navarrete Dominguez, 29, of Mexico, pleaded guilty to illegal re-entry.")
        #expect(ProceedingEventExtractor.mentionsFully(hyphen.lowercased(), tokens: ProceedingEventExtractor.nameTokens("Armando Navarrete-Dominguez")))
        // A weekday-derived day carries the release's own date beside it.
        let weekday = release("Thursday, August 20, 2020", "PENSACOLA, FLORIDA – Michael C. Greutman, 59, of Fort Walton Beach, Florida, was sentenced Tuesday afternoon to 42 months in federal prison on charges of wire fraud.")
        let mg = try #require(ProceedingAnswerer.parse("On what date was Michael C. Greutman sentenced?"))
        #expect(try #require(ProceedingAnswerer.answer(mg, sources: [.init(objectID: UUID(), text: weekday)])).body.hasPrefix("Michael C. Greutman was sentenced on August 18, 2020 (the release is dated August 20, 2020)"))
        // "A jury convicted three people of …" is a plural lead about each defendant named next.
        let moody = release("Monday, December 11, 2017", "A jury convicted three people of taking federal money earmarked for job training and instead using the money to fund lavish lifestyles. James D. Moody, 58, of Toledo, Victoria Hawkins, 31, and Angela Bowser, 46, were convicted on all counts.", heading: "Northern District of Ohio")
        let jm = try #require(ProceedingAnswerer.parse("What were the charges filed against James D. Moody?"))
        #expect(try #require(ProceedingAnswerer.answer(jm, sources: [.init(objectID: UUID(), text: moody)])).body.contains("taking federal money earmarked for job training"))
    }

    @Test("Held-out chronology 12 (2026-10-30): the term-stating sentence over the lead on the same day, an old conviction is not the charge, a singular lead in a multi-defendant release is the first-introduced person's")
    func heldOut12() throws {
        func release(_ date: String, _ body: String) -> String { "U.S. Department of Justice\nWestern District of Virginia\nFOR IMMEDIATE RELEASE\n\(date)\n\n" + body }
        // The lead reports the sentencing without the term; the next sentence states it: the term is found.
        let hooper = release("Wednesday, November 22, 2017", "Lynchburg, VIRGINIA – A former employee of the Internal Revenue Service was sentenced yesterday in the United States District Court for the Western District of Virginia. Ronald Lewis Hooper, 69, of Lynchburg, was sentenced yesterday to 20 months in federal prison to be followed by three years of supervised release.")
        let rh = try #require(ProceedingAnswerer.parse("What was the sentence handed down to Ronald Lewis Hooper?"))
        #expect(try #require(ProceedingAnswerer.answer(rh, sources: [.init(objectID: UUID(), text: hooper)])).body.hasPrefix("Ronald Lewis Hooper was sentenced to 20 months"))
        // A conviction ten years before the release is background, not this case's charge.
        let chester = release("Monday, November 27, 2017", "ROCHESTER, N.Y. - U.S. Attorney James P. Kennedy, Jr. announced today that Shamar R. Chester, 41, of Rochester, NY, pleaded guilty to failing to register as a sex offender before U.S. District Judge Elizabeth A. Wolford. Assistant U.S. Attorney John J. Field, who is handling the case, stated that Chester was convicted in 2007 in Washington, DC, for committing a sex crime involving a child.")
        let sc = try #require(ProceedingAnswerer.parse("What were the charges filed against Shamar R. Chester?"))
        #expect(try #require(ProceedingAnswerer.answer(sc, sources: [.init(objectID: UUID(), text: chester)])).body.contains("failing to register as a sex offender"))
        // A singular lead in a release that introduces co-defendants too: the first-introduced person's.
        let sullivan = release("Thursday, March 10, 2022", "BOISE – An Illinois woman was sentenced to 21 months in federal prison for bank fraud. Abbi L. Sullivan, 25, of Bloomington, Illinois, was sentenced by Senior U.S. District Judge B. Lynn Winmill. Co-defendants Jakara B. Edwards, 24, and Tatyana A. Love, 21, both of Chicago, pleaded guilty on October 19, 2021, to bank fraud.")
        let steps = ProceedingEventExtractor.findings(in: sullivan, person: "Abbi L. Sullivan")
        #expect(steps.contains { $0.step == .sentenced && $0.detail?.hasPrefix("21 months") == true }, "\(steps)")
        #expect(!steps.contains { $0.step == .pleaded }, "the co-defendants' plea is not hers")
        let edwards = ProceedingEventExtractor.findings(in: sullivan, person: "Jakara B. Edwards")
        #expect(edwards.contains { $0.step == .pleaded } && !edwards.contains { $0.step == .sentenced }, "\(edwards)")
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
