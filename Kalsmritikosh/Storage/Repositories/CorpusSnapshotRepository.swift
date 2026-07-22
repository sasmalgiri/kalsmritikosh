//
//  CorpusSnapshotRepository.swift
//  Kalsmritikosh
//
//  Ledger-AI v28 — a point-in-time census of the archive. Every answer
//  is tied to the snapshot it was produced against, so the UI can say
//  "answered from a corpus that was 87% ledgered, 1,204 files pending
//  OCR". This makes incomplete answers honest instead of frustrating.
//
//  The snapshot is cheap to build (a handful of COUNT queries) so a
//  fresh one is taken per answer. Old snapshots are retained — they're
//  the audit trail explaining what the archive looked like when a given
//  answer was produced.
//

import Foundation

/// EV-004 — one pinned source version covered by a snapshot.
public struct SnapshotSource: Sendable, Hashable, Codable {
    public let sourceVersionID: UUID
    public let contentHash: String?
    public nonisolated init(sourceVersionID: UUID, contentHash: String?) {
        self.sourceVersionID = sourceVersionID
        self.contentHash = contentHash
    }
}

public struct CorpusSnapshot: Sendable, Identifiable, Hashable {
    public typealias ID = UUID

    public let id: ID
    public let createdAt: Date
    public let schemaVersion: Int
    public let fileCount: Int
    public let parsedCount: Int
    public let indexedCount: Int
    public let ledgeredCount: Int
    public let failedCount: Int
    public let pendingOCRCount: Int
    public let pendingEnrichmentCount: Int
    public let contentManifestHash: String

    // EV-004 — reproducibility fields (additive to the v28 census). These pin the
    // PROCESSING configuration in effect, so an old answer/notebook/work product can
    // replay exactly even after new files arrive or parsers/embedders change.
    /// Workspace/scope the snapshot was taken for (e.g. "global", a matter id).
    public let scope: String?
    public let embeddingModel: String?
    public let retrievalConfigVersion: String?
    public let personaPolicyVersion: String?
    /// Parser/extractor versions in effect, as a name → version map.
    public let parserVersions: [String: String]
    /// The exact source versions this snapshot covered (+ their content hashes).
    public let sources: [SnapshotSource]
    /// Readiness/coverage 0…1 at snapshot time; falls back to `ledgeredFraction`.
    public let readiness: Double?

    public nonisolated init(
        id: ID = UUID(),
        createdAt: Date = Date(),
        schemaVersion: Int,
        fileCount: Int,
        parsedCount: Int,
        indexedCount: Int,
        ledgeredCount: Int,
        failedCount: Int,
        pendingOCRCount: Int = 0,
        pendingEnrichmentCount: Int = 0,
        contentManifestHash: String = "",
        scope: String? = nil,
        embeddingModel: String? = nil,
        retrievalConfigVersion: String? = nil,
        personaPolicyVersion: String? = nil,
        parserVersions: [String: String] = [:],
        sources: [SnapshotSource] = [],
        readiness: Double? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.schemaVersion = schemaVersion
        self.fileCount = fileCount
        self.parsedCount = parsedCount
        self.indexedCount = indexedCount
        self.ledgeredCount = ledgeredCount
        self.failedCount = failedCount
        self.pendingOCRCount = pendingOCRCount
        self.pendingEnrichmentCount = pendingEnrichmentCount
        self.contentManifestHash = contentManifestHash
        self.scope = scope
        self.embeddingModel = embeddingModel
        self.retrievalConfigVersion = retrievalConfigVersion
        self.personaPolicyVersion = personaPolicyVersion
        self.parserVersions = parserVersions
        self.sources = sources
        self.readiness = readiness
    }

    /// Fraction of registered files that are keyword-searchable (FTS).
    public var searchableFraction: Double {
        fileCount > 0 ? Double(indexedCount) / Double(fileCount) : 0
    }
    /// Fraction of registered files that have made it into the ledger
    /// (entities + events extracted).
    public var ledgeredFraction: Double {
        fileCount > 0 ? Double(ledgeredCount) / Double(fileCount) : 0
    }
}

