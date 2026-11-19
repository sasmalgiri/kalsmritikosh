//
//  CaseReportDocuments.swift
//  Kalsmritikosh
//
//  Ease fixes B (AI-off assessment 2026-11-15, friction point 4) — the case file report as PDF and as Word (.docx), next
//  to the Markdown file. Both are drawn from the SAME protected text the output door froze, revalidated and scrubbed
//  (CaseOutputService.prepare), so they carry exactly what the Markdown carries: the DRAFT or approval line with the case
//  revision, every section including "What the app could read" and the limitations, citations as "document, p. 4", and
//  the identifiers' appendix.
//
//  Built-in frameworks only, no dependency:
//  • PDF — Core Text laid out on US Letter pages with a page number, through a Core Graphics PDF context. No links, no
//    annotations, no forms, no script: the page holds text only.
//  • Word — Office Open XML (.docx) written with the app's ZipWriter: [Content_Types].xml, the package relationships,
//    word/document.xml and its (empty) relationships, plus docProps/core.xml. Chosen over .rtf because .docx is what courts,
//    HR teams and insurers ask for, and the app already writes valid OOXML (Data Lab). No macros (a plain .document
//    content type, never .macroEnabled), no external relationships, no fields, no embedded objects.
//
//  The read-back (`pdfText`, `docxText`, `activeContent`) is what the output door uses to reconcile a written file with
//  its manifest before it is recorded as an export.
//

import CoreGraphics
import CoreText
import Foundation
import PDFKit
import os

/// The binary formats of the case file report.
public nonisolated enum CaseReportDocumentFormat: String, Sendable, CaseIterable {
    case pdf, docx
    public var fileExtension: String { rawValue }
    public var label: String { self == .pdf ? "PDF" : "Word" }
}

