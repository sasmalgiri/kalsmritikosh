//
//  HistoryAndMessagesStructuralParsers.swift
//  Kalsmritikosh
//
//  W4-2 — semantic adapters for three SQLite stores that were PRESERVED-ONLY:
//
//    Safari  History.db   history_visits.visit_time = Apple epoch seconds (2001)
//    Chrome  History      visits.visit_time = WebKit microseconds since 1601-01-01
//    Messages chat.db     message.date = Apple epoch, seconds before macOS 10.13,
//                         nanoseconds after (AppleEpoch handles both)
//
//  Each emits a header, then one dated, readable sentence per visit / message,
//  capped with a stated warning. Messages whose text exists only in the
//  `attributedBody` typedstream archive are decoded byte-wise (no archived class
//  is ever instantiated); any that cannot be decoded are counted and reported.
//  Read-only on a private copy, deterministic, offline. Behind the "More file
//  types" switch: when it is off the file is reported as kept but not read.
//

import Foundation
import CryptoKit

nonisolated enum SQLiteAdapterSupport {
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Chrome/WebKit time: microseconds since 1601-01-01 UTC.
    static func webkitDate(_ micros: Int64?) -> Date? {
        guard let micros, micros > 0 else { return nil }
        let unix = Double(micros) / 1_000_000 - 11_644_473_600
        guard unix > 0, unix < 4_102_444_800 else { return nil }
        return Date(timeIntervalSince1970: unix)
    }

    struct Builder {
        let documentID = UUID()
        let sourceVersionID: UUID
        let name: String
        var blocks: [EvidenceBlock] = []
        var warnings: [ParserWarning] = []

        mutating func add(_ kind: EvidenceBlockKind, _ raw: String, path: [String], attributes: [String: AnyCodable] = [:]) {
            blocks.append(EvidenceBlock(documentID: documentID, sourceVersionID: sourceVersionID, ordinal: blocks.count,
                                        kind: kind, rawText: raw, locator: SourceLocator(sectionPath: [name] + path),
                                        attributes: attributes))
        }
    }

    /// Shared skeleton: switch check, empty check, private copy, open, run `body`.
    static func run(data: Data, filename: String, type: SourceType, mime: String, logicalSourceID: UUID, sourceVersionID: UUID,
                    code: String, body: (ExternalSQLiteSource, inout Builder) throws -> Void) -> ParsedDocument {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var b = Builder(sourceVersionID: sourceVersionID, name: (filename as NSString).lastPathComponent)
        func doc(_ status: ExtractionStatus) -> ParsedDocument {
            ParsedDocument(id: b.documentID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
                           filename: filename, detectedType: type, mimeType: mime, contentHash: hash,
                           blocks: b.blocks, warnings: b.warnings, extractionStatus: status)
        }
        guard ProductModuleFlags.isEnabled(.extraParsers) else {
            b.warnings.append(ParserWarning(severity: .warning, code: "\(code).switched_off",
                message: "Kept with custody but not read: \"More file types\" is switched off in Settings → Modules."))
            return doc(.empty)
        }
        guard !data.isEmpty else {
            b.warnings.append(ParserWarning(severity: .warning, code: "\(code).empty", message: "File is zero bytes."))
            return doc(.empty)
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kalsmritikosh-\(code)-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try data.write(to: tmp, options: .atomic)
            let db = try ExternalSQLiteSource(originalPath: tmp)
            try body(db, &b)
        } catch {
            b.warnings.append(ParserWarning(severity: .error, code: "\(code).unreadable", message: "\(error)"))
            return doc(.corrupt)
        }
        if b.blocks.isEmpty { return doc(b.warnings.contains { $0.severity == .error } ? .corrupt : .empty) }
        return doc(b.warnings.isEmpty ? .complete : .partial)
    }

    static func hasTables(_ db: ExternalSQLiteSource, _ names: [String]) -> Bool {
        let have = Set(((try? db.query("SELECT name FROM sqlite_master WHERE type='table';")) ?? []).compactMap { $0.cells.first?.string })
        return names.allSatisfy(have.contains)
    }
}

