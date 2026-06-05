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
    private let ocr: VisionOCR

    public init(ocr: VisionOCR = VisionOCR()) {
        self.ocr = ocr
    }

    public func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
        var meta: [String: AnyCodable] = [
            "filename": AnyCodable(.string(url.lastPathComponent)),
            "loader": AnyCodable(.string("vision-ocr"))
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

        let recognized = await ocr.recognizePrinted(at: url)
        let content = recognized.joined(separator: "\n")
        let confidence: Confidence = recognized.isEmpty ? .low : .high
        meta["ocrLineCount"] = AnyCodable(.int(Int64(recognized.count)))

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
