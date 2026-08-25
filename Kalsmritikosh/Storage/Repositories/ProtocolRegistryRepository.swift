//
//  ProtocolRegistryRepository.swift
//  Kalsmritikosh
//
//  Conformance roadmap 1.1 (v108). The registry of imported, signature-verified
//  protocol packs and the governed review records behind the assurance board.
//
//  Lifecycle: imported → active → superseded / revoked. Activating a version
//  supersedes the previously active version of the SAME sutra; revocation
//  records a reason. Nothing here ever mutates a frozen run — sealed
//  assessments carry their own snapshot (v107), so history stays intact when
//  the active constitution changes.
//

import Foundation
import CryptoKit

public nonisolated enum ProtocolStatus: String, Sendable, Codable {
    case imported, active, superseded, revoked
}

/// A detached P-256 signature over any canonical-encodable record — used to
/// sign governed review records with the same per-installation key that seals
/// conformance assessments.
public nonisolated struct RecordSignature: Sendable, Codable, Equatable {
    public let signatureHex: String
    public let publicKeyHex: String
    public let signerKeyID: String
}

public nonisolated enum RecordSigner {
    public static func sign<T: Encodable>(_ value: T,
                                          key: P256.Signing.PrivateKey? = nil) throws -> RecordSignature {
        let backend: ConformanceSigningKey.Backend
        if let key { backend = .software(key) }
        else if let stored = ConformanceSigningKey.loadOrGenerateBackend() { backend = stored }
        else { throw ConformanceSealError.keyUnavailable }
        let canonical = try ConformanceCanonical.data(of: value)
        let signature = try backend.signature(for: canonical)
        return RecordSignature(
            signatureHex: signature.derRepresentation.map { String(format: "%02x", $0) }.joined(),
            publicKeyHex: backend.publicKey.x963Representation.map { String(format: "%02x", $0) }.joined(),
            signerKeyID: ConformanceSigningKey.keyID(forPublicKey: backend.publicKey))
    }

    public static func verify<T: Encodable>(_ value: T, signature: RecordSignature) -> Bool {
        guard let canonical = try? ConformanceCanonical.data(of: value),
              let keyData = hexData(signature.publicKeyHex),
              let publicKey = try? P256.Signing.PublicKey(x963Representation: keyData),
              let sigData = hexData(signature.signatureHex),
              let sig = try? P256.Signing.ECDSASignature(derRepresentation: sigData) else { return false }
        return publicKey.isValidSignature(sig, for: canonical)
    }

    private static func hexData(_ hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var out = Data(capacity: hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<next], radix: 16) else { return nil }
            out.append(b); i = next
        }
        return out
    }
}

public nonisolated struct RegisteredProtocol: Sendable, Identifiable {
    public let id: String                 // "<sutra_id>@v<version>"
    public let sutraID: String
    public let version: Int
    public let sutraSHA256: String
    public let pack: SignedProtocolPack
    public let publisher: String
    public let assurance: String
    public let signerKeyID: String
    public let status: ProtocolStatus
    public let importedAt: Date
    public let activatedAt: Date?
    public let revokedAt: Date?
    public let revocationReason: String?
}

/// A governed "reviewed as of" record — who reviewed, against which source,
/// what changed, what was decided. The truthful board status is derived from
/// these, never from a bare "mark reviewed" click.
public nonisolated struct ProtocolReviewRecord: Sendable, Identifiable {
    public let id: UUID
    public let subjectID: String          // ComplianceBoard SOP id or registry id
    public let reviewer: String
    public let role: String?
    public let sourceNote: String?
    public let sourceSHA256: String?
    public let diffSummary: String?
    public let affectedRuleIDs: [String]
    public let decision: ReviewDecision
    public let notes: String?
    public let signature: RecordSignature?
    public let reviewedAt: Date

    public enum ReviewDecision: String, Sendable, Codable {
        case current, updateRequired, notApplicable
    }

    public init(id: UUID = UUID(), subjectID: String, reviewer: String, role: String? = nil,
                sourceNote: String? = nil, sourceSHA256: String? = nil, diffSummary: String? = nil,
                affectedRuleIDs: [String] = [], decision: ReviewDecision, notes: String? = nil,
                signature: RecordSignature? = nil, reviewedAt: Date) {
        self.id = id; self.subjectID = subjectID; self.reviewer = reviewer; self.role = role
        self.sourceNote = sourceNote; self.sourceSHA256 = sourceSHA256; self.diffSummary = diffSummary
        self.affectedRuleIDs = affectedRuleIDs; self.decision = decision; self.notes = notes
        self.signature = signature; self.reviewedAt = reviewedAt
    }

    /// The canonical-signable content (everything except the signature itself).
    public struct SignablePayload: Sendable, Codable {
        public let id: UUID; public let subjectID: String; public let reviewer: String
        public let role: String?; public let sourceNote: String?; public let sourceSHA256: String?
        public let diffSummary: String?; public let affectedRuleIDs: [String]
        public let decision: String; public let notes: String?; public let reviewedAt: Date
    }
    public var payload: SignablePayload {
        SignablePayload(id: id, subjectID: subjectID, reviewer: reviewer, role: role,
                        sourceNote: sourceNote, sourceSHA256: sourceSHA256, diffSummary: diffSummary,
                        affectedRuleIDs: affectedRuleIDs, decision: decision.rawValue,
                        notes: notes, reviewedAt: reviewedAt)
    }

    /// A copy with its payload signed by the installation key.
    public func signed(key: CryptoKit.P256.Signing.PrivateKey? = nil) throws -> ProtocolReviewRecord {
        ProtocolReviewRecord(id: id, subjectID: subjectID, reviewer: reviewer, role: role,
                             sourceNote: sourceNote, sourceSHA256: sourceSHA256, diffSummary: diffSummary,
                             affectedRuleIDs: affectedRuleIDs, decision: decision, notes: notes,
                             signature: try RecordSigner.sign(payload, key: key), reviewedAt: reviewedAt)
    }
}

