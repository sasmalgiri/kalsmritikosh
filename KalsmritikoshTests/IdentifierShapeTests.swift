//
//  IdentifierShapeTests.swift
//  KalsmritikoshTests
//
//  The case bench findings of 2026-10-18 (docs/CASE_BENCH_PLAN.md), pinned: agency case
//  numbers are references, a title carrying one is not a field, and an undeclared field's
//  name implies its value's shape — without turning look-alike words into identifiers.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Identifier shape — case numbers, titles and field names")
struct IdentifierShapeTests {

    @Test("Interleaved agency codes are references; names with a few digits are not",
          arguments: [("MIA08MA051", true), ("ZZZ99ZZ999", true), ("SEA08LA057", true), ("B737MAX", true),
                      ("COVID-19", false), ("MP3-320", false), ("iPhone15Pro", false), ("x86", false),
                      ("2ndhalf", false), ("EPOC", false)])
    func interleaved(token: String, expected: Bool) {
        #expect(IdentifierShape.isInterleavedReference(token) == expected, "\(token)")
    }

    @Test("A field's name implies identifier or date shape",
          arguments: [("inspectionnumbers", FactSchemaRegistry.ValueShape.identifier), ("docketno", .identifier),
                      ("rollno", .identifier), ("containerid", .identifier), ("policynumber", .identifier),
                      ("registration", .identifier), ("eventdate", .date), ("dateandtime", .date),
                      ("datereceived", .date), ("issuedates", .date)])
    func impliedShapes(field: String, expected: FactSchemaRegistry.ValueShape) {
        #expect(IdentifierShape.shape(impliedByFieldName: field) == expected, "\(field)")
        #expect(FactSchemaRegistry.expectedShape(of: field) == expected, "\(field)")
    }

    @Test("Look-alike names stay text",
          arguments: ["candidate", "mandate", "lastupdate", "casino", "piano", "invalid", "liquid",
                      "paid", "keywords", "injuries", "employee1", "location", "event"])
    func lookalikesStayText(field: String) {
        #expect(IdentifierShape.shape(impliedByFieldName: field) == nil, "\(field)")
    }

    @Test("Declared fields keep their declared shape")
    func declaredWins() {
        #expect(FactSchemaRegistry.expectedShape(of: "amount") == .money)
        #expect(FactSchemaRegistry.expectedShape(of: "employer") == .text)
        #expect(FactSchemaRegistry.expectedShape(of: "patentnumber") == .identifier)
    }

    @Test("A title carrying a case number is not a field; real labels still are")
    func titlesAreNotLabels() {
        let text = """
        NTSB SEA08LA057 — factual narrative
        OSHA accident 200072106 — injured employees
        Inspection number(s): 306505215
        Container ID — MSCU4416782
        Line 2 Address: 12 Main St
        """
        let fields = OpenFieldExtractor.fields(in: text, kind: .tableRow).map(\.fieldID)
        #expect(!fields.contains { $0.contains("sea08la057") || $0.contains("200072106") }, "\(fields)")
        #expect(fields.contains("inspectionnumbers"), "\(fields)")
        #expect(fields.contains("containerid"), "\(fields)")
        // A label with a small number is still a label; one carrying a reference is a title.
        #expect(OpenFieldExtractor.isLabelLike("Schedule 1040 Total"))
        #expect(OpenFieldExtractor.isLabelLike("Line 2 Address"))
        #expect(!OpenFieldExtractor.isLabelLike("NTSB SEA08LA057"))
        #expect(!OpenFieldExtractor.isLabelLike("OSHA accident 200072106"))
    }
}

@Suite("Legal pack — US court captions")
struct LegalCaseUSCaptionTests {

    private let caption = """
    UNITED STATES v. SOUTHERN RY. CO.
    (District Court, D. Tennessee.
    August 8, 1924.)
    No. 173.
    Action by the United States, plaintiff, against the defendant railway.
    """

    @Test("Caption docket line and caption date become case number and decision date")
    func captionFacts() {
        let facts = LegalCaseDomainPack.extractFacts(fromText: caption, subjectLabel: "case", blockID: UUID())
        #expect(facts.contains { $0.field.lowercased() == "decisiondate" && $0.value == "1924-08-08" }, "\(facts.map { "\($0.field)=\($0.value)" })")
        #expect(facts.contains { $0.field.lowercased() == "casenumber" && $0.value == "173" })
    }

    @Test("Appellate captions: Decided line and docket number")
    func appellate() {
        let text = """
        SWEET HOME CHAPTER OF COMMUNITIES FOR A GREAT OREGON, et al., Appellants,
        v. Bruce BABBITT, Secretary of the Interior, et al., Appellees.
        No. 92-5255.
        Argued March 10, 1993.
        Decided July 23, 1993.
        """
        let facts = LegalCaseDomainPack.extractFacts(fromText: text, subjectLabel: "case", blockID: UUID())
        #expect(facts.contains { $0.field.lowercased() == "casenumber" && $0.value == "92-5255" }, "\(facts.map { "\($0.field)=\($0.value)" })")
        #expect(facts.contains { $0.field.lowercased() == "decisiondate" && $0.value == "1993-07-23" })
    }

