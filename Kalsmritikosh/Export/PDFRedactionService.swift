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
//  W0-2 — text inside images. With `scanImages` (default on), every page that
//  CONTAINS AN IMAGE is also read with on-device text recognition (pure-text pages
//  are fully covered by the text search above); a term found in a page image (a
//  scan, a stamp, a screenshot) is burned in like any other match, and every
//  flattened page is recognised again after redaction — a term still readable
//  there fails the whole operation closed. Recognition is configured like
//  VisionOCR (pinned language, no automatic language detection): detection loads
//  extra assets, which on a fresh machine could block indefinitely. The output is written into a fresh PDF context
//  with no document info, so the source's title/author/keywords never carry over.
//

import Foundation
import PDFKit
import CoreGraphics
import Vision

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
    /// F24 — the produced PDF could not be re-read (or lost pages), so nothing is verified.
    case verificationUnreadable
    /// W0-2 — on-device text recognition did not answer in time, so text inside page images
    /// can be neither found nor ruled out. Nothing is produced (fail closed).
    case imageTextRecognitionUnavailable

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
        case .verificationUnreadable:
            return "The redacted PDF could not be re-read to verify it, so no file was produced."
        case .imageTextRecognitionUnavailable:
            return "Text recognition did not respond, so text inside the page images could not be checked. No file was produced. Try again, or redact with image scanning off and review image pages yourself."
        }
    }
}

public struct PDFRedactionService: Sendable {

    /// Page rasteriser. Injectable ONLY so a test can force a render failure (F24); production
    /// always uses the built-in flatten.
    typealias Flattener = @Sendable (PDFPage, CGRect, [CGRect], CGFloat) -> CGImage?
    private let flattener: Flattener?

