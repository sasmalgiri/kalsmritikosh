//
//  LegalProduction.swift
//  Kalsmritikosh
//
//  W2-5 — legal production pack (method from mailin's BatesEngine /
//  BatesPDFRenderer; native code):
//
//    IMAGES/<BATES>.pdf      one single-page PDF per Bates number, stamped in the footer
//    TEXT/<BEGBATES>.txt     the document's extracted text (redacted when asked)
//    NATIVES/<BEGBATES>.ext  the original file, when it is readable and not privileged/redacted
//    DATA/production.dat     Concordance load file (þ quote, ASCII 20 field separator)
//    DATA/production.opt     Opticon image load file (one line per page)
//    PRIVILEGE_LOG.csv       documents withheld as privileged (a slip sheet takes their number)
//
//  Bates numbers are page-level and continuous across documents. A number is
//  never reused: each run starts after the highest number ever produced with
//  the same prefix (schema v145 `bates_runs`).
//
//  Legal holds (v145 `legal_holds` / `legal_hold_items`) block the one
//  destructive user action — forgetting a folder — for any held document.
//

import Foundation
import CoreText
import CoreGraphics
import os

// MARK: - Bates numbering

public nonisolated enum BatesNumbering {
    public static func format(prefix: String, number: Int, width: Int = 7) -> String {
        let digits = String(number)
        return prefix + String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}

// MARK: - Load files

public nonisolated enum LoadFiles {
    /// Concordance delimiters: þ (U+00FE) quotes each field, ASCII 20 separates fields.
    static let quote = "\u{00FE}", separator = "\u{0014}"

    public struct DocumentRow: Sendable {
        public let begBates: String
        public let endBates: String
        public let pageCount: Int
        public let fileName: String
        public let docID: String
        public let textPath: String
        public let nativePath: String
        public let withheld: Bool
    }

    public static func dat(_ rows: [DocumentRow]) -> String {
        let header = ["BEGBATES", "ENDBATES", "PAGECOUNT", "FILENAME", "DOCID", "TEXTPATH", "NATIVEPATH", "WITHHELD"]
        func line(_ fields: [String]) -> String {
            fields.map { quote + $0.replacingOccurrences(of: quote, with: "") + quote }.joined(separator: separator)
        }
        var out = line(header) + "\r\n"
        for r in rows {
            out += line([r.begBates, r.endBates, String(r.pageCount), r.fileName, r.docID, r.textPath, r.nativePath,
                         r.withheld ? "Y" : "N"]) + "\r\n"
        }
        return out
    }

    /// Opticon: BatesNumber,Volume,ImagePath,DocumentBreak(Y or blank),FolderBreak,BoxBreak,PageCount
    public static func opt(pages: [(bates: String, imagePath: String, firstOfDoc: Bool, docPages: Int)], volume: String) -> String {
        pages.map { p in
            "\(p.bates),\(volume),\(p.imagePath),\(p.firstOfDoc ? "Y" : ""),,,\(p.firstOfDoc ? String(p.docPages) : "")"
        }.joined(separator: "\r\n") + "\r\n"
    }
}

// MARK: - Page rendering

nonisolated enum BatesPageRenderer {
    static let pageSize = CGSize(width: 612, height: 792)   // US Letter
    static let margin: CGFloat = 54, footer: CGFloat = 36

    /// Splits text into page-sized ranges using Core Text layout.
    static func paginate(_ text: String) -> [String] {
        let body = text.isEmpty ? " " : text
        let attr = NSAttributedString(string: body, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 10, nil)
        ])
        let setter = CTFramesetterCreateWithAttributedString(attr)
        let rect = CGRect(x: margin, y: margin + footer, width: pageSize.width - 2 * margin,
                          height: pageSize.height - 2 * margin - footer)
        var pages: [String] = []
        var start = 0
        let ns = body as NSString
        while start < ns.length {
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: start, length: 0), CGPath(rect: rect, transform: nil), nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { break }
            pages.append(ns.substring(with: NSRange(location: start, length: visible.length)))
            start += visible.length
        }
        return pages.isEmpty ? [" "] : pages
    }

    /// Writes one single-page PDF with `text` and the Bates stamp in the footer.
    static func writePage(text: String, bates: String, legend: String?, to url: URL) throws {
        var box = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw ProductionError.render(bates) }
        ctx.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 10, nil)
        let rect = CGRect(x: margin, y: margin + footer, width: pageSize.width - 2 * margin,
                          height: pageSize.height - 2 * margin - footer)
        let body = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(body), CFRange(), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, ctx)
        let stampFont = CTFontCreateWithName("Helvetica-Bold" as CFString, 10, nil)
        func draw(_ s: String, rightAligned: Bool) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): stampFont]))
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            ctx.textPosition = CGPoint(x: rightAligned ? pageSize.width - margin - width : margin, y: margin)
            CTLineDraw(line, ctx)
        }
        draw(bates, rightAligned: true)
        if let legend, !legend.isEmpty { draw(legend, rightAligned: false) }
        ctx.endPDFPage()
        ctx.closePDF()
        guard FileManager.default.fileExists(atPath: url.path) else { throw ProductionError.render(bates) }
    }
}

