//
//  PDFLoader.swift
//  Kalsmritikosh
//
//  PDFKit-backed text extraction with per-page OCR fallback. Pages whose
//  native text is empty are rendered to NSImage and handed to VisionOCR.
//

import Foundation
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(AppKit)
import AppKit
#endif

public struct PDFLoader: Ingestor {
    public let supportedTypes: Set<SourceType> = [.pdf]
    private let ocr: VisionOCR

    public nonisolated init(ocr: VisionOCR = VisionOCR()) {
        self.ocr = ocr
    }

    public func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
        #if canImport(PDFKit)
        guard let document = PDFDocument(url: url) else {
            throw IngestorError.unreadable(url, underlying: nil)
        }
        var combined = ""
        var pageOffsets: [Int] = []
        var ocrPagesUsed = 0

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            pageOffsets.append(combined.count)

            let nativeText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Trigger OCR when the native text layer is empty OR when it
            // looks like mojibake (PDFs with reversed font encoding or
            // broken CMaps return non-empty but unreadable strings like
            // "JADIGUL ОЙ АІДИІ" / "qтБ32-9" — observed on Final POA.pdf).
            if !nativeText.isEmpty && !Self.looksLikeMojibake(nativeText) {
                combined.append(nativeText)
                if !nativeText.hasSuffix("\n") { combined.append("\n") }
                continue
            }