    @Test("A numbered clause in prose is not a docket number")
    func proseNumberIgnored() {
        #expect(LegalCaseDomainPack.captionDocketNumber(in: "See No. 5 of the agreement, which the plaintiff signed.") == nil)
        #expect(LegalCaseDomainPack.captionDateLine(in: "The defendant was served on August 8, 1924, at home.") == nil)
    }
}

@Suite("Legal pack — docket numbers in flowing text")
struct LegalFlowingDocketTests {
    @Test("Normalized captions still yield the docket", arguments: [
        ("SWEET HOME CHAPTER, Appellants, v. Bruce BABBITT, Appellees. No. 92-5255. Argued March 10, 1993.", "92-5255"),
        ("EEOC v. Autozone Stores, No. 3:06-cv-00862 (M.D. Fla.), plaintiff", "3:06-cv-00862"),
        ("United States Court of Appeals, Second Circuit. No. 1497, Docket 93-1070. Argued March 1993.", "93-1070"),
    ])
    func flowing(text: String, expected: String) {
        #expect(LegalCaseDomainPack.flowingDocketNumber(in: text) == expected)
    }

    @Test("A numbered clause is not a docket")
    func clause() {
        #expect(LegalCaseDomainPack.flowingDocketNumber(in: "See No. 5 of the agreement signed by the plaintiff.") == nil)
        #expect(LegalCaseDomainPack.flowingDocketNumber(in: "The court read No. 12 of the exhibits. 1. Contracts — held binding.") == nil)
    }

    // Case bench 2026-10-20: state reporters and older F.2d volumes number a case plainly, next
    // to the court, and print the decision date with no label.
    static let plainCaptions: [(String, String, String)] = [
        ("WEISMAN v. UNITED STATES (Circuit Court of Appeals, Eighth Circuit. August 28, 1924.) No. 6602. 1. Indictment and information — Must state directly every essential element.", "6602", "1924-08-28"),
        ("UNITED ACCOUNTS, INCORPORATED, Plaintiff and Appellant, v. George DACHTLER, Defendant and Respondent. No. 7861. Supreme Court of North Dakota. Dec. 16, 1959. Joseph Coghlan, Bismarck, for plaintiff.", "7861", "1959-12-16"),
        ("STATE of Indiana, Appellant, v. Joseph H. NIXON, Appellee. No. 378S44. Supreme Court of Indiana. Jan. 5, 1979. Theodore L. Sendak, Atty. Gen.", "378S44", "1979-01-05"),
        ("SOVEREIGN CAMP W. O. W. v. BODEN. (No. 4781.) Special Supreme Court of Texas. Dec. 16, 1927. 1. Statutes — Law's province.", "4781", "1927-12-16"),
        ("[Civ. No. 33558. Second Dist., Div. Five. Nov. 18, 1969.] STATE COMPENSATION INSURANCE FUND, Petitioner, v. WORKMEN'S COMPENSATION APPEALS BOARD, Respondents.", "Civ. No. 33558", "1969-11-18"),
        ("LAWSON et al. v. GLOVER et al. No. 279. District Court, S. D. Texas, Corpus Christi Division. Nov. 15, 1932. Perkins & Floyd, of Alice, Tex., for plaintiffs.", "279", "1932-11-15"),
        ("UNITED STATES v. FOSTER et al. Civ. A. No. 9870. United States District Court W. D. Pennsylvania. Oct. 24, 1952. Albert C. Osofsky, for plaintiff.", "Civ. A. No. 9870", "1952-10-24"),
        ("FISCHER & PORTER CO. v. BROOKS ROTAMETER CO. Civ. A. 8710. United States District Court E. D. Pennsylvania. Sept. 8, 1952. Leonard L. Kalish, for plaintiff.", "Civ. A. 8710", "1952-09-08"),
        ("In re KEHL. Patent Appeals No. 4043. Court of Customs and Patent Appeals. Jan. 23, 1939. Charles C. Scheffler, of New York City.", "Patent Appeals No. 4043", "1939-01-23"),
        ("SAUNDERS v. COMMISSIONER OF INTERNAL REVENUE and three other cases. Nos. 1658, 1662-1664. Circuit Court of Appeals, Tenth Circuit. Jan. 9, 1939. A. W. McHendrie, of Trinidad.", "1658, 1662-1664", "1939-01-09"),
    ]

