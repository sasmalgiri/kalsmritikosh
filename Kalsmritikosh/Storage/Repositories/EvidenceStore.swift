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

/// PA-PROD B6 — a block resolved to its CANONICAL KnowledgeObject owner and a reopenable source
/// version. Unlike `ResolvedEvidenceReference` (which historically carried `logical_source_id` in
/// the objectID slot), `knowledgeObjectID` is a real `knowledge_objects` row.
public struct ResolvedEvidenceBlock: Sendable, Equatable {
    public let blockID: EvidenceBlock.ID
    public let knowledgeObjectID: KnowledgeObject.ID
    public let sourceVersionID: UUID
    public init(blockID: EvidenceBlock.ID, knowledgeObjectID: KnowledgeObject.ID, sourceVersionID: UUID) {
        self.blockID = blockID; self.knowledgeObjectID = knowledgeObjectID; self.sourceVersionID = sourceVersionID
    }
}

/// The outcome of resolving one block for canonical Claim evidence. Ambiguity (multiple distinct
/// KnowledgeObject owners) and absence (missing block, no owner, or no reopenable version) are
/// EXPLICIT — the producer must never guess a KnowledgeObject id or substitute `logical_source_id`.
public enum CanonicalBlockResolution: Sendable, Equatable {
    case resolved(ResolvedEvidenceBlock)
    case unresolved(blockID: EvidenceBlock.ID)
    case ambiguous(blockID: EvidenceBlock.ID)
}

/// USF-002.1 — the COMMITTED outcome of attaching a structural document, returned only after the
/// savepoint commits. Readiness may advance structural / metadata / OCR dimensions ONLY from this
/// receipt (never from the parser's in-memory result). A persistence failure throws instead of
/// producing a receipt, so a source can never claim structural readiness on uncommitted blocks.
public struct StructuralPersistenceReceipt: Sendable, Hashable {
    public let sourceVersionID: UUID
    public let sourceDocumentID: UUID
    public let parserRunID: UUID
    public let blockCount: Int
    public let substantiveBlockCount: Int
    public let locatedSubstantiveBlockCount: Int
    public let ocrBlockCount: Int
    public let extractionStatus: ExtractionStatus
    public let warningCount: Int
    public let parserID: String
    public let parserVersion: String

    /// Structural extraction is fully ready only when the parser reported COMPLETE and every
    /// substantive block is located. A `.partial` parse (or a missing locator) is never ready.
    public var isStructurallyComplete: Bool {
        extractionStatus == .complete && substantiveBlockCount > 0
            && locatedSubstantiveBlockCount == substantiveBlockCount
    }
}

