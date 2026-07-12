//
//  EvidenceStore.swift
//  Kalsmritikosh
//
//  A1 (2/3) — persistence for the canonical structural evidence layer (schema
//  v37): source_versions, evidence_blocks, document_profiles, parser_runs. This
//  is the authoritative store the ingest pipeline (A2) writes to and the block
//  compatibility projection (A1 3/3) reads from. Raw sqlite3 C-API style,
//  matching the other repositories; the Database actor owns the connection.
//

import Foundation

public actor EvidenceStore {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Write

    /// Persist a parsed document as a source version + ordered evidence blocks +
    /// a deterministic profile, and record the parser run. When `makeCurrent` is
    /// true the new version becomes the current one for its logical source and
    /// any prior current version is retired (A2 versioning — never deleted).
    /// Caller is responsible for wrapping this in the per-document transaction.
    public func persist(
        _ doc: ParsedDocument,
        parser: String,
        parserVersion: String,
        sizeBytes: Int64 = 0,
        originalURL: String? = nil,
        makeCurrent: Bool = true,
        startedAt: Date,
        endedAt: Date = Date()
    ) async throws {
        let now = Date().timeIntervalSince1970

        if makeCurrent {
            // Retire the prior current version (keep the row; just flip flags).
            try await database.exec("""
            UPDATE source_versions SET is_current = 0, valid_to = ?
            WHERE logical_source_id = ? AND is_current = 1;
            """, [.real(now), .uuid(doc.logicalSourceID)])
        }

        try await database.exec("""
        INSERT OR REPLACE INTO source_documents
            (id, logical_source_id, filename, detected_type, mime_type, content_hash, extraction_status, metadata, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, [
            .uuid(doc.id),
            .uuid(doc.logicalSourceID),
            .text(doc.filename),
            .text(doc.detectedType.rawValue),
            doc.mimeType.map { .text($0) } ?? .null,
            .text(doc.contentHash),
            .text(doc.extractionStatus.rawValue),
            .text(Self.json(doc.metadata) ?? "{}"),
            .real(now)
        ])

        try await database.exec("""
        INSERT OR REPLACE INTO source_versions
            (id, logical_source_id, document_id, content_hash, supersedes, valid_from, valid_to, is_current, original_url, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, [
            .uuid(doc.sourceVersionID),
            .uuid(doc.logicalSourceID),
            .uuid(doc.id),
            .text(doc.contentHash),
            .null,
            .real(now),
            .null,
            .integer(makeCurrent ? 1 : 0),
            originalURL.map { .text($0) } ?? .null,
            .real(now)
        ])

        for block in doc.blocks.sorted(by: { $0.ordinal < $1.ordinal }) {
            try await database.exec("""
            INSERT OR REPLACE INTO evidence_blocks
                (id, document_id, source_version_id, parent_block_id, ordinal, kind, raw_text, normalized_text, locator, extraction_method, extraction_confidence, language, attributes)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, [
                .uuid(block.id),
                .uuid(block.documentID),
                .uuid(doc.sourceVersionID),
                block.parentBlockID.map { .uuid($0) } ?? .null,
                .integer(Int64(block.ordinal)),
                .text(block.kind.rawValue),
                .text(block.rawText),
                .text(block.normalizedText),
                .text(Self.json(block.locator) ?? "{}"),
                .text(block.extractionMethod.rawValue),
                .real(block.extractionConfidence),
                block.language.map { .text($0) } ?? .null,
                .text(Self.json(block.attributes) ?? "{}")
            ])
        }

        let profile = DocumentProfile.from(doc, parser: parser, parserVersion: parserVersion, sizeBytes: sizeBytes)
        try await database.exec("""
        INSERT OR REPLACE INTO document_profiles
            (source_version_id, filename, detected_type, mime_type, content_hash, size_bytes, parser, parser_version, language, section_outline, first_meaningful_block, block_count, page_count, sheet_count, slide_count, message_count, attachment_count, child_count, extraction_status, warning_count, extraction_confidence, is_queryable, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, [
            .uuid(profile.sourceVersionID),
            .text(profile.filename),
            .text(profile.detectedType.rawValue),
            profile.mimeType.map { .text($0) } ?? .null,
            .text(profile.contentHash),
            .integer(profile.sizeBytes),
            .text(profile.parser),
            .text(profile.parserVersion),
            profile.language.map { .text($0) } ?? .null,
            .text(Self.json(profile.sectionOutline) ?? "[]"),
            profile.firstMeaningfulBlock.map { .text($0) } ?? .null,
            .integer(Int64(profile.blockCount)),
            profile.pageCount.map { .integer(Int64($0)) } ?? .null,
            profile.sheetCount.map { .integer(Int64($0)) } ?? .null,
            profile.slideCount.map { .integer(Int64($0)) } ?? .null,
            profile.messageCount.map { .integer(Int64($0)) } ?? .null,
            profile.attachmentCount.map { .integer(Int64($0)) } ?? .null,
            profile.childCount.map { .integer(Int64($0)) } ?? .null,
            .text(profile.extractionStatus.rawValue),
            .integer(Int64(profile.warningCount)),
            .real(profile.extractionConfidence),
            .integer(profile.isQueryable ? 1 : 0),
            .real(now)
        ])

        try await database.exec("""
        INSERT INTO parser_runs
            (id, source_version_id, parser, parser_version, started_at, ended_at, status, block_count, warning_count, error)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, [
            .uuid(UUID()),
            .uuid(doc.sourceVersionID),
            .text(parser),
            .text(parserVersion),
            .real(startedAt.timeIntervalSince1970),
            .real(endedAt.timeIntervalSince1970),
            .text(doc.extractionStatus.rawValue),
            .integer(Int64(doc.blocks.count)),
            .integer(Int64(doc.warnings.count)),
            .null
        ])
    }

    // MARK: - Read

    /// Blocks for a source version, in reading order.
    public func blocks(forVersion versionID: UUID) async throws -> [EvidenceBlock] {
        let rows = try await database.query("""
        SELECT id, document_id, source_version_id, parent_block_id, ordinal, kind, raw_text, normalized_text, locator, extraction_method, extraction_confidence, language, attributes
        FROM evidence_blocks WHERE source_version_id = ? ORDER BY ordinal ASC;
        """, [.uuid(versionID)])
        return rows.compactMap(decodeBlock)
    }

    /// The current version ID for a logical source, if any.
    public func currentVersionID(forLogicalSource logicalID: UUID) async throws -> UUID? {
        let rows = try await database.query("""
        SELECT id FROM source_versions WHERE logical_source_id = ? AND is_current = 1
        ORDER BY created_at DESC LIMIT 1;
        """, [.uuid(logicalID)])
        return rows.first?.uuid(0)
    }

    public func blockCount() async throws -> Int {
        let rows = try await database.query("SELECT COUNT(*) FROM evidence_blocks;", [])
        return Int(rows.first?.int(0) ?? 0)
    }

    // MARK: - Internals

    private nonisolated func decodeBlock(_ row: SQLRow) -> EvidenceBlock? {
        guard
            let id = row.uuid(0),
            let documentID = row.uuid(1),
            let ordinal = row.int(4),
            let kindRaw = row.string(5),
            let kind = EvidenceBlockKind(rawValue: kindRaw),
            let raw = row.string(6),
            let norm = row.string(7),
            let methodRaw = row.string(9),
            let method = ExtractionMethod(rawValue: methodRaw)
        else { return nil }
        let locator: SourceLocator = row.string(8).flatMap { Self.decode(SourceLocator.self, $0) } ?? SourceLocator()
        let attrs: [String: AnyCodable] = row.string(12).flatMap { Self.decode([String: AnyCodable].self, $0) } ?? [:]
        return EvidenceBlock(
            id: id,
            documentID: documentID,
            sourceVersionID: row.uuid(2),
            parentBlockID: row.uuid(3),
            ordinal: Int(ordinal),
            kind: kind,
            rawText: raw,
            normalizedText: norm,
            locator: locator,
            extractionMethod: method,
            extractionConfidence: row.double(10) ?? 1.0,
            language: row.string(11),
            attributes: attrs
        )
    }

    private nonisolated static func json<T: Encodable>(_ value: T) -> String? {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private nonisolated static func decode<T: Decodable>(_ type: T.Type, _ s: String) -> T? {
        s.data(using: .utf8).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
