//
//  WorkProductExporter.swift
//  Kalsmritikosh
//
//  Persona features Epic 2 (F3). ONE reusable export layer serving every
//  persona (§8). Takes a deterministic document (prose sections and/or a
//  table) + a citation list + a manifest, and renders it to the v1-priority
//  text formats. Pure value-in / string-out — reproducible and testable. PDF
//  and DOCX (binary formats) are a later slice; HTML export is print-to-PDF
//  ready in the meantime.
//
//  Acceptance honored here: every citation reopens (its identifiers travel in
//  the manifest citation_map), generated summaries are labelled by the
//  renderer and never cited as primary evidence, and a missing source becomes
//  an explicit unresolved-citation warning rather than a silent drop.
//

import Foundation

public enum ExportFormat: String, Sendable, CaseIterable, Codable {
    case markdown, html, csv, json, rtf

    public var fileExtension: String { self == .markdown ? "md" : rawValue }
    public nonisolated var displayName: String {
        switch self {
        case .markdown: return "Markdown"
        case .html:     return "HTML"
        case .csv:      return "CSV"
        case .json:     return "JSON"
        case .rtf:      return "RTF"
        }
    }
}

/// A prose section of a work product.
public struct ExportSection: Sendable, Hashable {
    public var title: String
    public var paragraphs: [String]
    public nonisolated init(title: String, paragraphs: [String]) {
        self.title = title; self.paragraphs = paragraphs
    }
}

/// A tabular block (chronology, review CSV, payment table, screening log).
public struct ExportTable: Sendable, Hashable {
    public var title: String
    public var columns: [String]
    public var rows: [[String]]
    public nonisolated init(title: String, columns: [String], rows: [[String]]) {
        self.title = title; self.columns = columns; self.rows = rows
    }
}

/// The neutral document any persona work product maps into before export.
public struct ExportableDocument: Sendable, Hashable {
    public var title: String
    public var subtitle: String?
    public var sections: [ExportSection]
    public var table: ExportTable?
    public var citations: [CitationRecord]
    public var citationStyle: CitationStyle
    public var disclaimer: String?
    public var manifest: ExportManifest

    public nonisolated init(
        title: String,
        subtitle: String? = nil,
        sections: [ExportSection] = [],
        table: ExportTable? = nil,
        citations: [CitationRecord] = [],
        citationStyle: CitationStyle = .footnote,
        disclaimer: String? = nil,
        manifest: ExportManifest
    ) {
        self.title = title
        self.subtitle = subtitle
        self.sections = sections
        self.table = table
        self.citations = citations
        self.citationStyle = citationStyle
        self.disclaimer = disclaimer
        self.manifest = manifest
    }
}

public enum WorkProductExporter {

    public static func render(_ doc: ExportableDocument, as format: ExportFormat) -> String {
        switch format {
        case .markdown: return markdown(doc)
        case .html:     return html(doc)
        case .csv:      return csv(doc)
        case .json:     return json(doc)
        case .rtf:      return rtf(doc)
        }
    }

    // MARK: - Markdown

    private static func markdown(_ doc: ExportableDocument) -> String {
        var out = "# \(doc.title)\n\n"
        if let s = doc.subtitle { out += "_\(s)_\n\n" }
        if let d = doc.disclaimer { out += "> \(d)\n\n" }
        for section in doc.sections {
            out += "## \(section.title)\n\n"
            for p in section.paragraphs { out += "\(p)\n\n" }
        }
        if let table = doc.table {
            out += "## \(table.title)\n\n"
            out += "| " + table.columns.joined(separator: " | ") + " |\n"
            out += "| " + table.columns.map { _ in "---" }.joined(separator: " | ") + " |\n"
            for row in table.rows {
                let padded = pad(row, to: table.columns.count)
                out += "| " + padded.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |\n"
            }
            out += "\n"
        }
        if !doc.citations.isEmpty {
            out += "## Sources\n\n"
            out += CitationRenderer.renderList(doc.citations, style: doc.citationStyle) + "\n\n"
        }
        out += doc.manifest.toMarkdown()
        return out
    }

    // MARK: - HTML

