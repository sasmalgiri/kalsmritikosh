//
//  SpeedBenchCorpus.swift
//  KalsmritikoshTests
//
//  Speed program PERF-33 (owner 2026-11-23) — a deterministic generated corpus for SpeedBenchmarkTests. Never the
//  owner's ledger or files: everything is written by this generator into a temporary folder and removed after the run.
//
//  Contents (medium; small is about a fifth): text and markdown documents, three mbox mailboxes (one large, its size
//  carried by binary attachments), PDFs (text pages, a few ~50-page ones, a few image-only pages for OCR), CSV tables,
//  and one ZIP with many members. Every text carries people, organisations, dates, amounts and invoice numbers so the
//  extraction stages have real work. The same seed writes byte-identical files on every run.
//

import Foundation
import CoreGraphics
import CoreText
@testable import Kalsmritikosh

nonisolated struct SpeedBenchCorpusSize: Sendable, Codable {
    let label: String
    let documents: Int
    let emailsPerSmallMailbox: Int
    let emailsInLargeMailbox: Int
    let largeMailboxBytes: Int
    let pdfs: Int
    let longPDFs: Int
    let longPDFPages: Int
    let imageOnlyPDFs: Int
    let csvs: Int
    let csvRows: Int
    let zipMembers: Int

    static let small = SpeedBenchCorpusSize(label: "small", documents: 400, emailsPerSmallMailbox: 10, emailsInLargeMailbox: 40,
                                            largeMailboxBytes: 10_000_000, pdfs: 40, longPDFs: 1, longPDFPages: 50, imageOnlyPDFs: 2,
                                            csvs: 10, csvRows: 400, zipMembers: 50)
    static let medium = SpeedBenchCorpusSize(label: "medium", documents: 2_000, emailsPerSmallMailbox: 50, emailsInLargeMailbox: 200,
                                             largeMailboxBytes: 50_000_000, pdfs: 200, longPDFs: 4, longPDFPages: 50, imageOnlyPDFs: 5,
                                             csvs: 50, csvRows: 1_000, zipMembers: 200)

    static func named(_ s: String?) -> SpeedBenchCorpusSize { s?.lowercased() == "medium" ? .medium : .small }
}

/// What the generator wrote.
nonisolated struct SpeedBenchCorpusManifest: Sendable, Codable {
    var size: SpeedBenchCorpusSize
    var files = 0
    var bytes: Int64 = 0
    var byKind: [String: Int] = [:]
    var bytesByKind: [String: Int64] = [:]
    var emails = 0
    var pdfPages = 0
    var zipMembers = 0
    var csvRows = 0
    var generateSeconds = 0.0
}

/// SplitMix64 — deterministic, no Foundation randomness.
nonisolated struct SpeedBenchRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
    mutating func pick<T>(_ xs: [T]) -> T { xs[int(xs.count)] }
}

