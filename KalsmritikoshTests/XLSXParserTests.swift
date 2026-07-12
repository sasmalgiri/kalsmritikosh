//
//  XLSXParserTests.swift
//  KalsmritikoshTests
//
//  A3 — XLSXStructuralParser: OOXML shared-strings + sheet-cell parsing into
//  structured spreadsheet rows. Tests the pure parsing functions (the ZIP
//  container itself is exercised by the shared ZIPReader tests). Add to the
//  test target to run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct XLSXParserTests {

    @Test func sharedStringsResolveInOrder() {
        let xml = """
        <sst><si><t>Name</t></si><si><t>Amount</t></si><si><r><t>Acme</t></r></si></sst>
        """
        let strings = XLSXStructuralParser.parseSharedStrings(Data(xml.utf8))
        #expect(strings == ["Name", "Amount", "Acme"])
    }

    @Test func workbookSheetNamesMapByIndex() {
        let xml = """
        <workbook><sheets><sheet name="Invoices" sheetId="1" r:id="rId1"/><sheet name="Q2" sheetId="2" r:id="rId2"/></sheets></workbook>
        """
        let map = XLSXStructuralParser.parseWorkbookSheetNames(Data(xml.utf8))
        #expect(map["xl/worksheets/sheet1.xml"] == "Invoices")
        #expect(map["xl/worksheets/sheet2.xml"] == "Q2")
    }

    @Test func sheetRowsResolveSharedAndInlineCells() {
        // c t="s" → shared-string index; plain c → literal number; self-closing → empty.
        let sheet = """
        <worksheet><sheetData>\
        <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>\
        <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>1200</v></c><c r="C2"/></row>\
        </sheetData></worksheet>
        """
        let shared = ["Name", "Amount", "Acme"]
        let rows = XLSXStructuralParser.parseSheetRows(Data(sheet.utf8), sharedStrings: shared)
        #expect(rows.count == 2)
        #expect(rows[0] == ["Name", "Amount"])
        #expect(rows[1] == ["Acme", "1200", ""])
    }
}
