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

    public init() {}

    public func recognizePrinted(at url: URL) async -> [String] {
        #if canImport(Vision) && canImport(AppKit)
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        } catch {
            return []
        }
        #else
        return []
        #endif
    }

    public func recognizeHandwritten(at url: URL) async -> [String] {
        await recognizePrinted(at: url)
    }

    public func recognizeTable(at url: URL) async -> [[String]] {
        let lines = await recognizePrinted(at: url)
        return lines.map { $0.split(separator: "\t").map(String.init) }
    }
}