public nonisolated enum ProductionError: LocalizedError {
    case render(String), empty
    /// S14 part 3 (PERF-08) — refused before the first file: the destination cannot hold the production.
    case notEnoughSpace(needed: Int64, available: Int64)
    /// S14 part 3 (PERF-08) — writing stopped part-way (a full disk, a removed drive); what was written was removed.
    case incomplete(String)
    public var errorDescription: String? {
        switch self {
        case .render(let b): return "The page \(b) could not be written."
        case .empty: return "There is nothing to produce."
        case .notEnoughSpace(let needed, let available):
            let f = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            let n = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
            return "Nothing was written: the destination has \(f) free and this production needs about \(n) with a safety margin. Free space or choose another folder; no Bates numbers were used."
        case .incomplete(let why):
            return "The production stopped part-way (\(why)). The partly written files were removed and no Bates numbers were used; the documents in the case are unchanged."
        }
    }
}

// MARK: - Production builder

public nonisolated struct ProductionDocument: Sendable {
    public let id: UUID
    public let fileName: String
    public let text: String
    public let nativeURL: URL?
    public let privileged: Bool
}

public nonisolated struct ProductionOptions: Sendable {
    public var prefix: String
    public var startNumber: Int
    public var width: Int = 7
    public var volume: String = "VOL001"
    public var legend: String = "CONFIDENTIAL"
    public var redaction: RedactionPolicy?
    public var includeNatives: Bool = true
}

public nonisolated struct ProductionResult: Sendable {
    public let firstBates: String
    public let lastBates: String
    public let firstNumber: Int
    public let lastNumber: Int
    public let documents: Int
    public let pages: Int
    public let withheld: Int
    public let redactions: Int
    public let nativesSkipped: Int
}

