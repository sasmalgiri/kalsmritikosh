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
import os
import CoreGraphics
import ImageIO

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
    case csv, json, markdown, html, docx, xlsx, pdf, tiff, mbox, emlZip
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
        case .tiff: return "TIFF (page images)"
        case .mbox: return "mbox (original emails)"
        case .emlZip: return "EML files in a ZIP (original emails)"
        }
    }
    public var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .emlZip: return "zip"
        default: return rawValue
        }
    }
    /// Formats built from original email files (shown only for source sets).
    public var needsOriginals: Bool { self == .mbox || self == .emlZip }

    /// Scope decision 2026-11-06 (SPLIT exportFormats): practical PDF, Word and CSV are core and never
    /// depend on the "More export formats" switch; the switch adds the specialist interchange formats.
    public static let core: [LedgerExportFormat] = [.csv, .docx, .pdf]

    /// The formats offered, given whether "More export formats" is on.
    public static func offered(specialistOn: Bool) -> [LedgerExportFormat] {
        specialistOn ? allCases : allCases.filter { core.contains($0) }
    }
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
        guard format.needsOriginals else { return LedgerExportPreflight(rows: t.rows.count, originalsReadable: 0, originalsMissing: []) }
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
        case .tiff: return tiff(fromPDF: DocumentExporter.pdf(records(t)) ?? Data())
        case .mbox: return mbox(t, missing: &missing)
        case .emlZip: return emlZip(t, missing: &missing)
        }
    }

    static func records(_ t: LedgerExportTable) -> [ExportRecord] {
        t.rows.map { row in
            ExportRecord(title: row.first ?? "", sourceType: t.title,
                         text: zip(t.columns, row).dropFirst().map { "\($0): \($1)" }.joined(separator: "\n"))
        }
    }

    /// S14 (SEC-10) — a cell a spreadsheet would run as a formula is written as text first (CSVFormulaGuard); this one
    /// escaper serves the ledger tables, the timeline and batch screening.
    public static func csvField(_ raw: String) -> String {
        CSVFormulaGuard.csvField(raw)
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
        mboxMessages(t, missing: &missing) { out.append($0) }
        return out
    }

    /// Speed PERF-30 (owner 2026-11-23) — not tested yet. The mbox one message at a time to `emit` (a file handle when
    /// streamed), so the whole mailbox is never held in memory.
    static func mboxMessages(_ t: LedgerExportTable, missing: inout [String], emit: (Data) throws -> Void) rethrows {
        for (i, url) in t.originals.enumerated() {
            guard let url, isEmailFile(url) else { missing.append(t.sources[safe: i] ?? "row \(i + 1)"); continue }
            guard let data = originalMessage(url) else { missing.append(t.sources[safe: i] ?? url.lastPathComponent); continue }
            var raw = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            raw = raw.replacingOccurrences(of: "\r\n", with: "\n")
            var body = ""
            body.reserveCapacity(raw.utf8.count + 64)
            for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
                let stripped = line.drop(while: { $0 == ">" })
                if stripped.hasPrefix("From ") { body += ">" }
                body += line
                body += "\n"
            }
            var message = Data("From kalsmritikosh@localhost Thu Jan  1 00:00:00 1970\n".utf8)
            message.append(Data(body.utf8))
            if !body.hasSuffix("\n\n") { message.append(Data("\n".utf8)) }
            try emit(message)
        }
    }

    /// One original message's bytes (.emlx unwrapped by its byte count); nil when unreadable.
    static func originalMessage(_ url: URL) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) } catch {
            KalsmritikoshLog.app.error("Export: original email unreadable: \(String(describing: error), privacy: .private)")
            return nil
        }
        // .emlx: first line is the message byte count; an Apple plist follows the message.
        if url.pathExtension.lowercased() == "emlx", let nl = data.firstIndex(of: 0x0A),
           let count = Int(String(decoding: data[data.startIndex..<nl], as: UTF8.self).trimmingCharacters(in: .whitespaces)) {
            let start = data.index(after: nl)
            data = data.subdata(in: start..<min(data.endIndex, start + count))
        }
        return data
    }

    /// Speed PERF-30 (owner 2026-11-23) — not tested yet. Render straight to `url`: mbox and the .eml ZIP are streamed
    /// message by message (written beside the file and moved into place); the other formats are rendered and written
    /// atomically as before. Returns the bytes written (0: nothing could be written).
    public static func renderToFile(_ t: LedgerExportTable, format: LedgerExportFormat, url: URL, missing: inout [String]) throws -> Int {
        switch format {
        case .mbox:
            let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).partial")
            guard FileManager.default.createFile(atPath: temp.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            var written = 0
            do {
                let handle = try FileHandle(forWritingTo: temp)
                defer { try? handle.close() }
                try mboxMessages(t, missing: &missing) { try handle.write(contentsOf: $0); written += $0.count }
            } catch {
                try? FileManager.default.removeItem(at: temp)
                throw error
            }
            // Nothing readable: no file, as before (the in-memory render wrote nothing for an empty mbox).
            if written == 0 {
                do { try FileManager.default.removeItem(at: temp) } catch {
                    KalsmritikoshLog.app.error("Export: empty mbox not removed: \(String(describing: error), privacy: .private)")
                }
                return 0
            }
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
            return written
        case .emlZip:
            let zip = try ZIPFileStreamer(writingTo: url)
            var names = Set<String>()
            var added = 0
            for (i, original) in t.originals.enumerated() {
                guard let original, isEmailFile(original) else { missing.append(t.sources[safe: i] ?? "row \(i + 1)"); continue }
                guard let data = originalMessage(original) else { missing.append(t.sources[safe: i] ?? original.lastPathComponent); continue }
                try zip.add(path: emlName(original, used: &names), data: data)
                added += 1
            }
            try zip.finish()
            return max(1, added)   // an archive is written even when empty, as before
        default:
            let data = render(t, format: format, missing: &missing)
            guard !data.isEmpty else { return 0 }
            try data.write(to: url, options: .atomic)
            return data.count
        }
    }

    static func emlName(_ url: URL, used: inout Set<String>) -> String {
        var name = url.deletingPathExtension().lastPathComponent + ".eml"
        var n = 2
        while used.contains(name) { name = url.deletingPathExtension().lastPathComponent + " \(n).eml"; n += 1 }
        used.insert(name)
        return name
    }

    /// Multipage TIFF: each page of the PDF rendering at 200 dpi (ImageIO, on-device).
    static func tiff(fromPDF pdf: Data) -> Data {
        guard let provider = CGDataProvider(data: pdf as CFData), let doc = CGPDFDocument(provider), doc.numberOfPages > 0 else { return Data() }
        let out = NSMutableData()
        let pages = doc.numberOfPages
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, "public.tiff" as CFString, pages, nil) else { return Data() }
        // Speed PERF-30 (owner 2026-11-23) — not tested yet. Pages rasterised in parallel, a window at a time (as many as
        // the memory budget carries at ~16 MB a page, each worker with its own PDF document), added in page order.
        let width = max(1, WorkStealingQueue.cpuWidth(perItemBytes: 16 << 20))
        var first = 1
        while first <= pages {
            let last = min(pages, first + width * 2 - 1)
            let images = WorkStealingQueue.mapSync(count: last - first + 1, workers: width) { k -> CGImage? in
                guard let p = CGDataProvider(data: pdf as CFData), let d = CGPDFDocument(p) else { return nil }
                return tiffPage(d, first + k)
            }
            for img in images { if let img { CGImageDestinationAddImage(dest, img, [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]] as CFDictionary) } }
            first = last + 1
        }
        return CGImageDestinationFinalize(dest) ? out as Data : Data()
    }

    /// One PDF page at 200 dpi on white (nil when the page cannot be drawn).
    static func tiffPage(_ doc: CGPDFDocument, _ i: Int) -> CGImage? {
        guard let page = doc.page(at: i) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        let scale: CGFloat = 200 / 72
        let w = Int(box.width * scale), h = Int(box.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale); ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    /// The original .eml/.emlx bytes as individual .eml files inside a ZIP (emlx unwrapped by byte count).
    static func emlZip(_ t: LedgerExportTable, missing: inout [String]) -> Data {
        var zip = ZIPArchiveWriter()
        var used = Set<String>()
        for (i, url) in t.originals.enumerated() {
            guard let url, isEmailFile(url) else { missing.append(t.sources[safe: i] ?? "row \(i + 1)"); continue }
            guard let data = originalMessage(url) else { missing.append(t.sources[safe: i] ?? url.lastPathComponent); continue }
            zip.addFile(path: emlName(url, used: &used), data: data)
        }
        return zip.build()
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