public nonisolated enum CaseReportDocumentRenderer {

    // MARK: The text, as blocks

    enum Block: Equatable {
        case heading(Int, String)
        case bullet(Int, String)
        case quote(String)
        case paragraph(String)
        case rule
    }

    /// The report's Markdown as blocks: headings, bullets (by indent), quoted lines, paragraphs and rules.
    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed == "---" { out.append(.rule); continue }
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix { $0 == "#" }.count
                out.append(.heading(min(level, 3), trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if trimmed.hasPrefix("> ") { out.append(.quote(String(trimmed.dropFirst(2)))); continue }
            if trimmed.hasPrefix("- ") {
                let indent = line.prefix { $0 == " " }.count
                out.append(.bullet(min(indent / 2, 3), String(trimmed.dropFirst(2))))
                continue
            }
            out.append(.paragraph(trimmed))
        }
        return out
    }

    /// Runs of a line: (text, bold, italic). "**x**" is bold; a line wrapped in "_…_" is italic; "`x`" loses its marks.
    static func runs(_ s: String) -> [(text: String, bold: Bool, italic: Bool)] {
        var line = s.replacingOccurrences(of: "`", with: "")
        var italic = false
        if line.count > 2, line.hasPrefix("_"), line.hasSuffix("_") { italic = true; line = String(line.dropFirst().dropLast()) }
        var out: [(String, Bool, Bool)] = []
        for (i, part) in line.components(separatedBy: "**").enumerated() where !part.isEmpty {
            out.append((part, i % 2 == 1, italic))
        }
        return out.isEmpty ? [("", false, italic)] : out
    }

    /// The plain text of the document as a reader sees it (what the read-back compares).
    static func plainLine(_ b: Block) -> String {
        switch b {
        case .heading(_, let t), .quote(let t), .paragraph(let t): return runs(t).map(\.text).joined()
        case .bullet(_, let t): return "• " + runs(t).map(\.text).joined()
        case .rule: return "—"
        }
    }

    /// The document title: the report's first heading (already protected), else "Case file report".
    static func title(_ text: String) -> String {
        for b in blocks(text) { if case .heading(_, let t) = b { return t } }
        return "Case file report"
    }

    // MARK: PDF (Core Text)

    static func font(_ size: CGFloat, bold: Bool, italic: Bool) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        guard italic else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitItalic, .traitItalic) ?? base
    }

    static func paragraphStyle(indent: CGFloat, spacingAfter: CGFloat) -> CTParagraphStyle {
        var first = indent, head = indent, after = spacingAfter
        return withUnsafePointer(to: &first) { f in
            withUnsafePointer(to: &head) { h in
                withUnsafePointer(to: &after) { a in
                    let size = MemoryLayout<CGFloat>.size
                    let settings = [CTParagraphStyleSetting(spec: .firstLineHeadIndent, valueSize: size, value: f),
                                    CTParagraphStyleSetting(spec: .headIndent, valueSize: size, value: h),
                                    CTParagraphStyleSetting(spec: .paragraphSpacing, valueSize: size, value: a)]
                    return CTParagraphStyleCreate(settings, settings.count)
                }
            }
        }
    }

    static func attributed(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let styleKey = NSAttributedString.Key(kCTParagraphStyleAttributeName as String)
        let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1), grey = CGColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1)
        func add(_ s: String, size: CGFloat, bold: Bool = false, italic: Bool = false, indent: CGFloat = 0, after: CGFloat = 4, color: CGColor? = nil) {
            let style = paragraphStyle(indent: indent, spacingAfter: after)
            for r in runs(s) {
                out.append(NSAttributedString(string: r.text, attributes: [fontKey: font(size, bold: bold || r.bold, italic: italic || r.italic),
                                                                           colorKey: color ?? black, styleKey: style]))
            }
            out.append(NSAttributedString(string: "\n", attributes: [fontKey: font(size, bold: false, italic: false), styleKey: style]))
        }
        for b in blocks(text) {
            switch b {
            case .heading(let level, let t): add(t, size: level == 1 ? 18 : (level == 2 ? 14 : 12), bold: true, after: 6)
            case .bullet(let level, let t): add("• " + t, size: 10.5, indent: CGFloat(12 + level * 14))
            case .quote(let t): add(t, size: 10.5, bold: true, after: 6, color: grey)
            case .paragraph(let t): add(t, size: 10.5)
            case .rule: add("—", size: 10.5, color: grey)
            }
        }
        return out
    }

    /// The report as a PDF: US Letter, 54-point margins, a page number at the foot of each page. nil when nothing could be
    /// drawn.
    public static func pdf(_ text: String) -> Data? {
        let body = attributed(text)
        guard body.length > 0 else { return nil }
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        let out = NSMutableData()
        let info: [CFString: Any] = [kCGPDFContextTitle: title(text), kCGPDFContextCreator: "Investigations Made Easy"]
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &media, info as CFDictionary) else { return nil }
        let fs = CTFramesetterCreateWithAttributedString(body)
        let path = CGPath(rect: CGRect(x: 54, y: 72, width: 504, height: 666), transform: nil)
        var start = 0, page = 0
        while start < body.length && page < 5_000 {
            page += 1
            ctx.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(fs, CFRange(location: start, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            let footer = NSAttributedString(string: "Page \(page)", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font(8.5, bold: false, italic: false)])
            let line = CTLineCreateWithAttributedString(footer)
            ctx.textPosition = CGPoint(x: 54, y: 40)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
            let shown = CTFrameGetVisibleStringRange(frame)
            if shown.length <= 0 { break }
            start += shown.length
        }
        ctx.closePDF()
        return out as Data
    }

    // MARK: Word (Office Open XML)

    static func xml(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                let v = u.value
                // Characters XML 1.0 cannot carry are dropped.
                if v == 0x9 || v == 0xA || v == 0xD || (v >= 0x20 && v != 0xFFFE && v != 0xFFFF) { out.unicodeScalars.append(u) }
            }
        }
        return out
    }

    static func paragraphXML(_ s: String, size: Int, bold: Bool = false, italic: Bool = false, indentTwips: Int = 0, afterTwips: Int = 80,
                             color: String? = nil) -> String {
        var p = "<w:p><w:pPr><w:spacing w:after=\"\(afterTwips)\"/>"
        if indentTwips > 0 { p += "<w:ind w:left=\"\(indentTwips)\" w:hanging=\"220\"/>" }
        p += "</w:pPr>"
        for r in runs(s) {
            var props = "<w:sz w:val=\"\(size)\"/>"
            if bold || r.bold { props = "<w:b/>" + props }
            if italic || r.italic { props = "<w:i/>" + props }
            if let color { props += "<w:color w:val=\"\(color)\"/>" }
            p += "<w:r><w:rPr>\(props)</w:rPr><w:t xml:space=\"preserve\">\(xml(r.text))</w:t></w:r>"
        }
        return p + "</w:p>"
    }

    /// The report as a Word document (.docx, Office Open XML, no macros).
    public static func docx(_ text: String) -> Data {
        var body = ""
        for b in blocks(text) {
            switch b {
            case .heading(let level, let t): body += paragraphXML(t, size: level == 1 ? 36 : (level == 2 ? 28 : 24), bold: true, afterTwips: 120)
            case .bullet(let level, let t): body += paragraphXML("• " + t, size: 21, indentTwips: 360 + level * 280)
            case .quote(let t): body += paragraphXML(t, size: 21, bold: true, afterTwips: 120, color: "4D4D4D")
            case .paragraph(let t): body += paragraphXML(t, size: 21)
            case .rule: body += paragraphXML("—", size: 21, color: "4D4D4D")
            }
        }
        let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
        let document = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<w:document xmlns:w=\"\(w)\"><w:body>\(body)<w:sectPr><w:pgSz w:w=\"12240\" w:h=\"15840\"/><w:pgMar w:top=\"1080\" w:right=\"1080\" w:bottom=\"1080\" w:left=\"1080\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/></w:sectPr></w:body></w:document>"
        let types = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/><Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/></Types>"
        let rels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/></Relationships>"
        let docRels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"></Relationships>"
        let core = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>\(xml(title(text)))</dc:title><dc:creator>Investigations Made Easy</dc:creator></cp:coreProperties>"
        return ZipWriter().archive([
            .init(path: "[Content_Types].xml", data: Data(types.utf8)),
            .init(path: "_rels/.rels", data: Data(rels.utf8)),
            .init(path: "docProps/core.xml", data: Data(core.utf8)),
            .init(path: "word/document.xml", data: Data(document.utf8)),
            .init(path: "word/_rels/document.xml.rels", data: Data(docRels.utf8))
        ])
    }

    // MARK: Read-back

    /// The text a PDF holds, read back with PDFKit (nil when it does not open or has no pages).
    public static func pdfText(_ data: Data) -> String? {
        guard let doc = PDFDocument(data: data), doc.pageCount > 0 else { return nil }
        return doc.string
    }

    /// The text of a .docx's document part, one paragraph per line (nil when the package or its XML does not read).
    public static func docxText(_ data: Data) -> String? {
        let xmlData: Data
        do { xmlData = try ZIPReader(data: data).read("word/document.xml") } catch {
            KalsmritikoshLog.app.error("Report read-back: the Word package does not open: \(String(describing: error), privacy: .public)")
            return nil
        }
        let reader = WordTextReader()
        let parser = XMLParser(data: xmlData)
        parser.delegate = reader
        guard parser.parse() else { return nil }
        return reader.paragraphs.joined(separator: "\n")
    }

    /// Anything in a written report that could run, fetch or open something: macros, external relationships, fields,
    /// embedded objects (Word); script, actions, links or form fields (PDF). Empty when there is none.
    public static func activeContent(_ data: Data, format: CaseReportDocumentFormat) -> [String] {
        switch format {
        case .docx:
            let zip = ZIPReader(data: data)
            let names: [String]
            do { names = try zip.entries().map(\.name) } catch { return ["the package does not open"] }
            var found: [String] = []
            if names.contains(where: { $0.lowercased().contains("vbaproject") }) { found.append("a macro project") }
            if names.contains(where: { $0.lowercased().hasPrefix("word/embeddings") || $0.lowercased().contains("activex") }) { found.append("an embedded object") }
            for name in names where name.hasSuffix(".rels") || name == "[Content_Types].xml" || name == "word/document.xml" {
                guard let part = try? zip.read(name), let s = String(data: part, encoding: .utf8) else { continue }
                if s.contains("TargetMode=\"External\"") { found.append("an external link in \(name)") }
                if s.lowercased().contains("macroenabled") { found.append("a macro-enabled content type") }
                if name == "word/document.xml", s.contains("<w:fldSimple") || s.contains("<w:instrText") { found.append("a field") }
            }
            return found
        case .pdf:
            guard let doc = PDFDocument(data: data) else { return ["the PDF does not open"] }
            var found: [String] = []
            for i in 0..<doc.pageCount where !(doc.page(at: i)?.annotations.isEmpty ?? true) { found.append("annotations on page \(i + 1)") }
            let raw = String(decoding: data, as: UTF8.self)
            for token in ["/JavaScript", "/JS ", "/Launch", "/URI", "/AcroForm", "/OpenAction", "/EmbeddedFile"] where raw.contains(token) {
                found.append(token)
            }
            return found
        }
    }
}

/// Collects the text of each Word paragraph (<w:p>) from its runs (<w:t>).
private nonisolated final class WordTextReader: NSObject, XMLParserDelegate {
    var paragraphs: [String] = []
    private var current = ""
    private var inText = false
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        if elementName == "w:p" { current = "" }
        if elementName == "w:t" { inText = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inText { current += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "w:t" { inText = false }
        if elementName == "w:p" { paragraphs.append(current) }
    }
}