    private static func html(_ doc: ExportableDocument) -> String {
        var body = "<h1>\(esc(doc.title))</h1>\n"
        if let s = doc.subtitle { body += "<p><em>\(esc(s))</em></p>\n" }
        if let d = doc.disclaimer { body += "<blockquote>\(esc(d))</blockquote>\n" }
        for section in doc.sections {
            body += "<h2>\(esc(section.title))</h2>\n"
            for p in section.paragraphs { body += "<p>\(esc(p))</p>\n" }
        }
        if let table = doc.table {
            body += "<h2>\(esc(table.title))</h2>\n<table border=\"1\" cellspacing=\"0\" cellpadding=\"4\">\n<thead><tr>"
            body += table.columns.map { "<th>\(esc($0))</th>" }.joined()
            body += "</tr></thead>\n<tbody>\n"
            for row in table.rows {
                let padded = pad(row, to: table.columns.count)
                body += "<tr>" + padded.map { "<td>\(esc($0))</td>" }.joined() + "</tr>\n"
            }
            body += "</tbody>\n</table>\n"
        }
        if !doc.citations.isEmpty {
            body += "<h2>Sources</h2>\n<ol>\n"
            for c in doc.citations {
                // Use general style per item inside an ordered list.
                body += "<li>\(esc(CitationRenderer.render(c, style: doc.citationStyle == .footnote ? .general : doc.citationStyle)))</li>\n"
            }
            body += "</ol>\n"
        }
        body += "<hr/>\n<pre>\(esc(doc.manifest.toMarkdown()))</pre>\n"
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(esc(doc.title))</title></head>
        <body>
        \(body)</body></html>
        """
    }

    // MARK: - CSV

    private static func csv(_ doc: ExportableDocument) -> String {
        // A CSV export is table-first (review CSV / chronology). When there is
        // no table, fall back to a citation list so the file is never empty.
        if let table = doc.table {
            var out = table.columns.map(csvField).joined(separator: ",") + "\n"
            for row in table.rows {
                out += pad(row, to: table.columns.count).map(csvField).joined(separator: ",") + "\n"
            }
            return out
        }
        var out = "label,source,locator,resolved,generated_summary\n"
        for c in doc.citations {
            out += [c.displayLabel, c.sourceTitle, c.effectiveLocator,
                    c.isResolved ? "yes" : "no", c.isGeneratedSummary ? "yes" : "no"]
                .map(csvField).joined(separator: ",") + "\n"
        }
        return out
    }

    // MARK: - JSON

    private static func json(_ doc: ExportableDocument) -> String {
        func str(_ s: String) -> String { CitationRenderer.jsonString(s) }
        var out = "{\n"
        out += "  \"title\": \(str(doc.title)),\n"
        if let s = doc.subtitle { out += "  \"subtitle\": \(str(s)),\n" }
        if let d = doc.disclaimer { out += "  \"disclaimer\": \(str(d)),\n" }
        let sections = doc.sections.map { section -> String in
            let paras = section.paragraphs.map(str).joined(separator: ", ")
            return "    { \"title\": \(str(section.title)), \"paragraphs\": [\(paras)] }"
        }
        out += "  \"sections\": [\n" + sections.joined(separator: ",\n") + "\n  ],\n"
        if let table = doc.table {
            let cols = table.columns.map(str).joined(separator: ", ")
            let rows = table.rows.map { "[" + pad($0, to: table.columns.count).map(str).joined(separator: ", ") + "]" }
            out += "  \"table\": { \"title\": \(str(table.title)), \"columns\": [\(cols)], \"rows\": [\(rows.joined(separator: ", "))] },\n"
        }
        let cites = doc.citations.enumerated().map { i, c -> String in
            "    { \"label\": \(str(c.displayLabel)), \"source\": \(str(c.sourceTitle)), \"locator\": \(str(c.effectiveLocator)), \"source_version_id\": \(c.sourceVersionID.map { str($0.uuidString) } ?? "null"), \"resolved\": \(c.isResolved), \"generated_summary\": \(c.isGeneratedSummary), \"rendered\": \(str(CitationRenderer.render(c, style: doc.citationStyle, index: i + 1))) }"
        }
        out += "  \"citations\": [\n" + cites.joined(separator: ",\n") + "\n  ],\n"
        out += "  \"manifest\": \(indentJSON(doc.manifest.toJSON()))\n"
        out += "}"
        return out
    }

    // MARK: - RTF

    private static func rtf(_ doc: ExportableDocument) -> String {
        func line(_ s: String, bold: Bool = false, size: Int = 24) -> String {
            let e = rtfEsc(s)
            return "{\\fs\(size)\(bold ? "\\b" : "") \(e)\\b0\\par}\n"
        }
        var body = line(doc.title, bold: true, size: 36)
        if let s = doc.subtitle { body += line(s, size: 20) }
        if let d = doc.disclaimer { body += line(d, size: 18) }
        for section in doc.sections {
            body += line(section.title, bold: true, size: 28)
            for p in section.paragraphs { body += line(p) }
        }
        if let table = doc.table {
            body += line(table.title, bold: true, size: 28)
            body += line(table.columns.joined(separator: "\t"), bold: true)
            for row in table.rows { body += line(pad(row, to: table.columns.count).joined(separator: "\t")) }
        }
        if !doc.citations.isEmpty {
            body += line("Sources", bold: true, size: 28)
            for (i, c) in doc.citations.enumerated() {
                body += line(CitationRenderer.render(c, style: doc.citationStyle, index: i + 1))
            }
        }
        return "{\\rtf1\\ansi\\deff0\n" + body + "}"
    }

    // MARK: - Helpers

    private static func pad(_ row: [String], to n: Int) -> [String] {
        row.count >= n ? Array(row.prefix(n)) : row + Array(repeating: "", count: n - row.count)
    }

    private nonisolated static func csvField(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func rtfEsc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
    }

    /// Re-indent a top-level JSON object by two spaces so it nests cleanly.
    private static func indentJSON(_ json: String) -> String {
        json.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : "  " + $0 }
            .joined(separator: "\n")
    }
}
