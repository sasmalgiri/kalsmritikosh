//
//  SourceSameness.swift
//  Kalsmritikosh
//
//  Smart-map IN-06 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md §04) — duplicates and versions kept apart.
//  Custody (CanonicalSourceIntakeRepository) already separates an exact byte copy at another location (an alias
//  occurrence of the same version, with its own receipt), a move, and a revision at the same location (a new version that
//  supersedes the old). Two classes were missing:
//
//  • CONTENT-EQUIVALENT sources: the same text in different bytes (a PDF and a DOCX of one letter, a re-saved file). Each
//    version's read text is normalised (Unicode compatibility form, whitespace folded) and its SHA-256 recorded in
//    `source_text_digests` (v178); equal digests with different bytes are content-equivalent.
//  • A REVISED document at a NEW location: linked to its earlier version only when a person confirms it
//    (`source_version_links`, relation revisionOf, with the basis and who confirmed it). The app may suggest candidates
//    (the same file name as another document); it never links by itself.
//
//  Nothing here merges, deletes or re-points anything: both versions, their intake receipts and every transaction or
//  event read from them stay separate records. Sameness is a relation shown to the person, not a deduplication.
//  Nothing here looks at a file's type.
//

import Foundation
import CryptoKit

/// How two source versions relate.
public nonisolated enum SourceSameness: String, Sendable, Codable, Hashable, CaseIterable {
    /// The same version (an exact copy at another location is an occurrence of the same version).
    case sameVersion
    /// The same bytes held as two documents.
    case exactCopy
    /// Versions of one document (at the same location), or a revision a person confirmed across locations.
    case revision
    /// The same text in different bytes.
    case contentEquivalent
    case distinct
}

