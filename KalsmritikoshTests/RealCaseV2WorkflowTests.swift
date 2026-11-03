//
//  RealCaseV2WorkflowTests.swift
//  KalsmritikoshTests
//
//  Real-case v2 (2026-11-04, interim review) — the case workflow's defects, each with a small fixture of
//  the quoted shape: false contradictions (the case growing, a fee against a loss, different records,
//  two messages' send dates, an office's holder changing) while real ones stay (Logan's $50k/$75k fee,
//  Simon's role, 22 vs 24 convicted) and a missed one is found ("13 months" vs "a year and a day");
//  leads that name the record type of the subject's domain; drafts without non-persons, other matters or
//  junk; terms bound to their clause; interview plans; gaps over name variants and charging lists; the
//  findings without officials, other matters' people or mis-scaled amounts.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Real-case v2 — case workflow", .serialized)
struct RealCaseV2WorkflowTests {
    typealias F = CaseContradictionFinder
    typealias B = CaseDraftBuilder

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }
    static func doc(_ text: String, _ date: Date? = nil) -> F.Document {
        F.Document(objectID: UUID(), sourceVersionID: UUID(), text: text, fileName: nil, date: date)
    }
    static func batch(_ docs: [F.Document], subject: String? = nil) -> F.Batch {
        F.Batch(subject: subject, passages: docs.map { F.Passage(objectID: $0.objectID, sourceVersionID: $0.sourceVersionID, text: $0.text) })
    }
    static func pair(_ about: String, _ kind: String, _ qa: String, _ qb: String, _ va: String, _ vb: String) -> String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: "\\\"") }
        return #"{"pairs": [{"about": ""# + esc(about) + #"", "kind": ""# + kind + #"", "a": {"passage": 1, "quote": ""# + esc(qa)
            + #""}, "b": {"passage": 2, "quote": ""# + esc(qb) + #""}, "value_a": ""# + esc(va) + #"", "value_b": ""# + esc(vb) + #""}]}"#
    }
    static func verify(_ a: F.Document, _ b: F.Document, _ reply: String, subject: String? = nil) -> F.Verification {
        F.verify(reply: reply, batch: batch([a, b], subject: subject), allDocuments: [a, b])
    }

    // MARK: - 2. Contradictions

    @Test("Rules: a loss rising between an early and a later release is growth; two lower bounds never conflict; a later figure below an earlier one still does")
    func growthAndBounds() {
        let early = "Harold Mignott caused losses of $800,000 to the victim company."
        let late = "Harold Mignott caused losses of $1,000,000 to the victim companies."
        #expect(F.ruleFindings([Self.doc(early, Self.day(2017, 4, 19)), Self.doc(late, Self.day(2018, 4, 16))]).filter { $0.kind == .amount }.isEmpty)
        #expect(F.ruleFindings([Self.doc(late, Self.day(2017, 4, 19)), Self.doc(early, Self.day(2018, 4, 16))]).filter { $0.kind == .amount }.count == 1)
        let over = Self.doc("Mohamed Kamara caused losses of over $500,000 to the programs.")
        let more = Self.doc("Mohamed Kamara caused losses of more than $2 million to the programs.")
        #expect(F.ruleFindings([over, more]).filter { $0.kind == .amount }.isEmpty)
    }

    static let burris4 = """
    BOSTON – A Florida man was sentenced today for his role in a home loan modification scheme.
    Vernell Burris, Jr., 54, of Coconut Creek, Fla., was sentenced today to serve 13 months in prison and ordered to serve two years of supervised release.
    """
    static let burris5 = """
    BOSTON – A Maryland man was sentenced today to serve one year and a day in prison.
    A third co-defendant, Vernell Burris, Jr., 54, of Coconut Creek, Fla, pleaded guilty and was sentenced on Feb. 25, 2014, to serve a year and a day in prison.
    """

    @Test("Rules: '13 months' and 'a year and a day' for one person's sentence are a contradiction; the same length in two wordings is not")
    func sentenceLengths() {
        #expect(F.duration("a year and a day in prison") == F.Duration(months: 12, days: 1))
        #expect(F.duration("13 months in prison") == F.Duration(months: 13, days: 0))
        #expect(F.duration("seven years and three months") == F.Duration(months: 87, days: 0))
        let found = F.ruleFindings([Self.doc(Self.burris4), Self.doc(Self.burris5)]).filter { $0.kind == .term }
        #expect(found.count == 1, "\(found.map(\.description))")
        #expect(found.first?.subject == "Vernell Burris" && found.first?.contradiction().evidenceB != nil)
        let same = F.ruleFindings([Self.doc("Jane K. Roe, 40, of Austin, was sentenced to 12 months in prison."),
                                   Self.doc("Jane K. Roe was sentenced on May 1, 2014, to one year in prison.")])
        #expect(same.filter { $0.kind == .term }.isEmpty)
        // A term is the person's own clause's: Simon's 22 months never becomes Williams's.
        let simon = Self.doc("Shawn C. Simon, 41, of Charleston, drove the getaway car for Miller and Michael D. Williams and was sentenced to 22 months in prison.")
        let williams = Self.doc("Michael D. Williams, 44, of Logan, was sentenced to 32 months in prison.")
        #expect(F.ruleFindings([simon, williams]).filter { $0.kind == .term }.isEmpty)
        // The AI reading's pair of the two lengths verifies as a sentence contradiction.
        let a = Self.doc(Self.burris4), b = Self.doc(Self.burris5)
        let v = Self.verify(a, b, Self.pair("Vernell Burris, Jr.", "count",
                                            "Vernell Burris, Jr., 54, of Coconut Creek, Fla., was sentenced today to serve 13 months in prison",
                                            "pleaded guilty and was sentenced on Feb. 25, 2014, to serve a year and a day in prison", "13 months", "a year and a day"))
        #expect(v.verified.count == 1 && v.verified.first?.kind == .term, "\(v.dropped)")
    }

    @Test("AI: an agreed fee against a loss, and a scheme's total growing between releases, are explained")
    func feeVersusLossAndGrowth() {
        let a = Self.doc("Adkins and Douglas allegedly defrauded an entity identified in the superseding indictment as “Victim Company B” out of approximately $250,000 in 2015. Victim Company B agreed to pay Adkins and Douglas $1 million for the bank fee associated with the standby letter of credit.", Self.day(2018, 4, 16))
        let b = Self.doc("Victim Company B agreed to pay Adkins and Douglas $1 million for the bank fee associated with the standby letter of credit. Jerrid Douglas was named.", Self.day(2018, 4, 17))
        let fee = Self.verify(a, b, Self.pair("Jerrid Douglas", "amount", "defrauded an entity identified in the superseding indictment as “Victim Company B” out of approximately $250,000",
                                              "Victim Company B agreed to pay Adkins and Douglas $1 million for the bank fee", "approximately $250,000", "$1 million"))
        #expect(fee.verified.isEmpty && fee.dropped.first?.contains("different amounts") == true, "\(fee.dropped)")
        let h1 = Self.doc("Four Men Charged In $800,000 Advance Fee Scheme. Harold Mignott, 54, of Voorhees was charged.", Self.day(2017, 4, 19))
        let h2 = Self.doc("Four Men Face Additional Fraud Charges In $1 Million Advance Fee Scheme. Harold Mignott, 55, of Voorhees was indicted.", Self.day(2018, 4, 16))
        let growth = Self.verify(h2, h1, Self.pair("Million Advance Fee Scheme", "amount", "Four Men Face Additional Fraud Charges In $1 Million Advance Fee Scheme",
                                                   "Four Men Charged In $800,000 Advance Fee Scheme", "$1 Million", "$800,000"))
        #expect(growth.verified.isEmpty && growth.dropped.first?.contains("grew") == true, "\(growth.dropped)")
        let k1 = Self.doc("Kamara and his conspirators fraudulent EIDL applications caused the SBA to provide more than $750,000 in EIDLs.")
        let k2 = Self.doc("The state approved and transferred more than $1 million, including funds to an account Kamara controlled.")
        let bounds = Self.verify(k1, k2, Self.pair("Mohamed Kamara", "amount", "caused the SBA to provide more than $750,000 in EIDLs",
                                                   "The state approved and transferred more than $1 million", "more than $750,000", "more than $1 million"))
        #expect(bounds.verified.isEmpty, "\(bounds.dropped)")
    }

    @Test("AI: Logan's $50,000 vs $75,000 to the same agent stays (an earlier, higher payment is no growth)")
    func loganFeeStays() {
        let a = Self.doc("Mr. Glick then paid co-defendant William Jamey Thompson, 44, an independent insurance agent from Chapmanville, approximately $75,000 to obtain a fraudulently-inflated $1 million insurance policy.", Self.day(2013, 9, 3))
        let b = Self.doc("Mr. Glick then paid William Jamey Thompson approximately $50,000 to obtain a fraudulently-inflated $1 million insurance policy.", Self.day(2013, 12, 12))
        let v = Self.verify(a, b, Self.pair("William Jamey Thompson", "amount", "paid co-defendant William Jamey Thompson, 44, an independent insurance agent from Chapmanville, approximately $75,000",
                                            "Mr. Glick then paid William Jamey Thompson approximately $50,000", "approximately $75,000", "approximately $50,000"),
                            subject: "William Jamey Thompson")
        #expect(v.verified.count == 1, "\(v.dropped)")
    }

    @Test("AI: counts of different records, of different things, and growing counts are explained; 22 vs 24 convicted stays")
    func counts() {
        let e1 = Self.doc("FDA Enforcement Report\n recall event 70738\nBlue Bell Creameries, L.P.\n 286 product record(s)\nEvent ID: 70738")
        let e2 = Self.doc("FDA Enforcement Report\n recall event 74032\nBlue Bell Creameries, L.P.\n 1 product record(s)\nEvent ID: 74032")
        let records = Self.verify(e1, e2, Self.pair("Blue Bell Creameries", "count", "Blue Bell Creameries, L.P. 286 product record(s)", "Blue Bell Creameries, L.P. 1 product record(s)", "286", "1"))
        #expect(records.verified.isEmpty && records.dropped.first?.contains("different records") == true, "\(records.dropped)")
        let c22 = Self.doc("The Vendstar investigation began in 2010 and resulted in criminal charges filed against 22 individuals in 2012 and 2013.", Self.day(2017, 1, 6))
        let c24 = Self.doc("He is one of 24 defendants who have been convicted of fraud in connection with Multivend LLC d/b/a/ Vendstar.", Self.day(2017, 2, 2))
        let kinds = Self.verify(c22, c24, Self.pair("Vendstar", "count", "resulted in criminal charges filed against 22 individuals in 2012 and 2013",
                                                    "He is one of 24 defendants who have been convicted of fraud", "22 individuals", "24 defendants"))
        #expect(kinds.verified.isEmpty && kinds.dropped.first?.contains("different counts") == true, "\(kinds.dropped)")
        let v22 = Self.doc("He is one of 22 defendants who have been convicted of fraud in connection with Multivend LLC d/b/ a/ Vendstar.", Self.day(2017, 3, 23))
        let real = Self.verify(v22, c24, Self.pair("Vendstar", "count", "He is one of 22 defendants who have been convicted of fraud",
                                                   "He is one of 24 defendants who have been convicted of fraud", "22 defendants", "24 defendants"))
        #expect(real.verified.count == 1, "\(real.dropped)")
        let two = Self.doc("Three men have been arrested for allegedly defrauding two individual victims out of approximately $800,000 through the Vendstar scheme.", Self.day(2017, 4, 19))
        let four = Self.doc("Three men were indicted today on additional charges stemming from the Vendstar scheme that defrauded four victims of over $1 million.", Self.day(2018, 4, 16))
        let grew = Self.verify(four, two, Self.pair("the Vendstar scheme", "count", "indicted today on additional charges stemming from the Vendstar scheme that defrauded four victims",
                                                    "defrauding two individual victims out of approximately $800,000 through the Vendstar scheme", "four victims", "two individual victims"))
        #expect(grew.verified.isEmpty && grew.dropped.first?.contains("grew") == true, "\(grew.dropped)")
    }

    @Test("AI: two messages' send dates, a scheduled date and an office's holder are explained; Simon's role stays")
    func datesOfficesRoles() {
        let m1 = Self.doc("Date: Fri, 9 Nov 2001 15:56:33 -0800 (PST)\nX-From: Ken Lay - Office of the Chairman\nSubject: Update")
        let m2 = Self.doc("Date: Thu, 8 Nov 2001 15:35:50 -0800 (PST)\nX-From: Ken Lay - Office of the Chairman\nSubject: Merger")
        let sent = Self.verify(m1, m2, Self.pair("Ken Lay", "date", "Date: Fri, 9 Nov 2001 15:56:33 -0800 (PST)", "Date: Thu, 8 Nov 2001 15:35:50 -0800 (PST)",
                                                 "Fri, 9 Nov 2001", "Thu, 8 Nov 2001"))
        #expect(sent.verified.isEmpty && sent.dropped.first?.contains("send dates") == true, "\(sent.dropped)")
        let s1 = Self.doc("Guy Miller faces a minimum of seven years in prison when he is sentenced on February 19, 2014.")
        let s2 = Self.doc("Guy Miller is set to be sentenced on May 28, 2014.")
        let scheduled = Self.verify(s1, s2, Self.pair("Guy Miller", "date", "Guy Miller faces a minimum of seven years in prison when he is sentenced on February 19, 2014.",
                                                      "Guy Miller is set to be sentenced on May 28, 2014.", "February 19, 2014", "May 28, 2014"))
        #expect(scheduled.verified.isEmpty, "\(scheduled.dropped)")
        let o1 = Self.doc("Sellinger credited special agents of the FBI, under the direction of Special Agent in Charge James E. Dennehy in Newark.")
        let o2 = Self.doc("Fishman credited special agents of the FBI, under the direction of Special Agent in Charge George M. Crouch Jr., in Newark.")
        let office = Self.verify(o1, o2, Self.pair("the FBI Special Agent in Charge in Newark", "role", "under the direction of Special Agent in Charge James E. Dennehy in Newark",
                                                   "under the direction of Special Agent in Charge George M. Crouch Jr., in Newark", "James E. Dennehy", "George M. Crouch Jr."))
        #expect(office.verified.isEmpty && office.dropped.first?.contains("office") == true, "\(office.dropped)")
        let r1 = Self.doc("Shawn C. Simon, 41, of Charleston and Michael Williams, 44, of Logan, worked together to set the fire to the building by spreading gasoline throughout the main floor.")
        let r2 = Self.doc("Shawn C. Simon, 41, of Charleston, drove the getaway car for Miller and Williams.")
        let role = Self.verify(r1, r2, Self.pair("Shawn C. Simon", "role", "Shawn C. Simon, 41, of Charleston and Michael Williams, 44, of Logan, worked together to set the fire to the building by spreading gasoline throughout the main floor",
                                                 "Shawn C. Simon, 41, of Charleston, drove the getaway car for Miller and Williams", "spreading gasoline throughout the main floor", "drove the getaway car"))
        #expect(role.verified.count == 1, "\(role.dropped)")
    }

    @Test("Leads name the record type of the subject's domain: no charging document for a recall, no court docket for e-mails")
    func leadRecords() {
        let recall = Contradiction(kind: .other, description: "Count — Blue Bell Creameries: 286 vs 1. (case check · AI reading, both quotes checked)",
                                   claimA: "Blue Bell Creameries, L.P. 286 product record(s)", claimB: "Blue Bell Creameries, L.P. 1 product record(s)",
                                   evidenceA: UUID(), evidenceB: UUID(), severity: .medium, detectedAt: Date())
        let mail = Contradiction(kind: .date, description: "Date — Ken Lay: Fri, 9 Nov 2001 vs Thu, 8 Nov 2001. (case check · AI reading, both quotes checked)",
                                 claimA: "Date: Fri, 9 Nov 2001 15:56:33 -0800 (PST)", claimB: "Date: Thu, 8 Nov 2001 15:35:50 -0800 (PST)",
                                 evidenceA: UUID(), evidenceB: UUID(), severity: .medium, detectedAt: Date())
        let leads = B.leads([], cast: [], contradictions: [recall, mail])
        let r = leads.first { $0.notEstablished.contains("Blue Bell") }?.records ?? ""
        let m = leads.first { $0.notEstablished.contains("Ken Lay") }?.records ?? ""
        #expect(!r.isEmpty && !r.contains("charging") && r.contains("recall"), "\(r)")
        #expect(!m.isEmpty && !m.contains("docket") && m.contains("messages"), "\(m)")
        #expect(B.records(forContradiction: "Count", quotes: ["24 defendants who have been convicted of fraud"]).contains("charging document"))
    }

    // MARK: - 3. Drafts

    @Test("Cast: capitalised runs no sentence treats as a person are left out; a title read into a name is removed")
    func castNonPersons() {
        let a = Self.doc("""
        The Avoid Concept applies to pilots. The Daily Update was sent. The Launch Date moved again.
        The government is represented by Assistant U.S. Attorneys Jason S. Gould and Joshua L. Haber.
        Harold Mignott, 54, of Voorhees, was charged by complaint.
        """)
        let b = Self.doc("""
        The Avoid Concept is described in the manual. The Daily Update listed trades. The Launch Date is in May.
        Assistant U.S. Attorneys Jason S. Gould prosecuted the case. Mignott pleaded guilty.
        """)
        let names = B.cast([a, b]).map(\.name)
        #expect(!names.contains { ["Avoid Concept", "Daily Update", "Launch Date"].contains($0) }, "\(names)")
        #expect(names.contains("Jason S. Gould") && !names.contains { $0.hasPrefix("Attorneys") }, "\(names)")
        #expect(names.contains("Harold Mignott"))
    }

    static let kamaraPlea = """
    NEWARK, N.J. – Mohamed Kamara, 42, of Greenbelt, Maryland, pleaded guilty on March 29, 2023, to wire fraud.
    """
    static let kamaraSentence = """
    NEWARK, N.J. – Mohamed Kamara, 43, of Greenbelt, Maryland, was sentenced on December 14, 2023, to 41 months in prison.
    """
    static let kamaraComplaint = """
    NEWARK, N.J. – Mohamed Kamara, 40, of Greenbelt, Maryland, was charged by complaint on June 16, 2021, with wire fraud.
    """
    static let crash = """
    WASHINGTON – Nakita Walker, 45, of Washington, D.C., was found guilty on April 6, 2026, in the March 15, 2023, vehicular deaths of Mohamed Kamara, Jonathan Alberto Cabrera Mendez and Olvin Josue.
    """
    static let sweep = """
    WASHINGTON – On November 13, 2012, the Department of Justice filed a criminal information charging Regina Rush, 51, of Houston, in connection with the Lauren Jewelry Collection.
    """

    @Test("Drafts: another matter's people (a sweep release, a crash victim of the subject's name) stay out of the chronology and the leads")
    func otherMatters() {
        let docs = [Self.kamaraComplaint, Self.kamaraPlea, Self.kamaraSentence, Self.crash, Self.sweep].map { Self.doc($0) }
        let cast = B.cast(docs)
        let byName = Dictionary(cast.map { ($0.name, $0) }, uniquingKeysWith: { x, _ in x })
        #expect(byName["Mohamed Kamara"]?.group == .defendants, "\(cast.map { "\($0.name)=\($0.group)" })")
        #expect(byName["Nakita Walker"]?.group == .otherMatters && byName["Regina Rush"]?.group == .otherMatters, "\(cast.map { "\($0.name)=\($0.group)" })")
        let s = B.subjects(docs, defendants: ["Mohamed Kamara", "Nakita Walker", "Regina Rush"])
        #expect(s.isSubject("Mohamed Kamara") && s.isOtherMatter("Nakita Walker") && s.documents["mohamed kamara"] == [0, 1, 2], "\(s)")
        let timeline = B.timeline(docs, cast: cast)
        #expect(timeline.allSatisfy { $0.who == "Mohamed Kamara" && $0.objectID != docs[3].objectID }, "\(timeline.map(\.what))")
        #expect(timeline.count == 3)
        let leads = B.leads(docs, cast: cast, contradictions: [])
        #expect(!leads.contains { $0.notEstablished.contains("Walker") || $0.notEstablished.contains("Rush") }, "\(leads.map(\.notEstablished))")
        // The AI reading's event from the crash release is not the case's.
        let batch = B.Batch(passages: [B.Passage(objectID: docs[3].objectID, sourceVersionID: docs[3].sourceVersionID, text: docs[3].text)])
        let reply = #"{"events": [{"date": "2023-03-15", "what": "Vehicular deaths of Mohamed Kamara, Jonathan Alberto Cabrera Mendez and Olvin Josue", "who": "", "quote": "in the March 15, 2023, vehicular deaths of Mohamed Kamara", "passage": 1}], "gaps": []}"#
        let v = B.verifyTimeline(reply: reply, batch: batch, documents: docs, cast: cast)
        #expect(v.items.isEmpty && v.dropped.contains { $0.contains("another matter") }, "\(v.dropped)")
        #expect(B.interviewPeople(cast) == ["Mohamed Kamara"])
    }

    @Test("Drafts: an item years older than its document about none of the case's people is junk")
    func junkItem() {
        let d = Self.doc("From: iam@michaelberry.com\nDate: Mon, 29 Oct 2001 20:48:33 -0800 (PST)\nSubject: campaign\nPublished: May 24, 1996\nA favorite dish of the week.", Self.day(2001, 10, 29))
        let batch = B.Batch(passages: [B.Passage(objectID: d.objectID, sourceVersionID: d.sourceVersionID, text: d.text)])
        let reply = #"{"events": [{"date": "1996-05-24", "what": "Item published", "who": "", "quote": "Published: May 24, 1996", "passage": 1}], "gaps": []}"#
        let v = B.verifyTimeline(reply: reply, batch: batch, documents: [d], cast: [])
        #expect(v.items.isEmpty && v.dropped.contains { $0.contains("years before") }, "\(v.dropped)")
    }

    @Test("Rules chronology: Simon's 22 months is not given to Miller or Williams")
    func termsBoundInChronology() {
        let d = Self.doc("""
        FOR IMMEDIATE RELEASE
        Friday, May 30, 2014
        Guy R. Miller, 40, of Logan, was sentenced on May 28, 2014, to six years and three months in prison.
        Michael D. Williams, 44, of Logan, was sentenced on May 29, 2014, to 32 months in prison.
        Shawn C. Simon, 41, of Charleston, drove the getaway car for Miller and Williams and was sentenced on May 29, 2014, to 22 months in prison for destroying the digital video recorder.
        """)
        let t = B.timeline([d], cast: B.cast([d]))
        let shown = t.map(\.what)
        #expect(!t.contains { ($0.who == "Guy R. Miller" || $0.who == "Michael D. Williams") && $0.what.contains("22 months") }, "\(shown)")
        #expect(t.contains { $0.who == "Shawn C. Simon" && $0.what.contains("22 months") }, "\(shown)")
    }

    // MARK: - 4. Gaps

    @Test("Gaps: name variants are one person; an information filed 'involving Williams' and an indictment's defendant list are charging documents")
    func gaps() {
        let release3 = (objectID: UUID(), text: """
        Michael Williams, 44, of Logan, is cooperating. An information has been filed in the case involving Williams, but a plea hearing has not yet been scheduled.
        """)
        let release5 = (objectID: UUID(), text: """
        Michael D. Williams, 44, of Logan, was sentenced today to 32 months in prison after pleading guilty.
        """)
        let g = GapDetector().detectProceedingGaps(texts: [release3, release5]).map(\.description)
        #expect(!g.contains { $0.contains("no charging document") }, "\(g)")
        #expect(Set(g.compactMap { $0.components(separatedBy: ":").first }).count <= 1, "\(g)")
        let alone = GapDetector().detectProceedingGaps(texts: [release5]).map(\.description)
        #expect(alone.filter { $0.contains("no charging document") }.count == 1, "\(alone)")
        let indictment = (objectID: UUID(), text: """
        Ten Individuals Indicted in National Business Opportunity Fraud Scam
        The Justice Department announced today the unsealing of an indictment charging 10 individuals.
        Named as defendants in the indictment were:
        Lawrence A. Kaplan, 54, of Brooklyn, N.Y., the technical support manager for Vendstar.
        Scott M. Doumas, 40, of East Setauket, N.Y., a salesman and sales manager at Vendstar.
        """)
        let sentencing = (objectID: UUID(), text: "Lawrence A. Kaplan, 58, of Brooklyn, New York, was sentenced to serve 54 months in prison. Kaplan was convicted of conspiracy.")
        let v = GapDetector().detectProceedingGaps(texts: [indictment, sentencing]).map(\.description)
        #expect(!v.contains { $0.contains("Kaplan: no charging") }, "\(v)")
    }

    // MARK: - 5. Findings

    static let hopeRelease = """
    Two Florida men were sentenced today to serve 84 months in prison for defrauding thousands of homeowners in a
    $4 million nationwide home loan modification scheme.
    Acting Assistant Attorney General Mythili Raman of the Justice Department’s Criminal Division, U.S. Attorney
    Carmen M. Ortiz of the District of Massachusetts and Special Inspector General for the Troubled Asset Relief
    Program (SIGTARP) Christy Romero made the announcement.
    Christopher S. Godfrey, 44, of Delray Beach, Fla., and Dennis Fischer, 42, of Highland Beach, Fla., were
    sentenced by U.S. District Court Judge Rya W. Zobel of the District of Massachusetts.
    """

    @Test("Findings: a SIGTARP inspector general and a titled judge take no step; the announcement's officials are officials")
    func officials() {
        #expect(ProceedingRoleClassifier.role(of: "Christy Romero", in: Self.hopeRelease)?.isOfficial == true)
        #expect(ProceedingEventExtractor.findings(in: Self.hopeRelease, person: "Christy Romero").isEmpty)
        #expect(ProceedingRoleClassifier.role(of: "Judge John Michael Vazquez", in: "Following a trial before U.S. District Judge John Michael Vazquez, Jerrid Douglas, 49, was convicted.") == .judge)
        #expect(ProceedingRoleClassifier.role(of: "Mohamed Kamara", in: Self.crash) == .victim)
        #expect(ProceedingRoleClassifier.role(of: "Christopher S. Godfrey", in: Self.hopeRelease) == .defendant)
    }

    @Test("Findings: a titled official's step and another matter's steps leave the report; the case's own stay")
    func findingsRows() {
        typealias P = P4RoleAndFindingsTests
        let kamara = UUID(), walker = UUID(), judge = UUID()
        func step(_ s: String, _ subject: UUID, _ label: String, _ object: UUID) -> SelectedClaim {
            let base = P.selected(s, subject: subject, label: label, kind: .event, day: DateComponents(year: 2023, month: 3, day: 29))
            let c = base.resolved.claim
            let claim = Claim(subjectID: c.subjectID, subjectLabel: c.subjectLabel, statement: c.statement, assessment: c.assessment,
                              confidence: c.confidence, evidence: [EvidenceReference(objectID: object, blockID: UUID(), sourceVersionID: UUID())],
                              derivedFrom: c.derivedFrom, scope: c.scope, createdAt: c.createdAt)
            return SelectedClaim(resolved: ResolvedClaim(claim: claim, effectiveAssessment: claim.assessment),
                                 temporalAnchor: base.temporalAnchor, selectionReason: .explicitlyRequested)
        }
        let d = (0..<4).map { _ in UUID() }
        let claims = [
            step("Mohamed Kamara charged", kamara, "Mohamed Kamara", d[0]),
            step("Mohamed Kamara pleaded guilty", kamara, "Mohamed Kamara", d[1]),
            step("Mohamed Kamara sentenced", kamara, "Mohamed Kamara", d[2]),
            step("Nakita Walker convicted", walker, "Nakita Walker", d[3]),
            step("Judge John Michael Vazquez convicted", judge, "Judge John Michael Vazquez", d[1]),
        ]
        let rows = InvestigationFindingsComposer().compose(WorkProductContext(selectedClaims: claims, subjectLabel: "case")).last?.claims.map(\.text) ?? []
        #expect(rows.filter { $0.contains("Mohamed Kamara") }.count == 3, "\(rows)")
        #expect(!rows.contains { $0.contains("Walker") || $0.contains("Vazquez") }, "\(rows)")
    }

    @Test("Findings: '$10 to $12 million' is $10,000,000, not '$10'")
    func rangeScale() {
        let amounts = TransactionDomainPack.extractFacts(fromText: "Before closing in July 2010, Vendstar made approximately $10 to $12 million in sales per year.",
                                                         subjectLabel: "x", blockID: UUID()).filter { $0.field == "amount" }.map(\.value)
        #expect(amounts == ["$10,000,000"], "\(amounts)")
        let plain = TransactionDomainPack.extractFacts(fromText: "He paid $10 to the clerk and $12 million later.", subjectLabel: "x", blockID: UUID())
            .filter { $0.field == "amount" }.map(\.value)
        #expect(plain == ["$10"], "\(plain)")
    }
}