    @Test("The court's initials do not end the court's name before the date")
    func initialsInCourt() {
        #expect(LegalCaseDomainPack.courtLineDate(in: "UNITED STATES v. MORGAN et al. District Court, E. D. Illinois. March 13, 1935. Paul F. Jones, U. S. Atty.") == "March 13, 1935")
        #expect(LegalCaseDomainPack.courtLineDate(in: "The Court held a hearing. On March 13, 1935, the defendant appeared.") == nil)
    }

    @Test("Plain docket and unlabeled date beside the court", arguments: plainCaptions)
    func plain(text: String, docket: String, date: String) {
        let facts = LegalCaseDomainPack.extractFacts(fromText: text, subjectLabel: "case", blockID: UUID())
        let shown = facts.map { "\($0.field)=\($0.value)" }
        #expect(facts.contains { $0.field.lowercased() == "casenumber" && $0.value == docket }, "\(shown)")
        #expect(facts.contains { $0.field.lowercased() == "decisiondate" && $0.value == date }, "\(shown)")
    }
}

@Suite("Legal pack — US court names and dispositions")
struct LegalCourtAndDispositionTests {
    @Test("Caption court names", arguments: [
        ("SWEET HOME, Appellants, v. BABBITT, Appellees. United States Court of Appeals, District of Columbia Circuit. Argued March 10, 1993.", "United States Court of Appeals, District of Columbia Circuit"),
        ("UNITED STATES v. SOUTHERN RY. CO. (District Court, D. Tennessee. August 8, 1924.)", "District Court, D. Tennessee"),
    ])
    func court(text: String, expected: String) {
        #expect(LegalCaseDomainPack.captionCourtName(in: text) == expected)
    }

    @Test("Closing dispositions", arguments: [
        ("For the foregoing reasons the judgment is reversed. Reversed and remanded.", "reversed and remanded"),
        ("We find no error. Affirmed.", "affirmed"),
        ("The district court did not err. The judgment of the district court is AFFIRMED.", "affirmed"),
        ("AFFIRMED in part, REVERSED in part.", "affirmed in part, reversed in part"),
        ("We find no error. Affirmed. SMITH, Circuit Judge, dissenting: I would reverse the conviction.", "affirmed"),
        ("For these reasons we see no error. The order and judgment of the district court are affirmed.", "affirmed"),
        // Case bench: normalized text joins the heading to the sentence after it.
        ("dismiss plaintiffs’ claims. CONCLUSION The order and judgment of the district court are affirmed. Costs to plaintiffs.", "affirmed"),
        ("For the foregoing reasons, the judgment of the district court is reversed and remanded.", "reversed and remanded"),
        ("We have considered the remaining contentions. Judgment affirmed.", "affirmed"),
        // Case bench 2026-10-20: the ruling as a full closing sentence.
        ("They should stand as written. The decree is reversed, and the bill dismissed.", "reversed and dismissed"),
        ("I find it unnecessary to consider the other questions. Defendants’ motion must be, and is hereby, sustained. Order may be entered accordingly.", "sustained"),
        ("Despite the fact that they made restoration. The decision of the Board of Tax Appeals and the judgments of the court are severally affirmed.", "affirmed"),
        ("A question not urged before the Board. The petition is denied and the judgment of the Board is affirmed.", "denied and affirmed"),
        ("The order appealed from is purely interlocutory. Appeal dismissed.", "dismissed"),
        ("We relegate him to his legal remedies by way of appeal. The writ is denied. GIVAN, C. J., and HUNTER, PRENTICE and PIVARNIK, JJ., concur.", "denied"),
        ("It was not a compliance. The order of the District Court is therefore reversed and the case remanded with directions that a new order be entered.", "reversed and remanded"),
    ])
    func disposition(text: String, expected: String) {
        #expect(LegalCaseDomainPack.disposition(in: text) == expected)
    }

    @Test("The opinion's author, as its header names them", arguments: [
        ("Before MIKVA, Chief Judge.\nSELYA, Circuit Judge.\nAfter selling drugs and a gun …", "Selya"),
        ("KEARSE, Circuit Judge:\nDefendants City of New York appeal …", "Kearse"),
        ("RUTH BADER GINSBURG, Circuit Judge:\nThe petition …", "Ruth Bader Ginsburg"),
        ("Mr. JUSTICE MORAN\ndelivered the opinion of the court:\nFred L. Agnew …", "Moran"),
        ("PER CURIAM.\nThe judgment is affirmed.", "Per curiam"),
        // Normalized block text: the line breaks are gone.
        ("Cozen O'Connor, P.C., by Kimberly Sullivan, Charlotte, for defendants-appellants. CALABRIA, Judge. CALABRIA, Judge. Assurance Company of America appeals.", "Calabria"),
        ("Jose M. Tous-Rodriguez, San Juan, PR, for plaintiff. CASELLAS, District Judge. OPINION AND ORDER", "Casellas"),
    ])
    func author(text: String, expected: String) {
        #expect(LegalCaseDomainPack.opinionAuthor(in: text) == expected)
    }

