//
//  PDFReportWriter.swift
//  Kalsmritikosh
//
//  Native PDF rendering of a work product using CoreGraphics + CoreText — no third-party library, fully
//  offline, on-device. Value-in (ExportableDocument) / Data-out. It lays the document out as an attributed
//  string (title, subtitle, disclaimer, prose sections, the optional table as tab-aligned rows, the sources
//  list, and the manifest block) and paginates it across US-Letter pages with a CTFramesetter, so long reports
//  flow onto as many pages as needed. The rendered PDF carries the same content as every other export format.
//

import Foundation
import CoreGraphics
import CoreText

public enum PDFReportWriter {

    public static func render(_ doc: ExportableDocument) -> Data {
        let attr = attributedString(for: doc)
        let pageWidth: CGFloat = 612, pageHeight: CGFloat = 792, margin: CGFloat = 54
        let contentRect = CGRect(x: margin, y: margin, width: pageWidth - 2 * margin, height: pageHeight - 2 * margin)
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return Data()
        }
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        let total = attr.length
        var start = 0
        let path = CGPath(rect: contentRect, transform: nil)

        // Always emit at least one page; then continue until the whole string is consumed.
        repeat {
            ctx.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            let visible = CTFrameGetVisibleStringRange(frame)
            ctx.endPDFPage()
            if visible.length <= 0 { break }          // nothing more fits / nothing left — stop
            start += visible.length
        } while start < total
        ctx.closePDF()
        return out as Data
    }

    // MARK: - Attributed content

    private static func attributedString(for doc: ExportableDocument) -> NSAttributedString {
        let s = NSMutableAttributedString()
        s.append(line(doc.title, size: 20, bold: true))
        if let sub = doc.subtitle { s.append(line(sub, size: 12, italic: true)) }
        if let d = doc.disclaimer { s.append(line(d, size: 10, italic: true)) }
        s.append(line("", size: 10))
        for section in doc.sections {
            s.append(line(section.title, size: 14, bold: true))
            for p in section.paragraphs { s.append(line(p, size: 11)) }
            s.append(line("", size: 6))
        }
        if let table = doc.table {
            s.append(line(table.title, size: 14, bold: true))
            s.append(line(table.columns.joined(separator: "\t"), size: 10, bold: true))
            for row in table.rows {
                let padded = row.count >= table.columns.count
                    ? Array(row.prefix(table.columns.count))
                    : row + Array(repeating: "", count: table.columns.count - row.count)
                s.append(line(padded.joined(separator: "\t"), size: 10))
            }
            s.append(line("", size: 6))
        }
        if !doc.citations.isEmpty {
            s.append(line("Sources", size: 14, bold: true))
            for (i, c) in doc.citations.enumerated() {
                s.append(line(CitationRenderer.render(c, style: doc.citationStyle, index: i + 1), size: 10))
            }
            s.append(line("", size: 6))
        }
        s.append(line("Manifest", size: 14, bold: true))
        for l in doc.manifest.toMarkdown().split(separator: "\n", omittingEmptySubsequences: false) {
            s.append(line(String(l), size: 9))
        }
        return s
    }

    private static func line(_ text: String, size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSAttributedString {
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        let base = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let font = traits.isEmpty ? base : (CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base)
        // CoreText-native attribute keys (CTFramesetter reads these) — avoids an AppKit dependency.
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        ]
        return NSAttributedString(string: text + "\n", attributes: attrs)
    }
}
