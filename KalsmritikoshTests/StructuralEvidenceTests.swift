//
//  StructuralEvidenceTests.swift
//  KalsmritikoshTests
//
//  A1 unit tests for the canonical structural evidence model (models only).
//  Add this file to the KalsmritikoshTests target in Xcode to run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct StructuralEvidenceTests {

    private func block(_ ordinal: Int, _ kind: EvidenceBlockKind, _ text: String) -> EvidenceBlock {
        EvidenceBlock(documentID: UUID(), ordinal: ordinal, kind: kind, rawText: text)
    }

    @Test func normalizeCollapsesWhitespaceAndDehyphenates() {
        let n = EvidenceBlock.normalize("The quick  brown\nfox jum-\nped over")
        #expect(n == "The quick brown fox jumped over")
    }

    @Test func reconstructedTextPreservesOrder() {
        let doc = ParsedDocument(
            logicalSourceID: UUID(), sourceVersionID: UUID(), filename: "a.txt",
            detectedType: .txt, contentHash: "h",
            blocks: [block(2, .paragraph, "second"), block(1, .sectionHeading, "first"), block(3, .paragraph, "third")]
        )
        #expect(doc.reconstructedText == "first\nsecond\nthird")
    }

    @Test func meaningfulBlocksExcludeBoilerplate() {
        let doc = ParsedDocument(
            logicalSourceID: UUID(), sourceVersionID: UUID(), filename: "a.pdf",
            detectedType: .pdf, contentHash: "h",
            blocks: [
                block(1, .pageHeader, "CONFIDENTIAL"),
                block(2, .paragraph, "The real first sentence."),
                block(3, .pageFooter, "Page 1")
            ]
        )
        #expect(doc.meaningfulBlocks.first?.normalizedText == "The real first sentence.")
    }

    @Test func sourceLocatorRoundTripsWithSourceRange() {
        let sr = SourceRange(chunkID: UUID(), characterRange: 5..<20, pageNumber: 3, line: 7)
        let loc = SourceLocator(sourceRange: sr)
        #expect(loc.characterRange == 5..<20)
        #expect(loc.page == 3)
        #expect(loc.asSourceRange == sr)
    }

    @Test func locatorCodableSurvivesRoundTrip() throws {
        let loc = SourceLocator(page: 2, sheet: "Sheet1", row: 4, column: "B", cellRange: "B4")
        let data = try JSONEncoder().encode(loc)
        let back = try JSONDecoder().decode(SourceLocator.self, from: data)
        #expect(back == loc)
    }

    @Test func documentProfileDerivesDeterministically() {
        let doc = ParsedDocument(
            logicalSourceID: UUID(), sourceVersionID: UUID(), filename: "deck.pptx",
            detectedType: .pptx, contentHash: "h",
            blocks: [
                block(1, .documentTitle, "Project Delta"),
                block(2, .slideTitle, "Agenda"),
                block(3, .slideBody, "Timeline and budget")
            ]
        )
        let p = DocumentProfile.from(doc, parser: "pptx", parserVersion: "1")
        #expect(p.blockCount == 3)
        #expect(p.sectionOutline.contains("Project Delta"))
        #expect(p.firstMeaningfulBlock == "Project Delta")
        #expect(p.slideCount == 1)
    }

    @Test func chunkBoundaryAndBoilerplateFlags() {
        #expect(EvidenceBlockKind.emailBody.isHardChunkBoundary)
        #expect(EvidenceBlockKind.pageFooter.isBoilerplate)
        #expect(!EvidenceBlockKind.paragraph.isHardChunkBoundary)
    }
}
