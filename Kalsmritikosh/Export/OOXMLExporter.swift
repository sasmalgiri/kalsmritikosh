//
//  OOXMLExporter.swift
//  Kalsmritikosh
//
//  Pure-Swift Office Open XML (OOXML) writers for the two binary office formats — DOCX (WordprocessingML) and
//  XLSX (SpreadsheetML). Both are ZIP packages of XML parts, assembled here with ZIPArchiveWriter and no
//  third-party library. Value-in (ExportableDocument) / Data-out, fully offline, deterministic (the ZIP writer
//  pins timestamps, and no Date.now() is called), so the same document always produces byte-identical output.
//
//  These renderers carry the SAME content the text renderers do — title, subtitle, disclaimer, prose sections,
//  the optional table, the sources list, and the manifest block — so an exported office file is a faithful,
//  reopenable rendering of the work product, not a lossy summary.
//

import Foundation

/// DOCX (WordprocessingML) writer — a minimal, conformant .docx package.
public enum DOCXExporter {

    public static func render(_ doc: ExportableDocument) -> Data {
        var body = ""
        body += para(doc.title, bold: true, size: 36)
        if let s = doc.subtitle { body += para(s, italic: true, size: 24) }
        if let d = doc.disclaimer { body += para(d, italic: true, size: 18) }
        for section in doc.sections {
            body += para(section.title, bold: true, size: 28)
            for p in section.paragraphs { body += para(p) }
        }
        if let table = doc.table {
            body += para(table.title, bold: true, size: 28)
            body += tableXML(columns: table.columns, rows: table.rows)
        }
        if !doc.citations.isEmpty {
            body += para("Sources", bold: true, size: 28)
            for (i, c) in doc.citations.enumerated() {
                body += para(CitationRenderer.render(c, style: doc.citationStyle, index: i + 1))
            }
        }
        body += para("Manifest", bold: true, size: 28)
        for line in doc.manifest.toMarkdown().split(separator: "\n", omittingEmptySubsequences: false) {
            body += para(String(line))
        }

        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body>
        \(body)<w:sectPr/>
        </w:body>
        </w:document>
        """

        var zip = ZIPArchiveWriter()
        zip.addFile(path: "[Content_Types].xml", text: contentTypes)
        zip.addFile(path: "_rels/.rels", text: rootRels)
        zip.addFile(path: "word/document.xml", text: document)
        return zip.build()
    }

    private static func para(_ text: String, bold: Bool = false, italic: Bool = false, size: Int? = nil) -> String {
        var rPr = ""
        if bold || italic || size != nil {
            rPr = "<w:rPr>" + (bold ? "<w:b/>" : "") + (italic ? "<w:i/>" : "")
                + (size.map { "<w:sz w:val=\"\($0)\"/>" } ?? "") + "</w:rPr>"
        }
        return "<w:p><w:r>\(rPr)<w:t xml:space=\"preserve\">\(esc(text))</w:t></w:r></w:p>\n"
    }

    private static func tableXML(columns: [String], rows: [[String]]) -> String {
        func cell(_ s: String, bold: Bool) -> String {
            let rPr = bold ? "<w:rPr><w:b/></w:rPr>" : ""
            return "<w:tc><w:p><w:r>\(rPr)<w:t xml:space=\"preserve\">\(esc(s))</w:t></w:r></w:p></w:tc>"
        }
        var out = "<w:tbl><w:tblPr><w:tblW w:w=\"0\" w:type=\"auto\"/><w:tblBorders>"
        out += ["top", "left", "bottom", "right", "insideH", "insideV"]
            .map { "<w:\($0) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/>" }.joined()
        out += "</w:tblBorders></w:tblPr>"
        out += "<w:tr>" + columns.map { cell($0, bold: true) }.joined() + "</w:tr>"
        for row in rows {
            let padded = pad(row, to: columns.count)
            out += "<w:tr>" + padded.map { cell($0, bold: false) }.joined() + "</w:tr>"
        }
        out += "</w:tbl>\n"
        return out
    }

    private static let contentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    </Types>
    """
    private static let rootRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
    """
}

/// XLSX (SpreadsheetML) writer — a minimal, conformant .xlsx package. One worksheet. Every cell is an inline
/// string, so the sheet is a faithful transcription of the table (or, when there is no table, the citation list).
public enum XLSXExporter {

    public static func render(_ doc: ExportableDocument) -> Data {
        let (columns, rows) = gridFor(doc)
        var sheet = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        sheet += "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>"
        sheet += rowXML(index: 1, cells: columns)
        for (i, row) in rows.enumerated() {
            sheet += rowXML(index: i + 2, cells: pad(row, to: columns.count))
        }
        sheet += "</sheetData></worksheet>"

        var zip = ZIPArchiveWriter()
        zip.addFile(path: "[Content_Types].xml", text: contentTypes)
        zip.addFile(path: "_rels/.rels", text: rootRels)
        zip.addFile(path: "xl/workbook.xml", text: workbook)
        zip.addFile(path: "xl/_rels/workbook.xml.rels", text: workbookRels)
        zip.addFile(path: "xl/worksheets/sheet1.xml", text: sheet)
        return zip.build()
    }

    /// The grid an XLSX represents: the document's table if present (with its citation
    /// block appended below — "Excel with citations baked in" holds for table exports
    /// too), else the citation list alone.
    private static func gridFor(_ doc: ExportableDocument) -> (columns: [String], rows: [[String]]) {
        let citationHeader = ["Label", "Source", "Locator", "Resolved", "Generated summary"]
        let citationRows = doc.citations.map { c in
            [c.displayLabel, c.sourceTitle, c.effectiveLocator, c.isResolved ? "yes" : "no", c.isGeneratedSummary ? "yes" : "no"]
        }
        guard let t = doc.table else { return (citationHeader, citationRows) }
        // A citation-free table export stays byte-identical to the pre-guard writer.
        guard !citationRows.isEmpty else { return (t.columns, t.rows) }
        let width = max(t.columns.count, citationHeader.count)
        var rows = t.rows
        rows.append([])
        rows.append(["Citations"])
        rows.append(citationHeader)
        rows.append(contentsOf: citationRows)
        return (pad(t.columns, to: width), rows)
    }

    private static func rowXML(index: Int, cells: [String]) -> String {
        var out = "<row r=\"\(index)\">"
        for (col, value) in cells.enumerated() {
            let ref = "\(columnLetters(col))\(index)"
            out += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(esc(value))</t></is></c>"
        }
        out += "</row>"
        return out
    }

    /// Zero-based column index → spreadsheet column letters (0→A, 25→Z, 26→AA).
    static func columnLetters(_ index: Int) -> String {
        var n = index, s = ""
        repeat { s = String(UnicodeScalar(UInt8(65 + n % 26))) + s; n = n / 26 - 1 } while n >= 0
        return s
    }

    private static let contentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
    <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
    </Types>
    """
    private static let rootRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
    </Relationships>
    """
    private static let workbook = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
    <sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets>
    </workbook>
    """
    private static let workbookRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
    </Relationships>
    """
}

// MARK: - Shared helpers

private func esc(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

private func pad(_ row: [String], to n: Int) -> [String] {
    row.count >= n ? Array(row.prefix(n)) : row + Array(repeating: "", count: n - row.count)
}
