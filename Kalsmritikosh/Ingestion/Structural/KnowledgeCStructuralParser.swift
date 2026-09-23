//
//  KnowledgeCStructuralParser.swift
//  Kalsmritikosh
//
//  HOST-7 — semantic adapter for macOS/iOS `knowledgeC.db`, Apple's CoreDuet
//  activity store. It is the single best answer to "what was this person doing
//  at 21:14": app focus with durations, device lock and unlock, screen backlight,
//  now-playing media, battery, Siri and web usage — all dated, often for weeks.
//
//  The generic record-level SQLite lane (DB-1) already indexes every row of this
//  file, so nothing here is about reading it. What this adds is MEANING, and one
//  correction that matters more than the rest:
//
//    ZSTARTDATE / ZENDDATE are APPLE EPOCH — seconds since 2001-01-01, not 1970.
//    Indexed generically they arrive as `ZSTARTDATE = 764851613.0`, which is
//    neither searchable nor on the timeline; read as a Unix time they would date
//    a 2026 event to 1994. Converted here, an app-usage row becomes
//    "com.apple.Safari was in focus 2026-03-14T09:26:53Z to 09:31:00Z (4m 7s)".
//
//  ZSECONDSFROMGMT is kept too, because it states the time zone the DEVICE was in
//  at that moment — something the timestamps themselves cannot tell an examiner.
//
//  Read-only on a private copy, deterministic, offline. Never throws.
//

import Foundation
import CryptoKit

