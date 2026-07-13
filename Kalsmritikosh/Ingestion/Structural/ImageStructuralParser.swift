//
//  ImageStructuralParser.swift
//  Kalsmritikosh
//
//  A3 — image (PNG/JPG/HEIC/TIFF/WEBP) into structured EvidenceBlocks via
//  Vision OCR. Emits one .image container block (pixel dimensions in
//  attributes) plus one .paragraph block per recognized printed line — each
//  flagged extractionMethod .ocr with a line locator — and, when the image is
//  genuinely tabular, a .table block with .tableRow children carrying cells.
//  Real engine (Apple Vision via the injected OCREngine), no placeholder;
//  word-level bounding boxes are a later refinement (the OCREngine boundary
//  yields lines/grids, not per-word boxes).
//

import Foundation
import CryptoKit
#if canImport(ImageIO)
import ImageIO
#endif

public struct ImageStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.png, .jpg, .heic, .tiff, .webp] }
    public nonisolated var parserName: String { "image-vision-ocr" }
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

        // OCR needs a file URL; write to a temp file with the original extension
        // so ImageIO/Vision can decode the container.
        let ext = (filename as NSString).pathExtension.isEmpty ? "img" : (filename as NSString).pathExtension
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kalsmritikosh-imgstruct-\(UUID().uuidString).\(ext)")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var blocks: [EvidenceBlock] = []
        var warnings: [ParserWarning] = []
        var ordinal = 0

        // Image container block with pixel dimensions when available.
        var imageAttrs: [String: AnyCodable] = ["mime": AnyCodable(.string(Self.mime(type)))]
        var pxW = 0, pxH = 0
        #if canImport(ImageIO)
        if let src = CGImageSourceCreateWithURL(tmp as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] {
            if let w = props[kCGImagePropertyPixelWidth as String] as? Int {
                pxW = w
                imageAttrs["pixelWidth"] = AnyCodable(.int(Int64(w)))
            }
            if let h = props[kCGImagePropertyPixelHeight as String] as? Int {
                pxH = h
                imageAttrs["pixelHeight"] = AnyCodable(.int(Int64(h)))
            }
        }
        #endif
        // PERF.4 — OCR triage: skip tiny images (tracking pixels, spacers, UI
        // icons, social badges). A 1×1 pixel or a 16×16 icon holds no readable
        // evidence; email archives are full of them. When dimensions are known
        // and below the threshold, we still ingest the image as a source block
        // but skip the (expensive, serialized) OCR passes. Unknown dimensions →
        // don't skip (fail open to OCR).
        let tooSmallForOCR = pxW > 0 && pxH > 0 && (min(pxW, pxH) < 64 || pxW * pxH < 64 * 64)
        let imageBlock = EvidenceBlock(
            documentID: documentID, sourceVersionID: sourceVersionID, ordinal: ordinal,
            kind: .image, rawText: filename,
            locator: SourceLocator(), extractionMethod: .native, attributes: imageAttrs
        )
        blocks.append(imageBlock)
        ordinal += 1

        // Printed OCR → one paragraph block per line (reading order preserved).
        // OCR is the dominant ingest cost (Vision serializes on the Neural
        // Engine); skip it when the user has turned OCR-during-ingest off.
        let ocrEnabled = FeatureFlags.ocrDuringIngestValue() && !tooSmallForOCR
        let lines = ocrEnabled
            ? (await ocr.recognizePrinted(at: tmp)).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            : []
        for (i, line) in lines.enumerated() {
            blocks.append(EvidenceBlock(
                documentID: documentID, sourceVersionID: sourceVersionID, parentBlockID: imageBlock.id,
                ordinal: ordinal, kind: .paragraph, rawText: line,
                locator: SourceLocator(line: i), extractionMethod: .ocr, extractionConfidence: 0.7
            ))
            ordinal += 1
        }

        // Table pass — only when genuinely tabular (≥2 rows × ≥2 columns).
        let grid = ocrEnabled ? await ocr.recognizeTable(at: tmp) : []
        let columnCount = grid.map(\.count).max() ?? 0
        if grid.count >= 2, columnCount >= 2 {
            let tableBlock = EvidenceBlock(
                documentID: documentID, sourceVersionID: sourceVersionID, parentBlockID: imageBlock.id,
                ordinal: ordinal, kind: .table,
                rawText: "Table: \(grid.count) rows × \(columnCount) columns",
                locator: SourceLocator(), extractionMethod: .ocr, extractionConfidence: 0.7,
                attributes: ["rowCount": AnyCodable(.int(Int64(grid.count))),
                             "columnCount": AnyCodable(.int(Int64(columnCount)))]
            )
            blocks.append(tableBlock)
            ordinal += 1
            for (r, row) in grid.enumerated() {
                let padded = row + Array(repeating: "", count: max(0, columnCount - row.count))
                blocks.append(EvidenceBlock(
                    documentID: documentID, sourceVersionID: sourceVersionID, parentBlockID: tableBlock.id,
                    ordinal: ordinal, kind: .tableRow, rawText: padded.joined(separator: " | "),
                    locator: SourceLocator(row: r), extractionMethod: .ocr, extractionConfidence: 0.7,
                    attributes: ["row": AnyCodable(.int(Int64(r))),
                                 "cells": AnyCodable(.array(padded.map { .string($0) }))]
                ))
                ordinal += 1
            }
        }

        if lines.isEmpty && grid.isEmpty {
            warnings.append(ParserWarning(severity: .warning, code: "image.no_text",
                                          message: "No text recognized in image."))
        }
        // The image is always tracked (container block present); status is
        // partial when OCR found no text, complete otherwise.
        let status: ExtractionStatus = warnings.isEmpty ? .complete : .partial
        return ParsedDocument(
            id: documentID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
            filename: filename, detectedType: type, mimeType: Self.mime(type),
            contentHash: hash, blocks: blocks, warnings: warnings, extractionStatus: status
        )
    }

    private static func mime(_ type: SourceType) -> String {
        switch type {
        case .png:  return "image/png"
        case .jpg:  return "image/jpeg"
        case .heic: return "image/heic"
        case .tiff: return "image/tiff"
        case .webp: return "image/webp"
        default:    return "application/octet-stream"
        }
    }
}
