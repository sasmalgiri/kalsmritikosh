//
//  BrowserHistoryLoader.swift
//  Kalsmritikosh
//
//  Phase K — reads Safari and Chromium (Chrome / Edge / Brave /
//  Arc) browser history into a single KnowledgeObject per profile.
//  Each visited URL becomes a line "[timestamp] title — url" so
//  the chunker, entity extractor, and event extractor all see the
//  history as ordinary content. Each visit can later be derived as
//  an event of kind `other` by the EventExtractor.
//
//  Requires Full Disk Access in System Settings → Privacy &
//  Security for Safari, and read-permission on the browser's
//  profile directory for Chromium. Like iMessage, we never open
//  the live DB in place — the ExternalSQLiteSource copies it
//  first so the browser's writes don't conflict.
//
//  Safari and Chromium use different epoch bases:
//    • Safari    — seconds since 2001-01-01 (Mach absolute time)
//    • Chromium  — microseconds since 1601-01-01 (Windows FILETIME)
//

import Foundation

public struct BrowserHistoryLoader: Ingestor {
    public let supportedTypes: Set<SourceType> = [.safariHistory, .chromeHistory]

    public static let maxVisits: Int = 5_000

    public nonisolated init() {}

    public func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
        let src: ExternalSQLiteSource
        do {
            src = try ExternalSQLiteSource(originalPath: url)
        } catch {
            throw IngestorError.unreadable(url, underlying: error)
        }
        let visits: [Visit]
        do {
            switch type {
            case .safariHistory:
                visits = try readSafari(src: src)
            case .chromeHistory:
                visits = try readChromium(src: src)
            default:
                throw IngestorError.unreadable(url, underlying: NSError(
                    domain: "BrowserHistoryLoader", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Unsupported type \(type.rawValue)"]
                ))
            }
        } catch {
            throw IngestorError.unreadable(url, underlying: error)
        }
        guard !visits.isEmpty else {
            throw IngestorError.empty(url)
        }
        let fmt = Self.timestampFormatter
        let lines = visits.map { visit -> String in
            let stamp = fmt.string(from: visit.date)
            let title = visit.title.isEmpty ? "(no title)" : visit.title
            return "[\(stamp)] \(title) — \(visit.url)"
        }
        let content = lines.joined(separator: "\n")
        let channelName: String
        switch type {
        case .safariHistory: channelName = "Safari"
        case .chromeHistory: channelName = "Chromium"
        default:             channelName = "Browser"
        }
        return KnowledgeObject(
            sourceFile: url,
            sourceType: type,
            content: content,
            metadata: [
                "filename": AnyCodable(.string(url.lastPathComponent)),
                "channel": AnyCodable(.string(channelName)),
                "visit_count": AnyCodable(.int(Int64(visits.count)))
            ]
        )
    }

    // MARK: - Safari

    private func readSafari(src: ExternalSQLiteSource) throws -> [Visit] {
        // Safari's schema (macOS 11+):
        //   history_items(id, url)
        //   history_visits(id, history_item, visit_time, title)
        // visit_time is seconds since Mach epoch (2001-01-01).
        let sql = """
        SELECT h.url, v.title, v.visit_time
        FROM history_visits v
        JOIN history_items h ON h.id = v.history_item
        WHERE h.url IS NOT NULL
        ORDER BY v.visit_time DESC
        LIMIT \(Self.maxVisits);
        """
        let rows = try src.query(sql)
        let appleEpoch: TimeInterval = 978_307_200
        return rows.compactMap { row -> Visit? in
            guard let urlStr = row.string(0) else { return nil }
            let title = row.string(1) ?? ""
            let raw = row.double(2) ?? 0
            return Visit(
                url: urlStr,
                title: title,
                date: Date(timeIntervalSince1970: appleEpoch + raw)
            )
        }
    }

    // MARK: - Chromium

    private func readChromium(src: ExternalSQLiteSource) throws -> [Visit] {
        // Chromium's schema:
        //   urls(id, url, title, ...)
        //   visits(id, url, visit_time, ...)
        // visit_time is microseconds since 1601-01-01.
        let sql = """
        SELECT u.url, u.title, v.visit_time
        FROM visits v
        JOIN urls u ON u.id = v.url
        WHERE u.url IS NOT NULL
        ORDER BY v.visit_time DESC
        LIMIT \(Self.maxVisits);
        """
        let rows = try src.query(sql)
        // FILETIME epoch: 1601-01-01 UTC = -11644473600 seconds from
        // UNIX epoch. Chromium stores microseconds since FILETIME.
        let chromiumEpochOffset: TimeInterval = -11_644_473_600
        return rows.compactMap { row -> Visit? in
            guard let urlStr = row.string(0) else { return nil }
            let title = row.string(1) ?? ""
            let raw = row.int(2) ?? 0
            let unixSeconds = chromiumEpochOffset + Double(raw) / 1_000_000.0
            return Visit(
                url: urlStr,
                title: title,
                date: Date(timeIntervalSince1970: unixSeconds)
            )
        }
    }

    // MARK: - Helpers

    private struct Visit {
        let url: String
        let title: String
        let date: Date
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
