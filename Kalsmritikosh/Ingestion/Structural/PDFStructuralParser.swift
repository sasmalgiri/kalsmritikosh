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
                for (p, para) in Self.paragraphize(native).enumerated() {
                    blocks.append(EvidenceBlock(
                        documentID: documentID, sourceVersionID: sourceVersionID, ordinal: ordinal,
                        kind: .paragraph, rawText: para,
                        locator: SourceLocator(page: pageNumber, paragraphIndex: p),
                        extractionMethod: .native
                    ))
                    ordinal += 1
                }
                continue
            }

            // Native layer missing or garbled → render + OCR this page.
            #if canImport(AppKit)
            let ocrText = await Self.renderAndOCR(page: page, ocr: ocr)
            if !ocrText.isEmpty {
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
    private static func renderAndOCR(page: PDFPage, ocr: any OCREngine) async -> String {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.0
        let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        guard size.width > 1, size.height > 1 else { return "" }
        let image = page.thumbnail(of: size, for: .mediaBox)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kalsmritikosh-pdfstruct-\(UUID().uuidString).png")
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return "" }
        do { try png.write(to: tmp) } catch { return "" }
        defer { try? FileManager.default.removeItem(at: tmp) }

        let printed = (await ocr.recognizePrinted(at: tmp)).joined(separator: "\n")
        let grid = await ocr.recognizeTable(at: tmp)
        let columnCount = grid.map(\.count).max() ?? 0
        guard grid.count >= 2, columnCount >= 2 else { return printed }
        let tsv = grid.map { $0.joined(separator: "\t") }.joined(separator: "\n")
        let base = printed.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? tsv : "\(base)\n\n\(tsv)"
    }
    #endif
}
