//
//  DocumentExporter.swift
//  Kalsmritikosh
//
//  Writes parsed content out to real document formats — PDF, RTF, PNG, and
//  genuine .docx / .xlsx (OOXML over ZipWriter) — using only Apple frameworks
//  (no third-party dependencies). Fidelity is text-level: paragraphs, cells,
//  and basic styling, not original layout. Pairs with the loaders (which read
//  these formats) to give Convert round-trip coverage.
//

import Foundation
#if canImport(AppKit)
import AppKit
#endif
import CoreText
import CoreGraphics

public struct ExportRecord: Sendable {
    public let title: String
    public let sourceType: String
    public let text: String
    public init(title: String, sourceType: String, text: String) {
        self.title = title
        self.sourceType = sourceType
        self.text = text
    }
}

public enum DocumentExporter {

    // MARK: - RTF (opens editable in Word/Pages)

    public static func rtf(_ records: [ExportRecord]) -> Data? {
        #if canImport(AppKit)
        let attr = attributedBody(records)
        return attr.rtf(from: NSRange(location: 0, length: attr.length),
                        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        #else
        return nil
        #endif
    }

    // MARK: - PDF (CoreText paginated)

    public static func pdf(_ records: [ExportRecord]) -> Data? {
        #if canImport(AppKit)
        let full = attributedBody(records)
        guard full.length > 0 else { return nil }
        let pageSize = CGSize(width: 612, height: 792)   // US Letter
        let margin: CGFloat = 48
        let textRect = CGRect(x: margin, y: margin,
                              width: pageSize.width - 2 * margin,
                              height: pageSize.height - 2 * margin)
        let outData = NSMutableData()
        guard let consumer = CGDataConsumer(data: outData) else { return nil }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        let framesetter = CTFramesetterCreateWithAttributedString(full as CFAttributedString)
        let path = CGPath(rect: textRect, transform: nil)
        var start = 0
        let total = full.length
        var guardPages = 0
        while start < total && guardPages < 5_000 {
            guardPages += 1
            ctx.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            let visible = CTFrameGetVisibleStringRange(frame)
            ctx.endPDFPage()
            if visible.length <= 0 { break }   // no progress — stop
            start += visible.length
        }
        ctx.closePDF()
        return outData as Data
        #else
        return nil
        #endif
    }

    // MARK: - PNG (text rendered to an image)

    public static func png(_ records: [ExportRecord]) -> Data? {
        #if canImport(AppKit)
        let full = attributedBody(records)
        guard full.length > 0 else { return nil }
        let width: CGFloat = 800
        let inset: CGFloat = 24
        let bounds = full.boundingRect(
            with: CGSize(width: width - 2 * inset, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let height = min(max(ceil(bounds.height) + 2 * inset, 200), 20_000)
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        full.draw(with: NSRect(x: inset, y: inset, width: width - 2 * inset, height: height - 2 * inset),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return png
        #else
        return nil
        #endif
    }

    // MARK: - DOCX (real OOXML)

    public static func docx(_ records: [ExportRecord]) -> Data {
        var body = ""
        for r in records {
            body += paragraph(r.title, bold: true)
            if !r.sourceType.isEmpty { body += paragraph(r.sourceType.uppercased(), bold: false, italic: true) }
            for line in r.text.components(separatedBy: "\n") {
                body += paragraph(line, bold: false)
            }
            body += paragraph("", bold: false)   // spacer
        }
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body)<w:sectPr/></w:body></w:document>
        """
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
        """
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """
        let docRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>
        """
        return ZipWriter().archive([
            .init(path: "[Content_Types].xml", data: Data(contentTypes.utf8)),
            .init(path: "_rels/.rels", data: Data(rels.utf8)),
            .init(path: "word/document.xml", data: Data(document.utf8)),
            .init(path: "word/_rels/document.xml.rels", data: Data(docRels.utf8))
        ])
    }

    private static func paragraph(_ text: String, bold: Bool, italic: Bool = false) -> String {
        let runProps = (bold || italic)
            ? "<w:rPr>\(bold ? "<w:b/>" : "")\(italic ? "<w:i/>" : "")</w:rPr>"
            : ""
        return "<w:p><w:r>\(runProps)<w:t xml:space=\"preserve\">\(xmlEscape(text))</w:t></w:r></w:p>"
    }

    // MARK: - XLSX (real OOXML, inline strings)

    /// One row per record with columns File | Source type | Content.
    public static func xlsx(_ records: [ExportRecord]) -> Data {
        var rows = row(1, ["File", "Source type", "Content"])
        for (i, r) in records.enumerated() {
            rows += row(i + 2, [r.title, r.sourceType, r.text])
        }
        let sheet = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\(rows)</sheetData></worksheet>
        """
        let workbook = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>
        """
        let workbookRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
        """
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>
        """
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """
        return ZipWriter().archive([
            .init(path: "[Content_Types].xml", data: Data(contentTypes.utf8)),
            .init(path: "_rels/.rels", data: Data(rels.utf8)),
            .init(path: "xl/workbook.xml", data: Data(workbook.utf8)),
            .init(path: "xl/_rels/workbook.xml.rels", data: Data(workbookRels.utf8)),
            .init(path: "xl/worksheets/sheet1.xml", data: Data(sheet.utf8))
        ])
    }

    private static func row(_ index: Int, _ cells: [String]) -> String {
        var out = "<row r=\"\(index)\">"
        for (c, value) in cells.enumerated() {
            let ref = "\(columnLetter(c))\(index)"
            out += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xmlEscape(value))</t></is></c>"
        }
        out += "</row>"
        return out
    }

    private static func columnLetter(_ index: Int) -> String {
        var n = index
        var s = ""
        repeat {
            s = String(UnicodeScalar(UInt8(65 + (n % 26)))) + s
            n = n / 26 - 1
        } while n >= 0
        return s
    }

    // MARK: - Shared

    #if canImport(AppKit)
    private static func attributedBody(_ records: [ExportRecord]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let titleFont = NSFont.boldSystemFont(ofSize: 15)
        let metaFont = NSFont.systemFont(ofSize: 10)
        let bodyFont = NSFont.systemFont(ofSize: 12)
        for r in records {
            out.append(NSAttributedString(string: r.title + "\n", attributes: [.font: titleFont]))
            if !r.sourceType.isEmpty {
                out.append(NSAttributedString(string: r.sourceType.uppercased() + "\n",
                                              attributes: [.font: metaFont, .foregroundColor: NSColor.secondaryLabelColor]))
            }
            out.append(NSAttributedString(string: r.text + "\n\n", attributes: [.font: bodyFont]))
        }
        return out
    }
    #endif

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            // Strip control chars that are illegal in XML 1.0 (OCR/носе).
            .unicodeScalars.reduce(into: "") { acc, scalar in
                let v = scalar.value
                if v == 0x9 || v == 0xA || v == 0xD || (v >= 0x20 && v != 0xFFFE && v != 0xFFFF) {
                    acc.unicodeScalars.append(scalar)
                }
            }
    }
}
