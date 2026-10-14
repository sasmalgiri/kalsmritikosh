//
//  ExportCenter.swift
//  Kalsmritikosh
//
//  W2-6 — export breadth (renderer set as in mailin's ArchiveExportService,
//  native code). One tabular model — `LedgerExportTable` — rendered to CSV, JSON,
//  Markdown, HTML, Word (.docx), Excel (.xlsx), PDF, and, for email sources,
//  mbox built from the original message bytes. Every export is written with a
//  signed receipt beside it (W1-3), one receipt entry per row.
//
//  `preflight` reports, before anything is written, how many rows will be
//  exported and — for mbox — how many originals are readable; nothing is
//  silently dropped: unreadable originals are counted and named in the result.
//

import Foundation

public nonisolated struct LedgerExportTable: Sendable {
    public var title: String
    public var columns: [String]
    public var rows: [[String]]
    /// Per-row source label and supporting passage, used for the receipt.
    public var sources: [String]
    public var passages: [String]
    /// Per-row original file (mbox only).
    public var originals: [URL?]

    public init(title: String, columns: [String], rows: [[String]], sources: [String], passages: [String], originals: [URL?] = []) {
        self.title = title; self.columns = columns; self.rows = rows
        self.sources = sources; self.passages = passages
        self.originals = originals.isEmpty ? Array(repeating: nil, count: rows.count) : originals
    }
}

public nonisolated enum LedgerExportFormat: String, Sendable, CaseIterable, Identifiable {
    case csv, json, markdown, html, docx, xlsx, pdf, mbox
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .csv: return "CSV"
        case .json: return "JSON"
        case .markdown: return "Markdown"
        case .html: return "HTML"
        case .docx: return "Word (.docx)"
        case .xlsx: return "Excel (.xlsx)"
        case .pdf: return "PDF"
        case .mbox: return "mbox (original emails)"
        }
    }
    public var fileExtension: String { self == .markdown ? "md" : rawValue }
}

public nonisolated struct LedgerExportPreflight: Sendable {
    public let rows: Int
    public let originalsReadable: Int
    public let originalsMissing: [String]
    public var summary: String {
        var s = "\(rows) row\(rows == 1 ? "" : "s") will be exported."
        if originalsReadable + originalsMissing.count > 0 {
            s += " \(originalsReadable) original email\(originalsReadable == 1 ? "" : "s") readable"
            if !originalsMissing.isEmpty { s += "; \(originalsMissing.count) not readable and will be listed, not exported" }
            s += "."
        }
        return s
    }
}

