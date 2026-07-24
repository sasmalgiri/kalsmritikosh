//
//  TemporalClaimRepository.swift
//  Kalsmritikosh
//
//  HIST-022 (Universal History program, Phase 3). Durable store for subject-scoped
//  temporal claims. Paged subject and predicate queries are DETERMINISTIC (ordered
//  by created_at then id). Raw sqlite3 C-API style; object/temporal values are
//  JSON-encoded columns. Deterministic date coding (secondsSince1970).
//

import Foundation

public actor TemporalClaimRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d
    }()

    public func insert(_ claim: TemporalClaim) async throws {
        // Write from the CANONICAL assessment (Commit C): dimensions ← assessment;
        // status ← compatibility encoding; legacy_status ← preserved original.
        let a = claim.assessment
        let enc = LegacyEvidenceStatusAdapter.encode(a)
        try await database.exec("""
        INSERT OR REPLACE INTO temporal_claims
            (id, subject_id, predicate, object_json, valid_from_json, valid_to_json,
             observed_at_json, status, confidence, source_object_ids_json,
             source_block_ids_json, assertion_ids_json, generic_fact_ids_json,
             extractor_id, extractor_version, created_at,
             evidence_basis, review_disposition, proposal_origin, availability_status, conflict_status, legacy_status)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        """, [
            .uuid(claim.id), .uuid(claim.subjectID), .text(claim.predicate),
            .text(Self.encode(claim.object)),
            Self.encodeOpt(claim.validFrom), Self.encodeOpt(claim.validTo), Self.encodeOpt(claim.observedAt),
            .text(enc.rawValue), .real(claim.confidence),
            .text(Self.encodeIDs(claim.sourceObjectIDs)), .text(Self.encodeIDs(claim.sourceBlockIDs)),
            .text(Self.encodeIDs(claim.assertionIDs)), .text(Self.encodeIDs(claim.genericFactIDs)),
            .text(claim.extractorID), .text(claim.extractorVersion),
            .real(claim.createdAt.timeIntervalSince1970),
            .text(a.basis.rawValue), .text(a.review.rawValue), .text(a.origin.rawValue),
            .text(a.availability.rawValue), .text(a.conflict.rawValue), .text((a.legacyStatus ?? enc).rawValue)
        ])
    }

    /// Paged, deterministic subject query (created_at asc, id asc).
    public func claims(subjectID: Entity.ID, offset: Int = 0, pageSize: Int = 500) async throws -> [TemporalClaim] {
        let rows = try await database.query("""
        \(Self.selectColumns)
        FROM temporal_claims WHERE subject_id = ?
        ORDER BY created_at ASC, id ASC LIMIT ? OFFSET ?;
        """, [.uuid(subjectID), .integer(Int64(pageSize)), .integer(Int64(offset))])
        return rows.compactMap(Self.decode)
    }

    /// Deterministic paged enumeration of ALL temporal claims (Claim-producer backfill).
    public func allClaims(offset: Int = 0, pageSize: Int = 500) async throws -> [TemporalClaim] {
        let rows = try await database.query("""
        \(Self.selectColumns)
        FROM temporal_claims ORDER BY id ASC LIMIT ? OFFSET ?;
        """, [.integer(Int64(pageSize)), .integer(Int64(offset))])
        return rows.compactMap(Self.decode)
    }

    /// Keyset page (`id > afterID ORDER BY id`) for the resumable projection backfill.
    public func page(afterID: UUID?, pageSize: Int) async throws -> [TemporalClaim] {
        let rows: [SQLRow]
        if let afterID {
            rows = try await database.query("""
            \(Self.selectColumns) FROM temporal_claims WHERE id > ? ORDER BY id ASC LIMIT ?;
            """, [.uuid(afterID), .integer(Int64(pageSize))])
        } else {
            rows = try await database.query("""
            \(Self.selectColumns) FROM temporal_claims ORDER BY id ASC LIMIT ?;
            """, [.integer(Int64(pageSize))])
        }
        return rows.compactMap(Self.decode)
    }

    /// Subject + predicate query, deterministic.
    public func claims(subjectID: Entity.ID, predicate: String) async throws -> [TemporalClaim] {
        let rows = try await database.query("""
        \(Self.selectColumns)
        FROM temporal_claims WHERE subject_id = ? AND predicate = ?
        ORDER BY created_at ASC, id ASC;
        """, [.uuid(subjectID), .text(HistoryPredicate.normalize(predicate))])
        return rows.compactMap(Self.decode)
    }

    public func count(subjectID: Entity.ID) async throws -> Int {
        Int((try await database.query(
            "SELECT COUNT(*) FROM temporal_claims WHERE subject_id = ?;", [.uuid(subjectID)])).first?.int(0) ?? 0)
    }

    // MARK: - Coding

    private static let selectColumns = """
    SELECT id, subject_id, predicate, object_json, valid_from_json, valid_to_json,
           observed_at_json, status, confidence, source_object_ids_json,
           source_block_ids_json, assertion_ids_json, generic_fact_ids_json,
           extractor_id, extractor_version, created_at,
           evidence_basis, review_disposition, proposal_origin, availability_status, conflict_status, legacy_status
    """

    private static func encode(_ v: ClaimValue) -> String {
        (try? String(data: encoder.encode(v), encoding: .utf8) ?? "") ?? ""
    }
    private static func encodeOpt(_ t: TemporalValue?) -> SQLValue {
        guard let t, let data = try? encoder.encode(t), let s = String(data: data, encoding: .utf8) else { return .null }
        return .text(s)
    }
    private static func encodeIDs(_ ids: [UUID]) -> String {
        (try? String(data: encoder.encode(ids), encoding: .utf8) ?? "[]") ?? "[]"
    }
    private static func decodeIDs(_ s: String?) -> [UUID] {
        guard let s, let data = s.data(using: .utf8), let ids = try? decoder.decode([UUID].self, from: data) else { return [] }
        return ids
    }
    private static func decodeTemporal(_ s: String?) -> TemporalValue? {
        guard let s, let data = s.data(using: .utf8) else { return nil }
        return try? decoder.decode(TemporalValue.self, from: data)
    }

    private nonisolated static func decode(_ r: SQLRow) -> TemporalClaim? {
        // Drop only on unusable identity/content — never because a dimension is malformed.
        guard let id = r.uuid(0), let subject = r.uuid(1), let predicate = r.string(2),
              let objJSON = r.string(3), let objData = objJSON.data(using: .utf8),
              let object = try? decoder.decode(ClaimValue.self, from: objData)
        else { return nil }
        let assessment = EvidenceAssessmentRowDecoder.decode(.init(
            evidenceBasis: r.string(16), reviewDisposition: r.string(17), proposalOrigin: r.string(18),
            availabilityStatus: r.string(19), conflictStatus: r.string(20),
            legacyStatus: r.string(21), status: r.string(7)))
        return TemporalClaim(
            id: id, subjectID: subject, predicate: predicate, object: object,
            validFrom: decodeTemporal(r.string(4)), validTo: decodeTemporal(r.string(5)),
            observedAt: decodeTemporal(r.string(6)),
            assessment: assessment, confidence: r.double(8) ?? 0.5,
            sourceObjectIDs: decodeIDs(r.string(9)), sourceBlockIDs: decodeIDs(r.string(10)),
            assertionIDs: decodeIDs(r.string(11)), genericFactIDs: decodeIDs(r.string(12)),
            extractorID: r.string(13) ?? "", extractorVersion: r.string(14) ?? "",
            createdAt: Date(timeIntervalSince1970: r.double(15) ?? 0))
    }
}
