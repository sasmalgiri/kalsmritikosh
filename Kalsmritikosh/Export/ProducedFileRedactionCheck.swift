//
//  ProducedFileRedactionCheck.swift
//  Kalsmritikosh
//
//  Completion instructions 2026-10-29, B3 — redaction validation of an ACTUAL produced file, not a
//  stored text snapshot. The file's bytes are hashed (its identity), then every channel the file
//  carries is checked for the protected terms with `RedactionVerifier`: a PDF's text layer, its
//  document metadata, its annotations, and — on pages that draw images — the words OCR can read
//  from the rendered page. Embedded attachments are detected and reported as not inspected. A plain
//  text file has only its text. Every channel is listed as checked or not checked; a check that
//  could not run (OCR timed out) is never counted as clean.
//

import Foundation
import PDFKit
import CryptoKit

public nonisolated struct ProducedFileRedactionCheck: Sendable, Equatable {
    public let fileName: String
    public let sha256: String
    /// Channels checked ("text layer", "metadata", "annotations", "OCR of 2 image page(s)", "text").
    public let checked: [String]
    /// Channels present but not checked, with why.
    public let notChecked: [String]
    /// Each leak: the channel and the leak kind — never the protected term itself.
    public let leaks: [String]

    public var passed: Bool { leaks.isEmpty && notChecked.isEmpty }

    public enum CheckError: Error, LocalizedError, Equatable {
        case unreadable(String)
        public var errorDescription: String? {
            switch self { case .unreadable(let why): return "The produced file could not be checked: \(why)." }
        }
    }

    /// Check the file at `url` for `terms`. `ocr` false skips OCR (then reported as not checked).
    public static func check(fileAt url: URL, protectedTerms terms: [String], ocr: Bool = true) throws -> ProducedFileRedactionCheck {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw CheckError.unreadable(error.localizedDescription) }
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let verifier = RedactionVerifier()
        var checked: [String] = [], notChecked: [String] = [], leaks: [String] = []
        func scan(_ text: String, _ channel: String) {
            for leak in verifier.leaks(in: text, protectedTerms: terms, artifact: channel) {
                leaks.append("\(channel): \(leak.channel.rawValue)")
            }
        }
        if data.starts(with: Array("%PDF".utf8)) {
            guard let doc = PDFDocument(data: data) else { throw CheckError.unreadable("not a readable PDF") }
            scan(doc.string ?? "", "text layer"); checked.append("text layer")
            let meta = (doc.documentAttributes ?? [:]).values.compactMap { $0 as? String }.joined(separator: "\n")
            scan(meta, "metadata"); checked.append("metadata")
            var notes: [String] = []
            var imagePages: [Int] = []
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                notes += page.annotations.compactMap(\.contents)
                if PDFRedactionService.pageHasImages(page) { imagePages.append(i) }
            }
            scan(notes.joined(separator: "\n"), "annotations"); checked.append("annotations")
            if !imagePages.isEmpty {
                if !ocr {
                    notChecked.append("OCR of \(imagePages.count) image page(s): not run")
                } else {
                    var unfinished = 0
                    for i in imagePages {
                        guard let page = doc.page(at: i), let image = render(page) else { unfinished += 1; continue }
                        guard let hits = PDFRedactionService.recognizedTermRects(in: image, terms: terms, caseSensitive: false) else {
                            unfinished += 1; continue
                        }
                        if !hits.isEmpty { leaks.append("OCR page \(i + 1): \(hits.count) occurrence(s)") }
                    }
                    if unfinished > 0 { notChecked.append("OCR of \(unfinished) image page(s): recognition did not finish") }
                    if unfinished < imagePages.count { checked.append("OCR of \(imagePages.count - unfinished) image page(s)") }
                }
            }
            if data.range(of: Data("/EmbeddedFile".utf8)) != nil {
                notChecked.append("embedded attachments: present, not inspected — remove them or check them separately")
            }
        } else if let text = String(data: data, encoding: .utf8) {
            scan(text, "text"); checked.append("text")
        } else {
            throw CheckError.unreadable("only PDF and text files can be checked")
        }
        return ProducedFileRedactionCheck(fileName: url.lastPathComponent, sha256: sha, checked: checked, notChecked: notChecked, leaks: leaks)
    }

    /// A page rendered at 150 dpi for OCR.
    static func render(_ page: PDFPage) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        let scale: CGFloat = 150 / 72
        let w = max(1, Int(box.width * scale)), h = max(1, Int(box.height * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }
}
