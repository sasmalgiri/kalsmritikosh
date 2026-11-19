//
//  P4RoleAndFindingsTests.swift
//  KalsmritikoshTests
//
//  P4 (real-case evaluation 2026-11-03) — fixtures from the quoted failures:
//  A. officials (judge, U.S. Attorney, AUSA, agents, defence counsel) take no proceeding step, the lead is
//     the defendant's, a name listed after "charging" is charged;
//  B. a cloud role reading is used only when its quote verifies (faked by a closure — no network);
//  C. a stated day prints as that day on any host time zone;
//  D. a mailbox is a person's only when it names them in full ("mark.frevert@" is not Mark Haedicke);
//  E. no surname/list/counsel fields, "$1.8 million" is $1,800,000, "no charging document" only when no
//     document charges the person, one plea is not two.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("P4 — roles, dates, email identity, findings hygiene")
struct P4RoleAndFindingsTests {

    // MARK: - Fixtures (text of the real releases, abridged)

    static let supersedingRelease = """
        U.S. Department of Justice
        District of New Jersey
        FOR IMMEDIATE RELEASE
        Monday, April 16, 2018
        Four Men Face Additional Fraud Charges In $1 Million Advance Fee Scheme
        NEWARK, N.J. –Three men from New Jersey and another from Nevada were indicted today on additional charges stemming from their alleged advance-fee scheme that defrauded four victims of over $1 million, U.S. Attorney Craig Carpenito announced.
        James Adkins, 65, of Hillside, New Jersey, Jerrid Douglas, 44, of Freehold, New Jersey, Roy Gillar, 45, of Las Vegas, Nevada, and Harold Mignott, 55, of Voorhees, New Jersey, were originally charged by indictment in December 2017 with one count of conspiracy to commit wire fraud and four counts of wire fraud.
        All four defendants are currently out on bail and will be arraigned at a later date before U.S. District Court Judge John Michael Vazquez in Newark federal court.
        The government is represented by Assistant U.S. Attorney Jason S. Gould of the U.S. Attorney’s Office Criminal Division in Newark.

        Defense counsel:
        Adkins: Kevin Buchan Esq., Holmdel, New Jersey
        Gillar: Thomas Ashley Esq., Newark
        Mignott: Eric Breslin Esq., Newark
        """

    static let convictionRelease = """
        U.S. Department of Justice
        District of New Jersey
        FOR IMMEDIATE RELEASE
        Monday, October 24, 2022
        Three Men Convicted of $1 Million ‘Upfront-Fee’ Scheme
        NEWARK, N.J. – Two men from New Jersey and another from Nevada were convicted by a federal jury for their roles in defrauding multiple victims out of money through a $1 million “upfront-fee” scheme, U.S. Attorney Philip R. Sellinger announced today.
        Following a five-week jury trial before U.S. District Judge John Michael Vazquez in Newark federal court, Jerrid Douglas, 49, of Freehold, New Jersey, Harold Mignott, 60, of Voorhees, New Jersey, and Roy Johannes Gillar, 50, of Las Vegas, were each convicted on Oct. 21, 2022, of wire fraud conspiracy and four counts of wire fraud.
        The government is represented by Assistant U.S. Attorneys Jason S. Gould and Joshua L. Haber of the U.S. Attorney’s Office Criminal Division in Newark.
        """

    static let pleaRelease = """
        U.S. Department of Justice
        Western District of New York
        FOR IMMEDIATE RELEASE
        Thursday, March 20, 2025
        Rapids Theatre owner pleads guilty to defrauding COVID relief programs out of more than $1.8 million
        BUFFALO, N.Y.-U.S. Attorney Michael DiGiacomo announced today that John L. Hutchins, 71, of Lewiston, NY, pleaded guilty before Judge Meredith A. Vacca to conspiracy to commit wire fraud and bank fraud.
        Hutchins and Soliman applied for loans under the following companies, which were owned by Hutchins:
        • Rapids Theatre Niagara Falls, USA, Inc.
        • 1711 Main, LLC
        Charges remain pending against Roberto Soliman.
        The plea is the result of an investigation by the Federal Bureau of Investigation, under the direction of Special Agent-in-Charge Matthew Miraglia.
        """

