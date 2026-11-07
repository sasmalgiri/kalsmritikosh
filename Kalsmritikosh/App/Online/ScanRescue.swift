//
//  ScanRescue.swift
//  Kalsmritikosh
//
//  A4 (completion mandate 2026-11-01) — “Read with AI” for a scanned PDF or image that the Mac's own
//  text recognition could not read (Sources ▸ Needs attention). The pages are rendered here, read by
//  the Online provider the person chose (their own key, or AI Included) through the usual consent and
//  outbound record, and the transcription is added as its own document:
//
//    “<original name> — AI transcription.txt”, headed with what it is, which file and pages it came
//    from, which model read it and when, and that it must be checked against the original.
//
//  The original file is never changed, and the transcription never stands in for it silently: it is a
//  separate, clearly named source that cites the original, so every answer built on it says where its
//  text came from.
//

import Foundation
import AppKit
import PDFKit
import CryptoKit
import os

nonisolated enum ScanRescue {
    /// Pages read per request (keeps each reply within AI Included's output ceiling).
    static let pagesPerRequest = 4
    /// The longest file read this way; longer ones are read up to here and say so.
    static let maxPages = 40
    /// Long side of a page image: Claude reads text well at this size without resampling it.
    static let maxPixels: CGFloat = 1568

    enum RescueError: Error, LocalizedError, Equatable {
        case notReadable(String), nothingReturned
        var errorDescription: String? {
            switch self {
            case .notReadable(let name): return "\(name) could not be opened as a PDF or an image, so there is nothing to send."
            case .nothingReturned: return "The AI returned no text for these pages. Nothing was added."
            }
        }
    }

    /// The pages of `url` as JPEG images (at most `maxPages`), plus how many pages the file has.
    static func pageImages(of url: URL) throws -> (images: [OutboundImage], totalPages: Int) {
        if url.pathExtension.lowercased() == "pdf" {
            guard let doc = PDFDocument(url: url) else { throw RescueError.notReadable(url.lastPathComponent) }
            var out: [OutboundImage] = []
            for i in 0..<min(doc.pageCount, maxPages) {
                guard let page = doc.page(at: i) else { continue }
                let bounds = page.bounds(for: .mediaBox)
                let scale = min(maxPixels / max(bounds.width, bounds.height), 4)
                let image = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
                if let jpeg = jpeg(image) { out.append(OutboundImage(mediaType: "image/jpeg", data: jpeg, label: "page \(i + 1)")) }
            }
            return (out, doc.pageCount)
        }
        guard let image = NSImage(contentsOf: url), let jpeg = jpeg(image, fit: maxPixels) else {
            throw RescueError.notReadable(url.lastPathComponent)
        }
        return ([OutboundImage(mediaType: "image/jpeg", data: jpeg, label: "page 1")], 1)
    }

    static func jpeg(_ image: NSImage, fit: CGFloat? = nil) -> Data? {
        guard var cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        if let fit, CGFloat(max(cg.width, cg.height)) > fit {
            let s = fit / CGFloat(max(cg.width, cg.height))
            let w = Int(CGFloat(cg.width) * s), h = Int(CGFloat(cg.height) * s)
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let scaled = ctx.makeImage() else { return nil }
            cg = scaled
        }
        return NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    /// The transcription document's text: a header that says exactly what it is, then the pages.
    static func document(original: URL, originalSHA256: String, provider: String, model: String,
                         pagesRead: Int, totalPages: Int, at date: Date, body: String) -> String {
        let df = ISO8601DateFormatter()
        var head = """
        AI TRANSCRIPTION — NOT THE ORIGINAL DOCUMENT
        Original file: \(original.lastPathComponent)
        Original SHA-256: \(originalSHA256)
        Read by: \(provider), model \(model), on \(df.string(from: date))
        Pages read: \(pagesRead) of \(totalPages)
        """
        if pagesRead < totalPages {
            head += "\nPages \(pagesRead + 1)–\(totalPages) were not read (limit \(maxPages) pages per file)."
        }
        head += "\nThe Mac's own text recognition could not read this file. This text was produced by an AI model from page images; check every quotation, name, number and date against the original before relying on it. [illegible] and [uncertain: …] mark what the model could not read with confidence.\n\n"
        return head + body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// Where transcriptions are kept (inside the app's own container).
    static func folder() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("AI transcriptions", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func fileName(for original: URL) -> String {
        "\(original.deletingPathExtension().lastPathComponent) — AI transcription.txt"
    }

    static func sha256(of url: URL) -> String {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return "unavailable" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