nonisolated enum SpeedBenchCorpus {
    static let people = ["Ann Lee", "Rahul Mehta", "Priya Nair", "John Carter", "Maria Gomez", "Wei Chen", "Fatima Khan",
                         "David Brown", "Sofia Rossi", "Arjun Rao", "Emily Clarke", "Kenji Sato", "Olga Petrova", "Samuel Okafor",
                         "Laura Schmidt", "Vikram Singh", "Grace Kim", "Tom Walsh", "Nadia Haddad", "Peter Novak",
                         "Hannah Miller", "Ravi Iyer", "Chloe Martin", "Ibrahim Musa", "Elena Ivanova", "George Hall",
                         "Meera Das", "Lucas Silva", "Zara Ahmed", "Owen Price"]
    static let orgs = ["Northwind Supplies Ltd", "Bluefin Logistics", "Harbor Bank", "Crescent Engineering", "Apex Holdings",
                       "Silverline Traders", "Meridian Health", "Kestrel Construction", "Orchid Pharma", "Granite Insurance",
                       "Lotus Textiles", "Summit Advisory", "Pioneer Freight", "Redwood Capital", "Delta Facilities"]
    static let places = ["Mumbai", "London", "Singapore", "Dubai", "Frankfurt", "New York", "Kolkata", "Chennai", "Toronto", "Sydney"]
    static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
                         "November", "December"]
    static let topics = ["the warehouse lease", "the freight contract", "the software licence", "the audit fee",
                         "the consulting retainer", "the equipment purchase", "the insurance claim", "the supplier rebate",
                         "the site renovation", "the loan repayment"]

    static func date(_ r: inout SpeedBenchRandom) -> String {
        "\(1 + r.int(28)) \(r.pick(months)) \(2019 + r.int(6))"
    }

    static func amount(_ r: inout SpeedBenchRandom) -> String {
        let n = 1_000 + r.int(990_000)
        let cents = r.int(100)
        let grouped = n >= 1_000 ? "\(n / 1_000)," + String(String(n % 1_000 + 1_000).dropFirst()) : "\(n)"
        return "$" + grouped + "." + (cents < 10 ? "0\(cents)" : "\(cents)")
    }

    /// One paragraph with names, dates, amounts and an invoice number.
    static func paragraph(_ r: inout SpeedBenchRandom, _ i: Int) -> String {
        let a = r.pick(people), b = r.pick(people), o = r.pick(orgs), o2 = r.pick(orgs), t = r.pick(topics), p = r.pick(places)
        let inv = "INV-\(10_000 + r.int(90_000))"
        switch r.int(6) {
        case 0: return "On \(date(&r)), \(a) of \(o) approved a payment of \(amount(&r)) to \(o2) for \(t) under invoice \(inv)."
        case 1: return "\(a) met \(b) in \(p) on \(date(&r)) to discuss \(t); \(b) said the amount of \(amount(&r)) had already been paid."
        case 2: return "Invoice \(inv) from \(o2) for \(amount(&r)) was received on \(date(&r)) and forwarded by \(a) to the finance team at \(o)."
        case 3: return "According to \(b), the contract for \(t) was signed in \(p) on \(date(&r)) by \(a) on behalf of \(o)."
        case 4: return "\(o) transferred \(amount(&r)) from account 44\(r.int(9_000) + 1_000) to \(o2) on \(date(&r)); reference \(inv)."
        default: return "Note \(i): \(a) asked \(b) whether \(t) was paid twice; the ledger shows \(amount(&r)) on \(date(&r)) and again later."
        }
    }

    static func text(_ r: inout SpeedBenchRandom, _ i: Int, paragraphs: Int) -> String {
        (0..<paragraphs).map { _ in paragraph(&r, i) }.joined(separator: "\n\n")
    }

    /// Write the corpus into `root` (created). Deterministic for a size.
    static func generate(_ size: SpeedBenchCorpusSize, into root: URL, seed: UInt64 = 0x5EED_2026_1123) throws -> SpeedBenchCorpusManifest {
        let t0 = Date()
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var m = SpeedBenchCorpusManifest(size: size)
        var r = SpeedBenchRandom(seed: seed)
        func write(_ data: Data, _ rel: String, kind: String) throws {
            let url = root.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            m.files += 1
            m.bytes += Int64(data.count)
            m.byKind[kind, default: 0] += 1
            m.bytesByKind[kind, default: 0] += Int64(data.count)
        }

        // 1. Text and markdown documents, in folders of 100.
        for i in 0..<size.documents {
            let paras = 4 + r.int(12)
            let body = text(&r, i, paragraphs: paras)
            if i % 2 == 0 {
                let md = "# Memo \(i): \(r.pick(topics))\n\nDate: \(date(&r))\nAuthor: \(r.pick(people))\n\n## Summary\n\n" + body + "\n"
                try write(Data(md.utf8), "docs/\(i / 100)/memo-\(i).md", kind: "md")
            } else {
                let txt = "MEMO \(i)\nFrom: \(r.pick(people)), \(r.pick(orgs))\nDate: \(date(&r))\n\n" + body + "\n"
                try write(Data(txt.utf8), "docs/\(i / 100)/note-\(i).txt", kind: "txt")
            }
        }

        // 2. Mailboxes: two small ones and one large one (its size carried by binary attachments).
        func message(_ n: Int, attachment: Int) -> String {
            let from = r.pick(people), to = r.pick(people)
            let mail = { (p: String) in p.lowercased().replacingOccurrences(of: " ", with: ".") + "@example.com" }
            let day = 1 + r.int(28), month = 1 + r.int(12), year = 2019 + r.int(6)
            let d = String(format: "%02d %@ %d %02d:%02d:00 +0000", day, ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][month - 1],
                           year, r.int(24), r.int(60))
            let paras = 3 + r.int(6)
            let body = text(&r, n, paragraphs: paras)
            var s = "From \(mail(from)) Mon Jan  1 00:00:00 2024\n"
            s += "From: \(from) <\(mail(from))>\nTo: \(to) <\(mail(to))>\nSubject: Re: \(r.pick(topics)) (\(n))\nDate: \(d)\n"
            s += "Message-ID: <bench-\(n)@example.com>\nMIME-Version: 1.0\n"
            if attachment > 0 {
                var bytes = [UInt8](repeating: 0, count: attachment)
                for k in 0..<attachment { bytes[k] = UInt8(truncatingIfNeeded: r.next()) }
                let b64 = Data(bytes).base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
                s += "Content-Type: multipart/mixed; boundary=\"b\(n)\"\n\n--b\(n)\nContent-Type: text/plain; charset=utf-8\n\n\(body)\n\n"
                s += "--b\(n)\nContent-Type: application/octet-stream; name=\"scan-\(n).bin\"\nContent-Transfer-Encoding: base64\n"
                s += "Content-Disposition: attachment; filename=\"scan-\(n).bin\"\n\n\(b64)\n--b\(n)--\n\n"
            } else {
                s += "Content-Type: text/plain; charset=utf-8\n\n\(body)\n\n"
            }
            return s
        }
        var n = 0
        for box in 0..<2 {
            var s = ""
            for _ in 0..<size.emailsPerSmallMailbox { s += message(n, attachment: 0); n += 1 }
            try write(Data(s.utf8), "mail/inbox-\(box).mbox", kind: "mbox")
        }
        do {
            let per = max(0, size.largeMailboxBytes / max(1, size.emailsInLargeMailbox) * 3 / 4 - 2_000)   // base64 grows 4/3
            var s = ""
            for _ in 0..<size.emailsInLargeMailbox { s += message(n, attachment: per); n += 1 }
            try write(Data(s.utf8), "mail/archive-large.mbox", kind: "mbox")
        }
        m.emails = n

        // 3. PDFs: short text PDFs, a few long ones, a few image-only (scanned) pages.
        for i in 0..<size.pdfs {
            let long = i < size.longPDFs
            let pages = long ? size.longPDFPages : 1 + r.int(3)
            let texts = (0..<pages).map { p in "Report \(i), page \(p + 1)\n\n" + text(&r, i, paragraphs: 6) }
            try write(pdf(texts, imageOnly: false), "pdf/report-\(i).pdf", kind: "pdf")
            m.pdfPages += pages
        }
        for i in 0..<size.imageOnlyPDFs {
            let t = "SCANNED LETTER \(i)\n\n" + text(&r, i, paragraphs: 2)
            try write(pdf([t], imageOnly: true), "pdf/scan-\(i).pdf", kind: "pdf-image")
            m.pdfPages += 1
        }

        // 4. CSV tables.
        for i in 0..<size.csvs {
            var s = "date,payer,payee,amount,invoice,memo\n"
            for _ in 0..<size.csvRows {
                s += "\(date(&r)),\(r.pick(orgs)),\(r.pick(orgs)),\(amount(&r).replacingOccurrences(of: ",", with: "")),INV-\(10_000 + r.int(90_000)),\(r.pick(topics))\n"
            }
            m.csvRows += size.csvRows
            try write(Data(s.utf8), "tables/ledger-\(i).csv", kind: "csv")
        }

        // 5. One ZIP with many members.
        var zip = ZIPArchiveWriter()
        for i in 0..<size.zipMembers {
            let paras = 3 + r.int(4)
            zip.addFile(path: "bundle/item-\(i).txt", text: "Bundle item \(i)\n\n" + text(&r, i, paragraphs: paras))
        }
        try write(zip.build(), "archive/bundle.zip", kind: "zip")
        m.zipMembers = size.zipMembers
        m.generateSeconds = Date().timeIntervalSince(t0)
        return m
    }

    // MARK: - PDF

    /// A PDF with one page per text. `imageOnly` draws the text into a bitmap and places only the image on the page
    /// (no text layer — the reader has to recognise it).
    static func pdf(_ pages: [String], imageOnly: Bool) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, imageOnly ? 22 : 11, nil)
        for page in pages {
            ctx.beginPDFPage(nil)
            let attributed = NSAttributedString(string: page, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let setter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
            if imageOnly {
                let scale = 2
                let w = Int(box.width) * scale, h = Int(box.height) * scale
                guard let bitmap = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                bitmap.setFillColor(gray: 1, alpha: 1)
                bitmap.fill(CGRect(x: 0, y: 0, width: w, height: h))
                bitmap.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
                bitmap.setFillColor(gray: 0, alpha: 1)
                let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: box.insetBy(dx: 54, dy: 54), transform: nil), nil)
                CTFrameDraw(frame, bitmap)
                guard let image = bitmap.makeImage() else { throw CocoaError(.fileWriteUnknown) }
                ctx.draw(image, in: box)
            } else {
                let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: box.insetBy(dx: 54, dy: 54), transform: nil), nil)
                CTFrameDraw(frame, ctx)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }
}
