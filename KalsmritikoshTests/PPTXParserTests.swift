//
//  PPTXParserTests.swift
//  KalsmritikoshTests
//
//  A3 — PPTXStructuralParser: DrawingML shape/paragraph parsing and title-vs-
//  body placeholder classification. Tests the pure parsing functions (the ZIP
//  container is exercised by the shared ZIPReader tests). Add to the test
//  target to run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct PPTXParserTests {

    @Test func paragraphsSplitOnParagraphBoundaries() {
        let xml = """
        <p:txBody>\
        <a:p><a:r><a:t>First </a:t></a:r><a:r><a:t>bullet</a:t></a:r></a:p>\
        <a:p><a:r><a:t>Second bullet</a:t></a:r></a:p>\
        <a:p></a:p>\
        </p:txBody>
        """
        let paras = PPTXStructuralParser.paragraphs(xml)
        #expect(paras == ["First bullet", "Second bullet"])
    }

    @Test func shapesFlagTitlePlaceholders() {
        let slide = """
        <p:spTree>\
        <p:sp><p:nvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>\
        <p:txBody><a:p><a:r><a:t>Deck Title</a:t></a:r></a:p></p:txBody></p:sp>\
        <p:sp><p:nvSpPr><p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr>\
        <p:txBody><a:p><a:r><a:t>Body point</a:t></a:r></a:p></p:txBody></p:sp>\
        </p:spTree>
        """
        let shapes = PPTXStructuralParser.shapes(slide)
        #expect(shapes.count == 2)
        #expect(shapes[0].isTitle == true)
        #expect(shapes[1].isTitle == false)
        #expect(PPTXStructuralParser.paragraphs(shapes[0].body) == ["Deck Title"])
        #expect(PPTXStructuralParser.paragraphs(shapes[1].body) == ["Body point"])
    }

    @Test func slideOrdinalSortsNumerically() {
        // slide10 must sort after slide2 (numeric, not lexicographic).
        #expect(PPTXStructuralParser.ordinal("ppt/slides/slide10.xml", "ppt/slides/slide") == 10)
        #expect(PPTXStructuralParser.ordinal("ppt/slides/slide2.xml", "ppt/slides/slide") == 2)
    }
}