public struct SafariHistoryStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.safariHistory] }
    public nonisolated var parserName: String { "safari-history" }
    public nonisolated var parserVersion: String { "1" }
    public nonisolated var boundedMemory: Bool { true }
    public nonisolated static let cap = 50_000
    public nonisolated init() {}

    public func parse(data: Data, filename: String, type: SourceType, logicalSourceID: UUID, sourceVersionID: UUID) async throws -> ParsedDocument {
        SQLiteAdapterSupport.run(data: data, filename: filename, type: .safariHistory, mime: "application/vnd.apple.safari-history",
                                 logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID, code: "safari") { db, b in
            guard SQLiteAdapterSupport.hasTables(db, ["history_items", "history_visits"]) else {
                b.warnings.append(ParserWarning(severity: .error, code: "safari.not_history",
                    message: "No history_items / history_visits tables: a SQLite file, but not Safari history."))
                return
            }
            let rows = try db.query("""
                SELECT i.url, v.title, v.visit_time FROM history_visits v JOIN history_items i ON i.id = v.history_item
                ORDER BY v.visit_time LIMIT \(Self.cap);
                """)
            let dates = rows.compactMap { AppleEpoch.date(fromAppleSeconds: $0.cells[2].double) }
            var header = "Safari history \"\(b.name)\": \(rows.count) visit(s)"
            if let a = dates.min(), let z = dates.max() { header += ", \(SQLiteAdapterSupport.iso.string(from: a)) to \(SQLiteAdapterSupport.iso.string(from: z))" }
            b.add(.documentHeader, header, path: [], attributes: ["visitCount": AnyCodable(.int(Int64(rows.count)))])
            for (i, r) in rows.enumerated() {
                guard r.cells.count >= 3, let url = r.cells[0].string else { continue }
                let when = AppleEpoch.date(fromAppleSeconds: r.cells[2].double)
                let title = r.cells[1].string.flatMap { $0.isEmpty ? nil : $0 }
                var attrs: [String: AnyCodable] = ["url": AnyCodable(.string(url))]
                if let when { attrs["timestamp"] = AnyCodable(.string(SQLiteAdapterSupport.iso.string(from: when))) }
                b.add(.logRecord, "Visited \(title.map { "“\($0)” " } ?? "")\(url) — \(when.map { SQLiteAdapterSupport.iso.string(from: $0) } ?? "no recorded time")",
                      path: ["visits", String(i)], attributes: attrs)
            }
            if rows.count >= Self.cap {
                b.warnings.append(ParserWarning(severity: .warning, code: "safari.cap", message: "Stopped after \(Self.cap) visits."))
            }
        }
    }
}

public struct ChromeHistoryStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.chromeHistory] }
    public nonisolated var parserName: String { "chrome-history" }
    public nonisolated var parserVersion: String { "1" }
    public nonisolated var boundedMemory: Bool { true }
    public nonisolated static let cap = 50_000
    public nonisolated init() {}

    public func parse(data: Data, filename: String, type: SourceType, logicalSourceID: UUID, sourceVersionID: UUID) async throws -> ParsedDocument {
        SQLiteAdapterSupport.run(data: data, filename: filename, type: .chromeHistory, mime: "application/x-chrome-history",
                                 logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID, code: "chrome") { db, b in
            guard SQLiteAdapterSupport.hasTables(db, ["urls", "visits"]) else {
                b.warnings.append(ParserWarning(severity: .error, code: "chrome.not_history",
                    message: "No urls / visits tables: a SQLite file, but not Chrome history."))
                return
            }
            let rows = try db.query("""
                SELECT u.url, u.title, v.visit_time FROM visits v JOIN urls u ON u.id = v.url
                ORDER BY v.visit_time LIMIT \(Self.cap);
                """)
            let dates = rows.compactMap { SQLiteAdapterSupport.webkitDate($0.cells[2].int64) }
            var header = "Chrome history \"\(b.name)\": \(rows.count) visit(s)"
            if let a = dates.min(), let z = dates.max() { header += ", \(SQLiteAdapterSupport.iso.string(from: a)) to \(SQLiteAdapterSupport.iso.string(from: z))" }
            b.add(.documentHeader, header, path: [], attributes: ["visitCount": AnyCodable(.int(Int64(rows.count)))])
            for (i, r) in rows.enumerated() {
                guard r.cells.count >= 3, let url = r.cells[0].string else { continue }
                let when = SQLiteAdapterSupport.webkitDate(r.cells[2].int64)
                let title = r.cells[1].string.flatMap { $0.isEmpty ? nil : $0 }
                var attrs: [String: AnyCodable] = ["url": AnyCodable(.string(url))]
                if let when { attrs["timestamp"] = AnyCodable(.string(SQLiteAdapterSupport.iso.string(from: when))) }
                b.add(.logRecord, "Visited \(title.map { "“\($0)” " } ?? "")\(url) — \(when.map { SQLiteAdapterSupport.iso.string(from: $0) } ?? "no recorded time")",
                      path: ["visits", String(i)], attributes: attrs)
            }
            if rows.count >= Self.cap {
                b.warnings.append(ParserWarning(severity: .warning, code: "chrome.cap", message: "Stopped after \(Self.cap) visits."))
            }
        }
    }
}

