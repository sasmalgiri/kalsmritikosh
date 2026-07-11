//
//  DerivedObjectsRepository.swift
//  Kalsmritikosh
//
//  Append-only store for query-time LLM extractions (schema v35, spec §16).
//  Nothing is UPDATEd or DELETEd — corrections insert a new row and mark the
//  prior one superseded. `currentByHash` powers reuse: before paying for a
//  model again, a caller can check whether an equivalent, non-superseded
//  result already exists for the same source + extractor version.
//

import Foundation

public actor DerivedObjectsRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    /// Append a derived object. Idempotent by (source_hash, extractor_version):
    /// if a non-superseded row already exists it is returned unchanged rather
    /// than duplicated — so re-answering the same question doesn't pile up rows.
    @discardableResult
    public func record(_ obj: DerivedObject) async throws -> DerivedObject {
        if let existing = try await currentByHash(obj.sourceHash, extractorVersion: obj.extractorVersion) {
            return existing
        }
        let evidenceJSON = (try? String(
            data: JSONEncoder().encode(obj.sourceEvidence.map(\.uuidString)), encoding: .utf8
        )) ?? "[]"
        try await database.exec("""
        INSERT INTO derived_objects
            (id, kind, content, source_evidence, source_hash, model_id, provider_id,
             prompt_version, extractor_version, confidence, review_status, superseded_by, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, [
            .uuid(obj.id),
            .text(obj.kind.rawValue),
            .text(obj.content),
            .text(evidenceJSON),
            .text(obj.sourceHash),
            obj.modelID.map { .text($0) } ?? .null,
            obj.providerID.map { .text($0) } ?? .null,
            obj.promptVersion.map { .text($0) } ?? .null,
            .text(obj.extractorVersion),
            .real(obj.confidence),
            .text(obj.reviewStatus.rawValue),
            obj.supersededBy.map { .uuid($0) } ?? .null,
            .real(obj.createdAt.timeIntervalSince1970)
        ])
        return obj
    }

    /// The newest non-superseded derived object for a given source hash +
    /// extractor version, or nil. This is the reuse hook (§16).
    public func currentByHash(_ hash: String, extractorVersion: String) async throws -> DerivedObject? {
        let rows = try await database.query("""
        SELECT id, kind, content, source_evidence, source_hash, model_id, provider_id,
               prompt_version, extractor_version, confidence, review_status, superseded_by, created_at
        FROM derived_objects
        WHERE source_hash = ? AND extractor_version = ? AND superseded_by IS NULL
        ORDER BY created_at DESC LIMIT 1;
        """, [.text(hash), .text(extractorVersion)])
        return rows.first.flatMap(decode)
    }

    public func count() async throws -> Int {
        let rows = try await database.query("SELECT COUNT(*) FROM derived_objects;", [])
        return Int(rows.first?.int(0) ?? 0)
    }

    // MARK: - Internals

    private func decode(_ row: SQLRow) -> DerivedObject? {
        guard
            let id = row.uuid(0),
            let kindRaw = row.string(1),
            let kind = DerivedObject.Kind(rawValue: kindRaw),
            let content = row.string(2),
            let extractorVersion = row.string(8),
            let at = row.double(12)
        else { return nil }
        let evidence: [KnowledgeObject.ID] = {
            guard let json = row.string(3), let data = json.data(using: .utf8),
                  let strings = try? JSONDecoder().decode([String].self, from: data)
            else { return [] }
            return strings.compactMap(UUID.init(uuidString:))
        }()
        let statusRaw = row.string(10) ?? "unreviewed"
        return DerivedObject(
            id: id,
            kind: kind,
            content: content,
            sourceEvidence: evidence,
            modelID: row.string(5),
            providerID: row.string(6),
            promptVersion: row.string(7),
            extractorVersion: extractorVersion,
            confidence: row.double(9) ?? 0,
            reviewStatus: DerivedObject.ReviewStatus(rawValue: statusRaw) ?? .unreviewed,
            supersededBy: row.uuid(11),
            createdAt: Date(timeIntervalSince1970: at)
        )
    }
}