public struct KnowledgeCStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.knowledgeC] }
    public nonisolated var parserName: String { "apple-knowledgec" }
    public nonisolated var parserVersion: String { "1" }

    /// Event ceiling. A months-old store holds hundreds of thousands of rows;
    /// this is the citation layer, so it stops at a stated number while the
    /// record lane keeps indexing everything.
    public nonisolated static let eventCap = 50_000

    public nonisolated init() {}

    public func parse(
        data: Data, filename: String, type: SourceType,
        logicalSourceID: UUID, sourceVersionID: UUID
    ) async throws -> ParsedDocument {
        let documentID = UUID()
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let dbName = (filename as NSString).lastPathComponent
        var blocks: [EvidenceBlock] = []
        var warnings: [ParserWarning] = []

        func add(_ kind: EvidenceBlockKind, _ raw: String, path: [String],
                 attributes: [String: AnyCodable] = [:]) {
            blocks.append(EvidenceBlock(
                documentID: documentID, sourceVersionID: sourceVersionID,
                ordinal: blocks.count, kind: kind, rawText: raw,
                locator: SourceLocator(sectionPath: [dbName] + path),
                attributes: attributes))
        }
        func document(_ status: ExtractionStatus) -> ParsedDocument {
            ParsedDocument(
                id: documentID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
                filename: filename, detectedType: .knowledgeC,
                mimeType: "application/vnd.apple.knowledgec", contentHash: hash,
                blocks: blocks, warnings: warnings, extractionStatus: status)
        }

        guard !data.isEmpty else {
            warnings.append(ParserWarning(severity: .warning, code: "knowledgec.empty",
                                          message: "File is zero bytes."))
            return document(.empty)
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kalsmritikosh-knowledgec-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: tmp) }

        var events: [Event] = []
        do {
            try data.write(to: tmp, options: .atomic)
            let db = try ExternalSQLiteSource(originalPath: tmp)

            // ZOBJECT is the activity table. Its absence means this is a SQLite
            // file that is not a knowledgeC store — reported, not guessed at.
            let hasZObject = ((try? db.query(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='ZOBJECT';")) ?? [])
                .isEmpty == false
            guard hasZObject else {
                warnings.append(ParserWarning(severity: .error, code: "knowledgec.no_zobject",
                    message: "No ZOBJECT table: this is a SQLite database but not a "
                           + "knowledgeC activity store."))
                return document(.corrupt)
            }

            // Only the columns this parser interprets, so a schema that gained or
            // lost unrelated columns between OS versions still reads.
            let available = Set(((try? db.query("PRAGMA table_info(ZOBJECT);")) ?? [])
                .compactMap { $0.cells.count > 1 ? $0.cells[1].string : nil })
            func column(_ name: String, _ fallback: String) -> String {
                available.contains(name) ? name
                    : (available.contains(fallback) ? fallback : "NULL")
            }
            let valueColumn = column("ZVALUESTRING", "ZSTRINGVALUE")
            let offsetColumn = column("ZSECONDSFROMGMT", "ZSECONDSFROMGMT")

            let sql = """
            SELECT ZSTREAMNAME, \(valueColumn), ZSTARTDATE, ZENDDATE, \(offsetColumn)
            FROM ZOBJECT
            WHERE ZSTREAMNAME IS NOT NULL
            ORDER BY ZSTARTDATE, Z_PK
            LIMIT \(Self.eventCap);
            """
            let rows = (try? db.query(sql)) ?? []
            if rows.isEmpty {
                warnings.append(ParserWarning(severity: .warning, code: "knowledgec.no_events",
                                              message: "ZOBJECT exists but holds no named streams."))
            }
            for row in rows {
                guard row.cells.count >= 5, let stream = row.cells[0].string else { continue }
                let start = AppleEpoch.date(fromAppleSeconds: row.cells[2].double)
                let end = AppleEpoch.date(fromAppleSeconds: row.cells[3].double)
                events.append(Event(
                    stream: stream,
                    value: row.cells[1].string,
                    start: start, end: end,
                    utcOffset: row.cells[4].int64.map { Int($0) }))
            }
            if rows.count >= Self.eventCap {
                warnings.append(ParserWarning(severity: .warning, code: "knowledgec.event_cap",
                    message: "Stopped after \(Self.eventCap) events; later activity has no "
                           + "individual citation. All rows remain searchable via record-level "
                           + "ingest."))
            }
        } catch {
            warnings.append(ParserWarning(severity: .error, code: "knowledgec.unreadable",
                                          message: "\(error)"))
            return document(.corrupt)
        }

        guard !events.isEmpty else { return document(.empty) }

        // Header: what this store covers, and which time zone the device was in.
        let dated = events.compactMap(\.start)
        var header = "Apple activity store \"\(dbName)\": \(events.count) event(s)"
        if let first = dated.min(), let last = dated.max() {
            header += ", \(Self.iso8601.string(from: first)) to \(Self.iso8601.string(from: last))"
        }
        let offsets = Set(events.compactMap { AppleEpoch.utcOffsetLabel(secondsFromGMT: $0.utcOffset) })
        if !offsets.isEmpty {
            header += ", device time zone " + offsets.sorted().joined(separator: " / ")
        }
        add(.documentHeader, header, path: [], attributes: [
            "eventCount": AnyCodable(.int(Int64(events.count))),
            "deviceUTCOffsets": AnyCodable(.string(offsets.sorted().joined(separator: ",")))
        ])

        // Group by stream so "app focus" reads as one body of activity rather
        // than interleaved with battery samples.
        let byStream = Dictionary(grouping: events, by: \.stream)
        for stream in byStream.keys.sorted() {
            let group = (byStream[stream] ?? []).sorted {
                switch ($0.start, $1.start) {
                case let (a?, b?) where a != b: return a < b
                case (nil, _?): return false
                case (_?, nil): return true
                default: return ($0.value ?? "") < ($1.value ?? "")
                }
            }
            let label = Self.streamLabel(stream)
            add(.sectionHeading, "\(label) (\(stream)): \(group.count) event(s)",
                path: [stream], attributes: [
                    "stream": AnyCodable(.string(stream)),
                    "eventCount": AnyCodable(.int(Int64(group.count)))
                ])

            for (index, event) in group.enumerated() {
                var line = Self.sentence(for: event, label: label)
                if let offset = AppleEpoch.utcOffsetLabel(secondsFromGMT: event.utcOffset) {
                    line += " [device UTC\(offset)]"
                }
                var attributes: [String: AnyCodable] = [
                    "stream": AnyCodable(.string(event.stream)),
                    "activity": AnyCodable(.string(label))
                ]
                if let value = event.value { attributes["value"] = AnyCodable(.string(value)) }
                if let start = event.start {
                    attributes["timestamp"] = AnyCodable(.string(Self.iso8601.string(from: start)))
                }
                if let end = event.end {
                    attributes["endTimestamp"] = AnyCodable(.string(Self.iso8601.string(from: end)))
                }
                if let offset = event.utcOffset {
                    attributes["deviceSecondsFromGMT"] = AnyCodable(.int(Int64(offset)))
                }
                add(.logRecord, line, path: [stream, String(index)], attributes: attributes)
            }
        }

        let status: ExtractionStatus = warnings.isEmpty ? .complete : .partial
        return document(status)
    }

    // MARK: - Model

    private struct Event {
        let stream: String
        let value: String?
        let start: Date?
        let end: Date?
        let utcOffset: Int?
    }

    /// One readable sentence per event. Written as prose because that is what the
    /// retrieval layer searches and what an answer quotes.
    private nonisolated static func sentence(for event: Event, label: String) -> String {
        var parts: [String] = []
        if let value = event.value, !value.isEmpty {
            parts.append("\(value) — \(label.lowercased())")
        } else {
            parts.append(label)
        }
        if let start = event.start {
            if let end = event.end, end > start {
                var span = "\(iso8601.string(from: start)) to \(iso8601.string(from: end))"
                if let duration = AppleEpoch.durationLabel(from: start, to: end) {
                    span += " (\(duration))"
                }
                parts.append(span)
            } else {
                parts.append(iso8601.string(from: start))
            }
        } else {
            // Said plainly rather than omitted: an undated activity row is a
            // different fact from a dated one.
            parts.append("no recorded time")
        }
        return parts.joined(separator: " ")
    }

    /// CoreDuet stream names are paths like `/app/inFocus`. The mapping covers the
    /// streams that carry investigative weight; anything else keeps its raw name
    /// rather than being dropped or given an invented label.
    nonisolated static func streamLabel(_ stream: String) -> String {
        switch stream {
        case "/app/inFocus":            return "App in focus"
        case "/app/usage":              return "App usage"
        case "/app/activity":           return "App activity"
        case "/app/install":            return "App installed"
        case "/app/webUsage":           return "Web usage in app"
        case "/display/isBacklit":      return "Screen on"
        case "/device/isLocked":        return "Device locked"
        case "/device/isPluggedIn":     return "Device charging"
        case "/device/batteryPercentage": return "Battery level"
        case "/safari/history":         return "Safari page visit"
        case "/media/nowPlaying":       return "Media playing"
        case "/audio/outputRoute":      return "Audio output route"
        case "/bluetooth/isConnected":  return "Bluetooth connected"
        case "/siri/usage":             return "Siri used"
        case "/notification/usage":     return "Notification shown"
        case "/portrait/topic":         return "On-screen topic"
        case "/searchengine/usage":     return "Search engine used"
        case "/user/motion":            return "User motion"
        default:
            // "/foo/barBaz" → "foo barBaz", so an unmapped stream still reads.
            let readable = stream.split(separator: "/").joined(separator: " ")
            return readable.isEmpty ? stream : readable
        }
    }

    private nonisolated static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
