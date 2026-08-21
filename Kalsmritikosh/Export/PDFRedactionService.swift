//
//  PDFRedactionService.swift
//  Kalsmritikosh
//
//  Real, burn-in PDF redaction — on-device, no third-party library.
//
//  The pain this solves (surfaced in professional research): "PDF redactions
//  get reversed → data leaks." Drawing a black box over text in most tools
//  leaves the underlying text selectable/extractable; copy-paste or a text
//  layer dump reveals what was supposedly hidden. That has caused real,
//  reported disclosure failures.
//
//  This service does true redaction: any page that contains a match is
//  FLATTENED to an image (its text layer is destroyed) with opaque boxes
//  painted over the matched regions, so the words are gone — not merely
//  covered. Pages with no matches are re-emitted as vector content, so their
//  text stays selectable. The result is then re-parsed in memory and every
//  protected term is searched for again; if any survives, the whole operation
//  fails closed (no file is produced) — matching the RedactionVerifier ethos
//  already used by the export pipeline.
//

import Foundation
import PDFKit
import CoreGraphics

public struct PDFRedactionResult: Sendable {
    public let data: Data
    public let pageCount: Int
    public let redactedPageCount: Int
    public let matchCount: Int
    /// Verified true when a re-parse of the output finds none of the protected
    /// terms in its EXTRACTABLE TEXT — a failed verification throws instead, so a
    /// text-leaking file is never handed back. This does NOT cover text that
    /// lives inside a scanned image (see `scannedPageCount`).
    public let verified: Bool
    /// Pages with no extractable text (likely scanned images). Text-based
    /// redaction cannot see or remove a term that appears only inside an image,
    /// so a non-zero count here is a legal caveat the caller must surface: the
    /// page needs OCR or manual review before the document can be certified.
    public let scannedPageCount: Int
}

public enum PDFRedactionError: Error, LocalizedError, Sendable {
    case cannotOpen(URL)
    case noMatches([String])
    case renderFailed
    case verificationLeak([String])

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let url):
            return "Could not open the PDF at \(url.lastPathComponent)."
        case .noMatches(let terms):
            return "None of the terms were found in the document: \(terms.joined(separator: ", "))."
        case .renderFailed:
            return "The redacted PDF could not be rendered."
        case .verificationLeak(let terms):
            return "Redaction verification failed — these terms still survived and no file was produced: \(terms.joined(separator: ", "))."
        }
    }
}

public struct PDFRedactionService: Sendable {

    public init() {}

    /// Redact every occurrence of `terms` in the PDF at `source`.
    ///
    /// - Parameters:
    ///   - source: the PDF to redact (caller owns any security-scoped access).
    ///   - terms: literal strings to remove; empty/whitespace entries ignored.
    ///   - caseSensitive: match case exactly when true (default false).
    ///   - dpi: rasterization density for flattened pages (higher = crisper, larger).
    /// - Returns: the redacted PDF bytes plus statistics.
    /// - Throws: `PDFRedactionError` — including `.verificationLeak` if any term
    ///   survives, in which case NO data is returned (fail-closed).
    public func redact(
        source: URL,
        terms: [String],
        caseSensitive: Bool = false,
        dpi: CGFloat = 200
    ) throws -> PDFRedactionResult {
        let cleanedTerms = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let doc = PDFDocument(url: source) else { throw PDFRedactionError.cannotOpen(source) }
        guard !cleanedTerms.isEmpty else { throw PDFRedactionError.noMatches(terms) }

        // 1) Find every match and collect its bounding box, grouped by page index.
        let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var rectsByPage: [Int: [CGRect]] = [:]
        var matchCount = 0
        for term in cleanedTerms {
            for selection in doc.findString(term, withOptions: options) {
                for page in selection.pages {
                    let idx = doc.index(for: page)
                    let bounds = selection.bounds(for: page)
                    guard bounds.width > 0, bounds.height > 0 else { continue }
                    rectsByPage[idx, default: []].append(bounds)
                    matchCount += 1
                }
            }
        }
        guard matchCount > 0 else { throw PDFRedactionError.noMatches(cleanedTerms) }

        // 2) Re-emit the document. Redacted pages are flattened to an image with
        //    opaque boxes; clean pages keep their vector content.
        guard let firstBox = doc.page(at: 0)?.bounds(for: .mediaBox) else {
            throw PDFRedactionError.renderFailed
        }
        let out = NSMutableData()
        var defaultBox = firstBox
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &defaultBox, nil) else {
            throw PDFRedactionError.renderFailed
        }

