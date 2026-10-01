//
//  XLSXCellPositionTests.swift
//  KalsmritikoshTests
//
//  F31 — XLSX cells land at their declared positions (c@r / row@r), sheets are named and
//  ordered through the workbook relationships, and a formula cell's value is its cached
//  <v>, never the formula text glued to it.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("F31 — XLSX native positions, sheet relationships, formula vs value")
struct XLSXCellPositionTests {

    @Test("A sparse row keeps A1 and C1 in their own columns")
    func sparseRowColumns() {
        let sheet = Data("""
        <worksheet><sheetData>\
        <row r="1"><c r="A1" t="inlineStr"><is><t>a</t></is></c><c r="C1"><v>3</v></c></row>\
        </sheetData></worksheet>
        """.utf8)
        #expect(XLSXStructuralParser.parseSheetRows(sheet, sharedStrings: []) == [["a", "", "3"]])
    }

    @Test("A row gap keeps the real row number; an empty self-closing row doesn't swallow the next")
    func rowNumbersAreNative() {
        let sheet = Data("""
        <worksheet><sheetData>\
        <row r="1"><c r="A1"><v>1</v></c></row>\
        <row r="3"/>\
        <row r="5"><c r="A5"><v>5</v></c></row>\
        </sheetData></worksheet>
        """.utf8)
        let rows = XLSXStructuralParser.parseSheet(sheet, sharedStrings: [], formats: [:])
        #expect(rows.map(\.index) == [0, 2, 4])
        #expect(rows.map(\.values) == [["1"], [], ["5"]])
    }

    @Test("A formula cell's value is its cached result; the formula is kept separately")
    func formulaAndValueSeparate() {
        let sheet = Data("""
        <worksheet><sheetData>\
        <row r="1"><c r="A1"><v>1</v></c><c r="B1"><f>SUM(A1:A2)</f><v>3</v></c></row>\
        </sheetData></worksheet>
        """.utf8)
        let rows = XLSXStructuralParser.parseSheet(sheet, sharedStrings: [], formats: [:])
        #expect(rows.first?.values == ["1", "3"])
        #expect(rows.first?.formulas == ["", "SUM(A1:A2)"])
    }

    @Test("Sheets follow workbook order and names through the relationships, not file names")
    func sheetsResolveThroughRelationships() {
        let workbook = Data("""
        <workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\
        <sheet name="Summary" sheetId="7" r:id="rId3"/><sheet name="Detail" sheetId="2" r:id="rId1"/>\
        </sheets></workbook>
        """.utf8)
        let rels = Data("""
        <Relationships>\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>\
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="/xl/worksheets/sheet2.xml"/>\
        </Relationships>
        """.utf8)
        let entries = ["xl/worksheets/sheet1.xml", "xl/worksheets/sheet2.xml", "xl/worksheets/sheet10.xml"]
        let sheets = XLSXStructuralParser.orderedSheets(workbook: workbook, relationships: rels, entries: entries)
        #expect(sheets.map(\.name) == ["Summary", "Detail", "Sheet 3"])
        #expect(sheets.map(\.path) == ["xl/worksheets/sheet2.xml", "xl/worksheets/sheet1.xml", "xl/worksheets/sheet10.xml"])
    }

    @Test("Without relationships, worksheet files order numerically (sheet2 before sheet10)")
    func numericFallbackOrder() {
        let entries = ["xl/worksheets/sheet10.xml", "xl/worksheets/sheet2.xml", "xl/worksheets/sheet1.xml"]
        let sheets = XLSXStructuralParser.orderedSheets(workbook: nil, relationships: nil, entries: entries)
        #expect(sheets.map(\.path) == ["xl/worksheets/sheet1.xml", "xl/worksheets/sheet2.xml", "xl/worksheets/sheet10.xml"])
    }
}