public nonisolated enum LedgerExportRenderer {

    public static func preflight(_ t: LedgerExportTable, format: LedgerExportFormat) -> LedgerExportPreflight {
        guard format == .mbox else { return LedgerExportPreflight(rows: t.rows.count, originalsReadable: 0, originalsMissing: []) }
        var ok = 0; var missing: [String] = []
        for (i, url) in t.originals.enumerated() {
            if let url, isEmailFile(url), FileManager.default.isReadableFile(atPath: url.path) { ok += 1 }
            else { missing.append(t.sources[safe: i] ?? "row \(i + 1)") }
        }
        return LedgerExportPreflight(rows: t.rows.count, originalsReadable: ok, originalsMissing: missing)
    }

    static func isEmailFile(_ url: URL) -> Bool { ["eml", "emlx"].contains(url.pathExtension.lowercased()) }

    /// Render the table. For mbox, `missing` receives the sources that had no readable original.
    public static func render(_ t: LedgerExportTable, format: LedgerExportFormat, missing: inout [String]) -> Data {
        switch format {
        case .csv: return Data(csv(t).utf8)
        case .json: return json(t)
        case .markdown: return Data(markdown(t).utf8)
        case .html: return Data(html(t).utf8)
        case .docx: return DocumentExporter.docx(records(t))
        case .xlsx: return DocumentExporter.xlsx(grid: [t.columns] + t.rows)
        case .pdf: return DocumentExporter.pdf(records(t)) ?? Data()
        case .mbox: return mbox(t, missing: &missing)
        }
    }

    static func records(_ t: LedgerExportTable) -> [ExportRecord] {
        t.rows.map { row in
            ExportRecord(title: row.first ?? "", sourceType: t.title,
                         text: zip(t.columns, row).dropFirst().map { "\($0): \($1)" }.joined(separator: "\n"))
        }
    }

    public static func csvField(_ s: String) -> String {
        s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
            ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    public static func csv(_ t: LedgerExportTable) -> String {
        ([t.columns] + t.rows).map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    public static func json(_ t: LedgerExportTable) -> Data {
        let objects: [[String: String]] = t.rows.map { row in
            Dictionary(zip(t.columns, row).map { ($0, $1) }, uniquingKeysWith: { a, _ in a })
        }
        let payload: [String: Any] = ["title": t.title, "columns": t.columns, "rows": objects]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    static func mdCell(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>")
    }

    public static func markdown(_ t: LedgerExportTable) -> String {
        var out = "# \(t.title)\n\n| " + t.columns.map(mdCell).joined(separator: " | ") + " |\n|"
        out += String(repeating: " --- |", count: t.columns.count) + "\n"
        for row in t.rows { out += "| " + row.map(mdCell).joined(separator: " | ") + " |\n" }
        return out
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    public static func html(_ t: LedgerExportTable) -> String {
        var out = """
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>\(esc(t.title))</title>
        <style>body{font:14px -apple-system,sans-serif;margin:2em}table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:4px 8px;vertical-align:top;text-align:left}</style>
        </head><body><h1>\(esc(t.title))</h1><table><thead><tr>
        """
        out += t.columns.map { "<th>\(esc($0))</th>" }.joined() + "</tr></thead><tbody>"
        for row in t.rows { out += "<tr>" + row.map { "<td>\(esc($0).replacingOccurrences(of: "\n", with: "<br>"))</td>" }.joined() + "</tr>" }
        return out + "</tbody></table></body></html>\n"
    }

    /// mbox (mboxrd): each original message preceded by a From_ line; body lines starting
    /// with "From " (after any '>' quoting) gain one more '>'.
    static func mbox(_ t: LedgerExportTable, missing: inout [String]) -> Data {
        var out = Data()
        for (i, url) in t.originals.enumerated() {
            guard let url, isEmailFile(url) else { missing.append(t.sources[safe: i] ?? "row \(i + 1)"); continue }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard var data = try? Data(contentsOf: url) else {
                missing.append(t.sources[safe: i] ?? url.lastPathComponent); continue
            }
            // .emlx: first line is the message byte count; an Apple plist follows the message.
            if url.pathExtension.lowercased() == "emlx", let nl = data.firstIndex(of: 0x0A),
               let count = Int(String(decoding: data[data.startIndex..<nl], as: UTF8.self).trimmingCharacters(in: .whitespaces)) {
                let start = data.index(after: nl)
                data = data.subdata(in: start..<min(data.endIndex, start + count))
            }
            var raw = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            raw = raw.replacingOccurrences(of: "\r\n", with: "\n")
            var body = ""
            for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
                let stripped = line.drop(while: { $0 == ">" })
                body += (stripped.hasPrefix("From ") ? ">" : "") + line + "\n"
            }
            out.append(Data("From kalsmritikosh@localhost Thu Jan  1 00:00:00 1970\n".utf8))
            out.append(Data(body.utf8))
            if !body.hasSuffix("\n\n") { out.append(Data("\n".utf8)) }
        }
        return out
    }

    /// Receipt drafts: one per row (claim = first column; passage = the row's supporting text).
    public static func receiptDrafts(_ t: LedgerExportTable) -> [ReceiptDraft] {
        t.rows.indices.map { i in
            ReceiptDraft(claim: t.rows[i].first ?? "", source: t.sources[safe: i] ?? "",
                         passage: t.passages[safe: i] ?? t.rows[i].joined(separator: " · "))
        }
    }
}

private extension Array {
    nonisolated subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