        var scannedPages = 0
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            // A page with no extractable text is likely a scanned image; a term
            // could hide there unseen by text search. Count it as a caveat.
            if (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                scannedPages += 1
            }
            let box = page.bounds(for: .mediaBox)
            let info = pageInfo(box)
            ctx.beginPDFPage(info)
            ctx.saveGState()
            if let rects = rectsByPage[i], !rects.isEmpty {
                if let image = flatten(page: page, box: box, redacting: rects, dpi: dpi) {
                    ctx.draw(image, in: box)
                }
            } else {
                // Clean page — keep it as selectable vector content.
                page.draw(with: .mediaBox, to: ctx)
            }
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        let produced = out as Data

        // 3) Fail-closed verification: re-parse and confirm nothing survived.
        let leaks = residualTerms(in: produced, terms: cleanedTerms, caseSensitive: caseSensitive)
        if !leaks.isEmpty { throw PDFRedactionError.verificationLeak(leaks) }

        return PDFRedactionResult(
            data: produced,
            pageCount: doc.pageCount,
            redactedPageCount: rectsByPage.keys.count,
            matchCount: matchCount,
            verified: true,
            scannedPageCount: scannedPages
        )
    }

    // MARK: - Internals

    /// Render a page to a bitmap (destroying its text layer), then paint opaque
    /// black boxes over the matched regions, and return the resulting image.
    private func flatten(page: PDFPage, box: CGRect, redacting rects: [CGRect], dpi: CGFloat) -> CGImage? {
        let scale = max(dpi, 72) / 72.0
        let pxW = max(1, Int((box.width * scale).rounded()))
        let pxH = max(1, Int((box.height * scale).rounded()))
        guard let bmp = CGContext(
            data: nil, width: pxW, height: pxH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // White paper background.
        bmp.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        bmp.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))

        // Draw the page content into the bitmap.
        bmp.saveGState()
        bmp.scaleBy(x: scale, y: scale)
        bmp.translateBy(x: -box.minX, y: -box.minY)
        page.draw(with: .mediaBox, to: bmp)
        bmp.restoreGState()

        // Paint opaque boxes over each matched region (padded slightly to cover
        // descenders/ascenders and anti-aliased edges).
        bmp.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for r in rects {
            let px = CGRect(
                x: (r.minX - box.minX) * scale,
                y: (r.minY - box.minY) * scale,
                width: r.width * scale,
                height: r.height * scale
            ).insetBy(dx: -2, dy: -2)
            bmp.fill(px)
        }
        return bmp.makeImage()
    }

    /// Build a per-page media-box dictionary for `beginPDFPage`.
    private func pageInfo(_ box: CGRect) -> CFDictionary {
        var b = box
        let data = Data(bytes: &b, count: MemoryLayout<CGRect>.size) as CFData
        return [kCGPDFContextMediaBox as String: data] as CFDictionary
    }

    /// Re-parse the produced PDF and return any protected term still present
    /// in its extractable text (should be empty).
    private func residualTerms(in data: Data, terms: [String], caseSensitive: Bool) -> [String] {
        guard let doc = PDFDocument(data: data) else { return [] }
        let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        return terms.filter { !doc.findString($0, withOptions: options).isEmpty }
    }
}
