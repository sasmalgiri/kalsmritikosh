//
//  VisionOCR.swift
//  Kalsmritikosh
//
//  Vision-backed OCR variants: printed text, table layout, form fields.
//  M5 implements printed text; handwritten + table + form recognition
//  are wired but use the same printed pipeline until VNRecognize
//  DocumentRequest is paired with a custom layout pass.
//

import Foundation
#if canImport(Vision)
import Vision
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Format-specialist abstraction for OCR. Apple Vision is the
/// default; future swap-ins (PaddleOCR-VL, Surya, TrOCR for
/// handwriting, Mistral OCR as a cloud variant) conform to this
/// protocol and ImageLoader / PDFLoader pick them up via
/// constructor injection.
///
/// Quality ranking on 2026 benchmarks (printed text):
///   PaddleOCR-VL ~94.5% OmniDocBench
///   Mistral OCR  (cloud, paid, single forward pass)
///   Surya v2     (open weights, layout-aware)
///   Apple Vision (current, excellent printed text, weak on handwriting)
///   Tesseract    (CPU only, legacy)
///
/// Handwriting specifically: TrOCR / Donut / DTrOCR are leaders.
public protocol OCREngine: Sendable {
    nonisolated var engineID: String { get }
    func recognizePrinted(at url: URL) async -> [String]
    func recognizeHandwritten(at url: URL) async -> [String]
    func recognizeTable(at url: URL) async -> [[String]]
}

public actor VisionOCR: OCREngine {
    public nonisolated let engineID = "apple-vision"

    /// Languages Vision should consider when recognizing. Default is
    /// English-only — without this, Vision falls through to the
    /// user's locale languages and a system with Cyrillic / Greek
    /// installed mis-picks them as candidates for Latin glyphs (real
    /// case observed on a scanned POA: Latin "O" became Cyrillic "О",
    /// Latin "A" became "А", whole document came out as a Latin /
    /// Cyrillic mix). Set ["en-US", "hi-IN"] etc. for genuinely
    /// multilingual archives.
    private let recognitionLanguages: [String]

    public init(recognitionLanguages: [String] = ["en-US"]) {
        self.recognitionLanguages = recognitionLanguages
    }

    public func recognizePrinted(at url: URL) async -> [String] {
        #if canImport(Vision) && canImport(AppKit)
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return [] }

        // Run OCR on all four right-angle rotations and keep the
        // result with the highest mean confidence. Scanned docs
        // (notary stamps, watermarks, official forms with rotated
        // headers) routinely have text at 90° / 180° / 270° relative
        // to the page; without rotation passes Vision reads it
        // mirrored / jumbled and language-correction makes it worse
        // (real case: "yino bebruH enO" came out for "One Hundred only"
        // because the stamp was upside-down).
        let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
        var bestText: [String] = []
        var bestConfidence: Float = -1
        for orientation in orientations {
            let (text, confidence) = recognize(
                cgImage: cgImage,
                orientation: orientation
            )
            if confidence > bestConfidence {
                bestConfidence = confidence
                bestText = text
            }
        }
        return bestText
        #else
        return []
        #endif
    }

    #if canImport(Vision)
    /// One OCR pass at the requested orientation. Returns recognized
    /// strings + mean confidence across all candidates, so the
    /// caller can pick the best-scoring orientation.
    private nonisolated func recognize(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation
    ) -> (text: [String], confidence: Float) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Pin the language so Vision doesn't drift into the user's
        // locale fallbacks. Language correction stays on — it helps
        // for in-language words; the wrong-language candidate
        // problem above is fixed by the explicit language pin, not
        // by disabling correction.
        request.recognitionLanguages = recognitionLanguages
        request.usesLanguageCorrection = true
        if #available(macOS 13.0, *) {
            request.automaticallyDetectsLanguage = false
        }
        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: orientation,
            options: [:]
        )
        do {
            try handler.perform([request])
            let observations = request.results ?? []
            var strings: [String] = []
            var totalConfidence: Float = 0
            var count = 0
            for obs in observations {
                guard let top = obs.topCandidates(1).first else { continue }
                strings.append(top.string)
                totalConfidence += top.confidence
                count += 1
            }
            let mean = count > 0 ? totalConfidence / Float(count) : 0
            return (strings, mean)
        } catch {
            return ([], 0)
        }
    }
    #endif

    public func recognizeHandwritten(at url: URL) async -> [String] {
        await recognizePrinted(at: url)
    }

    public func recognizeTable(at url: URL) async -> [[String]] {
        // Ported ocr-table-pipeline: deskew → column/row structure → per-cell
        // OCR → row×column grid (Apple-native, no third-party deps). Falls back
        // to one cell per printed line if no table structure is found.
        let result = await TableOCR(recognitionLanguages: recognitionLanguages).extract(at: url)
        if !result.isEmpty { return result.asRows() }
        let lines = await recognizePrinted(at: url)
        return lines.map { [$0] }
    }
}
