//
//  XLSXFormulaModelTests.swift
//  KalsmritikoshTests
//
//  PAR-005 — the spreadsheet parser distinguishes a cell's formula (<f>) from its cached
//  value (<v>), so a formula-vs-value exact query can tell `=A1+B1` apart from a literal.
//  The existing resolved-text path is unchanged (fidelity preserved).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("XLSX formula/value model (PAR-005)")
struct XLSXFormulaModelTests {

    @Test("Formula cell exposes its expression and cached value")
    func formulaCell() {
        let body = "<f>A1+B1</f><v>42</v>"
        #expect(XLSXStructuralParser.cellFormula(inBody: body) == "A1+B1")
        #expect(XLSXStructuralParser.cellRawValue(inBody: body) == "42")
    }

    @Test("Literal cell has no formula but has a raw value")
    func literalCell() {
        let body = "<v>42</v>"
        #expect(XLSXStructuralParser.cellFormula(inBody: body) == nil)
        #expect(XLSXStructuralParser.cellRawValue(inBody: body) == "42")
    }

    @Test("Self-closing shared-formula slave carries no expression")
    func sharedFormulaSlave() {
        #expect(XLSXStructuralParser.cellFormula(inBody: "<f t=\"shared\" si=\"0\"/><v>7</v>") == nil)
    }

    @Test("Number formats resolve custom + built-in via cellXfs")
    func numberFormats() {
        let styles = Data("""
        <styleSheet>
        <numFmts count="1"><numFmt numFmtId="164" formatCode="yyyy-mm-dd"/></numFmts>
        <cellXfs count="3">
          <xf numFmtId="0"/>
          <xf numFmtId="9"/>
          <xf numFmtId="164"/>
        </cellXfs>
        </styleSheet>
        """.utf8)
        let map = XLSXStructuralParser.parseNumberFormats(styles)
        #expect(map[0] == "General")     // built-in
        #expect(map[1] == "0%")          // built-in id 9 at xf index 1
        #expect(map[2] == "yyyy-mm-dd")  // custom id 164 at xf index 2
    }

    @Test("Cell style index parses from the header")
    func styleIndex() {
        #expect(XLSXStructuralParser.cellStyleIndex(inHeader: "r=\"A1\" s=\"2\" t=\"n\"") == 2)
        #expect(XLSXStructuralParser.cellStyleIndex(inHeader: "r=\"A1\"") == nil)
    }

    @Test("Row formats align to cells (date column flagged)")
    func rowFormatsAlign() {
        let sheet = Data("""
        <worksheet><sheetData>
        <row r="1"><c r="A1" s="0"><v>5</v></c><c r="B1" s="2"><v>45000</v></c></row>
        </sheetData></worksheet>
        """.utf8)
        let formats = [0: "General", 2: "yyyy-mm-dd"]
        let rows = XLSXStructuralParser.parseSheetFormats(sheet, formats: formats)
        #expect(rows[0] == ["General", "yyyy-mm-dd"])
    }

    @Test("Row formulas align to cells; formula and literal 42 are distinguishable")
    func rowFormulasAlign() {
        let sheet = Data("""
        <worksheet><sheetData>
        <row r="1"><c r="A1"><v>42</v></c><c r="B1"><f>A1*2</f><v>84</v></c></row>
        </sheetData></worksheet>
        """.utf8)
        let text = XLSXStructuralParser.parseSheetRows(sheet, sharedStrings: [])
        let formulas = XLSXStructuralParser.parseSheetFormulas(sheet)
        #expect(formulas.count == 1)
        #expect(formulas[0] == ["", "A1*2"])         // A1 literal (no formula), B1 formula
        #expect(text[0].first == "42")               // text path still resolves the value
        #expect(text[0].count == formulas[0].count)  // aligned
    }
}
