//
//  OpenDocumentParserTests.swift
//  KalsmritikoshTests
//
//  A3 — ODT / ODS structural parsers: OpenDocument content.xml reading-order
//  text extraction and spreadsheet cell/repeat handling (the ZIP-independent
//  core). Full-document parsing is exercised on real fixtures by the ingestion
//  smoke test. Add to the test target to run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct OpenDocumentParserTests {

    // MARK: ODT

    @Test func odtHeadingsAndParagraphsInReadingOrder() {
        let content = """
        <office:body><office:text>\
        <text:h text:outline-level="1">Title</text:h>\
        <text:p>Intro paragraph.</text:p>\
        <text:h text:outline-level="2">Scope</text:h>\
        <text:p>Scope body.</text:p>\
        <text:p/>\
        </office:text></office:body>
        """
        let els = ODTStructuralParser.textElements(content)
        #expect(els.map(\.isHeading) == [true, false, true, false])
        #expect(els[0].outlineLevel == 1)
        #expect(els[2].outlineLevel == 2)
        #expect(els[1].text == "Intro paragraph.")
    }

    // MARK: ODS

    @Test func odsCellsAndColumnRepeat() {
        let body = """
        <table:table-row>\
        <table:table-cell><text:p>Name</text:p></table:table-cell>\
        <table:table-cell table:number-columns-repeated="2"><text:p>x</text:p></table:table-cell>\
        </table:table-row>
        """
        let cells = ODSStructuralParser.cells(body)
        #expect(cells == ["Name", "x", "x"])
    }

    @Test func odsSheetRowsTrimTrailingEmpties() {
        let xml = """
        <office:spreadsheet>\
        <table:table table:name="Data">\
        <table:table-row><table:table-cell><text:p>a</text:p></table:table-cell>\
        <table:table-cell/></table:table-row>\
        <table:table-row><table:table-cell/></table:table-row>\
        </table:table>\
        </office:spreadsheet>
        """
        let sheets = ODSStructuralParser.sheets(xml)
        #expect(sheets.count == 1)
        #expect(sheets[0].name == "Data")
        // Trailing empty cell trimmed to ["a"]; trailing empty row dropped.
        #expect(sheets[0].rows == [["a"]])
    }
}