/// The text normaliser behind content equivalence. Changing it changes `identifier`, so digests made by another
/// normaliser are never compared.
public nonisolated enum SourceTextNormalizer {
    public static let identifier = "nfkc-whitespace-1"

    public static func normalized(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    /// SHA-256 (hex) of the normalised text and its length; nil when there is no text.
    public static func digest(_ text: String) -> (sha256: String, characters: Int)? {
        let n = normalized(text)
        guard !n.isEmpty else { return nil }
        let hex = SHA256.hash(data: Data(n.utf8)).map { String(format: "%02x", $0) }.joined()
        return (hex, n.count)
    }
}

/// A person-confirmed link between a revised document and its earlier version.
public nonisolated struct SourceVersionLink: Sendable, Equatable, Hashable, Identifiable {
    public let id: UUID
    public let sourceVersionID: UUID
    public let earlierSourceVersionID: UUID
    public let basis: String
    public let confirmedBy: String
    public let confirmedAt: Date
    public let withdrawnBy: String?
    public let withdrawnAt: Date?
    public let withdrawnReason: String?
    public var isActive: Bool { withdrawnAt == nil }
}

public nonisolated enum SourceSamenessError: Error, Sendable, Equatable, LocalizedError {
    case versionNotFound(UUID)
    case sameDocument
    case blankActor
    case blankBasis
    case blankReason
    case linkNotFound(UUID)
    case alreadyWithdrawn(UUID)

    public var errorDescription: String? {
        switch self {
        case .versionNotFound: return "That document version is not in the archive."
        case .sameDocument: return "These are already versions of one document; there is nothing to link."
        case .blankActor: return "Say who is confirming this."
        case .blankBasis: return "Say why one is a revision of the other."
        case .blankReason: return "Give a reason."
        case .linkNotFound: return "That link was not found."
        case .alreadyWithdrawn: return "That link was already withdrawn."
        }
    }
}

public actor SourceSamenessRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    // MARK: - Content equivalence

    /// Compute and record the text digest of a version from the text read from it: its own evidence blocks, or — for the
    /// current version of a document — the document's ledger text. Returns the digest, or nil when no text was read (a
    /// scan not yet recognised has no text, so it is never "equivalent" to anything). Idempotent.
    @discardableResult
    public func recordTextDigest(sourceVersionID: UUID, at date: Date) async throws -> String? {
        guard let row = try await database.query("SELECT logical_source_id, is_current FROM source_versions WHERE id = ?;",
                                                 [.uuid(sourceVersionID)]).first, let logical = row.string(0) else {
            throw SourceSamenessError.versionNotFound(sourceVersionID)
        }
        var text = try await database.query("""
            SELECT raw_text FROM evidence_blocks WHERE source_version_id = ? AND parent_block_id IS NULL ORDER BY ordinal;
            """, [.uuid(sourceVersionID)]).compactMap { $0.string(0) }.joined(separator: "\n")
        if SourceTextNormalizer.normalized(text).isEmpty, row.int(1) == 1 {
            text = try await database.query("SELECT content FROM knowledge_objects WHERE file_id = ? ORDER BY created_at, rowid;",
                                            [.text(logical)]).compactMap { $0.string(0) }.joined(separator: "\n")
        }
        guard let d = SourceTextNormalizer.digest(text) else { return nil }
        try await database.exec("""
            INSERT INTO source_text_digests (source_version_id, text_sha256, normalizer, character_count, computed_at) VALUES (?,?,?,?,?)
            ON CONFLICT(source_version_id) DO UPDATE SET text_sha256 = excluded.text_sha256, normalizer = excluded.normalizer,
                character_count = excluded.character_count, computed_at = excluded.computed_at;
            """, [.uuid(sourceVersionID), .text(d.sha256), .text(SourceTextNormalizer.identifier), .integer(Int64(d.characters)), .date(date)])
        return d.sha256
    }

    /// Other versions with the same normalised text but different bytes — content-equivalent sources.
    public func contentEquivalents(of sourceVersionID: UUID) async throws -> [UUID] {
        try await database.query("""
            SELECT o.source_version_id FROM source_text_digests me
            JOIN source_text_digests o ON o.text_sha256 = me.text_sha256 AND o.normalizer = me.normalizer AND o.source_version_id <> me.source_version_id
            JOIN source_versions a ON a.id = me.source_version_id
            JOIN source_versions b ON b.id = o.source_version_id
            WHERE me.source_version_id = ? AND a.content_hash <> b.content_hash
            ORDER BY o.source_version_id;
            """, [.uuid(sourceVersionID)]).compactMap { $0.uuid(0) }
    }

    /// How two versions relate (most specific first).
    public func sameness(_ a: UUID, _ b: UUID) async throws -> SourceSameness {
        if a == b { return .sameVersion }
        let rows = try await database.query("SELECT id, logical_source_id, content_hash FROM source_versions WHERE id IN (?, ?);", [.uuid(a), .uuid(b)])
        guard let ra = rows.first(where: { $0.uuid(0) == a }) else { throw SourceSamenessError.versionNotFound(a) }
        guard let rb = rows.first(where: { $0.uuid(0) == b }) else { throw SourceSamenessError.versionNotFound(b) }
        if ra.string(2) == rb.string(2) { return .exactCopy }
        if ra.string(1) == rb.string(1) { return .revision }
        let linked = try await database.query("""
            SELECT 1 FROM source_version_links WHERE withdrawn_at IS NULL AND
              ((source_version_id = ? AND earlier_source_version_id = ?) OR (source_version_id = ? AND earlier_source_version_id = ?)) LIMIT 1;
            """, [.uuid(a), .uuid(b), .uuid(b), .uuid(a)])
        if !linked.isEmpty { return .revision }
        let digests = try await database.query("SELECT source_version_id, text_sha256, normalizer FROM source_text_digests WHERE source_version_id IN (?, ?);",
                                               [.uuid(a), .uuid(b)])
        if digests.count == 2, digests[0].string(1) == digests[1].string(1), digests[0].string(2) == digests[1].string(2) {
            return .contentEquivalent
        }
        return .distinct
    }

    // MARK: - Revisions across locations (person-confirmed)

    /// A person confirms that `revised` is a revision of `earlier` (a different document, e.g. the same contract saved
    /// under a new name). Refused for versions of one document (already linked by custody) and without a basis.
    @discardableResult
    public func confirmRevision(revised: UUID, earlier: UUID, basis: String, actor: String, at date: Date) async throws -> SourceVersionLink {
        let who = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !who.isEmpty else { throw SourceSamenessError.blankActor }
        let why = basis.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !why.isEmpty else { throw SourceSamenessError.blankBasis }
        let id = UUID()
        let existing: UUID? = try await database.withSavepoint("svl_\(id.uuidString.prefix(8))") { db in
            let rows = try db.query("SELECT id, logical_source_id FROM source_versions WHERE id IN (?, ?);", [.uuid(revised), .uuid(earlier)])
            guard let r = rows.first(where: { $0.uuid(0) == revised }) else { throw SourceSamenessError.versionNotFound(revised) }
            guard let e = rows.first(where: { $0.uuid(0) == earlier }) else { throw SourceSamenessError.versionNotFound(earlier) }
            guard revised != earlier, r.string(1) != e.string(1) else { throw SourceSamenessError.sameDocument }
            if let known = try db.query("""
                SELECT id FROM source_version_links WHERE source_version_id = ? AND earlier_source_version_id = ? AND relation = 'revisionOf' AND withdrawn_at IS NULL;
                """, [.uuid(revised), .uuid(earlier)]).first?.uuid(0) { return known }
            try db.exec("""
                INSERT INTO source_version_links (id, source_version_id, earlier_source_version_id, relation, basis, confirmed_by, confirmed_at)
                VALUES (?,?,?,'revisionOf',?,?,?);
                """, [.uuid(id), .uuid(revised), .uuid(earlier), .text(why), .text(who), .date(date)])
            return nil
        }
        guard let made = try await self.link(existing ?? id) else { throw SourceSamenessError.linkNotFound(existing ?? id) }
        return made
    }

    /// Withdraw a link with a reason (it is kept, marked withdrawn).
    public func withdrawRevisionLink(_ id: UUID, reason: String, actor: String, at date: Date) async throws {
        let who = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !who.isEmpty else { throw SourceSamenessError.blankActor }
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !why.isEmpty else { throw SourceSamenessError.blankReason }
        try await database.withSavepoint("svlw_\(id.uuidString.prefix(8))") { db in
            guard let row = try db.query("SELECT withdrawn_at FROM source_version_links WHERE id = ?;", [.uuid(id)]).first else {
                throw SourceSamenessError.linkNotFound(id)
            }
            guard row.isNull(0) else { throw SourceSamenessError.alreadyWithdrawn(id) }
            try db.exec("UPDATE source_version_links SET withdrawn_by = ?, withdrawn_at = ?, withdrawn_reason = ? WHERE id = ?;",
                        [.text(who), .date(date), .text(why), .uuid(id)])
        }
    }

    public func link(_ id: UUID) async throws -> SourceVersionLink? {
        try await database.query("""
            SELECT id, source_version_id, earlier_source_version_id, basis, confirmed_by, confirmed_at, withdrawn_by, withdrawn_at, withdrawn_reason
            FROM source_version_links WHERE id = ?;
            """, [.uuid(id)]).first.flatMap(Self.decodeLink)
    }

    /// Every link touching a version (either end), oldest first.
    public func revisionLinks(of sourceVersionID: UUID) async throws -> [SourceVersionLink] {
        try await database.query("""
            SELECT id, source_version_id, earlier_source_version_id, basis, confirmed_by, confirmed_at, withdrawn_by, withdrawn_at, withdrawn_reason
            FROM source_version_links WHERE source_version_id = ? OR earlier_source_version_id = ? ORDER BY confirmed_at, rowid;
            """, [.uuid(sourceVersionID), .uuid(sourceVersionID)]).compactMap(Self.decodeLink)
    }

    /// Suggestions only: current versions of OTHER documents with the same file name and different bytes, not yet linked.
    /// The person decides; nothing is linked from this.
    public func revisionCandidates(for sourceVersionID: UUID) async throws -> [UUID] {
        try await database.query("""
            SELECT o.id FROM source_versions me JOIN source_versions o
              ON lower(o.filename) = lower(me.filename) AND o.logical_source_id <> me.logical_source_id AND o.content_hash <> me.content_hash
             AND o.is_current = 1
            WHERE me.id = ? AND me.filename IS NOT NULL AND length(trim(me.filename)) > 0
              AND NOT EXISTS (SELECT 1 FROM source_version_links l WHERE l.withdrawn_at IS NULL AND
                    ((l.source_version_id = me.id AND l.earlier_source_version_id = o.id) OR (l.source_version_id = o.id AND l.earlier_source_version_id = me.id)))
            ORDER BY o.created_at, o.id;
            """, [.uuid(sourceVersionID)]).compactMap { $0.uuid(0) }
    }

    nonisolated static func decodeLink(_ r: SQLRow) -> SourceVersionLink? {
        guard let id = r.uuid(0), let v = r.uuid(1), let e = r.uuid(2), let basis = r.string(3), let by = r.string(4), let at = r.date(5) else { return nil }
        return SourceVersionLink(id: id, sourceVersionID: v, earlierSourceVersionID: e, basis: basis, confirmedBy: by, confirmedAt: at,
                                 withdrawnBy: r.string(6), withdrawnAt: r.date(7), withdrawnReason: r.string(8))
    }
}
