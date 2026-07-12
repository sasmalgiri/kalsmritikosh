//
//  EPUBParserTests.swift
//  KalsmritikoshTests
//
//  A3 — EPUBStructuralParser: reading-order XHTML block extraction and heading /
//  paragraph / list / quote classification. Full spine resolution is exercised
//  by the ingestion smoke test on real fixtures. Add to the test target to run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct EPUBParserTests {

    @Test func blocksAreExtractedInReadingOrder() {
        let xhtml = """
        <html><head><style>x{}</style></head><body>\
        <h1>Chapter One</h1>\
        <p>Opening paragraph.</p>\
        <h2>A Section</h2>\
        <p>Section body.</p>\
        <ul><li>first</li><li>second</li></ul>\
        <blockquote>A cited line.</blockquote>\
        </body></html>
        """
        let blocks = EPUBStructuralParser.htmlBlocks(xhtml)
        // Reading order preserved: h1, p, h2, p, li, li, blockquote.
        #expect(blocks.map(\.tag) == ["h1", "p", "h2", "p", "li", "li", "blockquote"])
        #expect(blocks[0].headingLevel == 1)
        #expect(blocks[2].headingLevel == 2)
        #expect(blocks[1].kind == .paragraph)
        #expect(blocks[4].kind == .listItem)
        #expect(blocks[6].kind == .quote)
        #expect(blocks[0].text == "Chapter One")
    }

    @Test func headScriptStyleIsExcluded() {
        let xhtml = """
        <html><head><title>Ignore me</title><script>var a=1;</script></head>\
        <body><p>Only body text.</p></body></html>
        """
        let blocks = EPUBStructuralParser.htmlBlocks(xhtml)
        #expect(blocks.count == 1)
        #expect(blocks[0].text == "Only body text.")
    }
}
