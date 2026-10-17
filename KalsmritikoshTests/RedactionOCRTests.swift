//
//  RedactionOCRTests.swift
//  KalsmritikoshTests
//
//  W0-2 — a protected term that exists ONLY inside a page image (no text layer) is found
//  by on-device text recognition, burned in, and verified gone; pure-text pages are not
//  OCR'd at all (the text layer already covers them).
//

import Foundation
import AppKit
import PDFKit
import CoreGraphics
import Testing
@testable import Kalsmritikosh

/// Whether on-device text recognition answers on this machine (it can stall on runners without
/// the Neural Engine). Probed once with a short deadline.
enum TextRecognitionProbe {
    static let works: Bool = {
        let size = 64
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = ctx.makeImage() else { return false }
        return PDFRedactionService.recognizedTermRects(in: image, terms: ["x"], caseSensitive: false, deadline: 20) != nil
    }()
}

@Suite("W0-2 redaction of text inside images")
struct RedactionOCRTests {
    /// A raster image of `text` in large black type on white.
    private func textImage(_ text: String) throws -> CGImage {
        let size = NSSize(width: 1400, height: 260)
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        (text as NSString).draw(at: NSPoint(x: 40, y: 80),
                                withAttributes: [.font: NSFont.systemFont(ofSize: 110, weight: .bold), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        return try #require(rep.cgImage)
    }

    /// Page 1: only an IMAGE of the text. Page 2: ordinary selectable text, no image.
    private func makePDF(imageText: String, layerText: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("redact-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        ctx.draw(try textImage(imageText), in: CGRect(x: 36, y: 500, width: 540, height: 100))
        ctx.endPDFPage()
        ctx.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        (layerText as NSString).draw(at: NSPoint(x: 72, y: 700), withAttributes: [.font: NSFont.systemFont(ofSize: 18)])
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    @Test func pagesWithImagesAreTheOnlyOnesScanned() throws {
        let url = try makePDF(imageText: "MEERA IYER", layerText: "Plain selectable text only.")
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try #require(PDFDocument(url: url))
        #expect(PDFRedactionService.pageHasImages(try #require(doc.page(at: 0))))
        #expect(!PDFRedactionService.pageHasImages(try #require(doc.page(at: 1))))
    }

    /// Recognition that does not answer in time reports "unknown" (nil) — never "nothing found",
    /// which would let an unverified image page through.
    @Test func recognitionPastItsDeadlineIsUnknownNotEmpty() throws {
        let image = try textImage("DEADLINE")
        #expect(PDFRedactionService.recognizedTermRects(in: image, terms: ["DEADLINE"], caseSensitive: false, deadline: 0) == nil)
    }

    @Test(.timeLimit(.minutes(3)), .enabled(if: TextRecognitionProbe.works, "text recognition does not answer on this machine"))
    func aTermOnlyInsideAnImageIsFoundBurnedInAndVerified() throws {
        let url = try makePDF(imageText: "MEERA IYER", layerText: "Plain selectable text only.")
        defer { try? FileManager.default.removeItem(at: url) }
        // The text layer has no trace of the term — only recognition can find it.
        let doc = try #require(PDFDocument(url: url))
        #expect(doc.findString("MEERA", withOptions: [.caseInsensitive]).isEmpty)

        let result = try PDFRedactionService().redact(source: url, terms: ["Meera Iyer"])
        #expect(result.matchCount >= 1)
        #expect(result.redactedPageCount == 1)
        #expect(result.verified)
        // Re-read the output page as an image: the term is no longer readable.
        let out = try #require(PDFDocument(data: result.data))
        #expect(out.pageCount == 2)
        #expect(out.page(at: 1)?.string?.contains("Plain selectable text only.") == true)   // clean page kept as text
    }
}
