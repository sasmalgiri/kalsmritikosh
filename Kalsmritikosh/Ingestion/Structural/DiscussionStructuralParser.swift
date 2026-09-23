//
//  DiscussionStructuralParser.swift
//  Kalsmritikosh
//
//  DISC-1 — the ONE parser for every discussion platform. It never knows which
//  platform it is reading: DiscussionExportRegistry picks a mapper, the mapper
//  produces DiscussionRecords, and this turns records into typed blocks. Adding
//  Discord or Reddit adds a mapper, not a parser.
//
//  Structure emitted, grouped by thread:
//    .sectionHeading   one per thread — title, message count, date span
//    .discussionMessage one per utterance — "author (time): body", located by
//                       thread and record id, with the reply target in attributes
//
//  Threads are ordered by their earliest message and messages within a thread by
//  time, so the archive reads as conversations in the order they happened. Ties
//  break on record id, because two messages in the same second must still have a
//  fixed order or citations renumber on re-ingest.
//

import Foundation
import CryptoKit

public struct DiscussionStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.discussionExport] }
    public nonisolated var parserName: String { "discussion-export" }
    public nonisolated var parserVersion: String { "1" }

    private let registry: DiscussionExportRegistry

    public nonisolated init(registry: DiscussionExportRegistry = .standard) {
        self.registry = registry
    }

    public func parse(
        data: Data, filename: String, type: SourceType,
        logicalSourceID: UUID, sourceVersionID: UUID
    ) async throws -> ParsedDocument {
        let documentID = UUID()
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var blocks: [EvidenceBlock] = []
        var warnings: [ParserWarning] = []

        func add(_ kind: EvidenceBlockKind, _ raw: String, path: [String],
                 attributes: [String: AnyCodable] = [:]) {
            blocks.append(EvidenceBlock(
                documentID: documentID, sourceVersionID: sourceVersionID,
                ordinal: blocks.count, kind: kind, rawText: raw,
                locator: SourceLocator(sectionPath: path), attributes: attributes))
        }

        func document(_ status: ExtractionStatus) -> ParsedDocument {
            ParsedDocument(
                id: documentID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
                filename: filename, detectedType: .discussionExport,
                mimeType: "application/vnd.kalsmritikosh.discussion-export",
                contentHash: hash, blocks: blocks, warnings: warnings, extractionStatus: status)
        }

        guard !data.isEmpty else {
            warnings.append(ParserWarning(severity: .warning, code: "discussion.empty",
                                          message: "File is zero bytes."))
            return document(.empty)
        }
        guard let mapper = registry.mapper(filename: filename, data: data) else {
            // Recognized as a discussion export by name but no mapper claims the
            // content. Named honestly so the gap is visible, never guessed at.
            warnings.append(ParserWarning(severity: .error, code: "discussion.no_mapper",
                message: "No platform mapper claims \"\(filename)\". Known platforms: "
                       + registry.platforms.joined(separator: ", ") + "."))
            return document(.corrupt)
        }

        let export = mapper.map(data: data, filename: filename)
        warnings.append(contentsOf: export.warnings)
        guard !export.records.isEmpty else {
            warnings.append(ParserWarning(severity: .warning, code: "discussion.no_records",
                message: "\(export.platform) export decoded but contained no messages."))
            return document(.empty)
        }

        add(.documentHeader,
            "\(export.platform) export \"\(export.artifact)\": \(export.records.count) record(s)",
            path: [export.platform, export.artifact],
            attributes: [
                "platform": AnyCodable(.string(export.platform)),
                "mapper": AnyCodable(.string(mapper.mapperVersion)),
                "recordCount": AnyCodable(.int(Int64(export.records.count)))
            ])

        // Group into threads. Records with no thread id share one bucket, labelled
        // as such rather than pretending each is its own conversation.
        let unthreadedKey = "\u{0}unthreaded"
        var threads: [String: [DiscussionRecord]] = [:]
        for record in export.records {
            threads[record.threadID ?? unthreadedKey, default: []].append(record)
        }

        let ordered = threads.sorted { lhs, rhs in
            let l = lhs.value.compactMap(\.timestamp).min()
            let r = rhs.value.compactMap(\.timestamp).min()
            switch (l, r) {
            case let (l?, r?) where l != r: return l < r
            // Undated threads sort last, then by key, so the order is total.
            case (nil, _?): return false
            case (_?, nil): return true
            default: return lhs.key < rhs.key
            }
        }

        for (key, unsorted) in ordered {
            let records = unsorted.sorted { a, b in
                switch (a.timestamp, b.timestamp) {
                case let (x?, y?) where x != y: return x < y
                case (nil, _?): return false
                case (_?, nil): return true
                default: return a.recordID < b.recordID
                }
            }
            let title = records.first?.threadTitle
                ?? (key == unthreadedKey ? "(no thread recorded)" : key)
            let dates = records.compactMap(\.timestamp)
            var heading = "\(export.platform) — \(title): \(records.count) message(s)"
            if let first = dates.min(), let last = dates.max() {
                heading += first == last
                    ? ", \(Self.iso8601.string(from: first))"
                    : ", \(Self.iso8601.string(from: first)) to \(Self.iso8601.string(from: last))"
            }
            let threadPath = [export.platform, title]
            add(.sectionHeading, heading, path: threadPath, attributes: [
                "platform": AnyCodable(.string(export.platform)),
                "threadID": AnyCodable(.string(key == unthreadedKey ? "" : key)),
                "messageCount": AnyCodable(.int(Int64(records.count)))
            ])

            for record in records {
                var line = record.citedAuthor
                if let when = record.timestamp { line += " (\(Self.iso8601.string(from: when)))" }
                if record.kind == .reply, let parent = record.parentID {
                    line += " replying to \(parent)"
                }
                line += ": \(record.body)"

                var attributes: [String: AnyCodable] = [
                    "platform": AnyCodable(.string(record.platform)),
                    "kind": AnyCodable(.string(record.kind.rawValue)),
                    "recordID": AnyCodable(.string(record.recordID))
                ]
                if let parent = record.parentID { attributes["parentID"] = AnyCodable(.string(parent)) }
                if let author = record.authorID { attributes["authorID"] = AnyCodable(.string(author)) }
                if let handle = record.authorHandle { attributes["authorHandle"] = AnyCodable(.string(handle)) }
                if let when = record.timestamp {
                    attributes["timestamp"] = AnyCodable(.string(Self.iso8601.string(from: when)))
                }
                if let link = record.permalink { attributes["permalink"] = AnyCodable(.string(link)) }

                add(.discussionMessage, line,
                    path: threadPath + [record.recordID], attributes: attributes)
            }
        }

        let status: ExtractionStatus = warnings.isEmpty ? .complete : .partial
        return document(status)
    }

    private nonisolated static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
