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
    ])
    func flowing(text: String, expected: String) {
        #expect(LegalCaseDomainPack.flowingDocketNumber(in: text) == expected)
    }

    @Test("A numbered clause is not a docket")
    func clause() {
        #expect(LegalCaseDomainPack.flowingDocketNumber(in: "See No. 5 of the agreement signed by the plaintiff.") == nil)
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
    ])
    func disposition(text: String, expected: String) {
        #expect(LegalCaseDomainPack.disposition(in: text) == expected)
    }

    @Test("A bare court name in an opinion's body is not the deciding court")
    func bareCourtIgnored() {
        #expect(LegalCaseDomainPack.captionCourtName(in: "As the Supreme Court held, the statute is plain.") == nil)
    }

    @Test("Prose that mentions a disposition word is not a disposition")
    func proseIgnored() {
        #expect(LegalCaseDomainPack.disposition(in: "The board affirmed its commitment to safety and met again in May.") == nil)
        #expect(LegalCaseDomainPack.disposition(in: "In Smith, the conviction was affirmed on appeal, which the defendant now disputes.") == nil)
    }
}
