//
//  DiscussionExportLoader.swift
//  Kalsmritikosh
//
//  DISC-1 — searchable-text surface for a discussion export, ONE KnowledgeObject
//  PER THREAD. That grouping is the point: a conversation is the unit a person
//  asks about, and keeping a thread whole means retrieval returns the exchange
//  rather than one orphaned comment. A platform export holding thousands of
//  threads becomes thousands of objects, the same way an mbox becomes one object
//  per message.
//

import Foundation

public struct DiscussionExportLoader: Ingestor {
    /// Injected, NOT fixed. `.chatExport` is an opt-in adapter, so a loader that
    /// claimed it unconditionally would open that gate by existing — the registry
    /// decides ownership purely from which loaders are present. Default is the
    /// ungated type only.
    public let supportedTypes: Set<SourceType>

    private let registry: DiscussionExportRegistry

    public nonisolated init(registry: DiscussionExportRegistry = .standard,
                            supportedTypes: Set<SourceType> = [.discussionExport]) {
        self.registry = registry
        self.supportedTypes = supportedTypes
    }

    public func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
        let objects = try await ingestMany(fileAt: url, type: type)
        guard let first = objects.first else { throw IngestorError.empty(url) }
        return first
    }

    public func ingestMany(fileAt url: URL, type: SourceType) async throws -> [KnowledgeObject] {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw IngestorError.unreadable(url, underlying: error) }

        let filename = url.lastPathComponent
        guard let mapper = registry.mapper(filename: filename, data: data) else {
            throw IngestorError.unreadable(url, underlying: NSError(
                domain: "Kalsmritikosh.DiscussionExportLoader", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                            "no platform mapper claims \"\(filename)\""]))
        }
        let export = mapper.map(data: data, filename: filename)
        guard !export.records.isEmpty else { throw IngestorError.empty(url) }

        let unthreaded = "\u{0}unthreaded"
        var threads: [String: [DiscussionRecord]] = [:]
        for record in export.records {
            threads[record.threadID ?? unthreaded, default: []].append(record)
        }

        var objects: [KnowledgeObject] = []
        for key in threads.keys.sorted() {
            let records = (threads[key] ?? []).sorted { a, b in
                switch (a.timestamp, b.timestamp) {
                case let (x?, y?) where x != y: return x < y
                case (nil, _?): return false
                case (_?, nil): return true
                default: return a.recordID < b.recordID
                }
            }
            let title = records.first?.threadTitle
                ?? (key == unthreaded ? "(no thread recorded)" : key)

            var lines = ["\(export.platform) — \(title) (\(records.count) message(s)):"]
            for record in records {
                var line = record.citedAuthor
                if let when = record.timestamp { line += " (\(Self.iso8601.string(from: when)))" }
                if record.kind == .reply, let parent = record.parentID {
                    line += " replying to \(parent)"
                }
                lines.append(line + ": " + record.body)
            }

            var meta: [String: AnyCodable] = [
                "filename": AnyCodable(.string(filename)),
                "loader": AnyCodable(.string("discussion-export")),
                "platform": AnyCodable(.string(export.platform)),
                "threadTitle": AnyCodable(.string(title)),
                "messageCount": AnyCodable(.int(Int64(records.count)))
            ]
            if key != unthreaded { meta["threadID"] = AnyCodable(.string(key)) }
            if let first = records.compactMap(\.timestamp).min() {
                meta["threadStart"] = AnyCodable(.string(Self.iso8601.string(from: first)))
            }

            objects.append(KnowledgeObject(
                sourceFile: url, sourceType: type,
                content: lines.joined(separator: "\n"),
                metadata: meta,
                confidence: export.warnings.isEmpty ? .high : .medium))
        }
        return objects
    }

    private nonisolated static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
