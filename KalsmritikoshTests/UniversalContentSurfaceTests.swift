//
//  UniversalContentSurfaceTests.swift
//  KalsmritikoshTests
//
//  USF-M1 (USF-004) — content surfaces DESCRIBE what a parser recovered over the existing
//  EvidenceBlock model; they are not a second readiness system. Coverage is only complete /
//  partial / notApplicable, never ready/blocked/failed/unsupported/deferred. typedFields stays
//  notApplicable until an accepted producer exists.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("USF-M1 — universal content surfaces")
struct UniversalContentSurfaceTests {

    private let doc = UUID()
    private func block(_ ordinal: Int, _ kind: EvidenceBlockKind, located: Bool = true,
                       text: String = "substantive content", method: ExtractionMethod = .native) -> EvidenceBlock {
        EvidenceBlock(documentID: doc, ordinal: ordinal, kind: kind, rawText: text,
                      locator: located ? SourceLocator(page: 1) : SourceLocator(), extractionMethod: method)
    }
    private func project(_ blocks: [EvidenceBlock], metadata: [String: AnyCodable] = [:],
                         status: ExtractionStatus = .complete) -> [ContentSurfaceReceipt] {
        ContentSurfaceProjector.project(blocks: blocks, metadata: metadata, extractionStatus: status)
    }
    private func surface(_ surfaces: [ContentSurfaceReceipt], _ kind: ContentSurfaceKind) -> ContentSurfaceReceipt? {
        surfaces.first { $0.kind == kind }
    }

    @Test("A complete parse of paragraphs yields a complete text surface")
    func textComplete() {
        let s = project([block(0, .paragraph), block(1, .paragraph)])
        #expect(surface(s, .text)?.coverage == .complete)
        #expect(surface(s, .text)?.unitCount == 2)
    }

    @Test("A partial parse yields a partial text surface")
    func textPartial() {
        let s = project([block(0, .paragraph)], status: .partial)
        #expect(surface(s, .text)?.coverage == .partial)
    }

    @Test("Metadata surface reflects document metadata presence")
    func metadataSurface() {
        #expect(surface(project([block(0, .paragraph)], metadata: ["author": AnyCodable(.string("x"))]), .metadata)?.coverage == .complete)
        #expect(surface(project([block(0, .paragraph)]), .metadata)?.coverage == .notApplicable)
    }

    @Test("Structure surface is complete only when every substantive block is located")
    func structureComplete() {
        #expect(surface(project([block(0, .paragraph, located: true)]), .structure)?.coverage == .complete)
        #expect(surface(project([block(0, .paragraph, located: true), block(1, .paragraph, located: false)]), .structure)?.coverage == .partial)
    }

    @Test("Tables surface is produced from table + spreadsheet blocks")
    func tablesSurface() {
        let s = project([block(0, .table), block(1, .tableRow), block(2, .spreadsheetCell)])
        #expect(surface(s, .tables)?.coverage == .complete)
        #expect((surface(s, .tables)?.unitCount ?? 0) == 3)
    }

    @Test("Images surface is produced from image + figure-caption blocks")
    func imagesSurface() {
        #expect(surface(project([block(0, .image), block(1, .figureCaption)]), .images)?.coverage == .complete)
    }

    @Test("Attachments surface is produced from attachment blocks")
    func attachmentsSurface() {
        #expect(surface(project([block(0, .attachment)]), .attachments)?.coverage == .complete)
    }

    @Test("Transcript surface is produced from transcript-segment blocks")
    func transcriptSurface() {
        #expect(surface(project([block(0, .transcriptSegment)]), .transcript)?.coverage == .complete)
    }

    @Test("typedFields is notApplicable when the document carries no identity fields (MMI producer)")
    func typedFieldsNotApplicable() {
        // MMI-FINAL is now the accepted typed-field producer; a generic paragraph with no
        // identity/document fields still projects notApplicable (nothing to type).
        #expect(surface(project([block(0, .paragraph)]), .typedFields)?.coverage == .notApplicable)
    }

    @Test("Boilerplate blocks are excluded from the text surface")
    func boilerplateExcluded() {
        let s = project([block(0, .paragraph), block(1, .pageFooter), block(2, .emailSignature)])
        #expect(surface(s, .text)?.unitCount == 1)   // only the paragraph is substantive
    }

    @Test("A loader-only projection yields a text surface and nothing else")
    func objectProjection() {
        let ko = KnowledgeObject(sourceFile: URL(fileURLWithPath: "/tmp/x"), sourceType: .txt, content: "hello body")
        let s = ContentSurfaceProjector.projectFromObjects([ko], extractionStatus: .complete)
        #expect(surface(s, .text)?.coverage == .complete)
        #expect(surface(s, .structure)?.coverage == .notApplicable)
        let empty = ContentSurfaceProjector.projectFromObjects([KnowledgeObject(sourceFile: URL(fileURLWithPath: "/tmp/y"), sourceType: .txt, content: "  ")], extractionStatus: .empty)
        #expect(surface(empty, .text)?.coverage == .notApplicable)
    }

    @Test("Surface coverage is never a readiness state")
    func coverageIsNotReadiness() {
        let s = project([block(0, .paragraph), block(1, .table)], metadata: ["k": AnyCodable(.string("v"))])
        for receipt in s {
            #expect([.complete, .partial, .notApplicable].contains(receipt.coverage))
        }
    }

    @Test("Structure surface is notApplicable when no substantive block is located")
    func structureNotApplicable() {
        #expect(surface(project([block(0, .paragraph, located: false)]), .structure)?.coverage == .notApplicable)
    }
}