public actor CorpusSnapshotRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    private nonisolated static let encoder = JSONEncoder()
    private nonisolated static let decoder = JSONDecoder()

    public func insert(_ snapshot: CorpusSnapshot) async throws {
        let parserJSON = String(
            data: (try? Self.encoder.encode(snapshot.parserVersions)) ?? Data("{}".utf8),
            encoding: .utf8) ?? "{}"
        try await database.exec("""
        INSERT INTO corpus_snapshots
            (id, created_at, schema_version, file_count, parsed_count,
             indexed_count, ledgered_count, failed_count,
             pending_ocr_count, pending_enrichment_count, content_manifest_hash,
             scope, embedding_model, retrieval_config_version, persona_policy_version,
             parser_versions_json, readiness)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, [
            .uuid(snapshot.id),
            .real(snapshot.createdAt.timeIntervalSince1970),
            .integer(Int64(snapshot.schemaVersion)),
            .integer(Int64(snapshot.fileCount)),
            .integer(Int64(snapshot.parsedCount)),
            .integer(Int64(snapshot.indexedCount)),
            .integer(Int64(snapshot.ledgeredCount)),
            .integer(Int64(snapshot.failedCount)),
            .integer(Int64(snapshot.pendingOCRCount)),
            .integer(Int64(snapshot.pendingEnrichmentCount)),
            .text(snapshot.contentManifestHash),
            snapshot.scope.map { SQLValue.text($0) } ?? .null,
            snapshot.embeddingModel.map { SQLValue.text($0) } ?? .null,
            snapshot.retrievalConfigVersion.map { SQLValue.text($0) } ?? .null,
            snapshot.personaPolicyVersion.map { SQLValue.text($0) } ?? .null,
            .text(parserJSON),
            snapshot.readiness.map { SQLValue.real($0) } ?? .null
        ])
        // EV-004 — pin the exact source versions this snapshot covered.
        for s in snapshot.sources {
            try await database.exec("""
            INSERT OR REPLACE INTO snapshot_sources (snapshot_id, source_version_id, content_hash)
            VALUES (?, ?, ?);
            """, [
                .uuid(snapshot.id), .uuid(s.sourceVersionID),
                s.contentHash.map { SQLValue.text($0) } ?? .null
            ])
        }
    }

    /// EV-004 — fetch a snapshot by id WITH its full reproducibility fields (processing
    /// versions + pinned source versions), so an old output can replay its exact scope.
    public func snapshot(id: CorpusSnapshot.ID) async throws -> CorpusSnapshot? {
        let rows = try await database.query("""
        SELECT id, created_at, schema_version, file_count, parsed_count,
               indexed_count, ledgered_count, failed_count,
               pending_ocr_count, pending_enrichment_count, content_manifest_hash,
               scope, embedding_model, retrieval_config_version, persona_policy_version,
               parser_versions_json, readiness
        FROM corpus_snapshots WHERE id = ?;
        """, [.uuid(id)])
        guard let row = rows.first, let base = decodeRow(row) else { return nil }
        let srcRows = try await database.query(
            "SELECT source_version_id, content_hash FROM snapshot_sources WHERE snapshot_id = ?;",
            [.uuid(id)])
        let sources: [SnapshotSource] = srcRows.compactMap { r in
            guard let sv = r.uuid(0) else { return nil }
            return SnapshotSource(sourceVersionID: sv, contentHash: r.string(1))
        }
        let parsers = (row.string(15)).flatMap {
            try? Self.decoder.decode([String: String].self, from: Data($0.utf8))
        } ?? [:]
        return CorpusSnapshot(
            id: base.id, createdAt: base.createdAt, schemaVersion: base.schemaVersion,
            fileCount: base.fileCount, parsedCount: base.parsedCount, indexedCount: base.indexedCount,
            ledgeredCount: base.ledgeredCount, failedCount: base.failedCount,
            pendingOCRCount: base.pendingOCRCount, pendingEnrichmentCount: base.pendingEnrichmentCount,
            contentManifestHash: base.contentManifestHash,
            scope: row.string(11), embeddingModel: row.string(12),
            retrievalConfigVersion: row.string(13), personaPolicyVersion: row.string(14),
            parserVersions: parsers, sources: sources, readiness: row.double(16))
    }

    public func latest() async throws -> CorpusSnapshot? {
        let rows = try await database.query("""
        SELECT id, created_at, schema_version, file_count, parsed_count,
               indexed_count, ledgered_count, failed_count,
               pending_ocr_count, pending_enrichment_count, content_manifest_hash
        FROM corpus_snapshots
        ORDER BY created_at DESC
        LIMIT 1;
        """, [])
        return rows.first.flatMap(decodeRow)
    }

    public func count() async throws -> Int {
        let rows = try await database.query("SELECT COUNT(*) FROM corpus_snapshots;", [])
        return Int(rows.first?.int(0) ?? 0)
    }

    // MARK: - Internals

    private func decodeRow(_ row: SQLRow) -> CorpusSnapshot? {
        guard
            let id = row.uuid(0),
            let createdAtRaw = row.double(1)
        else { return nil }
        return CorpusSnapshot(
            id: id,
            createdAt: Date(timeIntervalSince1970: createdAtRaw),
            schemaVersion: Int(row.int(2) ?? 0),
            fileCount: Int(row.int(3) ?? 0),
            parsedCount: Int(row.int(4) ?? 0),
            indexedCount: Int(row.int(5) ?? 0),
            ledgeredCount: Int(row.int(6) ?? 0),
            failedCount: Int(row.int(7) ?? 0),
            pendingOCRCount: Int(row.int(8) ?? 0),
            pendingEnrichmentCount: Int(row.int(9) ?? 0),
            contentManifestHash: row.string(10) ?? ""
        )
    }
}