    @Test("A court line with initials, and a long caption, still give the decision date")
    func courtLineDateInitialsAndLongCaption() {
        #expect(LegalCaseDomainPack.courtLineDate(in: "No. 99-CV-5688 (NGG). United States District Court, E.D. New York. Feb. 14, 2001. A. Kathleen Tomlinson") == "Feb. 14, 2001")
        let parties = String(repeating: "Assurance Company of America, Zurich American Insurance Company, ", count: 22)
        #expect(LegalCaseDomainPack.courtLineDate(in: "WACHOVIA BANK v. " + parties + "Defendants. No. COA05-1112. Court of Appeals of North Carolina. July 18, 2006. Appeal by defendants") == "July 18, 2006")
    }

    @Test("A caption split across blocks gives the decision date, citing the court and date blocks")
    func splitCaptionDate() {
        let court = UUID(), date = UUID()
        let blocks: [(id: UUID, text: String)] = [
            (UUID(), "Keltch ex rel. Outhier v. Strunk"), (UUID(), "No. 36959."),
            (court, "Supreme Court of Oklahoma."), (date, "March 27, 1956."),
            (UUID(), "This was an unfortunate accident in which the plaintiff was injured."),
        ]
        let fact = LegalCaseDomainPack.documentLevelDecisionDate(blocks: blocks, subjectLabel: "Keltch")
        #expect(fact?.value == "1956-03-27")
        #expect(fact?.sourceBlockIDs == [court, date])
        #expect(LegalCaseDomainPack.documentLevelDecisionDate(
            blocks: [(UUID(), "The meeting is on March 27, 1956."), (UUID(), "Bring the minutes.")], subjectLabel: "x") == nil)
    }

    @Test("A caption split across blocks gives the docket and the court")
    func splitCaptionDocketCourt() {
        let blocks: [(id: UUID, text: String)] = [
            (UUID(), "Goudeau v. Daigle"), (UUID(), "GOUDEAU v. DAIGLE et al."), (UUID(), "No. 9941."),
            (UUID(), "Circuit Court of Appeals, Fifth Circuit."), (UUID(), "Jan. 6, 1942."),
            (UUID(), "This appeal is from a judgment dismissing appellant's suit to enforce specific performance."),
        ]
        let facts = LegalCaseDomainPack.documentLevelCaption(blocks: blocks, subjectLabel: "Goudeau", have: [])
        #expect(facts.first(where: { $0.field == "caseNumber" })?.value == "9941")
        #expect(facts.first(where: { $0.field == "court" })?.value.contains("Fifth Circuit") == true)
        #expect(facts.first(where: { $0.field == "decisionDate" })?.value == "1942-01-06")
        // Already filed by a block: left alone. Not a caption: nothing.
        #expect(LegalCaseDomainPack.documentLevelCaption(blocks: blocks, subjectLabel: "Goudeau", have: ["caseNumber", "court", "decisionDate"]).isEmpty)
        #expect(LegalCaseDomainPack.documentLevelCaption(blocks: [(UUID(), "Minutes of the meeting."), (UUID(), "No. 5 on the agenda.")], subjectLabel: "x", have: []).isEmpty)
    }

    @Test("A Northern District of Illinois docket keeps its letter")
    func ndIllDocket() {
        #expect(LegalCaseDomainPack.captionDocketNumber(in: "MISSOURI-KANSAS-TEXAS RAILROAD v. BOARD\nNo. 50 C 684.\nUnited States District Court, N. D. Illinois, E. D.") == "50 C 684")
    }

    @Test("A judge mentioned in the body is not the author")
    func bodyMentionIgnored() {
        #expect(LegalCaseDomainPack.opinionAuthor(in: "As Judge Smith explained in an earlier case, the rule applies.") == nil)
    }

    @Test("A bare court name in an opinion's body is not the deciding court")
    func bareCourtIgnored() {
        #expect(LegalCaseDomainPack.captionCourtName(in: "As the Supreme Court held, the statute is plain.") == nil)
    }

    @Test("Prose that mentions a disposition word is not a disposition")
    func proseIgnored() {
        #expect(LegalCaseDomainPack.disposition(in: "The board affirmed its commitment to safety and met again in May.") == nil)
        #expect(LegalCaseDomainPack.disposition(in: "In Smith, the conviction was affirmed on appeal, which the defendant now disputes.") == nil)
        // The case's history, in the past tense, is not its outcome.
        #expect(LegalCaseDomainPack.disposition(in: "The trial began in May. The defendant's motion to suppress was denied. The jury convicted him.") == nil)
        #expect(LegalCaseDomainPack.disposition(in: "We turn to the merits. The question is whether the order was granted in time.") == nil)
    }
}
