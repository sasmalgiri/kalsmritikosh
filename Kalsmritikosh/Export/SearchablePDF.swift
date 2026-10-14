//
//  SearchablePDF.swift
//  Kalsmritikosh
//
//  W4-1 — searchable-PDF export of a scanned PDF or photo: each page is drawn as
//  its image and Apple's on-device text recognition (accurate, language pinned,
//  as in VisionOCR) adds an invisible text layer positioned over the words, so
//  the copy can be searched and selected in any PDF reader. One page is held in
//  memory at a time. The original file is never changed.
//

import Foundation
import CoreGraphics
import CoreText
import Vision
import PDFKit
import AppKit

public nonisolated enum SearchablePDF {

    public struct Result: Sendable {
        public let pages: Int
        public let recognizedLines: Int
        public let meanConfidence: Double
    }

    public enum Failure: LocalizedError {
        case unreadable, cannotWrite
        public var errorDescription: String? {
            switch self {
            case .unreadable: return "The file could not be opened as a PDF or image."
            case .cannotWrite: return "The searchable PDF could not be written."
            }
        }
    }

    /// Recognised lines of one page image: text + normalised box (origin lower-left) + confidence.
    static func recognize(_ image: CGImage, languages: [String]) -> [(String, CGRect, Float)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = false
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch { return [] }
        return (request.results ?? []).compactMap { obs in
            guard let top = obs.topCandidates(1).first else { return nil }
            return (top.string, obs.boundingBox, top.confidence)
        }
    }

    /// Page images, rendered one at a time (300 dpi for PDFs).
    static func forEachPage(of url: URL, _ body: (CGImage, CGSize) throws -> Void) throws -> Int {
        if url.pathExtension.lowercased() == "pdf" {
            guard let doc = PDFDocument(url: url) else { throw Failure.unreadable }
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                let box = page.bounds(for: .mediaBox)
                let scale: CGFloat = 300 / 72
                let size = CGSize(width: box.width * scale, height: box.height * scale)
                try autoreleasepool {
                    let ns = page.thumbnail(of: size, for: .mediaBox)
                    guard let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                    try body(cg, box.size)
                }
            }
            return doc.pageCount
        }
        guard let ns = NSImage(contentsOf: url), let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw Failure.unreadable
        }
        // Photos: one page at 72 points per 300 pixels so print size stays sensible.
        try body(cg, CGSize(width: CGFloat(cg.width) * 72 / 300, height: CGFloat(cg.height) * 72 / 300))
        return 1
    }

    public static func make(from source: URL, to destination: URL, languages: [String] = ["en-US"]) throws -> Result {
        guard let consumer = CGDataConsumer(url: destination as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw Failure.cannotWrite }
        var lines = 0
        var confidenceSum: Double = 0
        let pages = try forEachPage(of: source) { image, size in
            var box = CGRect(origin: .zero, size: size)
            ctx.beginPage(mediaBox: &box)
            ctx.draw(image, in: box)
            ctx.saveGState()
            ctx.setTextDrawingMode(.invisible)
            for (text, norm, conf) in recognize(image, languages: languages) {
                let rect = CGRect(x: norm.minX * size.width, y: norm.minY * size.height,
                                  width: norm.width * size.width, height: norm.height * size.height)
                let font = CTFontCreateWithName("Helvetica" as CFString, max(rect.height * 0.9, 1), nil)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font]))
                let natural = CTLineGetTypographicBounds(line, nil, nil, nil)
                ctx.saveGState()
                ctx.translateBy(x: rect.minX, y: rect.minY + rect.height * 0.15)
                // Stretch the invisible line to the word box so selection matches the image.
                if natural > 0 { ctx.scaleBy(x: rect.width / natural, y: 1) }
                ctx.textPosition = .zero
                CTLineDraw(line, ctx)
                ctx.restoreGState()
                lines += 1; confidenceSum += Double(conf)
            }
            ctx.restoreGState()
            ctx.endPage()
        }
        ctx.closePDF()
        guard FileManager.default.fileExists(atPath: destination.path) else { throw Failure.cannotWrite }
        return Result(pages: pages, recognizedLines: lines, meanConfidence: lines > 0 ? confidenceSum / Double(lines) : 0)
    }
}
