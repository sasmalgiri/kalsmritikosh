//
//  TypedFieldRepository.swift
//  Kalsmritikosh
//
//  MMI-FINAL — the authoritative store for deterministic typed identity/document fields. It
//  writes fields for one exact SourceVersion atomically (one savepoint), keyed by producer so
//  a re-extraction replaces its own prior output without disturbing another producer's. Reads
//  are exact-version. Conflicts (two located values of the same field type disagreeing) are
//  surfaced, never resolved.
//

import Foundation

public actor TypedFieldRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    /// Atomically replace this producer's typed fields for an exact source version.
    public func replaceFields(
        sourceVersionID: UUID, producerID: String, producerVersion: String,
        fields: [TypedField], at when: Date = Date()
    ) async throws {
        // Encode provenance JSON OUTSIDE the savepoint (pure).
        let rows: [(TypedField, String?, String?)] = fields.map { f in
            let locatorJSON = (try? JSONEncoder().encode(f.locator)).flatMap { String(data: $0, encoding: .utf8) }
            let bboxJSON = f.boundingBox.flatMap { bb in (try? JSONEncoder().encode(bb)).flatMap { String(data: $0, encoding: .utf8) } }
            return (f, locatorJSON, bboxJSON)
        }
        try await database.withSavepoint("mmi_typed_fields") { db in
            try db.exec("DELETE FROM typed_fields WHERE source_version_id = ? AND producer_id = ? AND producer_version = ?;",
                        [.uuid(sourceVersionID), .text(producerID), .text(producerVersion)])
            for (f, locatorJSON, bboxJSON) in rows {
                try db.exec("""
                    INSERT INTO typed_fields
                        (id, source_version_id, evidence_block_id, field_type, raw_value, normalized_value,
                         confidence, extraction_method, locator, ocr_confidence, bounding_box,
                         producer_id, producer_version, created_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                    """, [
                        .uuid(f.id), .uuid(f.sourceVersionID), .uuid(f.evidenceBlockID), .text(f.fieldType.rawValue),
                        .text(f.rawValue), .text(f.normalizedValue), .real(f.confidence), .text(f.extractionMethod.rawValue),
                        locatorJSON.map { .text($0) } ?? .null, f.ocrConfidence.map { .real($0) } ?? .null,
                        bboxJSON.map { .text($0) } ?? .null, .text(f.producerID), .text(f.producerVersion),
                        .real(f.createdAt.timeIntervalSince1970)
                    ])
            }
        }
    }

    /// All typed fields for an exact source version, ordered by confidence (desc) then type.
    public func fields(forVersion sourceVersionID: UUID) async throws -> [TypedField] {
        let rows = try await database.query("""
            SELECT id, source_version_id, evidence_block_id, field_type, raw_value, normalized_value,
                   confidence, extraction_method, locator, ocr_confidence, bounding_box,
                   producer_id, producer_version, created_at
            FROM typed_fields WHERE source_version_id = ?
            ORDER BY confidence DESC, field_type ASC;
            """, [.uuid(sourceVersionID)])
        return rows.compactMap(Self.decode)
    }

    /// Typed fields of a specific type for an exact source version (confidence desc).
    public func fields(forVersion sourceVersionID: UUID, type: TypedFieldType) async throws -> [TypedField] {
        let rows = try await database.query("""
            SELECT id, source_version_id, evidence_block_id, field_type, raw_value, normalized_value,
                   confidence, extraction_method, locator, ocr_confidence, bounding_box,
                   producer_id, producer_version, created_at
            FROM typed_fields WHERE source_version_id = ? AND field_type = ?
            ORDER BY confidence DESC;
            """, [.uuid(sourceVersionID), .text(type.rawValue)])
        return rows.compactMap(Self.decode)
    }

    /// Field types that carry more than one DISTINCT located value for a version — surfaced as
    /// conflicts (both sides preserved), never silently resolved.
    public func conflicts(forVersion sourceVersionID: UUID) async throws -> [TypedFieldConflict] {
        let all = try await fields(forVersion: sourceVersionID)
        var byType: [TypedFieldType: [TypedField]] = [:]
        for f in all { byType[f.fieldType, default: []].append(f) }
        var out: [TypedFieldConflict] = []
        for type in byType.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let group = byType[type] ?? []
            let distinct = Set(group.map(\.normalizedValue))
            if distinct.count > 1 { out.append(TypedFieldConflict(fieldType: type, candidates: group)) }
        }
        return out
    }

    public func count() async throws -> Int {
        Int(try await database.query("SELECT COUNT(*) FROM typed_fields;", []).first?.int(0) ?? 0)
    }

    /// All located values of a field type across the corpus (confidence desc) — the input to the
    /// deterministic identity fast path. Bounded so a huge corpus never fans out unboundedly.
    public func allFields(type: TypedFieldType, limit: Int = 200) async throws -> [TypedField] {
        let rows = try await database.query("""
            SELECT id, source_version_id, evidence_block_id, field_type, raw_value, normalized_value,
                   confidence, extraction_method, locator, ocr_confidence, bounding_box,
                   producer_id, producer_version, created_at
            FROM typed_fields WHERE field_type = ?
            ORDER BY confidence DESC LIMIT ?;
            """, [.text(type.rawValue), .integer(Int64(limit))])
        return rows.compactMap(Self.decode)
    }

    /// Resolve a source version to the current KnowledgeObject that owns it (for a citation).
    /// version → logical source (files) → the KO whose file_id is that logical source.
    public func sourceKnowledgeObjectID(forVersion sourceVersionID: UUID) async throws -> UUID? {
        let rows = try await database.query("""
            SELECT ko.id FROM knowledge_objects ko
            JOIN source_versions sv ON sv.logical_source_id = ko.file_id
            WHERE sv.id = ? LIMIT 1;
            """, [.uuid(sourceVersionID)])
        return rows.first?.uuid(0)
    }

    // MARK: - Decoding

    private static func decode(_ r: SQLRow) -> TypedField? {
        guard let id = r.uuid(0), let sv = r.uuid(1), let block = r.uuid(2),
              let typeRaw = r.string(3), let raw = r.string(4), let normalized = r.string(5),
              let methodRaw = r.string(7) else { return nil }
        let locator: SourceLocator = {
            guard let json = r.string(8), let data = json.data(using: .utf8),
                  let loc = try? JSONDecoder().decode(SourceLocator.self, from: data) else { return SourceLocator() }
            return loc
        }()
        let bbox: [Double]? = {
            guard let json = r.string(10), let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode([Double].self, from: data)
        }()
        return TypedField(
            id: id, sourceVersionID: sv, evidenceBlockID: block,
            fieldType: TypedFieldType.from(rawValue: typeRaw), rawValue: raw, normalizedValue: normalized,
            confidence: r.double(6) ?? 0, extractionMethod: ExtractionMethod(rawValue: methodRaw) ?? .native,
            locator: locator, ocrConfidence: r.double(9), boundingBox: bbox,
            producerID: r.string(11) ?? "mmi.typed-field", producerVersion: r.string(12) ?? "1",
            createdAt: Date(timeIntervalSince1970: r.double(13) ?? 0))
    }
}
