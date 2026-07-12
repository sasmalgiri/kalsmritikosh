//
//  SourceRelationsRepository.swift
//  Kalsmritikosh
//
//  A2 §7.6 — persist parent→child source provenance. When a file contains other
//  files (an email's attachment, an archive's member), the child is ingested as
//  its own source and hash-dedup may fold it into a single canonical copy. This
//  table records WHICH parents referenced each child, so "the PDF attached to
//  two emails" keeps both parent links even though the bytes are stored once.
//  Best-effort recording; never fails an ingest.
//

import Foundation

public actor SourceRelationsRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    public enum Relation: String, Sendable {
        case attachment        // email → attachment
        case archiveMember     // zip/archive → member
        case message           // mbox → message
        case embedded          // document → embedded object
        case derivedConversion // source version → converted output
    }

    public struct Link: Sendable, Hashable {
        public let parentFileID: UUID
        public let childFileID: UUID
        public let relation: String
    }

    /// Record a parent→child relation. Deduped by (parent, child, relation);
    /// best-effort (swallows errors so it can never fail an ingest).
    public func record(parent: UUID, child: UUID, relation: Relation, at when: Date = Date()) async {
        guard parent != child else { return }   // a file isn't its own parent
        try? await database.exec("""
        INSERT OR IGNORE INTO source_relations
            (id, parent_file_id, child_file_id, relation, created_at)
        VALUES (?, ?, ?, ?, ?);
        """, [
            .uuid(UUID()), .uuid(parent), .uuid(child),
            .text(relation.rawValue), .real(when.timeIntervalSince1970)
        ])
    }

    /// Children of a parent file (its attachments / members).
    public func children(of parent: UUID) async -> [Link] {
        await links("parent_file_id", parent)
    }

    /// Parents of a child file (which emails/archives referenced it).
    public func parents(of child: UUID) async -> [Link] {
        await links("child_file_id", child)
    }

    private func links(_ column: String, _ id: UUID) async -> [Link] {
        let rows = (try? await database.query("""
        SELECT parent_file_id, child_file_id, relation FROM source_relations
        WHERE \(column) = ?;
        """, [.uuid(id)])) ?? []
        return rows.compactMap { row in
            guard let p = row.uuid(0), let c = row.uuid(1), let r = row.string(2) else { return nil }
            return Link(parentFileID: p, childFileID: c, relation: r)
        }
    }

    public func count() async -> Int {
        let rows = (try? await database.query("SELECT COUNT(*) FROM source_relations;", [])) ?? []
        return Int(rows.first?.int(0) ?? 0)
    }
}
