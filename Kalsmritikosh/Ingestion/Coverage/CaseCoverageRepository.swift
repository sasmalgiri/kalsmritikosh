//
//  CaseCoverageRepository.swift
//  Kalsmritikosh
//
//  USF-M2 (USF-007 §19) — READ-ONLY access to the existing authorities the coverage manifest is
//  reconstructed from. It performs NO writes and copies NO evidence. Alias resolution + current-version
//  selection happen here so the builder stays a pure assembler.
//

import Foundation

public struct CaseCoverageRepository: Sendable {

    private let database: Database
    public init(database: Database) { self.database = database }

    /// Resolved current-version metadata for a source (never its content bytes).
    public struct VersionMeta: Sendable, Hashable {
        public let logicalSourceID: UUID
        public let sourceVersionID: UUID
        public let sourceType: SourceType
        public let custodyMode: String
        public let preservationStatus: String
    }

    public func workspaceUpdatedAt(_ workspaceID: UUID) async throws -> Date? {
        try await database.query("SELECT updated_at FROM workspaces WHERE id = ? LIMIT 1;", [.uuid(workspaceID)]).first?.double(0).map { Date(timeIntervalSince1970: $0) }
    }

    /// The workspace's direct-membership file ids, in a deterministic order.
    public func directRootFileIDs(_ workspaceID: UUID) async throws -> [UUID] {
        try await database.query(
            "SELECT file_id FROM workspace_sources WHERE workspace_id = ? ORDER BY added_at ASC, file_id ASC;", [.uuid(workspaceID)])
            .compactMap { $0.uuid(0) }
    }

    /// Resolve a workspace file id to the CURRENT version of its canonical source (aliases canonicalized).
    public func currentVersion(forFileID fileID: UUID) async throws -> VersionMeta? {
        var id = fileID
        var contentHash: String? = nil
        // Follow alias_of to the canonical file (bounded — alias chains are one deep, but loop-guard anyway).
        for _ in 0..<8 {
            guard let row = try await database.query(
                "SELECT alias_of, content_hash FROM files WHERE id = ? LIMIT 1;", [.uuid(id)]).first else { return nil }
            if let alias = row.uuid(0) { id = alias; continue }
            contentHash = row.string(1); break
        }
        guard let hash = contentHash else { return nil }
        return try await version(whereClause: "content_hash = ? AND is_current = 1", [.text(hash)])
    }

    /// Current-version metadata by exact source version id.
    public func versionMeta(sourceVersionID: UUID) async throws -> VersionMeta? {
        try await version(whereClause: "id = ?", [.uuid(sourceVersionID)])
    }

    private func version(whereClause: String, _ bindings: [SQLValue]) async throws -> VersionMeta? {
        guard let r = try await database.query("""
            SELECT id, logical_source_id, detected_type, custody_mode, preservation_status
              FROM source_versions WHERE \(whereClause) LIMIT 1;
            """, bindings).first,
            let id = r.uuid(0), let logical = r.uuid(1) else { return nil }
        return VersionMeta(logicalSourceID: logical, sourceVersionID: id,
                           sourceType: SourceType(rawValue: r.string(2) ?? "") ?? .unknown,
                           custodyMode: r.string(3) ?? "", preservationStatus: r.string(4) ?? "")
    }

    /// Children of a source version by relation kind (deterministic order).
    public func descendants(of parent: UUID, relations: [String]) async throws -> [(child: UUID, relation: String, ordinal: Int?)] {
        guard !relations.isEmpty else { return [] }
        let placeholders = relations.map { _ in "?" }.joined(separator: ",")
        let rows = try await database.query("""
            SELECT child_source_version_id, relation, ordinal FROM source_version_relations
             WHERE parent_source_version_id = ? AND relation IN (\(placeholders))
             ORDER BY ordinal ASC, child_source_version_id ASC;
            """, [.uuid(parent)] + relations.map { SQLValue.text($0) })
        return rows.compactMap { r in r.uuid(0).map { (child: $0, relation: r.string(1) ?? "", ordinal: r.int(2).map(Int.init)) } }
    }

    /// Whether a container coverage manifest exists for this source version (v87). Absence on a
    /// container source becomes a "container inspection missing" limitation — never a false "0 members".
    public func hasContainerManifest(sourceVersionID: UUID) async throws -> Bool {
        try await database.query(
            "SELECT 1 FROM container_manifests WHERE source_version_id = ? LIMIT 1;", [.uuid(sourceVersionID)]).first != nil
    }
}