public nonisolated enum ProtocolRegistryError: Error, Equatable {
    case notFound(String)
    case revoked(String)      // a revoked pack can never activate again
}

public actor ProtocolRegistryRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Packs

    /// Register a signature-VERIFIED pack (callers go through ProtocolPacks.verify
    /// first — the repository never accepts raw bytes). Idempotent per identity.
    @discardableResult
    public func importPack(_ pack: SignedProtocolPack, at now: Date) async throws -> RegisteredProtocol {
        let id = "\(pack.envelope.sutraID)@v\(pack.envelope.sutraVersion)"
        let packJSON = String(data: try ConformanceCanonical.data(of: pack), encoding: .utf8) ?? "{}"
        try await database.exec("""
        INSERT INTO protocol_registry
            (id, sutra_id, version, sutra_sha256, pack_json, publisher, assurance,
             signer_key_id, status, imported_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'imported', ?)
        ON CONFLICT(id) DO NOTHING;
        """, [
            .text(id),
            .text(pack.envelope.sutraID),
            .integer(Int64(pack.envelope.sutraVersion)),
            .text(pack.envelope.sutraSHA256),
            .text(packJSON),
            .text(pack.envelope.publisher),
            .text(pack.envelope.assurance),
            .text(ProtocolPacks.signerKeyID(of: pack)),
            .date(now)
        ])
        guard let row = try await find(id: id) else { throw ProtocolRegistryError.notFound(id) }
        return row
    }

    /// Activate a registered pack: the previously active version of the same
    /// sutra becomes `superseded`. A revoked pack can never activate.
    public func activate(id: String, at now: Date) async throws {
        guard let row = try await find(id: id) else { throw ProtocolRegistryError.notFound(id) }
        guard row.status != .revoked else { throw ProtocolRegistryError.revoked(id) }
        try await database.exec(
            "UPDATE protocol_registry SET status = 'superseded' WHERE sutra_id = ? AND status = 'active';",
            [.text(row.sutraID)])
        try await database.exec(
            "UPDATE protocol_registry SET status = 'active', activated_at = ? WHERE id = ?;",
            [.date(now), .text(id)])
    }

    /// Revoke a pack with a recorded reason. Frozen runs are unaffected — they
    /// carry their own snapshot; new runs simply stop resolving this version.
    public func revoke(id: String, reason: String, at now: Date) async throws {
        guard try await find(id: id) != nil else { throw ProtocolRegistryError.notFound(id) }
        try await database.exec("""
        UPDATE protocol_registry SET status = 'revoked', revoked_at = ?, revocation_reason = ? WHERE id = ?;
        """, [.date(now), .text(reason), .text(id)])
    }

    /// The ACTIVE constitution for a sutra id, decoded from its registered
    /// snapshot — what new runs freeze. nil = fall back to the built-in.
    public func activeSutra(id sutraID: String) async throws -> Sutra? {
        let rows = try await database.query("""
        SELECT pack_json FROM protocol_registry
        WHERE sutra_id = ? AND status = 'active'
        ORDER BY version DESC LIMIT 1;
        """, [.text(sutraID)])
        guard let json = rows.first?.string(0) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let pack = try? decoder.decode(SignedProtocolPack.self, from: Data(json.utf8)) else { return nil }
        return try? decoder.decode(Sutra.self, from: Data(pack.sutraSnapshotJSON.utf8))
    }

    public func list() async throws -> [RegisteredProtocol] {
        let rows = try await database.query("""
        SELECT id, sutra_id, version, sutra_sha256, pack_json, publisher, assurance,
               signer_key_id, status, imported_at, activated_at, revoked_at, revocation_reason
        FROM protocol_registry ORDER BY sutra_id ASC, version DESC;
        """, [])
        return rows.compactMap(Self.decode(row:))
    }

    private func find(id: String) async throws -> RegisteredProtocol? {
        let rows = try await database.query("""
        SELECT id, sutra_id, version, sutra_sha256, pack_json, publisher, assurance,
               signer_key_id, status, imported_at, activated_at, revoked_at, revocation_reason
        FROM protocol_registry WHERE id = ?;
        """, [.text(id)])
        return rows.first.flatMap(Self.decode(row:))
    }

    private nonisolated static func decode(row r: SQLRow) -> RegisteredProtocol? {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let packJSON = r.string(4),
              let pack = try? decoder.decode(SignedProtocolPack.self, from: Data(packJSON.utf8)),
              let status = ProtocolStatus(rawValue: r.string(8) ?? "") else { return nil }
        return RegisteredProtocol(
            id: r.string(0) ?? "", sutraID: r.string(1) ?? "", version: Int(r.int(2) ?? 1),
            sutraSHA256: r.string(3) ?? "", pack: pack,
            publisher: r.string(5) ?? "", assurance: r.string(6) ?? "",
            signerKeyID: r.string(7) ?? "", status: status,
            importedAt: r.date(9) ?? Date(timeIntervalSince1970: 0),
            activatedAt: r.date(10), revokedAt: r.date(11), revocationReason: r.string(12))
    }

    // MARK: - Governed review records

    @discardableResult
    public func recordReview(_ record: ProtocolReviewRecord) async throws -> ProtocolReviewRecord {
        let sealJSON = try record.signature.map {
            String(data: try ConformanceCanonical.data(of: $0), encoding: .utf8) ?? ""
        }
        try await database.exec("""
        INSERT INTO protocol_review_records
            (id, subject_id, reviewer, role, source_note, source_sha256, diff_summary,
             affected_rules, decision, notes, record_seal_json, reviewed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, [
            .uuid(record.id),
            .text(record.subjectID),
            .text(record.reviewer),
            .optionalText(record.role),
            .optionalText(record.sourceNote),
            .optionalText(record.sourceSHA256),
            .optionalText(record.diffSummary),
            .text(record.affectedRuleIDs.joined(separator: ",")),
            .text(record.decision.rawValue),
            .optionalText(record.notes),
            .optionalText(sealJSON),
            .date(record.reviewedAt)
        ])
        return record
    }

    /// The latest governed review for a subject — the board's truthful
    /// "reviewed as of" status. nil = never reviewed with a record.
    public func latestReview(subjectID: String) async throws -> ProtocolReviewRecord? {
        let rows = try await database.query("""
        SELECT id, subject_id, reviewer, role, source_note, source_sha256, diff_summary,
               affected_rules, decision, notes, record_seal_json, reviewed_at
        FROM protocol_review_records WHERE subject_id = ?
        ORDER BY reviewed_at DESC LIMIT 1;
        """, [.text(subjectID)])
        return rows.first.flatMap(Self.decodeReview(row:))
    }

    public func reviews(subjectID: String) async throws -> [ProtocolReviewRecord] {
        let rows = try await database.query("""
        SELECT id, subject_id, reviewer, role, source_note, source_sha256, diff_summary,
               affected_rules, decision, notes, record_seal_json, reviewed_at
        FROM protocol_review_records WHERE subject_id = ?
        ORDER BY reviewed_at ASC;
        """, [.text(subjectID)])
        return rows.compactMap(Self.decodeReview(row:))
    }

    private nonisolated static func decodeReview(row r: SQLRow) -> ProtocolReviewRecord? {
        guard let decision = ProtocolReviewRecord.ReviewDecision(rawValue: r.string(8) ?? "") else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let signature: RecordSignature? = r.string(10).flatMap {
            try? decoder.decode(RecordSignature.self, from: Data($0.utf8))
        }
        let affected = (r.string(7) ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        return ProtocolReviewRecord(
            id: r.uuid(0) ?? UUID(), subjectID: r.string(1) ?? "",
            reviewer: r.string(2) ?? "", role: r.string(3),
            sourceNote: r.string(4), sourceSHA256: r.string(5), diffSummary: r.string(6),
            affectedRuleIDs: affected, decision: decision, notes: r.string(9),
            signature: signature, reviewedAt: r.date(11) ?? Date(timeIntervalSince1970: 0))
    }
}
