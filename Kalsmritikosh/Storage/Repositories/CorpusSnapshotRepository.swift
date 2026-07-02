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
        contentManifestHash: String = ""
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

    public func insert(_ snapshot: CorpusSnapshot) async throws {
        try await database.exec("""
        INSERT INTO corpus_snapshots
            (id, created_at, schema_version, file_count, parsed_count,
             indexed_count, ledgered_count, failed_count,
             pending_ocr_count, pending_enrichment_count, content_manifest_hash)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
            .text(snapshot.contentManifestHash)
        ])
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