    static let indictmentRelease2022 = """
        U.S. Department of Justice
        Western District of New York
        FOR IMMEDIATE RELEASE
        Tuesday, March 29, 2022
        Lewiston Man Charged In COVID Fraud
        BUFFALO, N.Y.-U.S. Attorney Trini E. Ross announced today that a federal grand jury has returned an indictment charging John L. Hutchins, 68, of Lewiston, NY, and Roberto Soliman, 39, of Niagara Falls, NY, with conspiracy to commit wire fraud.
        """

    static let arsonCharges = """
        U.S. Department of Justice
        Southern District of West Virginia
        FOR IMMEDIATE RELEASE
        Tuesday, September 3, 2013
        Four Charged In Connection With Logan Arson Investigation
        CHARLESTON, W.Va. - United States Attorney Booth Goodwin announced today that an indictment was unsealed today charging four people in connection with a Logan County arson investigation. A 36-count indictment was unsealed today, charging James Gregory Glick, Guy R. Miller, Shawn C. Simon and William Jamey Thompson with conspiracy to commit arson, conspiracy to commit mail and wire fraud. Glick, 44, of Logan, was also charged with obstruction of justice.
        On the night of February 1, 2012, the indictment alleges that Guy R. Miller, 39, of Logan, co-defendant Shawn C. Simon, 41, of Charleston, and another person worked together to set the fire.
        Assistant United States Attorney Thomas Ryan is in charge of the prosecution.
        """

    static let arsonSentencing = """
        U.S. Department of Justice
        Southern District of West Virginia
        FOR IMMEDIATE RELEASE
        Friday, May 30, 2014
        Three More Sentenced In Logan Arson Scheme
        CHARLESTON, W.Va. – Three more participants in a Logan County arson scheme were sentenced to prison, United States Attorney Booth Goodwin announced today. On Wednesday, Guy R. Miller, Jr., 40, of Logan, was sentenced to six years and three months in prison for his role in the burning. Shawn C. Simon, 41, of Charleston, was sentenced Thursday to a term of 22 months.
        """

    static let thompsonPlea = """
        U.S. Department of Justice
        Southern District of West Virginia
        FOR IMMEDIATE RELEASE
        Thursday, December 12, 2013
        Former Chapmanville Insurance Agent Pleads Guilty To Federal Charges In Connection With Arson Scheme
        CHARLESTON, W.Va. – A former Chapmanville insurance agent pleaded guilty today to federal conspiracy charges, announced U.S. Attorney Booth Goodwin. William Jamey Thompson, 44, entered a guilty plea today to conspiracy to commit mail fraud before United States District Judge Thomas E. Johnston in Charleston.
        On the night of February 1, 2012, Guy Miller, 39, of Logan, along with Shawn C. Simon, 41, of Charleston worked together to set the fire.
        Mr. Glick and co-defendant Guy R. Miller both previously pleaded guilty last month to arson and conspiracy to commit mail and wire fraud.
        """

    static let millerPlea = """
        U.S. Department of Justice
        Southern District of West Virginia
        FOR IMMEDIATE RELEASE
        Wednesday, November 6, 2013
        Logan Men Enter Guilty Pleas In Connection With Arson Scheme
        CHARLESTON, W.Va. – Two men entered guilty pleas in federal court today in connection with a Logan arson scheme, announced U.S. Attorney Booth Goodwin. James Gregory Glick, and co-defendant Guy R. Miller, 39, both pleaded guilty to arson and conspiracy to commit mail and wire fraud.
        """

    static func steps(_ text: String, _ person: String) -> Set<ProceedingEventExtractor.Step> {
        Set(ProceedingEventExtractor.findings(in: text, person: person).map(\.step))
    }

    // MARK: - A. Roles