public actor EvidenceStore: EvidenceBlockResolving {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Write

    /// USF-001.1 — ATTACH a parsed document to the source version universal intake already
    /// created, in ONE savepoint. EvidenceStore never inserts or retires a `source_versions`
    /// row: intake is the sole version authority. The attachment is fully fail-closed — the
    /// version must exist, its logical source + normalized content hash must match the parsed
    /// document, and its `document_id` must be NULL or already this document. Any mismatch
    /// writes nothing (no partial source_documents row).
    @discardableResult
    public func persist(
        _ doc: ParsedDocument,
        parser: String,
        parserVersion: String,
        sizeBytes: Int64 = 0,
        originalURL: String? = nil,
        makeCurrent: Bool = true,
        startedAt: Date,
        endedAt: Date = Date()
    ) async throws -> StructuralPersistenceReceipt {
        let now = Date().timeIntervalSince1970
        let profile = DocumentProfile.from(doc, parser: parser, parserVersion: parserVersion, sizeBytes: sizeBytes)
        let docHash = doc.contentHash.lowercased()
        let parserRunID = UUID()
        // USF-002.1 — the committed receipt is computed from the blocks this savepoint persists.
        let substantive = doc.meaningfulBlocks
        let receipt = StructuralPersistenceReceipt(
            sourceVersionID: doc.sourceVersionID, sourceDocumentID: doc.id, parserRunID: parserRunID,
            blockCount: doc.blocks.count, substantiveBlockCount: substantive.count,
            locatedSubstantiveBlockCount: substantive.filter { $0.locator.isResolvable }.count,
            ocrBlockCount: doc.blocks.filter { $0.extractionMethod == .ocr }.count,
            extractionStatus: doc.extractionStatus, warningCount: doc.warnings.count,
            parserID: parser, parserVersion: parserVersion)
        let sp = "es_attach_\(doc.sourceVersionID.uuidString.prefix(8))"
        try await database.withSavepoint(sp) { db in
            // Identity gate FIRST — before any write.
            guard let v = try db.query("""
                SELECT logical_source_id, content_hash, document_id FROM source_versions WHERE id = ?;
                """, [.uuid(doc.sourceVersionID)]).first else {
                throw SourceIntakeError.sourceVersionNotFound(doc.sourceVersionID)
            }
            guard v.uuid(0) == doc.logicalSourceID else {
                throw SourceIntakeError.parsedDocumentIdentityMismatch("logical source mismatch for version \(doc.sourceVersionID)")
            }
            guard (v.string(1) ?? "").lowercased() == docHash else {
                throw SourceIntakeError.parsedDocumentIdentityMismatch("content hash mismatch for version \(doc.sourceVersionID)")
            }
            if let existingDoc = v.uuid(2), existingDoc != doc.id {
                throw SourceIntakeError.parsedDocumentIdentityMismatch("version \(doc.sourceVersionID) already has document \(existingDoc)")
            }

            try db.exec("""
            INSERT OR REPLACE INTO source_documents
                (id, logical_source_id, filename, detected_type, mime_type, content_hash, extraction_status, metadata, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, [.uuid(doc.id), .uuid(doc.logicalSourceID), .text(doc.filename), .text(doc.detectedType.rawValue),
                   doc.mimeType.map { .text($0) } ?? .null, .text(doc.contentHash), .text(doc.extractionStatus.rawValue),
                   .text(Self.json(doc.metadata) ?? "{}"), .real(now)])

            // Attach only — never create or retire a version.
            try db.exec("UPDATE source_versions SET document_id = ? WHERE id = ?;", [.uuid(doc.id), .uuid(doc.sourceVersionID)])

            for block in doc.blocks.sorted(by: { $0.ordinal < $1.ordinal }) {
                try db.exec("""
                INSERT OR REPLACE INTO evidence_blocks
                    (id, document_id, source_version_id, parent_block_id, ordinal, kind, raw_text, normalized_text, locator, extraction_method, extraction_confidence, language, attributes)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """, [.uuid(block.id), .uuid(block.documentID), .uuid(doc.sourceVersionID),
                       block.parentBlockID.map { .uuid($0) } ?? .null, .integer(Int64(block.ordinal)),
                       .text(block.kind.rawValue), .text(block.rawText), .text(block.normalizedText),
                       .text(Self.json(block.locator) ?? "{}"), .text(block.extractionMethod.rawValue),
                       .real(block.extractionConfidence), block.language.map { .text($0) } ?? .null,
                       .text(Self.json(block.attributes) ?? "{}")])
            }

            try db.exec("""
            INSERT OR REPLACE INTO document_profiles
                (source_version_id, filename, detected_type, mime_type, content_hash, size_bytes, parser, parser_version, language, section_outline, first_meaningful_block, block_count, page_count, sheet_count, slide_count, message_count, attachment_count, child_count, extraction_status, warning_count, extraction_confidence, is_queryable, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, [.uuid(profile.sourceVersionID), .text(profile.filename), .text(profile.detectedType.rawValue),
                   profile.mimeType.map { .text($0) } ?? .null, .text(profile.contentHash), .integer(profile.sizeBytes),
                   .text(profile.parser), .text(profile.parserVersion), profile.language.map { .text($0) } ?? .null,
                   .text(Self.json(profile.sectionOutline) ?? "[]"), profile.firstMeaningfulBlock.map { .text($0) } ?? .null,
                   .integer(Int64(profile.blockCount)), profile.pageCount.map { .integer(Int64($0)) } ?? .null,
                   profile.sheetCount.map { .integer(Int64($0)) } ?? .null, profile.slideCount.map { .integer(Int64($0)) } ?? .null,
                   profile.messageCount.map { .integer(Int64($0)) } ?? .null, profile.attachmentCount.map { .integer(Int64($0)) } ?? .null,
                   profile.childCount.map { .integer(Int64($0)) } ?? .null, .text(profile.extractionStatus.rawValue),
                   .integer(Int64(profile.warningCount)), .real(profile.extractionConfidence),
                   .integer(profile.isQueryable ? 1 : 0), .real(now)])

            try db.exec("""
            INSERT INTO parser_runs
                (id, source_version_id, parser, parser_version, started_at, ended_at, status, block_count, warning_count, error)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, [
            .uuid(parserRunID),
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
        return receipt
    }

    // MARK: - B6 — canonical block → KnowledgeObject ownership

    /// Record that each of `blockIDs` belongs to KnowledgeObject `koID` (PA-PROD B6). Idempotent
    /// (INSERT OR IGNORE on the composite PK). Called by ingest once the structural blocks and the
    /// KnowledgeObject both exist, so canonical Claim evidence can resolve a real object id.
    public func linkBlocks(_ blockIDs: [EvidenceBlock.ID], toObject koID: KnowledgeObject.ID, at when: Date) async throws {
        guard !blockIDs.isEmpty else { return }
        let now = when.timeIntervalSince1970
        for blockID in blockIDs {
            try await database.exec("""
            INSERT OR IGNORE INTO evidence_block_objects (evidence_block_id, knowledge_object_id, linked_at)
            VALUES (?, ?, ?);
            """, [.uuid(blockID), .uuid(koID), .real(now)])
        }
    }

    /// Resolve blocks to their canonical KnowledgeObject owner + reopenable source version. A block
    /// is `.resolved` only when it exists, has exactly ONE persisted KnowledgeObject owner, and its
    /// source version (its own, or its document's current) exists. Zero owners → `.unresolved`;
    /// more than one distinct owner → `.ambiguous`. Never falls back to `logical_source_id`.
    public func resolveCanonicalBlocks(_ blockIDs: [EvidenceBlock.ID]) async throws -> [CanonicalBlockResolution] {
        var out: [CanonicalBlockResolution] = []
        for blockID in blockIDs {
            let rows = try await database.query("""
            SELECT ebo.knowledge_object_id, COALESCE(sv.id, cur.id) AS version_id
            FROM evidence_blocks b
            JOIN evidence_block_objects ebo ON ebo.evidence_block_id = b.id
            LEFT JOIN source_versions sv  ON sv.id = b.source_version_id
            LEFT JOIN source_versions cur ON cur.document_id = b.document_id AND cur.is_current = 1
            WHERE b.id = ?;
            """, [.uuid(blockID)])
            let owners = Set(rows.compactMap { $0.uuid(0) })
            if owners.isEmpty { out.append(.unresolved(blockID: blockID)); continue }
            if owners.count > 1 { out.append(.ambiguous(blockID: blockID)); continue }
            guard let version = rows.compactMap({ $0.uuid(1) }).first else {
                out.append(.unresolved(blockID: blockID)); continue
            }
            out.append(.resolved(ResolvedEvidenceBlock(
                blockID: blockID, knowledgeObjectID: owners.first!, sourceVersionID: version)))
        }
        return out
    }

    /// Whether a `knowledge_objects` row exists — so object-only evidence can verify its object id
    /// is a REAL KnowledgeObject before it is stored on an EvidenceReference.
    public func knowledgeObjectExists(_ id: KnowledgeObject.ID) async throws -> Bool {
        let rows = try await database.query("SELECT 1 FROM knowledge_objects WHERE id = ? LIMIT 1;", [.uuid(id)])
        return !rows.isEmpty
    }

    /// The current, reopenable source version for a KnowledgeObject, resolved through the file it
    /// belongs to:  knowledge_objects.file_id → source_versions.logical_source_id (is_current). Used
    /// for object-only evidence — NEVER by passing a KnowledgeObject id to a file-keyed lookup.
    public func currentVersionID(forObject koID: KnowledgeObject.ID) async throws -> UUID? {
        let rows = try await database.query("""
        SELECT sv.id
        FROM knowledge_objects ko
        JOIN source_versions sv ON sv.logical_source_id = ko.file_id AND sv.is_current = 1
        WHERE ko.id = ?
        ORDER BY sv.created_at DESC LIMIT 1;
        """, [.uuid(koID)])
        return rows.first?.uuid(0)
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

    /// PA-REC-001 — the EXACT custody hash of each given source VERSION (never the current file
    /// hash). This is the canonical authority for work-product receipts: a receipt citing an older
    /// source version must pin that version's bytes, not whatever the file now holds. Chunked ≤500;
    /// blank/malformed hashes are ignored; a returned value is always a normalized 64-char
    /// lowercase SHA-256. Database failures propagate.
    public func contentHashes(forSourceVersionIDs ids: Set<UUID>) async throws -> [UUID: String] {
        guard !ids.isEmpty else { return [:] }
        var out: [UUID: String] = [:]
        let all = Array(ids)
        for chunk in stride(from: 0, to: all.count, by: 500).map({ Array(all[$0..<min($0 + 500, all.count)]) }) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try await database.query(
                "SELECT id, content_hash FROM source_versions WHERE id IN (\(placeholders));",
                chunk.map { SQLValue.uuid($0) })
            for r in rows {
                guard let id = r.uuid(0), let raw = r.string(1),
                      let norm = Self.normalizedSHA256(raw) else { continue }
                out[id] = norm
            }
        }
        return out
    }

    /// A content hash is accepted only as a 64-char hex SHA-256 (case/space-insensitive input),
    /// returned lowercase. Anything else → nil (treated as "no recorded hash").
    nonisolated static func normalizedSHA256(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard t.count == 64, t.allSatisfy({ $0.isHexDigit }) else { return nil }
        return t
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

    /// S0.5 — resolve EvidenceBlock ids to the KnowledgeObject / source version / locator
    /// that back them. A block belongs to a source version (or, when its version id is
    /// null, to the current version of its document); that version's `logical_source_id`
    /// IS the KnowledgeObject id. This is what lets a GenericFact-derived HistoryItem
    /// carry a reopenable objectID+blockID citation instead of an empty evidence array.
    /// Order is not guaranteed; the caller keys by blockID.
    public func resolveEvidenceBlocks(_ blockIDs: [EvidenceBlock.ID]) async throws -> [ResolvedEvidenceReference] {
        guard !blockIDs.isEmpty else { return [] }
        let placeholders = blockIDs.map { _ in "?" }.joined(separator: ", ")
        let rows = try await database.query("""
        SELECT b.id, b.locator,
               COALESCE(sv1.id, sv2.id)                 AS version_id,
               COALESCE(sv1.logical_source_id, sv2.logical_source_id) AS object_id
        FROM evidence_blocks b
        LEFT JOIN source_versions sv1 ON sv1.id = b.source_version_id
        LEFT JOIN source_versions sv2 ON sv2.document_id = b.document_id AND sv2.is_current = 1
        WHERE b.id IN (\(placeholders));
        """, blockIDs.map { SQLValue.uuid($0) })
        return rows.compactMap { row in
            guard let blockID = row.uuid(0), let objectID = row.uuid(3) else { return nil }
            let locator = row.string(1).flatMap { Self.decode(SourceLocator.self, $0) }
            return ResolvedEvidenceReference(
                objectID: objectID, blockID: blockID,
                sourceVersionID: row.uuid(2), locator: locator)
        }
    }

    /// A6.1 — full-text search over the structural evidence layer (schema v41).
    /// Returns matching EvidenceBlocks (with their exact locators) ranked by
    /// bm25, so retrieval can surface typed, precisely-located evidence rather
    /// than only flattened chunks. The query is sanitized into quoted tokens so
    /// user punctuation can't produce an FTS5 syntax error.
    public func searchBlocks(_ query: String, limit: Int = 50) async throws -> [EvidenceBlock] {
        let match = Self.ftsQuery(query)
        guard !match.isEmpty else { return [] }
        let rows = try await database.query("""
        SELECT eb.id, eb.document_id, eb.source_version_id, eb.parent_block_id, eb.ordinal, eb.kind,
               eb.raw_text, eb.normalized_text, eb.locator, eb.extraction_method, eb.extraction_confidence,
               eb.language, eb.attributes
        FROM evidence_blocks eb
        JOIN evidence_blocks_fts ON evidence_blocks_fts.rowid = eb.rowid
        WHERE evidence_blocks_fts MATCH ?
        ORDER BY rank
        LIMIT ?;
        """, [.text(match), .integer(Int64(limit))])
        return rows.compactMap(decodeBlock)
    }

    /// Turn free text into a safe FTS5 MATCH expression: alphanumeric tokens,
    /// each quoted (so operators / punctuation are treated literally), ANDed.
    nonisolated static func ftsQuery(_ query: String) -> String {
        let tokens = query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 2 }
        guard !tokens.isEmpty else { return "" }
        return tokens.map { "\"\($0)\"" }.joined(separator: " ")
    }

    /// A5.7 — document profiles whose extraction was not clean: partial,
    /// corrupt, encrypted, unsupported, or failed. Used by the gap scanner to
    /// surface unreadable regions where evidence may be missing from the ledger.
    public struct ExtractionIssue: Sendable, Hashable {
        public let sourceVersionID: UUID
        public let filename: String
        public let status: String
        public let warningCount: Int
    }

    public func documentsWithExtractionIssues(limit: Int = 200) async throws -> [ExtractionIssue] {
        let rows = try await database.query("""
        SELECT source_version_id, filename, extraction_status, warning_count
        FROM document_profiles
        WHERE extraction_status IN ('partial', 'corrupt', 'encrypted', 'unsupported', 'failed')
        ORDER BY created_at DESC LIMIT ?;
        """, [.integer(Int64(limit))])
        return rows.compactMap { row in
            guard let vid = row.uuid(0), let filename = row.string(1), let status = row.string(2) else { return nil }
            return ExtractionIssue(
                sourceVersionID: vid, filename: filename, status: status,
                warningCount: Int(row.int(3) ?? 0)
            )
        }
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