public struct IMessageStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.imessage] }
    public nonisolated var parserName: String { "apple-messages" }
    public nonisolated var parserVersion: String { "1" }
    public nonisolated var boundedMemory: Bool { true }
    public nonisolated static let cap = 100_000
    public nonisolated init() {}

    public func parse(data: Data, filename: String, type: SourceType, logicalSourceID: UUID, sourceVersionID: UUID) async throws -> ParsedDocument {
        SQLiteAdapterSupport.run(data: data, filename: filename, type: .imessage, mime: "application/vnd.apple.messages",
                                 logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID, code: "imessage") { db, b in
            guard SQLiteAdapterSupport.hasTables(db, ["message", "handle"]) else {
                b.warnings.append(ParserWarning(severity: .error, code: "imessage.not_messages",
                    message: "No message / handle tables: a SQLite file, but not a Messages database."))
                return
            }
            let hasChat = SQLiteAdapterSupport.hasTables(db, ["chat", "chat_message_join"])
            let chatColumn = hasChat
                ? "(SELECT COALESCE(NULLIF(c.display_name, ''), c.chat_identifier) FROM chat_message_join j JOIN chat c ON c.ROWID = j.chat_id WHERE j.message_id = m.ROWID LIMIT 1)"
                : "NULL"
            let rows = try db.query("""
                SELECT m.text, m.date, m.is_from_me, h.id, \(chatColumn), m.attributedBody
                FROM message m LEFT JOIN handle h ON h.ROWID = m.handle_id
                ORDER BY m.date LIMIT \(Self.cap);
                """)
            var withoutText = 0
            let dates = rows.compactMap { AppleEpoch.date(fromAppleSecondsOrNanoseconds: $0.cells[1].double) }
            var header = "Messages \"\(b.name)\": \(rows.count) message(s)"
            if let a = dates.min(), let z = dates.max() { header += ", \(SQLiteAdapterSupport.iso.string(from: a)) to \(SQLiteAdapterSupport.iso.string(from: z))" }
            b.add(.documentHeader, header, path: [], attributes: ["messageCount": AnyCodable(.int(Int64(rows.count)))])
            for (i, r) in rows.enumerated() {
                guard r.cells.count >= 6 else { continue }
                // Newer macOS keeps the text only in attributedBody (a typedstream archive).
                var fromArchive = false
                let plain = r.cells[0].string.flatMap { $0.isEmpty ? nil : $0 }
                let archived = plain == nil ? r.cells[5].data.flatMap(TypedStreamText.firstString) : nil
                if archived != nil { fromArchive = true }
                guard let text = plain ?? archived, !text.isEmpty else {
                    if r.cells[5].data != nil { withoutText += 1 }
                    continue
                }
                let when = AppleEpoch.date(fromAppleSecondsOrNanoseconds: r.cells[1].double)
                let fromMe = (r.cells[2].int64 ?? 0) != 0
                let other = r.cells[3].string ?? "unknown sender"
                let chat = r.cells[4].string
                let who = fromMe ? "Me → \(other)" : "\(other) → me"
                var attrs: [String: AnyCodable] = ["direction": AnyCodable(.string(fromMe ? "sent" : "received")),
                                                   "participant": AnyCodable(.string(other))]
                if let chat { attrs["chat"] = AnyCodable(.string(chat)) }
                if fromArchive { attrs["textSource"] = AnyCodable(.string("attributedBody")) }
                if let when { attrs["timestamp"] = AnyCodable(.string(SQLiteAdapterSupport.iso.string(from: when))) }
                b.add(.logRecord, "\(when.map { SQLiteAdapterSupport.iso.string(from: $0) } ?? "no recorded time") \(who)\(chat.map { " [\($0)]" } ?? ""): \(text)",
                      path: [chat ?? other, String(i)], attributes: attrs)
            }
            if withoutText > 0 {
                b.warnings.append(ParserWarning(severity: .warning, code: "imessage.attributed_body_only",
                    message: "\(withoutText) message(s) have an attributedBody archive whose text could not be decoded."))
            }
            if rows.count >= Self.cap {
                b.warnings.append(ParserWarning(severity: .warning, code: "imessage.cap", message: "Stopped after \(Self.cap) messages."))
            }
        }
    }
}

/// The message string inside an Apple typedstream `attributedBody` (NSAttributedString archive),
/// read byte-wise without instantiating any archived class: after the `NSString` class name the
/// archive holds `+` followed by a length (1 byte; 0x81 + 2 bytes LE; 0x82 + 4 bytes LE) and UTF-8.
nonisolated enum TypedStreamText {
    static func firstString(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        // The header holds non-ASCII bytes (e.g. 0x81) next to the "streamtyped" magic, so search bytes, not a decoded string.
        guard bytes.count > 16, find(Array("streamtyped".utf8), in: Array(bytes.prefix(24))) != nil else { return nil }
        let marker = Array("NSString".utf8)
        guard let at = find(marker, in: bytes) else { return nil }
        var i = at + marker.count
        // Skip the class-version bytes up to the '+' that introduces the C string.
        while i < bytes.count, i < at + marker.count + 8, bytes[i] != 0x2B { i += 1 }
        guard i < bytes.count, bytes[i] == 0x2B else { return nil }
        i += 1
        guard i < bytes.count else { return nil }
        var length = Int(bytes[i]); i += 1
        if length == 0x81 {
            guard i + 2 <= bytes.count else { return nil }
            length = Int(bytes[i]) | Int(bytes[i + 1]) << 8; i += 2
        } else if length == 0x82 {
            guard i + 4 <= bytes.count else { return nil }
            length = Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24; i += 4
        }
        guard length > 0, i + length <= bytes.count else { return nil }
        return String(bytes: bytes[i..<(i + length)], encoding: .utf8)
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard needle.count <= hay.count else { return nil }
        for i in 0...(hay.count - needle.count) where hay[i] == needle[0] && Array(hay[i..<(i + needle.count)]) == needle { return i }
        return nil
    }
}
