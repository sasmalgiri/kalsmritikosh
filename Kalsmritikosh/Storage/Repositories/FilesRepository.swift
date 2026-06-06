//
//  FilesRepository.swift
//  Kalsmritikosh
//
//  Row-level access to the `files` table. Tracks the raw on-disk
//  identities Atlas has discovered; KnowledgeObjects link back here.
//

import Foundation

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

    public init(
        id: UUID = UUID(),
        url: URL,
        sourceType: SourceType,
        sizeBytes: Int64 = 0,
        modifiedAt: Date = .init(),
        ingestedAt: Date? = nil,
        contentHash: String? = nil,
        aliasOf: UUID? = nil
    ) {
        self.id = id
        self.url = url
        self.sourceType = sourceType
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.ingestedAt = ingestedAt
        self.contentHash = contentHash
        self.aliasOf = aliasOf
    }
}

public actor FilesRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func upsert(_ record: FileRecord) async throws {
        try await database.exec("""
        INSERT INTO files (id, url, source_type, size_bytes, modified_at, ingested_at, content_hash, alias_of)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          url = excluded.url,
          source_type = excluded.source_type,
          size_bytes = excluded.size_bytes,
          modified_at = excluded.modified_at,
          ingested_at = excluded.ingested_at,
          content_hash = excluded.content_hash,
          alias_of = excluded.alias_of;
        """, [
            .uuid(record.id),
            .text(record.url.absoluteString),
            .text(record.sourceType.rawValue),
            .integer(record.sizeBytes),
            .date(record.modifiedAt),
            .optionalDate(record.ingestedAt),
            .optionalText(record.contentHash),
            record.aliasOf.map { SQLValue.uuid($0) } ?? .null
        ])
    }

    public func findByURL(_ url: URL) async throws -> FileRecord? {
        let rows = try await database.query(
            "SELECT id, url, source_type, size_bytes, modified_at, ingested_at, content_hash, alias_of FROM files WHERE url = ? LIMIT 1;",
            [.text(url.absoluteString)]
        )
        return rows.first.flatMap(decode)
    }

    /// Look up an already-ingested file by content hash, ignoring alias
    /// rows so callers always get the canonical owner of the KO.
    public func findCanonicalByContentHash(_ hash: String) async throws -> FileRecord? {
        let rows = try await database.query(
            "SELECT id, url, source_type, size_bytes, modified_at, ingested_at, content_hash, alias_of FROM files WHERE content_hash = ? AND alias_of IS NULL LIMIT 1;",
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
            "SELECT id, url, source_type, size_bytes, modified_at, ingested_at, content_hash, alias_of FROM files ORDER BY ingested_at DESC NULLS LAST;"
        )
        return rows.compactMap(decode)
    }

    public func count() async throws -> Int {
        let rows = try await database.query("SELECT COUNT(*) FROM files;")
        return Int(rows.first?.int(0) ?? 0)
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

        return FileRecord(
            id: id,
            url: url,
            sourceType: type,
            sizeBytes: row.int(3) ?? 0,
            modifiedAt: modified,
            ingestedAt: row.date(5),
            contentHash: row.string(6),
            aliasOf: row.uuid(7)
        )
    }
}
