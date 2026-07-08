//
//  FilesRepository.swift
//  Kalsmritikosh
//
//  Row-level access to the `files` table. Tracks the raw on-disk
//  identities Kalsmritikosh has discovered; KnowledgeObjects link back here.
//

import Foundation

/// Where a file's bytes are right now, from the system's point of view.
public enum FileAvailability: String, Sendable, Codable, Hashable {
    /// File exists at its url and we last saw bytes.
    case available
    /// The root volume / folder this file belongs to isn't currently
    /// reachable (drive unplugged, network share down). Knowledge is
    /// kept; answers may cite with an "offline" badge.
    case offlineRoot = "offline_root"
    /// The root is reachable but the file is no longer at its url.
    /// Knowledge is kept; answers may cite with a "no longer on disk"
    /// badge. NEVER auto-cascade-deleted.
    case missing
}

public struct FileRecord: Sendable, Hashable {
    public let id: UUID
    public let url: URL
    public let sourceType: SourceType
    public let sizeBytes: Int64
    public let modifiedAt: Date
    public let ingestedAt: Date?
    public let contentHash: String?
    /// Non-nil when this file is a hash duplicate of another file: the
    /// canonical file owns the knowledge_objects row + chunks; this row
    /// just records that the duplicate URL also exists on disk.
    public let aliasOf: UUID?
    public let availability: FileAvailability

    public nonisolated init(
        id: UUID = UUID(),
        url: URL,
        sourceType: SourceType,
        sizeBytes: Int64 = 0,
        modifiedAt: Date = .init(),
        ingestedAt: Date? = nil,
        contentHash: String? = nil,
        aliasOf: UUID? = nil,
        availability: FileAvailability = .available
    ) {
        self.id = id
        self.url = url
        self.sourceType = sourceType
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.ingestedAt = ingestedAt
        self.contentHash = contentHash
        self.aliasOf = aliasOf
        self.availability = availability
    }
}