    @Test("Judge, U.S. Attorney, AUSA, agent and defence counsel are classified as officials, defendants as defendants")
    func rolesFromTheText() {
        typealias R = ProceedingRoleClassifier
        #expect(R.role(of: "John Michael Vazquez", in: Self.convictionRelease) == .judge)
        #expect(R.role(of: "Philip R. Sellinger", in: Self.convictionRelease) == .prosecutor)
        #expect(R.role(of: "Joshua L. Haber", in: Self.convictionRelease) == .prosecutor)
        #expect(R.role(of: "Jason S. Gould", in: Self.supersedingRelease) == .prosecutor)
        #expect(R.role(of: "Thomas Ashley", in: Self.supersedingRelease) == .counsel)
        #expect(R.role(of: "Michael DiGiacomo", in: Self.pleaRelease) == .prosecutor)
        #expect(R.role(of: "Meredith A. Vacca", in: Self.pleaRelease) == .judge)
        #expect(R.role(of: "Matthew Miraglia", in: Self.pleaRelease) == .agent)
        #expect(R.role(of: "Trini E. Ross", in: Self.indictmentRelease2022) == .prosecutor)
        #expect(R.role(of: "Booth Goodwin", in: Self.arsonCharges) == .prosecutor)
        #expect(R.role(of: "Thomas Ryan", in: Self.arsonCharges) == .prosecutor)
        #expect(R.role(of: "Harold Mignott", in: Self.convictionRelease) == .defendant)
        #expect(R.role(of: "John L. Hutchins", in: Self.pleaRelease) == .defendant)
        #expect(R.role(of: "Guy R. Miller", in: Self.arsonCharges) == .defendant)
    }

    @Test("Officials get no proceeding steps; the defendants keep theirs")
    func officialsNeverDefendants() {
        #expect(Self.steps(Self.supersedingRelease, "John Michael Vazquez").isEmpty)        // "John Michael Vazquez charged"
        #expect(Self.steps(Self.convictionRelease, "John Michael Vazquez").isEmpty)         // "Judge John Michael Vazquez convicted"
        #expect(Self.steps(Self.pleaRelease, "Michael DiGiacomo").isEmpty)                  // "Michael DiGiacomo pleaded guilty"
        #expect(Self.steps(Self.pleaRelease, "Meredith A. Vacca").isEmpty)
        #expect(Self.steps(Self.indictmentRelease2022, "Trini E. Ross").isEmpty)            // "Trini E. Ross charged"
        #expect(Self.steps(Self.arsonCharges, "Booth Goodwin").isEmpty)                     // "Booth Goodwin charged"
        #expect(Self.steps(Self.arsonSentencing, "Booth Goodwin").isEmpty)                  // "Booth Goodwin sentenced"
        #expect(Self.steps(Self.supersedingRelease, "Thomas Ashley").isEmpty)
        #expect(Self.steps(Self.convictionRelease, "Harold Mignott").contains(.convicted))
        #expect(Self.steps(Self.pleaRelease, "John L. Hutchins").contains(.pleaded))
        let events = ProceedingEventExtractor.extract(text: Self.convictionRelease, sourceObjectID: UUID(), people: [
            (name: "John Michael Vazquez", entityID: UUID()), (name: "Philip R. Sellinger", entityID: UUID()),
            (name: "Harold Mignott", entityID: UUID()), (name: "Joshua L. Haber", entityID: UUID())])
        #expect(!events.isEmpty && events.allSatisfy { $0.title.hasPrefix("Harold Mignott") }, "\(events.map(\.title))")
        #expect(events.allSatisfy { $0.attributes["proceedingRole"] != nil })
    }

    @Test("The descriptive lead and 'He'/'The defendant' go to the one defendant, not to the judge")
    func leadToDefendant() {
        let text = """
            U.S. Department of Justice
            FOR IMMEDIATE RELEASE
            Friday, June 23, 2023
            Camden Man Sentenced In Scheme
            NEWARK, N.J. – A Camden County man was sentenced today to three years in prison, U.S. Attorney Philip R. Sellinger announced. Harold Mignott, 60, of Voorhees, was convicted at trial. The sentence was imposed by U.S. District Judge John Michael Vazquez, who presided. He was also ordered to pay restitution.
            """
        #expect(Self.steps(text, "Harold Mignott").contains(.sentenced))
        #expect(Self.steps(text, "John Michael Vazquez").isEmpty)
        #expect(Self.steps(text, "Philip R. Sellinger").isEmpty)
    }

