//
//  ImageParserTests.swift
//  KalsmritikoshTests
//
//  A3 — ImageStructuralParser: OCR lines → paragraph blocks + a table when the
//  image is tabular. Uses a stub OCREngine so the parser's block-structuring
//  logic is tested deterministically without Vision. Add to the test target to
//  run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

private struct StubOCR: OCREngine {
    nonisolated var engineID: String { "stub" }
    let lines: [String]
    let grid: [[String]]
    func recognizePrinted(at url: URL) async -> [String] { lines }
    func recognizeHandwritten(at url: URL) async -> [String] { [] }
    func recognizeTable(at url: URL) async -> [[String]] { grid }
}

struct ImageParserTests {

    private let png = Data([0x89, 0x50, 0x4E, 0x47])  // stub bytes; OCR is mocked

    @Test func linesBecomeParagraphBlocksUnderImageContainer() async throws {
        let ocr = StubOCR(lines: ["Invoice #42", "Total: 1200"], grid: [])
        let doc = try await ImageStructuralParser(ocr: ocr).parse(
            data: png, filename: "scan.png", type: .png,
            logicalSourceID: UUID(), sourceVersionID: UUID()
        )
        #expect(doc.blocks.first?.kind == .image)
        let paras = doc.blocks.filter { $0.kind == .paragraph }
        #expect(paras.count == 2)
        #expect(paras.allSatisfy { $0.extractionMethod == .ocr })
        #expect(paras.first?.parentBlockID == doc.blocks.first?.id)
        #expect(paras.first?.locator.line == 0)
        #expect(doc.extractionStatus == .complete)
    }

    @Test func tabularImageEmitsTableAndRows() async throws {
        let ocr = StubOCR(lines: [], grid: [["Name", "Qty"], ["Acme", "3"]])
        let doc = try await ImageStructuralParser(ocr: ocr).parse(
            data: png, filename: "grid.png", type: .png,
            logicalSourceID: UUID(), sourceVersionID: UUID()
        )
        #expect(doc.blocks.contains { $0.kind == .table })
        let rows = doc.blocks.filter { $0.kind == .tableRow }
        #expect(rows.count == 2)
        if case .array(let cells)? = rows.last?.attributes["cells"]?.value {
            #expect(cells.count == 2)
        } else {
            Issue.record("table row cells not persisted as array")
        }
    }

    @Test func noTextStillTracksImageAsPartial() async throws {
        let ocr = StubOCR(lines: [], grid: [])
        let doc = try await ImageStructuralParser(ocr: ocr).parse(
            data: png, filename: "blank.png", type: .png,
            logicalSourceID: UUID(), sourceVersionID: UUID()
        )
        // The image is always tracked (container block), flagged partial.
        #expect(doc.blocks.count == 1)
        #expect(doc.blocks.first?.kind == .image)
        #expect(doc.extractionStatus == .partial)
    }
}
