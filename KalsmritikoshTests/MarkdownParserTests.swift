//
//  MarkdownParserTests.swift
//  KalsmritikoshTests
//
//  Release gate F1 (macro E) — Markdown is an ADVERTISED structural format but
//  was only implicitly covered through PlainTextParserTests. Proves the
//  markdown-specific behavior of PlainTextStructuralParser: heading levels and
//  live section paths, list items, and the unclosed-code-fence warning.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct MarkdownParserTests {

    private func parse(_ text: String) async throws -> ParsedDocument {
        try await PlainTextStructuralParser().parse(
            data: Data(text.utf8), filename: "fixture.md", type: .markdown,
            logicalSourceID: UUID(), sourceVersionID: UUID())
    }

    @Test("Headings, paragraphs and list items become typed blocks with section paths")
    func markdownBlocks() async throws {
        let md = """
        # Project Delta

        Opening summary paragraph.

        ## Delays

        - Supplier slipped twice
        - Contract amended

        Body under Delays.
        """
        let doc = try await parse(md)
        #expect(doc.extractionStatus == .complete)
        #expect(doc.mimeType == "text/markdown")
        let kinds = doc.blocks.map(\.kind)
        #expect(kinds.first == .documentTitle || kinds.first == .sectionHeading)
        #expect(kinds.contains(.paragraph))
        #expect(kinds.filter { $0 == .listItem }.count == 2)
        // The paragraph under "Delays" carries the heading-derived section path.
        let under = doc.blocks.first { $0.rawText.contains("Body under Delays") }
        #expect(under?.locator.sectionPath?.contains("Delays") == true)
    }

    @Test("Heading level detection requires a space after the hashes")
    func headingLevelRules() {
        #expect(PlainTextStructuralParser.headingLevel("# Title") == 1)
        #expect(PlainTextStructuralParser.headingLevel("### Sub") == 3)
        #expect(PlainTextStructuralParser.headingLevel("#not-a-heading") == nil)
        #expect(PlainTextStructuralParser.headingLevel("plain line") == nil)
    }

    @Test("List item detection covers dash/asterisk bullets")
    func listItemRules() {
        #expect(PlainTextStructuralParser.isListItem("- item"))
        #expect(PlainTextStructuralParser.isListItem("* item"))
        #expect(!PlainTextStructuralParser.isListItem("plain line"))
    }

    @Test("An unclosed code fence is surfaced as the named warning, not silently swallowed")
    func unclosedCodeFence() async throws {
        let md = """
        # Doc

        ```swift
        let x = 1
        """
        let doc = try await parse(md)
        #expect(doc.warnings.contains { $0.code == "markdown.unclosed_code_fence" })
    }
}