    @Test("Every name listed after 'charging' is charged")
    func chargingList() {
        #expect(Self.steps(Self.arsonCharges, "Guy R. Miller").contains(.charged))
        #expect(Self.steps(Self.arsonCharges, "Shawn C. Simon").contains(.charged))
        #expect(Self.steps(Self.arsonCharges, "William Jamey Thompson").contains(.charged))
    }

    // MARK: - B. Cloud role reading

    @Test("A role reading is kept only when its quote is verbatim, names the person in full and states the role")
    func roleReadingVerification() async {
        let doc = UUID()
        let passages = [VerifiedRoleReader.Passage(objectID: doc, text: "Following a five-week jury trial before U.S. District Judge John Michael Vazquez in Newark federal court, Harold Mignott, 60, of Voorhees, was convicted.")]
        let reply = """
            {"roles": [
              {"person": "John Michael Vazquez", "role": "judge", "quote": "before U.S. District Judge John Michael Vazquez in Newark federal court", "passage": 1},
              {"person": "Harold Mignott", "role": "judge", "quote": "Harold Mignott, 60, of Voorhees, was convicted", "passage": 1},
              {"person": "Roy Gillar", "role": "defendant", "quote": "Roy Gillar was convicted", "passage": 1}
            ]}
            """
        let reader = VerifiedRoleReader { _, clearance in
            #expect(clearance?.clearedObjectIDs.contains(doc) == true)
            return reply
        }
        let clearance = CloudSourceClearance(clearedObjectIDs: [doc], deniedCount: 0, checkedAt: Date(), purpose: "test")
        let got = await reader.read(people: ["John Michael Vazquez", "Harold Mignott", "Roy Gillar"], passages: passages, clearance: clearance)
        #expect(got.count == 1)
        #expect(got.first?.person == "John Michael Vazquez" && got.first?.role == .judge && got.first?.provenance == VerifiedRoleReader.provenance)
        // Without a clearance, or for an uncleared document, nothing is sent.
        let never = VerifiedRoleReader { _, _ in Issue.record("sent without clearance"); return reply }
        #expect(await never.read(people: ["John Michael Vazquez"], passages: passages, clearance: nil).isEmpty)
        let other = CloudSourceClearance(clearedObjectIDs: [UUID()], deniedCount: 1, checkedAt: Date(), purpose: "test")
        #expect(await never.read(people: ["John Michael Vazquez"], passages: passages, clearance: other).isEmpty)
    }

    // MARK: - C. Dates on two time zones

    @Test("A stated day is stored at midnight UTC and prints as that day on IST and on Pacific time")
    func datesAnyTimeZone() throws {
        let events = ProceedingEventExtractor.extract(text: Self.convictionRelease, sourceObjectID: UUID(),
                                                      people: [(name: "Harold Mignott", entityID: UUID())])
        let convicted = events.filter { $0.title == "Harold Mignott convicted" }
        #expect(!convicted.isEmpty)
        for zone in ["Asia/Kolkata", "America/Los_Angeles", "UTC"] {
            let tz = try #require(TimeZone(identifier: zone))
            let phrases = Set(convicted.compactMap { HistoryNarrativeRenderer.datePhrase(TemporalValue(start: $0.date, precision: .day, confidence: 1), hostTimeZone: tz) })
            // "were each convicted on Oct. 21, 2022" prints as Oct 21 — never the day before.
            #expect(phrases.contains("On 2022-10-21") && !phrases.contains("On 2022-10-20"), "\(zone): \(phrases)")
        }
        // A ledger written before the fix holds the day at the host's local midnight: still that day.
        for zone in ["Asia/Kolkata", "America/Los_Angeles"] {
            let tz = try #require(TimeZone(identifier: zone))
            var local = Calendar(identifier: .gregorian); local.timeZone = tz
            let legacy = try #require(local.date(from: DateComponents(year: 2023, month: 6, day: 22)))
            #expect(HistoryNarrativeRenderer.datePhrase(TemporalValue(start: legacy, precision: .day, confidence: 1), hostTimeZone: tz) == "On 2023-06-22", "\(zone)")
        }
        #expect(ProceedingAnswerer.render(DateComponents(year: 2023, month: 6, day: 22)) == "June 22, 2023")
    }

