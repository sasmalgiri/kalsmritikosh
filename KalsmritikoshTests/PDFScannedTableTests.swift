//
//  PDFScannedTableTests.swift
//  KalsmritikoshTests
//
//  C-6b (S2-U3) — a scanned PDF page whose OCR reconstructs a table must
//  yield .table + per-row .tableRow blocks with cells, exactly the shape
//  the image parser and the CSV path emit — so DataLab, Fund Flow, and the
//  transaction pack see a scanned bank statement as they see a CSV.
//  Stubbed OCR: the block-structuring logic is what's under test, not Vision.
//

import Testing
import Foundation
import PDFKit
@testable import Kalsmritikosh

private struct TableStubOCR: OCREngine {
    nonisolated var engineID: String { "stub-table" }
    let grid: [[String]]
    func recognizePrinted(at url: URL) async -> [String] { ["BANK STATEMENT"] }
    func recognizeHandwritten(at url: URL) async -> [String] { [] }
    func recognizeTable(at url: URL) async -> [[String]] { grid }
}

@MainActor
struct PDFScannedTableTests {

    /// A one-page PDF with NO native text layer (image-only) so the parser
    /// takes the OCR path.
    private func imageOnlyPDF() -> Data {
        let image = NSImage(size: NSSize(width: 200, height: 100), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }
        let page = PDFPage(image: image)!
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        return doc.dataRepresentation()!
    }

    @Test("A scanned tabular page emits .table + .tableRow blocks with cells")
    func scannedTableBecomesRows() async throws {
        let grid = [["Date", "Payee", "Amount"],
                    ["14/08/2024", "Khurana & Khurana", "Rs20,000"],
                    ["06/08/2024", "IP Office", "Rs4,000"]]
        let parser = PDFStructuralParser(ocr: TableStubOCR(grid: grid))
        let doc = try await parser.parse(
            data: imageOnlyPDF(), filename: "statement.pdf", type: .pdf,
            logicalSourceID: UUID(), sourceVersionID: UUID())

        #expect(doc.blocks.contains { $0.kind == .table }, "the grid must surface as a table block")
        let rows = doc.blocks.filter { $0.kind == .tableRow }
        #expect(rows.count == 3, "one block per scanned row, got \(rows.count)")
        #expect(rows.allSatisfy { $0.extractionMethod == .ocr })
        // Cells persist structurally — the transaction pack's food.
        if case .array(let cells)? = rows.last?.attributes["cells"]?.value {
            #expect(cells.count == 3)
        } else {
            Issue.record("row cells not persisted as an array")
        }
        // The printed text still lands as a paragraph — nothing is lost.
        #expect(doc.blocks.contains { $0.kind == .paragraph && $0.rawText.contains("BANK STATEMENT") })
        // Rows parent to the table block.
        let table = doc.blocks.first { $0.kind == .table }
        #expect(rows.allSatisfy { $0.parentBlockID == table?.id })
    }

    @Test("A non-tabular scanned page emits no table blocks")
    func nonTabularStaysProse() async throws {
        let parser = PDFStructuralParser(ocr: TableStubOCR(grid: []))
        let doc = try await parser.parse(
            data: imageOnlyPDF(), filename: "letter.pdf", type: .pdf,
            logicalSourceID: UUID(), sourceVersionID: UUID())
        #expect(!doc.blocks.contains { $0.kind == .table || $0.kind == .tableRow })
        #expect(doc.blocks.contains { $0.kind == .paragraph })
    }
}