public nonisolated enum ProductionBuilder {
    /// S14 part 3 (PERF-08) — a generous size estimate: each page image (a one-page PDF), the text twice (page and
    /// text file) and every native's size. Used only to refuse before writing; never to skip content.
    static let bytesPerPageImage: Int64 = 48 * 1024
    public static func estimatedBytes(_ docs: [ProductionDocument], options: ProductionOptions) -> Int64 {
        var total: Int64 = 64 * 1024   // load files and privilege log
        for doc in docs {
            let textBytes = Int64(doc.text.utf8.count)
            let pages = doc.privileged ? 1 : max(1, BatesPageRenderer.paginate(doc.text).count)
            total += Int64(pages) * bytesPerPageImage + textBytes * 2
            if options.includeNatives, !doc.privileged, let src = doc.nativeURL {
                total += (try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
            }
        }
        return total
    }

    /// Build the production folder. S14 part 3 (PERF-08): refused before the first file when the destination
    /// cannot hold it, and if writing fails part-way every file and folder this run created is removed and
    /// `ProductionError.incomplete` is thrown — a half production is never left looking like a finished one.
    public static func build(_ docs: [ProductionDocument], options: ProductionOptions, into folder: URL,
                             availableCapacity: ((URL) -> Int64?)? = nil) throws -> ProductionResult {
        guard !docs.isEmpty else { throw ProductionError.empty }
        let available = availableCapacity?(folder) ?? DiskSpaceCheck.availableCapacity(at: folder)
        if let available, let needed = DiskSpaceCheck.shortfall(writing: estimatedBytes(docs, options: options), available: available) {
            KalsmritikoshLog.app.error("Production refused before writing: not enough space at the destination")
            throw ProductionError.notEnoughSpace(needed: needed, available: available)
        }
        let fm = FileManager.default
        let folderExisted = fm.fileExists(atPath: folder.path)
        var created: [URL] = []
        do {
            return try writeAll(docs, options: options, into: folder, created: &created)
        } catch {
            KalsmritikoshLog.app.error("Production stopped part-way; removing what it wrote: \(error.localizedDescription, privacy: .private)")
            let toRemove = folderExisted ? created.reversed() : [folder]
            for url in toRemove {
                do { try fm.removeItem(at: url) } catch {
                    KalsmritikoshLog.app.error("Production clean-up could not remove a file: \(error.localizedDescription, privacy: .private)")
                }
            }
            if let e = error as? ProductionError, case .empty = e { throw e }
            throw ProductionError.incomplete(error.localizedDescription)
        }
    }

    private static func writeAll(_ docs: [ProductionDocument], options: ProductionOptions, into folder: URL,
                                 created: inout [URL]) throws -> ProductionResult {
        let fm = FileManager.default
        func write(_ data: Data, _ rel: String) throws {
            let url = folder.appendingPathComponent(rel)
            // Only what this run brings into being is removed on failure — never something that stood there before.
            if !fm.fileExists(atPath: url.path) { created.append(url) }
            try data.write(to: url)
        }
        for sub in ["IMAGES", "TEXT", "NATIVES", "DATA"] {
            let dir = folder.appendingPathComponent(sub)
            if !fm.fileExists(atPath: dir.path) { created.append(dir) }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var number = options.startNumber
        var rows: [LoadFiles.DocumentRow] = []
        var optPages: [(bates: String, imagePath: String, firstOfDoc: Bool, docPages: Int)] = []
        var privLog = "BEGBATES,ENDBATES,FILENAME,DOCID,BASIS\r\n"
        var withheld = 0, redactions = 0, nativesSkipped = 0, pages = 0
        let redactor = PIIRedactor()
        for doc in docs {
            let begBates = BatesNumbering.format(prefix: options.prefix, number: number, width: options.width)
            var text = doc.text
            var redacted = false
            if let policy = options.redaction, !doc.privileged {
                let r = redactor.redact(text, policy: policy)
                text = r.redactedText; redactions += r.redactionCount; redacted = r.redactionCount > 0
            }
            let pageTexts = doc.privileged
                ? ["Document withheld — privileged.\n\nBates number \(begBates) is assigned to this slip sheet. See PRIVILEGE_LOG.csv."]
                : BatesPageRenderer.paginate(text)
            for (i, pageText) in pageTexts.enumerated() {
                let bates = BatesNumbering.format(prefix: options.prefix, number: number, width: options.width)
                let rel = "IMAGES/\(bates).pdf"
                if !fm.fileExists(atPath: folder.appendingPathComponent(rel).path) { created.append(folder.appendingPathComponent(rel)) }
                try BatesPageRenderer.writePage(text: pageText, bates: bates, legend: options.legend,
                                                to: folder.appendingPathComponent(rel))
                optPages.append((bates, rel, i == 0, pageTexts.count))
                number += 1; pages += 1
            }
            let endBates = BatesNumbering.format(prefix: options.prefix, number: number - 1, width: options.width)
            let textRel = "TEXT/\(begBates).txt"
            try write(Data((doc.privileged ? "" : text).utf8), textRel)
            var nativeRel = ""
            // Natives only when the document is neither privileged nor redacted (a native would undo the redaction).
            if options.includeNatives, !doc.privileged, !redacted, let src = doc.nativeURL {
                let rel = "NATIVES/\(begBates)" + (src.pathExtension.isEmpty ? "" : ".\(src.pathExtension)")
                let scoped = src.startAccessingSecurityScopedResource()
                do { try fm.copyItem(at: src, to: folder.appendingPathComponent(rel)); created.append(folder.appendingPathComponent(rel)); nativeRel = rel }
                catch {
                    KalsmritikoshLog.app.error("Production: a native was not copied: \(error.localizedDescription, privacy: .private)")
                    nativesSkipped += 1
                }
                if scoped { src.stopAccessingSecurityScopedResource() }
            } else if options.includeNatives, !doc.privileged {
                nativesSkipped += 1
            }
            if doc.privileged {
                withheld += 1
                privLog += [begBates, endBates, doc.fileName, doc.id.uuidString, "Privileged"].map(csv).joined(separator: ",") + "\r\n"
            }
            rows.append(.init(begBates: begBates, endBates: endBates, pageCount: pageTexts.count, fileName: doc.fileName,
                              docID: doc.id.uuidString, textPath: textRel, nativePath: nativeRel, withheld: doc.privileged))
        }
        try write(Data(LoadFiles.dat(rows).utf8), "DATA/production.dat")
        try write(Data(LoadFiles.opt(pages: optPages, volume: options.volume).utf8), "DATA/production.opt")
        try write(Data(privLog.utf8), "PRIVILEGE_LOG.csv")
        return ProductionResult(
            firstBates: rows.first?.begBates ?? "", lastBates: rows.last?.endBates ?? "",
            firstNumber: options.startNumber, lastNumber: number - 1, documents: docs.count, pages: pages,
            withheld: withheld, redactions: redactions, nativesSkipped: nativesSkipped)
    }

    static func csv(_ raw: String) -> String {
        CSVFormulaGuard.csvField(raw)   // S14 (SEC-10) — document names in the privilege log are untrusted
    }
}

// MARK: - Repository: Bates runs and legal holds

public nonisolated struct LegalHold: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let name: String
    public let createdAt: Date
    public let releasedAt: Date?
    public let items: Int
}

public actor LegalProductionRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    /// The first unused number for `prefix` — after the highest ever produced, never below `minimum`.
    public func nextNumber(prefix: String, minimum: Int = 1) async throws -> Int {
        let rows = try await database.query("SELECT MAX(last_number) FROM bates_runs WHERE prefix = ?;", [.text(prefix)])
        let used = rows.first?.int(0).map(Int.init) ?? 0
        return max(minimum, used + 1)
    }

    public func recordRun(prefix: String, result: ProductionResult) async throws {
        try await database.exec("""
            INSERT INTO bates_runs (id, prefix, first_number, last_number, documents, created_at) VALUES (?, ?, ?, ?, ?, ?);
            """, [.uuid(UUID()), .text(prefix), .integer(Int64(result.firstNumber)), .integer(Int64(result.lastNumber)),
                  .integer(Int64(result.documents)), .date(Date())])
    }

    @discardableResult
    public func createHold(name: String) async throws -> UUID {
        let id = UUID()
        try await database.exec("INSERT INTO legal_holds (id, name, created_at) VALUES (?, ?, ?);", [.uuid(id), .text(name), .date(Date())])
        return id
    }

    public func addToHold(_ hold: UUID, objects: [UUID]) async throws {
        let now = Date()
        try await database.withSavepoint("legal_hold_add") { db in
            for o in objects {
                try db.exec("""
                    INSERT INTO legal_hold_items (hold_id, object_id, created_at) VALUES (?, ?, ?)
                    ON CONFLICT(hold_id, object_id) DO UPDATE SET removed_at = NULL;
                    """, [.uuid(hold), .uuid(o), .date(now)])
            }
        }
    }

    public func release(_ hold: UUID) async throws {
        try await database.exec("UPDATE legal_holds SET released_at = ? WHERE id = ?;", [.date(Date()), .uuid(hold)])
    }

    public func holds() async throws -> [LegalHold] {
        try await database.query("""
            SELECT h.id, h.name, h.created_at, h.released_at,
                   (SELECT COUNT(*) FROM legal_hold_items i WHERE i.hold_id = h.id AND i.removed_at IS NULL)
            FROM legal_holds h ORDER BY h.released_at IS NOT NULL, h.created_at DESC;
            """, []).compactMap { r in
            guard let id = r.uuid(0), let name = r.string(1) else { return nil }
            return LegalHold(id: id, name: name, createdAt: r.date(2) ?? Date(), releasedAt: r.date(3), items: Int(r.int(4) ?? 0))
        }
    }

    /// Documents under an active hold whose source file lies under `root` (blocks "forget this folder").
    public func heldCount(underRoot root: URL) async throws -> Int {
        let rows = try await database.query("""
            SELECT COUNT(DISTINCT i.object_id) FROM legal_hold_items i
            JOIN legal_holds h ON h.id = i.hold_id AND h.released_at IS NULL
            JOIN knowledge_objects ko ON ko.id = i.object_id
            JOIN files f ON f.id = ko.file_id
            WHERE i.removed_at IS NULL AND f.url LIKE ?;
            """, [.text(root.absoluteString + "%")])
        return Int(rows.first?.int(0) ?? 0)
    }
}