    // MARK: - D. Email identity

    @Test("A mailbox is the person's only when its address or display name names them in full")
    func emailIdentity() {
        typealias P = PersonAnswerComposer
        #expect(!P.correspondenceNames("Mark Haedicke", address: "mark.frevert@enron.com", displayName: "Mark Haedicke"))
        #expect(!P.correspondenceNames("Mark Haedicke", address: "mark.frevert@enron.com", displayName: nil))
        #expect(!P.correspondenceNames("Andrew Fastow", address: "andrew.wilson@enron.com", displayName: nil))
        #expect(!P.correspondenceNames("Jeff Mcmahon", address: "jeff.donahue@enron.com", displayName: "Jeff Donahue"))
        #expect(P.correspondenceNames("Mark Haedicke", address: "e..haedicke@enron.com", displayName: nil))
        #expect(P.correspondenceNames("Mark Haedicke", address: "mhaedicke@enron.com", displayName: nil))
        #expect(P.correspondenceNames("Jeff McMahon", address: "jeffrey.mcmahon@enron.com", displayName: nil))
        #expect(P.correspondenceNames("Mark Haedicke", address: "legal@enron.com", displayName: "Haedicke, Mark E."))
        let mark = UUID(), frevert = UUID()
        let rows = [P.Correspondence(address: "mark.frevert@enron.com", displayName: nil, sourceObjectID: frevert, role: "to"),
                    P.Correspondence(address: "mark.frevert@enron.com", displayName: nil, sourceObjectID: UUID(), role: "to"),
                    P.Correspondence(address: "e..haedicke@enron.com", displayName: nil, sourceObjectID: mark, role: "to")]
        let text = P.composeWhoIs(name: "mark haedicke", rows: rows, emailEvents: [])?.primaryText ?? ""
        #expect(text.contains("<e..haedicke@enron.com>") && !text.contains("frevert") && text.contains("appears in 1 email"), "\(text)")
        #expect(P.composeWhoIs(name: "mark haedicke", rows: Array(rows.prefix(2)), emailEvents: []) == nil)
    }

    // MARK: - E. Findings hygiene

    @Test("No surname, list-item or defence-counsel fields; '$1.8 million' is $1,800,000")
    func junkFields() {
        let blocks = Self.supersedingRelease.components(separatedBy: "\n").map { (id: UUID(), text: $0, kind: EvidenceBlockKind.paragraph) }
            + Self.pleaRelease.components(separatedBy: "\n").map { (id: UUID(), text: $0, kind: EvidenceBlockKind.listItem) }
        let facts = OpenFieldExtractor.extractFacts(blocks: blocks, subjectLabel: "release").facts
        let fields = Set(facts.map(\.field))
        #expect(!fields.contains("gillar") && !fields.contains("mignott") && !fields.contains("adkins") && !fields.contains("hutchins"), "\(fields)")
        #expect(OpenFieldExtractor.fields(in: "the F-16 would intercept that course at 1100:56, one second before the collision", kind: .paragraph).isEmpty)
        let amounts = TransactionDomainPack.extractFacts(fromText: "defrauding COVID relief programs out of more than $1.8 million", subjectLabel: "x", blockID: UUID())
            .filter { $0.field == "amount" }.map(\.value)
        #expect(amounts == ["$1,800,000"], "\(amounts)")
    }

