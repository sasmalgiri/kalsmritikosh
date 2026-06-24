//
//  KnowledgeObjectRepository.swift
//  Kalsmritikosh
//
//  Persists the normalized KnowledgeObject. Metadata is JSON-encoded
//  into a single TEXT column; relationships to entities/events/summaries
//  live in their respective tables.
//

import Foundation

public actor KnowledgeObjectRepository {
    private let database: Database
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(database: Database) {
        self.database = database
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func insert(_ object: KnowledgeObject, fileID: UUID) async throws {
        let metadataJSON = try encoder.encode(object.metadata)
        try await database.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, metadata_json, confidence, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """, [
            .uuid(object.id),
            .uuid(fileID),
            .text(object.sourceType.rawValue),
            .text(object.content),
            .text(String(data: metadataJSON, encoding: .utf8) ?? "{}"),
            .real(object.confidence.value),
            .date(object.createdAt),
            .date(object.updatedAt)
        ])
    }

    public func count() async throws -> Int {
        let rows = try await database.query("SELECT COUNT(*) FROM knowledge_objects;")
        return Int(rows.first?.int(0) ?? 0)
    }

    public func fetchContent(id: KnowledgeObject.ID) async throws -> String? {
        let rows = try await database.query("""
        SELECT content FROM knowledge_objects WHERE id = ? LIMIT 1;
        """, [.uuid(id)])
        return rows.first?.string(0)
    }

    /// Resolve a batch of object IDs to their source file's last-path
    /// component (e.g. "contract.md", "invoice-401.eml"). The eval scorer
    /// uses this so it compares citations against the STABLE filename
    /// contract in questions.json — not the volatile per-ingest UUIDs.
    /// IDs that have no row map to nothing.
    public func sourceFilenames(
        for ids: Set<KnowledgeObject.ID>
    ) async throws -> [KnowledgeObject.ID: String] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let bindings: [SQLValue] = ids.map { .uuid($0) }
        let rows = try await database.query("""
        SELECT k.id, f.url
        FROM knowledge_objects k
        JOIN files f ON f.id = k.file_id
        WHERE k.id IN (\(placeholders));
        """, bindings)
        var out: [KnowledgeObject.ID: String] = [:]
        for row in rows {
            guard let id = row.uuid(0), let urlString = row.string(1) else { continue }
            let filename = URL(fileURLWithPath: urlString).lastPathComponent
            let resolved = filename.isEmpty
                ? URL(string: urlString)?.lastPathComponent ?? urlString
                : filename
            out[id] = resolved
        }
        return out
    }

    /// G3 BondBackfill — enumerate all KO ids in the ledger, paged so
    /// a million-KO archive doesn't blow up memory. Caller iterates
    /// (offset += pageSize) until the returned array is shorter than
    /// `pageSize`. Used to rebuild fact_bonds against an already-
    /// ingested corpus.
    public func allIDs(offset: Int = 0, pageSize: Int = 500) async throws -> [KnowledgeObject.ID] {
        let rows = try await database.query("""
        SELECT id FROM knowledge_objects
        ORDER BY created_at ASC
        LIMIT ? OFFSET ?;
        """, [.integer(Int64(pageSize)), .integer(Int64(offset))])
        return rows.compactMap { $0.uuid(0) }
    }

    /// G3 Phase 5 UI — resolve a KO id to the underlying file's URL.
    /// Used by the walk-step clickthrough so tapping a row in the
    /// "Why this answer?" panel reveals the source in Finder.
    /// Returns nil when the KO has no file row or the URL doesn't parse.
    public func fetchSourceURL(id: KnowledgeObject.ID) async throws -> URL? {
        let rows = try await database.query("""
        SELECT f.url FROM knowledge_objects k
        JOIN files f ON f.id = k.file_id
        WHERE k.id = ? LIMIT 1;
        """, [.uuid(id)])
        guard let urlString = rows.first?.string(0) else { return nil }
        return URL(string: urlString) ?? URL(fileURLWithPath: urlString)
    }

    public func recentContents(limit: Int = 30) async throws -> [String] {
        let rows = try await database.query("""
        SELECT content FROM knowledge_objects ORDER BY created_at DESC LIMIT ?;
        """, [.integer(Int64(limit))])
        return rows.compactMap { $0.string(0) }
    }

    public func findMentioning(_ needle: String, limit: Int = 30) async throws -> [(id: UUID, content: String)] {
        let pattern = "%\(needle)%"
        let rows = try await database.query("""
        SELECT id, content FROM knowledge_objects
        WHERE content LIKE ?
        ORDER BY created_at DESC
        LIMIT ?;
        """, [.text(pattern), .integer(Int64(limit))])
        return rows.compactMap { row in
            guard let id = row.uuid(0), let content = row.string(1) else { return nil }
            return (id, content)
        }
    }

    public func recent(limit: Int = 50) async throws -> [KnowledgeObjectSummaryRow] {
        let rows = try await database.query("""
        SELECT k.id, k.source_type, k.content, k.confidence, k.created_at, f.url
        FROM knowledge_objects k
        JOIN files f ON f.id = k.file_id
        ORDER BY k.created_at DESC
        LIMIT ?;
        """, [.integer(Int64(limit))])

        return rows.compactMap { row in
            guard
                let id = row.uuid(0),
                let typeRaw = row.string(1),
                let type = SourceType(rawValue: typeRaw),
                let content = row.string(2),
                let conf = row.double(3),
                let created = row.date(4),
                let urlString = row.string(5),
                let url = URL(string: urlString)
            else { return nil }
            return KnowledgeObjectSummaryRow(
                id: id,
                sourceFile: url,
                sourceType: type,
                preview: String(content.prefix(180)),
                confidence: Confidence(conf),
                createdAt: created
            )
        }
    }
}

/// Lightweight projection used by UI lists so we never load full content.
public struct KnowledgeObjectSummaryRow: Identifiable, Sendable, Hashable {
    public let id: KnowledgeObject.ID
    public let sourceFile: URL
    public let sourceType: SourceType
    public let preview: String
    public let confidence: Confidence
    public let createdAt: Date
}
