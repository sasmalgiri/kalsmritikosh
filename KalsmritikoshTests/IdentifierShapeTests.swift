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