            // Fallback: render the page and OCR it.
            #if canImport(AppKit)
            let ocrText = await renderAndOCR(page: page, index: index)
            if !ocrText.isEmpty {
                combined.append(ocrText)
                if !ocrText.hasSuffix("\n") { combined.append("\n") }
                ocrPagesUsed += 1
            } else if !nativeText.isEmpty {
                // OCR failed too — keep the mojibake so the file is at least
                // tracked and downstream search-by-filename still works.
                combined.append(nativeText)
                if !nativeText.hasSuffix("\n") { combined.append("\n") }
            }
            #endif
        }

        if combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw IngestorError.empty(url)
        }

        return KnowledgeObject(
            sourceFile: url,
            sourceType: type,
            content: combined,
            metadata: [
                "filename": AnyCodable(.string(url.lastPathComponent)),
                "pageCount": AnyCodable(.int(Int64(document.pageCount))),
                "ocrPagesUsed": AnyCodable(.int(Int64(ocrPagesUsed)))
            ]
        )
        #else
        throw IngestorError.unsupportedType(type)
        #endif
    }

    /// Heuristic mojibake detector — flags PDF page text that's
    /// technically non-empty but has been mangled by a reversed font
    /// encoding or broken CMap. PDFKit returns characters from real
    /// Unicode blocks (so the per-letter checks pass), but the WORDS
    /// don't form real text — they're scrambled letter sequences that
    /// hit no common bigrams in any natural language.
    ///
    /// Six independent signals are computed; if 2+ trigger, the text
    /// is flagged. This keeps false positives low on bilingual or
    /// non-English real text (Cyrillic prose, Devanagari prose, short
    /// English forms) while reliably catching observed Final POA.pdf
    /// extracts where the font CMap is broken.
    static func looksLikeMojibake(_ text: String) -> Bool {
        guard text.count >= 40 else { return false }
        var totalChars = 0
        var letters = 0
        var uppercaseLetters = 0
        var readableLetters = 0
        var tokenCount = 0
        var shortTokens = 0  // 1-2 chars
        var hasLatinInToken = false
        var hasCyrillicInToken = false
        var mixedScriptTokens = 0
        var currentTokenLength = 0
        var inToken = false

        let lower = text.lowercased()

        for ch in text {
            if ch.isWhitespace || ch.isNewline {
                if inToken {
                    tokenCount += 1
                    if currentTokenLength <= 2 { shortTokens += 1 }
                    if hasLatinInToken && hasCyrillicInToken { mixedScriptTokens += 1 }
                }
                inToken = false
                hasLatinInToken = false
                hasCyrillicInToken = false
                currentTokenLength = 0
                totalChars += 1
                continue
            }
            inToken = true
            currentTokenLength += 1
            totalChars += 1
            if ch.isLetter {
                letters += 1
                if ch.isUppercase { uppercaseLetters += 1 }
                for scalar in ch.unicodeScalars {
                    let v = scalar.value
                    if (0x0041...0x007A).contains(v) || (0x00C0...0x024F).contains(v) {
                        readableLetters += 1
                        hasLatinInToken = true
                        break
                    }
                    if (0x0900...0x0D7F).contains(v) {  // Devanagari / Bengali / Tamil / Gujarati / etc.
                        readableLetters += 1
                        break
                    }
                    if (0x0400...0x04FF).contains(v) {  // Cyrillic
                        readableLetters += 1
                        hasCyrillicInToken = true
                        break
                    }
                }
            }
        }
        if inToken {
            tokenCount += 1
            if currentTokenLength <= 2 { shortTokens += 1 }
            if hasLatinInToken && hasCyrillicInToken { mixedScriptTokens += 1 }
        }
        guard totalChars > 0, letters > 0, tokenCount > 0 else { return false }

        let letterDensity = Double(letters) / Double(totalChars)
        let readableRatio = Double(readableLetters) / Double(letters)
        let uppercaseRatio = Double(uppercaseLetters) / Double(letters)
        let shortTokenRatio = Double(shortTokens) / Double(tokenCount)

        // Common bigrams across Latin, Cyrillic, Devanagari. Real text in
        // any of these scripts hits dozens; mojibake hits a handful.
        let bigramSet: Set<String> = [
            "th", "he", "in", "er", "an", "re", "on", "at", "en", "es",
            "or", "is", "of", "to", "ng", "ed", "nd", "ha", "se", "le",
            "ст", "но", "то", "на", "по", "ра", "ко", "ро", "ен", "ни",
            "की", "के", "का", "है", "हो", "ने", "मे", "से", "और", "जा"
        ]
        // Substring search rather than char[i..i+1] indexing: Devanagari
        // grapheme clusters ("की" = क + ी combining) count as ONE Swift
        // Character, so the Array(lower) approach never finds Hindi
        // bigrams and false-positives Hindi prose as mojibake.
        var bigramHits = 0
        for bigram in bigramSet {
            var searchRange = lower.startIndex..<lower.endIndex
            while let found = lower.range(of: bigram, range: searchRange) {
                bigramHits += 1
                searchRange = found.upperBound..<lower.endIndex
            }
        }
        let bigramDensity = Double(bigramHits) / Double(max(1, totalChars))

        var signals = 0
        if mixedScriptTokens >= 1 { signals += 1 }
        if letterDensity < 0.45 { signals += 1 }
        if readableRatio < 0.7 { signals += 1 }
        if uppercaseRatio > 0.6 { signals += 1 }
        if shortTokenRatio > 0.4 { signals += 1 }
        if bigramDensity < 0.025 { signals += 1 }
        // Require 3 corroborating signals so isolated quirks (a Hindi-only
        // page that happens to have many 2-char words, an all-caps invoice
        // header) don't trigger false positives. Final POA's page 1
        // ("JADIGUL ОЙ АІДИІ qтБ32-9 УВИТА ЧІ СИ ЗТА АНАН ...") hits 4-5.
        return signals >= 3
    }

    #if canImport(AppKit) && canImport(PDFKit)
    private func renderAndOCR(page: PDFPage, index: Int) async -> String {
        let bounds = page.bounds(for: .mediaBox)
        let size = NSSize(width: bounds.width * 2, height: bounds.height * 2)
        let image = NSImage(size: size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 2.0, y: -2.0)
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
        }
        image.unlockFocus()

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("atlas-pdfpage-\(UUID().uuidString).png")
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return ""
        }
        do { try png.write(to: tmp) } catch { return "" }
        defer { try? FileManager.default.removeItem(at: tmp) }
        return (await ocr.recognizePrinted(at: tmp)).joined(separator: "\n")
    }
    #endif
}
