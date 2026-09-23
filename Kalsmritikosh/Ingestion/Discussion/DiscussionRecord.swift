//
//  DiscussionRecord.swift
//  Kalsmritikosh
//
//  DISC-1 — the normalized unit of a discussion platform. Every platform export
//  (YouTube comments, Discord package, Reddit CSVs, X archive, Telegram JSON,
//  Twitch chat, saved forum HTML) maps into THIS, so the archive gains one
//  discussion model rather than nine parallel ones. Same rule as "formats die at
//  ingestion": platforms die at ingestion too.
//
//  What makes a discussion row evidence rather than a spreadsheet cell is here:
//  an author, a time, a thread it belongs to, and the record it replies to. With
//  those four, "what did this person say, where, in what order, and to whom"
//  becomes a query over the existing entity and timeline layers.
//
//  Collection is deliberately NOT part of this file. Kalsmritikosh reads exports
//  the account holder or a lawful order produced; it makes no network calls (the
//  target builds with ENABLE_OUTGOING_NETWORK_CONNECTIONS = NO), so there is no
//  API client and no credentialed scraper anywhere in the app.
//

import Foundation

public struct DiscussionRecord: Sendable, Equatable {

    public enum Kind: String, Sendable, Equatable {
        case post, comment, reply, directMessage, liveChat, activity
    }

    /// Platform display name, e.g. "YouTube". Used in citations, so it is the
    /// user-facing spelling, not a slug.
    public let platform: String
    public let kind: Kind
    /// Platform-native identifier. Carries dedup and reply-linking, so it must be
    /// the platform's own id, never one we invent.
    public let recordID: String
    /// The record this one replies to, when the export states it.
    public let parentID: String?
    /// Conversation this belongs to: a video id, channel, subreddit thread, DM pair.
    public let threadID: String?
    public let threadTitle: String?
    /// Display name / handle as it appeared.
    public let authorHandle: String?
    /// Stable platform id for the author. A handle can be changed or reused; this
    /// is what lets the entity layer unify one person across platforms safely.
    public let authorID: String?
    public let timestamp: Date?
    public let body: String
    public let permalink: String?

    public nonisolated init(
        platform: String, kind: Kind, recordID: String, parentID: String? = nil,
        threadID: String? = nil, threadTitle: String? = nil,
        authorHandle: String? = nil, authorID: String? = nil,
        timestamp: Date? = nil, body: String, permalink: String? = nil
    ) {
        self.platform = platform
        self.kind = kind
        self.recordID = recordID
        self.parentID = parentID
        self.threadID = threadID
        self.threadTitle = threadTitle
        self.authorHandle = authorHandle
        self.authorID = authorID
        self.timestamp = timestamp
        self.body = body
        self.permalink = permalink
    }

    /// Author as it should appear in a citation: the handle when we have one,
    /// otherwise the opaque id, never a fabricated "Unknown user".
    public nonisolated var citedAuthor: String {
        if let authorHandle, !authorHandle.isEmpty { return authorHandle }
        if let authorID, !authorID.isEmpty { return authorID }
        return "unattributed"
    }
}

/// One mapped export file.
public struct DiscussionExport: Sendable {
    public let platform: String
    /// Which file inside the export this came from, for provenance.
    public let artifact: String
    public let records: [DiscussionRecord]
    public let warnings: [ParserWarning]

    public nonisolated init(platform: String, artifact: String,
                            records: [DiscussionRecord], warnings: [ParserWarning] = []) {
        self.platform = platform; self.artifact = artifact
        self.records = records; self.warnings = warnings
    }
}

/// A per-platform mapper. Thin by design: it knows one export's field names and
/// nothing about blocks, chunking or the ledger.
public protocol DiscussionExportMapper: Sendable {
    nonisolated var platform: String { get }
    nonisolated var mapperVersion: String { get }

    /// Whether this mapper owns the file. Decided from the filename AND a sample
    /// of the bytes — content is the reliable signal, because export filenames
    /// like `comments.csv` or `messages.json` are not unique to one platform.
    nonisolated func claims(filename: String, sample: Data) -> Bool

    /// Map the whole file. Never throws for merely-empty or partly-malformed
    /// input: it returns what it could read plus warnings, so a damaged export
    /// yields evidence instead of nothing.
    nonisolated func map(data: Data, filename: String) -> DiscussionExport
}

/// Dispatch table over the registered mappers. Exactly one mapper handles a file;
/// ambiguity resolves by registration order, which is fixed and testable.
public struct DiscussionExportRegistry: Sendable {
    private let mappers: [any DiscussionExportMapper]

    public nonisolated init(mappers: [any DiscussionExportMapper]) {
        self.mappers = mappers
    }

    /// Registration order is the tie-break when two mappers could claim a file.
    /// In practice their content fingerprints are disjoint — YouTube's CSV needs a
    /// "Comment ID" + "Video ID" header, Reddit's needs "id" + "permalink", Discord's
    /// needs "ID" + "Timestamp" + "Contents" — and a test pins that no export is
    /// claimed by more than one mapper.
    public static let standard = DiscussionExportRegistry(mappers: [
        YouTubeTakeoutMapper(),
        DiscordPackageMapper(),
        RedditExportMapper(),
        XArchiveMapper(),
        MetaDownloadMapper()
    ])

    /// Every mapper, for the cross-platform disjointness test and for naming the
    /// supported set in an honest "no mapper claims this" warning.
    public nonisolated var allMappers: [any DiscussionExportMapper] { mappers }

    /// How many leading bytes a mapper may inspect to claim a file.
    public nonisolated static let sampleSize = 4096

    public nonisolated func mapper(filename: String, data: Data) -> (any DiscussionExportMapper)? {
        let sample = data.prefix(Self.sampleSize)
        return mappers.first { $0.claims(filename: filename, sample: sample) }
    }

    public nonisolated var platforms: [String] { mappers.map(\.platform) }
}