public actor FilesRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func upsert(_ record: FileRecord) async throws {
        try await database.exec("""
        INSERT INTO files (id, url, source_type, size_bytes, modified_at, ingested_at, content_hash, alias_of, availability)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          url = excluded.url,
          source_type = excluded.source_type,
          size_bytes = excluded.size_bytes,
          modified_at = excluded.modified_at,
          ingested_at = excluded.ingested_at,
          content_hash = excluded.content_hash,
          alias_of = excluded.alias_of,
          availability = excluded.availability;
        """, [
            .uuid(record.id),
            .text(record.url.absoluteString),
            .text(record.sourceType.rawValue),
            .integer(record.sizeBytes),
            .date(record.modifiedAt),
            .optionalDate(record.ingestedAt),
            .optionalText(record.contentHash),
            record.aliasOf.map { SQLValue.uuid($0) } ?? .null,
            .text(record.availability.rawValue)
        ])
    }

    /// Repoint a file row at a new url (move detected via content hash).
    /// Also resets availability back to .available since the bytes have
    /// just been resolved at the new path.
    public func updateURL(id: UUID, to newURL: URL) async throws {
        try await database.exec(
            "UPDATE files SET url = ?, availability = 'available' WHERE id = ?;",
            [.text(newURL.absoluteString), .uuid(id)]
        )
    }

    public func updateAvailability(id: UUID, to availability: FileAvailability) async throws {
        try await database.exec(
            "UPDATE files SET availability = ? WHERE id = ?;",
            [.text(availability.rawValue), .uuid(id)]
        )
    }

    /// Mark every file whose url begins with the given root prefix.
    /// Used for offline-root sweeps and reconciliation.
    public func markFilesUnderRoot(_ rootURL: URL, as availability: FileAvailability) async throws {
        let prefix = rootURL.absoluteString
        let pattern = "\(prefix)%"
        try await database.exec(
            "UPDATE files SET availability = ? WHERE url LIKE ?;",
            [.text(availability.rawValue), .text(pattern)]
        )
    }

    /// Count files (any availability) under a root prefix.
    public func countUnderRoot(_ rootURL: URL) async throws -> Int {
        let pattern = "\(rootURL.absoluteString)%"
        let rows = try await database.query(
            "SELECT COUNT(*) FROM files WHERE url LIKE ?;",
            [.text(pattern)]
        )
        return Int(rows.first?.int(0) ?? 0)
    }

    /// Cascading delete of every file under a root prefix. Used ONLY
    /// for the explicit "stop and forget everything from this folder"
    /// path — never from a reconciliation sweep.
    public func deleteAllUnderRoot(_ rootURL: URL) async throws {
        let pattern = "\(rootURL.absoluteString)%"
        try await database.exec(
            "DELETE FROM files WHERE url LIKE ?;",
            [.text(pattern)]
        )
    }

    public func listURLsUnderRoot(_ rootURL: URL) async throws -> [URL] {
        let pattern = "\(rootURL.absoluteString)%"
        let rows = try await database.query(
            "SELECT url FROM files WHERE url LIKE ?;",
            [.text(pattern)]
        )
        return rows.compactMap {
            guard let s = $0.string(0) else { return nil }
            return URL(string: s)
        }
    }

    public func findByURL(_ url: URL) async throws -> FileRecord? {
        let rows = try await database.query(
            "SELECT id, url, source_type, size_bytes, modified_at, ingested_at, content_hash, alias_of, availability FROM files WHERE url = ? LIMIT 1;",
            [.text(url.absoluteString)]
        )
        return rows.first.flatMap(decode)
    }

    /// Look up an already-ingested file by content hash, ignoring alias
    /// rows so callers always get the canonical owner of the KO.
    public func findCanonicalByContentHash(_ hash: String) async throws -> FileRecord? {
        let rows = try await database.query(
            "SELECT id, url, source_type, size_bytes, modified_at, ingested_at, content_hash, alias_of, availability FROM files WHERE content_hash = ? AND alias_of IS NULL LIMIT 1;",
            [.text(hash)]
        )
        return rows.first.flatMap(decode)
    }

    /// Count files (including aliases). Used for alias-bookkeeping
    /// assertions.
    public func countAll() async throws -> Int { try await count() }

    /// Count alias rows pointing at the given canonical file.
    public func countAliases(of canonicalID: UUID) async throws -> Int {
        let rows = try await database.query(
            "SELECT COUNT(*) FROM files WHERE alias_of = ?;",
            [.uuid(canonicalID)]
        )
        return Int(rows.first?.int(0) ?? 0)
    }

    public func all() async throws -> [FileRecord] {
        let rows = try await database.query(
            "SELECT id, url, source_type, size_bytes, modified_at, ingested_at, content_hash, alias_of, availability FROM files ORDER BY ingested_at DESC NULLS LAST;"
        )
        return rows.compactMap(decode)
    }

    public func count() async throws -> Int {
        let rows = try await database.query("SELECT COUNT(*) FROM files;")
        return Int(rows.first?.int(0) ?? 0)
    }

    /// Phase J.13 — per-format file census for the Live tab's
    /// "format breakdown" panel. One row per distinct source_type
    /// with its file count, sorted desc by count.
    public func countsBySourceType() async throws -> [(sourceType: String, count: Int)] {
        let rows = try await database.query("""
        SELECT source_type, COUNT(*) AS c
        FROM files
        GROUP BY source_type
        ORDER BY c DESC;
        """)
        return rows.compactMap { row in
            guard let type = row.string(0), let c = row.int(1) else { return nil }
            return (type, Int(c))
        }
    }

    /// Deletes the file row + everything tied to it via FK cascade
    /// (knowledge_objects → chunks / entities / events / relationships /
    /// summaries — see schema v1 for the cascade chain).
    public func deleteByID(_ id: UUID) async throws {
        try await database.exec(
            "DELETE FROM files WHERE id = ?;",
            [.uuid(id)]
        )
    }

    private func decode(_ row: SQLRow) -> FileRecord? {
        guard
            let id = row.uuid(0),
            let urlString = row.string(1),
            let url = URL(string: urlString),
            let typeRaw = row.string(2),
            let type = SourceType(rawValue: typeRaw),
            let modified = row.date(4)
        else { return nil }

        let availabilityRaw = row.string(8) ?? FileAvailability.available.rawValue
        return FileRecord(
            id: id,
            url: url,
            sourceType: type,
            sizeBytes: row.int(3) ?? 0,
            modifiedAt: modified,
            ingestedAt: row.date(5),
            contentHash: row.string(6),
            aliasOf: row.uuid(7),
            availability: FileAvailability(rawValue: availabilityRaw) ?? .available
        )
    }
}
