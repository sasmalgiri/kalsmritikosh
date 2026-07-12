//
//  PlainTextParserTests.swift
//  KalsmritikoshTests
//
//  A3 — PlainTextStructuralParser produces correctly-typed, ordered, located
//  EvidenceBlocks for Markdown. Add to the test target to run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct PlainTextParserTests {

    private func parseMarkdown(_ md: String) throws -> ParsedDocument {
        try PlainTextStructuralParser().parse(
            data: Data(md.utf8), filename: "doc.md", type: .markdown,
            logicalSourceID: UUID(), sourceVersionID: UUID()
        )
    }

    @Test func markdownBlockKindsAndOrder() throws {
        let md = """
        # Project Delta

        ## Timeline

        The kickoff happened in March.

        - milestone one
        - milestone two

        > A quoted line.

        ```
        code here
        ```
        """
        let doc = try parseMarkdown(md)
        let kinds = doc.blocks.map(\.kind)
        #expect(kinds.first == .documentTitle)
        #expect(kinds.contains(.sectionHeading))
        #expect(kinds.contains(.paragraph))
        #expect(kinds.contains(.listItem))
        #expect(kinds.contains(.quote))
        #expect(kinds.contains(.codeBlock))
        // Ordinals are strictly increasing in reading order.
        #expect(doc.blocks.map(\.ordinal) == Array(0..<doc.blocks.count))
    }

    @Test func sectionPathTracksHeadings() throws {
        let doc = try parseMarkdown("# Title\n\n## Scope\n\nBody text here.")
        let body = doc.blocks.first { $0.kind == .paragraph }
        #expect(body?.locator.sectionPath?.contains("Scope") == true)
    }

    @Test func headingLevelParsing() {
        #expect(PlainTextStructuralParser.headingLevel("## Heading") == 2)
        #expect(PlainTextStructuralParser.headingLevel("#NoSpace") == nil)
        #expect(PlainTextStructuralParser.headingLevel("plain") == nil)
        #expect(PlainTextStructuralParser.isListItem("- item"))
        #expect(PlainTextStructuralParser.isListItem("3. item"))
        #expect(!PlainTextStructuralParser.isListItem("not a list"))
    }

    @Test func emptyInputIsEmptyStatus() throws {
        let doc = try parseMarkdown("   \n  \n")
        #expect(doc.extractionStatus == .empty)
        #expect(doc.blocks.isEmpty)
    }
}