    public init() { self.flattener = nil }
    init(flattener: @escaping Flattener) { self.flattener = flattener }

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
        dpi: CGFloat = 200,
        scanImages: Bool = true
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
        // 1b) W0-2 — terms inside page images, found by on-device text recognition.
        var imageMatchCount = 0
        if scanImages {
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i), Self.pageHasImages(page) else { continue }
                let box = page.bounds(for: .mediaBox)
                guard let image = flatten(page: page, box: box, redacting: [], dpi: dpi) else { continue }
                guard let recognized = Self.recognizedTermRects(in: image, terms: cleanedTerms, caseSensitive: caseSensitive) else {
                    throw PDFRedactionError.imageTextRecognitionUnavailable
                }
                let found = recognized
                    .map { CGRect(x: box.minX + $0.minX * box.width, y: box.minY + $0.minY * box.height,
                                  width: $0.width * box.width, height: $0.height * box.height) }
                // Only boxes not already covered by a text-layer match count as new.
                let existing = rectsByPage[i] ?? []
                let new = found.filter { r in !existing.contains { $0.insetBy(dx: -2, dy: -2).contains(CGPoint(x: r.midX, y: r.midY)) } }
                if !new.isEmpty { rectsByPage[i, default: []].append(contentsOf: new); imageMatchCount += new.count }
            }
        }
        matchCount += imageMatchCount
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
            // F24 — a page that cannot be read is a failure, never a silently skipped page.
            guard let page = doc.page(at: i) else { throw PDFRedactionError.renderFailed }
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
                // F24 — a page that fails to flatten must not become a blank page in a
                // "verified" output: the redaction is refused.
                let image = flattener.map { $0(page, box, rects, dpi) } ?? flatten(page: page, box: box, redacting: rects, dpi: dpi)
                guard let image else { throw PDFRedactionError.renderFailed }
                ctx.draw(image, in: box)
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
        let leaks = try Self.residualTerms(in: produced, terms: cleanedTerms, caseSensitive: caseSensitive,
                                           expectedPageCount: doc.pageCount)
        if !leaks.isEmpty { throw PDFRedactionError.verificationLeak(leaks) }
        // W0-2 — and nothing is still READABLE in the flattened page images.
        if scanImages, let outDoc = PDFDocument(data: produced) {
            var imageLeaks = Set<String>()
            for i in rectsByPage.keys.sorted() {
                guard let page = outDoc.page(at: i) else { throw PDFRedactionError.verificationUnreadable }
                let box = page.bounds(for: .mediaBox)
                guard let image = flatten(page: page, box: box, redacting: [], dpi: dpi) else { throw PDFRedactionError.verificationUnreadable }
                for t in cleanedTerms {
                    guard let still = Self.recognizedTermRects(in: image, terms: [t], caseSensitive: caseSensitive) else {
                        throw PDFRedactionError.imageTextRecognitionUnavailable
                    }
                    if !still.isEmpty { imageLeaks.insert(t) }
                }
            }
            if !imageLeaks.isEmpty { throw PDFRedactionError.verificationLeak(imageLeaks.sorted()) }
        }

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

    /// W0-2 — true when the page draws at least one raster image (directly or inside a form
    /// XObject), i.e. when text could exist that the text layer does not carry.
    static func pageHasImages(_ page: PDFPage) -> Bool {
        guard let cgPage = page.pageRef, let dict = cgPage.dictionary else { return true }   // unknown → scan
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources else { return false }
        return resourcesHaveImages(resources, depth: 0)
    }

    private static func resourcesHaveImages(_ resources: CGPDFDictionaryRef, depth: Int) -> Bool {
        guard depth < 4 else { return true }                                   // deep nesting → scan
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return false }
        final class Box { var found = false; var depth = 0 }
        let box = Box(); box.depth = depth
        CGPDFDictionaryApplyBlock(xobjects, { _, object, info in
            guard let info else { return true }
            let b = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let sdict = CGPDFStreamGetDictionary(stream) else { return true }
            var subtype: UnsafePointer<CChar>?
            if CGPDFDictionaryGetName(sdict, "Subtype", &subtype), let subtype {
                let name = String(cString: subtype)
                if name == "Image" { b.found = true; return false }
                if name == "Form" {
                    var inner: CGPDFDictionaryRef?
                    if CGPDFDictionaryGetDictionary(sdict, "Resources", &inner), let inner,
                       PDFRedactionService.resourcesHaveImages(inner, depth: b.depth + 1) {
                        b.found = true; return false
                    }
                }
            }
            return true
        }, Unmanaged.passUnretained(box).toOpaque())
        return box.found
    }

    /// Longest a single recognition may take before it is cancelled. On a Mac with the Neural
    /// Engine a page takes well under a second; without it (some virtual machines) Vision can
    /// stall indefinitely, and a redaction must then fail closed, never hang.
    static let recognitionDeadline: TimeInterval = 90

    /// W0-2 — normalised boxes (origin lower-left) of every recognised occurrence of the terms in
    /// an image; nil when recognition did not finish within `recognitionDeadline`.
    static func recognizedTermRects(in image: CGImage, terms: [String], caseSensitive: Bool,
                                    deadline: TimeInterval = recognitionDeadline) -> [CGRect]? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false   // a name or number must be read as written
        // Same configuration as VisionOCR: a pinned language and no automatic detection, which
        // would load extra language assets (and could block on a machine that lacks them).
        request.recognitionLanguages = ["en-US"]
        request.automaticallyDetectsLanguage = false
        // Run on its own queue with a deadline; on timeout the request is cancelled and the
        // caller fails closed. (The caller's thread waits; it never runs Vision itself.)
        let done = DispatchSemaphore(value: 0)
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? handler.perform([request])
            done.signal()
        }
        if done.wait(timeout: .now() + deadline) == .timedOut {
            request.cancel()
            return nil
        }
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var out: [CGRect] = []
        for obs in request.results ?? [] {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let text = candidate.string
            for term in terms {
                var searchStart = text.startIndex
                while let r = text.range(of: term, options: options, range: searchStart..<text.endIndex) {
                    // Exact word box when Vision can give one; otherwise the whole line (over-redacts, never under).
                    let box = (try? candidate.boundingBox(for: r))?.boundingBox ?? obs.boundingBox
                    out.append(box)
                    searchStart = r.upperBound
                }
            }
        }
        return out
    }

    /// Build a per-page media-box dictionary for `beginPDFPage`.
    private func pageInfo(_ box: CGRect) -> CFDictionary {
        var b = box
        let data = Data(bytes: &b, count: MemoryLayout<CGRect>.size) as CFData
        return [kCGPDFContextMediaBox as String: data] as CFDictionary
    }

    /// Re-parse the produced PDF and return any protected term still present
    /// in its extractable text (should be empty).
    /// F24 — an output that cannot be re-parsed, or that lost pages, THROWS: returning "no
    /// residual terms" for an unreadable file reported `verified: true` for nothing verified.
    static func residualTerms(in data: Data, terms: [String], caseSensitive: Bool,
                              expectedPageCount: Int) throws -> [String] {
        guard let doc = PDFDocument(data: data), doc.pageCount == expectedPageCount else {
            throw PDFRedactionError.verificationUnreadable
        }
        let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        return terms.filter { !doc.findString($0, withOptions: options).isEmpty }
    }
}
