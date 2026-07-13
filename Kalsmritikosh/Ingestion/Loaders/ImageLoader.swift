//
//  ImageLoader.swift
//  Kalsmritikosh
//
//  Real Vision-backed OCR runs at ingest time. The OCRExpert can re-OCR
//  later for specialized table/form passes, but the baseline text lands
//  immediately so retrieval has something to index.
//

import Foundation
#if canImport(ImageIO)
import ImageIO
#endif

public struct ImageLoader: Ingestor {
    public let supportedTypes: Set<SourceType> = [.png, .jpg, .heic, .tiff, .webp]
    public let primaryLane: ResourceLane = .neuralEngine // Vision OCR runs on the NE
    private let ocr: any OCREngine

    public nonisolated init(ocr: any OCREngine) {
        self.ocr = ocr
    }

    public func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
        var meta: [String: AnyCodable] = [
            "filename": AnyCodable(.string(url.lastPathComponent)),
            "loader": AnyCodable(.string("ocr:\(ocr.engineID)"))
        ]

        #if canImport(ImageIO)
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] {
            if let width = props[kCGImagePropertyPixelWidth as String] as? Int {
                meta["pixelWidth"] = AnyCodable(.int(Int64(width)))
            }
            if let height = props[kCGImagePropertyPixelHeight as String] as? Int {
                meta["pixelHeight"] = AnyCodable(.int(Int64(height)))
            }
        }
        #endif

        // OCR is the dominant ingest cost (Vision serializes on the NE); skip
        // when the user has turned OCR-during-ingest off (FeatureFlags).
        let recognized = FeatureFlags.ocrDuringIngestValue() ? await ocr.recognizePrinted(at: url) : []
        var content = recognized.joined(separator: "\n")
        let confidence: Confidence = recognized.isEmpty ? .low : .high
        meta["ocrLineCount"] = AnyCodable(.int(Int64(recognized.count)))

        // Table pass (ocr-table-pipeline port). Printed OCR gives reading-order
        // text; the table pass reconstructs the grid. We KEEP both and append
        // a tab-separated grid only when the page is genuinely tabular (≥2 rows
        // × ≥2 columns) so ordinary scans aren't polluted. Deterministic /
        // non-generative (Apple Vision), so it's fine under the minimum-LLM rule.
        let grid = FeatureFlags.ocrDuringIngestValue() ? await ocr.recognizeTable(at: url) : []
        let columnCount = grid.map(\.count).max() ?? 0
        if grid.count >= 2 && columnCount >= 2 {
            let tsv = grid.map { $0.joined(separator: "\t") }.joined(separator: "\n")
            meta["tableRows"] = AnyCodable(.int(Int64(grid.count)))
            meta["tableColumns"] = AnyCodable(.int(Int64(columnCount)))
            let base = content.trimmingCharacters(in: .whitespacesAndNewlines)
            content = base.isEmpty ? tsv : "\(base)\n\n[TABLE]\n\(tsv)"
        }

        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Still emit a KO so the file is tracked; downstream Memory
            // layer notices the empty-content signal via metadata.
            meta["ocrEmpty"] = AnyCodable(.bool(true))
        }

        return KnowledgeObject(
            sourceFile: url,
            sourceType: type,
            content: content.isEmpty ? "[image: no text recognized]" : content,
            metadata: meta,
            confidence: confidence
        )
    }
}
