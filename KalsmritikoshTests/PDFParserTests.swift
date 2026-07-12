//
//  PDFParserTests.swift
//  KalsmritikoshTests
//
//  A3 — PDFStructuralParser: paragraph segmentation of page text (the
//  deterministic, PDFKit-independent part). Full-document parsing + OCR
//  fallback are exercised by the ingestion smoke test on real fixtures. Add to
//  the test target to run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct PDFParserTests {

    @Test func paragraphizeSplitsOnBlankLines() {
        let page = "First paragraph line one\nline two\n\nSecond paragraph\n\n\nThird"
        let paras = PDFStructuralParser.paragraphize(page)
        #expect(paras.count == 3)
        #expect(paras[0] == "First paragraph line one\nline two")
        #expect(paras[1] == "Second paragraph")
        #expect(paras[2] == "Third")
    }

    @Test func paragraphizeNormalizesCRLFAndEmpty() {
        #expect(PDFStructuralParser.paragraphize("\n\n   \n\n").isEmpty)
        let crlf = PDFStructuralParser.paragraphize("A\r\n\r\nB")
        #expect(crlf == ["A", "B"])
    }
}