    static func selected(_ statement: String, subject: UUID?, label: String, kind: DerivedReference.Kind, day: DateComponents?) -> SelectedClaim {
        let claim = Claim(subjectID: subject, subjectLabel: label, statement: statement,
                          assessment: EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction), confidence: 0.8,
                          evidence: [EvidenceReference(objectID: UUID(), blockID: UUID(), sourceVersionID: UUID())],
                          derivedFrom: [DerivedReference(kind: kind, id: UUID())], scope: subject.map { .entity($0) }, createdAt: Date())
        let anchor = day.flatMap(ProceedingEventExtractor.ledgerDate).map {
            ClaimTemporalAnchor(start: $0, precision: .day, source: DerivedReference(kind: .event, id: UUID()))
        }
        return SelectedClaim(resolved: ResolvedClaim(claim: claim, effectiveAssessment: claim.assessment),
                             temporalAnchor: anchor, selectionReason: .explicitlyRequested)
    }

    @Test("Findings: junk fields dropped; one plea dated twice is one row with a date discrepancy")
    func findingsHygiene() {
        let miller = UUID(), gillar = UUID()
        let claims = [
            Self.selected("Guy R. Miller pleaded guilty", subject: miller, label: "Guy R. Miller", kind: .event, day: DateComponents(year: 2013, month: 11, day: 6)),
            Self.selected("Guy R. Miller pleaded guilty", subject: miller, label: "Guy R. Miller", kind: .event, day: DateComponents(year: 2013, month: 12, day: 12)),
            Self.selected("Roy Johannes Gillar convicted", subject: gillar, label: "Roy Johannes Gillar", kind: .event, day: DateComponents(year: 2022, month: 10, day: 21)),
            Self.selected("gillar: Thomas Ashley Esq., Newark", subject: nil, label: "release", kind: .genericFact, day: nil),
            Self.selected("hutchins: • Rapids Theatre Niagara Falls, USA, Inc.", subject: nil, label: "release", kind: .genericFact, day: nil),
            Self.selected("fax: (716) 551-3051", subject: nil, label: "release", kind: .genericFact, day: nil),
        ]
        let sections = InvestigationFindingsComposer().compose(WorkProductContext(selectedClaims: claims, subjectLabel: "case"))
        let rows = sections.last?.claims.map(\.text) ?? []
        #expect(!rows.contains { $0.contains("gillar:") || $0.contains("hutchins:") }, "\(rows)")
        #expect(rows.contains { $0.contains("fax:") })
        let pleas = rows.filter { $0.contains("Guy R. Miller pleaded guilty") }
        #expect(pleas.count == 1 && pleas[0].hasPrefix("On 2013-11-06") && pleas[0].contains("2013-12-12") && pleas[0].contains("date discrepancy"), "\(pleas)")
        #expect(rows.contains { $0 == "On 2022-10-21 — Roy Johannes Gillar convicted" }, "\(rows)")
    }

    @Test("'No charging document on file' only when no document charges the person")
    func chargingDocumentGap() {
        let texts = [(objectID: UUID(), text: Self.arsonCharges), (objectID: UUID(), text: Self.arsonSentencing)]
        let gaps = GapDetector().detectProceedingGaps(texts: texts).map(\.description)
        #expect(!gaps.contains { $0.contains("Shawn C. Simon: no charging") || $0.contains("Guy R. Miller: no charging") }, "\(gaps)")
        let alone = GapDetector().detectProceedingGaps(texts: [(objectID: UUID(), text: Self.arsonSentencing)]).map(\.description)
        #expect(alone.contains { $0.contains("Shawn C. Simon: no charging document on file") }, "\(alone)")
    }

    @Test("A plea restated 'previously … last month' is not a second plea")
    func noInventedRepeatPlea() throws {
        let parsed = try #require(ProceedingAnswerer.parse("When did Guy R. Miller plead guilty?"))
        let answer = ProceedingAnswerer.answer(parsed, sources: [.init(objectID: UUID(), text: Self.millerPlea), .init(objectID: UUID(), text: Self.thompsonPlea)])
        let body = answer?.body ?? ""
        #expect(!body.contains("and again on") && body.contains("November 6, 2013"), "\(body)")
    }
}
