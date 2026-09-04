//
//  PDFStructuralParser.swift
//  Kalsmritikosh
//
//  A3 — PDF into structured EvidenceBlocks with PER-PAGE locators. Each page's
//  native text layer is split into paragraphs (one .paragraph block per
//  paragraph, page + paragraphIndex locator, extractionMethod .native). Pages
//  whose native layer is empty OR mojibake (broken CMap / reversed font
//  encoding — same detector the legacy PDFLoader proved) fall back to rendering
//  the page and OCRing it: those blocks are flagged extractionMethod .ocr with a
//  lower extractionConfidence so the ledger can down-weight them. Real engine
//  (PDFKit + Vision), no placeholder; word-level bboxes are a later refinement
//  (the OCREngine boundary currently yields lines, not boxes).
//

import Foundation
import CryptoKit
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(AppKit)
import AppKit
#endif

public struct PDFStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.pdf] }
    public nonisolated var parserName: String { "pdf-pdfkit" }
    public nonisolated var parserVersion: String { "1" }

    private let ocr: any OCREngine

    public nonisolated init(ocr: any OCREngine) {
        self.ocr = ocr
    }

    public func parse(
        data: Data,
        filename: String,
        type: SourceType,
        logicalSourceID: UUID,
        sourceVersionID: UUID
    ) async throws -> ParsedDocument {
        let documentID = UUID()
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        #if canImport(PDFKit)
        guard let document = PDFDocument(data: data) else {
            return Self.empty(documentID, logicalSourceID, sourceVersionID, filename, hash, [
                ParserWarning(severity: .error, code: "pdf.unreadable", message: "PDFKit could not open the document.")
            ], .corrupt)
        }

        var blocks: [EvidenceBlock] = []
        var warnings: [ParserWarning] = []
        var ordinal = 0
        var ocrPages = 0

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let pageNumber = index + 1
            let native = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if !native.isEmpty && !PDFLoader.looksLikeMojibake(native) {
                // PAR-004 — resolve each paragraph's page-region box for exact-highlight
                // citations. Best-effort: a nil box just omits the region (page still cited).
                let pageString = page.string ?? native
                var searchStart = pageString.startIndex
                for (p, para) in Self.paragraphize(native).enumerated() {
                    let box = Self.paragraphBox(para, in: pageString, from: &searchStart, page: page)
                    blocks.append(EvidenceBlock(
                        documentID: documentID, sourceVersionID: sourceVersionID, ordinal: ordinal,
                        kind: .paragraph, rawText: para,
                        locator: SourceLocator(page: pageNumber, boundingBox: box, paragraphIndex: p),
                        extractionMethod: .native
                    ))
                    ordinal += 1
                }
                continue
            }

            // Native layer missing or garbled → render + OCR this page.
            #if canImport(AppKit)
            let (ocrText, ocrGrid) = await Self.renderAndOCR(page: page, ocr: ocr)
            if !ocrText.isEmpty || !ocrGrid.isEmpty {
                ocrPages += 1
                for (p, para) in Self.paragraphize(ocrText).enumerated() {
                    blocks.append(EvidenceBlock(
                        documentID: documentID, sourceVersionID: sourceVersionID, ordinal: ordinal,
                        kind: .paragraph, rawText: para,
                        locator: SourceLocator(page: pageNumber, paragraphIndex: p),
                        extractionMethod: .ocr, extractionConfidence: 0.6
                    ))
                    ordinal += 1
                }
                // C-6b — a genuinely tabular scanned page yields .table +
                // per-row .tableRow blocks (the image parser's exact shape):
                // every structured-row consumer sees the scan as it sees a CSV.
                if !ocrGrid.isEmpty {
                    let columnCount = ocrGrid.map(\.count).max() ?? 0
                    let tableBlock = EvidenceBlock(
                        documentID: documentID, sourceVersionID: sourceVersionID, ordinal: ordinal,
                        kind: .table,
                        rawText: "Table: \(ocrGrid.count) rows × \(columnCount) columns",
                        locator: SourceLocator(page: pageNumber),
                        extractionMethod: .ocr, extractionConfidence: 0.7,
                        attributes: ["rowCount": AnyCodable(.int(Int64(ocrGrid.count))),
                                     "columnCount": AnyCodable(.int(Int64(columnCount)))]
                    )
                    blocks.append(tableBlock)
                    ordinal += 1
                    for (r, row) in ocrGrid.enumerated() {
                        let padded = row + Array(repeating: "", count: max(0, columnCount - row.count))
                        blocks.append(EvidenceBlock(
                            documentID: documentID, sourceVersionID: sourceVersionID,
                            parentBlockID: tableBlock.id,
                            ordinal: ordinal, kind: .tableRow,
                            rawText: padded.joined(separator: " | "),
                            locator: SourceLocator(page: pageNumber, row: r),
                            extractionMethod: .ocr, extractionConfidence: 0.7,
                            attributes: ["row": AnyCodable(.int(Int64(r))),
                                         "cells": AnyCodable(.array(padded.map { .string($0) }))]
                        ))
                        ordinal += 1
                    }
                }
            } else if !native.isEmpty {
                // OCR failed too — keep the (garbled) native text so the page is
                // at least tracked and never silently dropped, flagged low.
                warnings.append(ParserWarning(severity: .warning, code: "pdf.mojibake_kept",
                                              message: "Page \(pageNumber): native text looks garbled and OCR yielded nothing; kept as low-confidence."))
                blocks.append(EvidenceBlock(
                    documentID: documentID, sourceVersionID: sourceVersionID, ordinal: ordinal,
                    kind: .paragraph, rawText: native,
                    locator: SourceLocator(page: pageNumber, paragraphIndex: 0),
                    extractionMethod: .native, extractionConfidence: 0.2
                ))
                ordinal += 1
            } else {
                // A page with no native text and nothing from OCR is (almost
                // always) genuinely blank — an informational note, NOT lost
                // content. Recorded for provenance but must not downgrade a
                // document whose other pages extracted faithfully.
                warnings.append(ParserWarning(severity: .info, code: "pdf.empty_page",
                                              message: "Page \(pageNumber): no extractable text."))
            }
            #endif
        }

        // Only genuine content degradation/loss (.warning/.error — e.g. a page
        // kept as low-confidence mojibake) downgrades to .partial. Informational
        // notes such as a blank page (.info) do NOT: the pages we extracted are
        // faithful, and flagging the whole document "partial" would make the
        // confidence layer under-trust a complete extraction.
        let degraded = warnings.contains { $0.severity == .warning || $0.severity == .error }
        let status: ExtractionStatus = blocks.isEmpty
            ? .empty
            : (degraded ? .partial : .complete)
        return ParsedDocument(
            id: documentID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
            filename: filename, detectedType: .pdf, mimeType: "application/pdf",
            contentHash: hash,
            metadata: [
                "pageCount": AnyCodable(.int(Int64(document.pageCount))),
                "ocrPagesUsed": AnyCodable(.int(Int64(ocrPages)))
            ],
            blocks: blocks, warnings: warnings, extractionStatus: status
        )
        #else
        return Self.empty(documentID, logicalSourceID, sourceVersionID, filename, hash, [
            ParserWarning(severity: .error, code: "pdf.no_pdfkit", message: "PDFKit unavailable on this platform.")
        ], .unsupported)
        #endif
    }

    private static func empty(_ id: UUID, _ logical: UUID, _ version: UUID, _ filename: String,
                              _ hash: String, _ warnings: [ParserWarning], _ status: ExtractionStatus) -> ParsedDocument {
        ParsedDocument(id: id, logicalSourceID: logical, sourceVersionID: version, filename: filename,
                       detectedType: .pdf, contentHash: hash, blocks: [], warnings: warnings, extractionStatus: status)
    }

    /// PAR-004 — the [x, y, w, h] locator box (page points) for a paragraph, found by
    /// locating its text in the page string and unioning the PDFKit character bounds over
    /// its range. nil when the range can't be resolved. `#if` so tests can run the pure
    /// math even where PDFKit char bounds aren't exercised.
    #if canImport(PDFKit)
    static func paragraphBox(_ paragraph: String, in pageString: String,
                             from searchStart: inout String.Index, page: PDFPage) -> [Double]? {
        guard let r = pageString.range(of: paragraph, range: searchStart..<pageString.endIndex) else { return nil }
        searchStart = r.upperBound
        let ns = NSRange(r, in: pageString)
        guard ns.length > 0 else { return nil }
        // Sample up to a few character bounds across the range (first, quartiles, last)
        // and union — enough to bound the paragraph without O(n) per-char calls.
        let offsets = PDFBoxMath.sampleOffsets(location: ns.location, length: ns.length, samples: 6)
        var rects: [CGRect] = []
        for o in offsets {
            let b = page.characterBounds(at: o)
            if b.width > 0 || b.height > 0 { rects.append(b) }
        }
        guard let u = PDFBoxMath.union(rects) else { return nil }
        return PDFBoxMath.array(u)
    }
    #endif

    /// Split page text into paragraphs on blank-line boundaries, keeping single
    /// newlines inside a paragraph. Falls back to the whole page as one block.
    static func paragraphize(_ text: String) -> [String] {
        let parts = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? [] : parts
    }

    #if canImport(AppKit) && canImport(PDFKit)
    /// Render a page upright (PDFKit's own rasterizer honors /Rotate) and OCR it.
    /// Mirrors the legacy PDFLoader render path; a tabular grid is appended when
    /// the page is genuinely a table.
    private static func renderAndOCR(page: PDFPage, ocr: any OCREngine) async -> (text: String, grid: [[String]]) {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.0
        let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        guard size.width > 1, size.height > 1 else { return ("", []) }
        let image = page.thumbnail(of: size, for: .mediaBox)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kalsmritikosh-pdfstruct-\(UUID().uuidString).png")
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return ("", []) }
        do { try png.write(to: tmp) } catch { return ("", []) }
        defer { try? FileManager.default.removeItem(at: tmp) }

        // C-6b — the grid returns STRUCTURED, not flattened to TSV prose:
        // the caller emits .table/.tableRow blocks (the same shape the image
        // parser and the CSV path produce), so a scanned bank statement is as
        // first-class to DataLab / Fund Flow / the transaction pack as a CSV.
        let printed = (await ocr.recognizePrinted(at: tmp)).joined(separator: "\n")
        let grid = await ocr.recognizeTable(at: tmp)
        let columnCount = grid.map(\.count).max() ?? 0
        guard grid.count >= 2, columnCount >= 2 else { return (printed, []) }
        return (printed, grid)
    }
    #endif
}
