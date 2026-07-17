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

    // MARK: - T18 privilege (§21)

    /// Mark / unmark a KnowledgeObject as privileged. Privileged material is
    /// withheld from answer/evidence surfaces (enforced at the presentation
    /// boundary; full retrieval-layer enforcement is a follow-up).
    public func setPrivileged(_ privileged: Bool, forID id: KnowledgeObject.ID) async throws {
        try await database.exec(
            "UPDATE knowledge_objects SET privileged = ? WHERE id = ?;",
            [.integer(privileged ? 1 : 0), .uuid(id)]
        )
    }

    /// Whether a KnowledgeObject is flagged privileged. Missing row → false.
    public func isPrivileged(_ id: KnowledgeObject.ID) async throws -> Bool {
        let rows = try await database.query(
            "SELECT privileged FROM knowledge_objects WHERE id = ? LIMIT 1;",
            [.uuid(id)]
        )
        return (rows.first?.int(0) ?? 0) != 0
    }

    /// Count of privileged objects — a UI signal that material is withheld.
    public func privilegedCount() async throws -> Int {
        let rows = try await database.query(
            "SELECT COUNT(*) FROM knowledge_objects WHERE privileged = 1;")
        return Int(rows.first?.int(0) ?? 0)
    }

    /// The set of privileged object ids — used by the retriever to withhold
    /// their chunks from answers (§21).
    public func privilegedObjectIDs() async throws -> Set<UUID> {
        let rows = try await database.query(
            "SELECT id FROM knowledge_objects WHERE privileged = 1;")
        return Set(rows.compactMap { $0.uuid(0) })
    }

    public func fetchContent(id: KnowledgeObject.ID) async throws -> String? {
        let rows = try await database.query("""
        SELECT content FROM knowledge_objects WHERE id = ? LIMIT 1;
        """, [.uuid(id)])
        return rows.first?.string(0)
    }

    /// HISTORY backfill helper — hydrate a full KnowledgeObject by
    /// id. Joined with the files table so `sourceFile` is real
    /// (NarrativeSlotExtractor relies on it for non-email channel
    /// classification). Returns nil when the row is missing.
    public func load(id: KnowledgeObject.ID) async throws -> KnowledgeObject? {
        let rows = try await database.query("""
        SELECT k.id, k.source_type, k.content, k.metadata_json, k.confidence,
               k.created_at, k.updated_at, f.url
        FROM knowledge_objects k
        JOIN files f ON f.id = k.file_id
        WHERE k.id = ? LIMIT 1;
        """, [.uuid(id)])
        guard let row = rows.first,
              let objID = row.uuid(0),
              let typeRaw = row.string(1),
              let type = SourceType(rawValue: typeRaw),
              let content = row.string(2),
              let conf = row.double(4),
              let createdAt = row.date(5),
              let updatedAt = row.date(6),
              let urlString = row.string(7)
        else { return nil }
        let url = URL(string: urlString) ?? URL(fileURLWithPath: urlString)
        var metadata: [String: AnyCodable] = [:]
        if let metaJSON = row.string(3),
           let data = metaJSON.data(using: .utf8),
           let decoded = try? decoder.decode([String: AnyCodable].self, from: data) {
            metadata = decoded
        }
        return KnowledgeObject(
            id: objID,
            sourceFile: url,
            sourceType: type,
            content: content,
            metadata: metadata,
            confidence: Confidence(conf),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
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

    /// Map each object id to its source file's custody content hash
    /// (files.content_hash). Used by verifiable receipts to pin a claim to the
    /// immutable source-file hash, not just the quoted passage — the difference
    /// between a nice citation and a court-grade one. IDs with no hash are omitted.
    public func sourceHashes(
        for ids: Set<KnowledgeObject.ID>
    ) async throws -> [KnowledgeObject.ID: String] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let bindings: [SQLValue] = ids.map { .uuid($0) }
        let rows = try await database.query("""
        SELECT k.id, f.content_hash
        FROM knowledge_objects k
        JOIN files f ON f.id = k.file_id
        WHERE k.id IN (\(placeholders));
        """, bindings)
        var out: [KnowledgeObject.ID: String] = [:]
        for row in rows {
            guard let id = row.uuid(0), let hash = row.string(1), !hash.isEmpty else { continue }
            out[id] = hash
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

/// Per-file ingest health row used by the Completeness panel. All
/// fields come from KO metadata stamped by the loaders.
public struct CompletenessRow: Identifiable, Sendable, Hashable {
    public let id: KnowledgeObject.ID
    public let sourceFile: URL
    public let sourceType: SourceType
    public let loader: String?
    public let confidence: Confidence
    public let createdAt: Date
    public let contentBytes: Int
    public let pageCount: Int?
    public let ocrPagesUsed: Int?
    public let quotedBytesRemoved: Int?
    public let streamsScanned: Int?
    public let messageCount: Int?
    public let isStub: Bool
}

extension KnowledgeObjectRepository {
    /// Walk every KO and pull the ingest-health fields out of its
    /// JSON metadata blob. Heavy-ish (full-table scan + per-row JSON
    /// parse) so the caller paginates or restricts.
    public func completenessRows(limit: Int = 1000) async throws -> [CompletenessRow] {
        let rows = try await database.query("""
        SELECT k.id, k.source_type, k.content, k.metadata_json, k.confidence, k.created_at, f.url
        FROM knowledge_objects k
        JOIN files f ON f.id = k.file_id
        ORDER BY k.created_at DESC
        LIMIT ?;
        """, [.integer(Int64(limit))])

        var out: [CompletenessRow] = []
        out.reserveCapacity(rows.count)
        for row in rows {
            guard
                let id = row.uuid(0),
                let typeRaw = row.string(1),
                let type = SourceType(rawValue: typeRaw),
                let content = row.string(2),
                let metaJSON = row.string(3),
                let conf = row.double(4),
                let created = row.date(5),
                let urlString = row.string(6),
                let url = URL(string: urlString)
            else { continue }

            let meta = parseMetadataBag(metaJSON)
            out.append(CompletenessRow(
                id: id,
                sourceFile: url,
                sourceType: type,
                loader: meta["loader"] ?? meta["loaderStub"],
                confidence: Confidence(conf),
                createdAt: created,
                contentBytes: content.utf8.count,
                pageCount: meta["pageCount"].flatMap(Int.init),
                ocrPagesUsed: meta["ocrPagesUsed"].flatMap(Int.init),
                quotedBytesRemoved: meta["quotedBytesRemoved"].flatMap(Int.init),
                streamsScanned: meta["streamsScanned"].flatMap(Int.init),
                messageCount: meta["messageCount"].flatMap(Int.init),
                isStub: meta["loaderStub"] != nil
            ))
        }
        return out
    }

    /// Flatten the JSON metadata blob to a plain [String: String] —
    /// every value lands as its string form, integer/double/bool are
    /// coerced. We can re-parse on the consumer side when needed.
    private nonisolated func parseMetadataBag(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8) else { return [:] }
        guard let parsed = try? JSONDecoder().decode([String: AnyCodable].self, from: data) else {
            return [:]
        }
        var out: [String: String] = [:]
        for (k, v) in parsed {
            switch v.value {
            case .string(let s): out[k] = s
            case .int(let i): out[k] = String(i)
            case .double(let d): out[k] = String(d)
            case .bool(let b): out[k] = String(b)
            default: continue
            }
        }
        return out
    }
}
