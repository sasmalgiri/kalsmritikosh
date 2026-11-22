//
//  ReferenceShelfRepository.swift
//  Kalsmritikosh
//
//  Unified path SEARCH-17 (owner 2026-11-22) — not tested yet.
//
//  The reference shelf's store (v201): folders the person adds as REFERENCE (acts, rules, manuals),
//  their documents and passages, and a full-text index over the passages. Kept in its own tables —
//  never knowledge_objects, chunks, entities, events or facts — so a reference passage can never be
//  archive evidence, case scope or story material. The only reader is the shelf lane in Ask.
//

import Foundation

public actor ReferenceShelfRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    public struct Folder: Sendable, Hashable, Identifiable {
        public let id: UUID
        public let path: String
        public let label: String
        public let bookmark: Data?
        public let addedAt: Date
    }

    public struct DocumentSummary: Sendable, Hashable, Identifiable {
        public let id: UUID
        public let title: String
        public let status: String
        public let detail: String?
        public let passageCount: Int
    }

    public struct Hit: Sendable, Hashable {
        public let passageID: UUID
        public let documentTitle: String
        public let section: String?
        public let text: String
    }

    @discardableResult
    public func addFolder(path: String, label: String, bookmark: Data?) async throws -> UUID {
        if let existing = try await database.query("SELECT id FROM reference_shelf_folders WHERE path = ?;", [.text(path)]).first?.uuid(0) {
            return existing
        }
        let id = UUID()
        try await database.exec("""
            INSERT INTO reference_shelf_folders (id, path, bookmark, label, added_at) VALUES (?,?,?,?,?);
            """, [.uuid(id), .text(path), bookmark.map { .blob($0) } ?? .null, .text(label), .date(Date())])
        return id
    }

    /// Removes a folder from the shelf (its documents and passages go with it). Shelf material is the
    /// person's reference copy, not extracted archive evidence; the files themselves are untouched.
    public func removeFolder(id: UUID) async throws {
        try await database.withSavepoint("shelf_remove") { db in
            try db.exec("""
                DELETE FROM reference_shelf_passages WHERE document_id IN
                    (SELECT id FROM reference_shelf_documents WHERE folder_id = ?);
                """, [.uuid(id)])
            try db.exec("DELETE FROM reference_shelf_documents WHERE folder_id = ?;", [.uuid(id)])
            try db.exec("DELETE FROM reference_shelf_folders WHERE id = ?;", [.uuid(id)])
        }
    }

    public func folders() async throws -> [Folder] {
        try await database.query("SELECT id, path, label, bookmark, added_at FROM reference_shelf_folders ORDER BY added_at;", [])
            .compactMap { r in
                guard let id = r.uuid(0), let path = r.string(1) else { return nil }
                return Folder(id: id, path: path, label: r.string(2) ?? path, bookmark: r.blob(3),
                              addedAt: Date(timeIntervalSince1970: r.double(4) ?? 0))
            }
    }

    public func documents(folderID: UUID) async throws -> [DocumentSummary] {
        try await database.query("""
            SELECT d.id, d.title, d.status, d.detail, (SELECT COUNT(*) FROM reference_shelf_passages p WHERE p.document_id = d.id)
            FROM reference_shelf_documents d WHERE d.folder_id = ? ORDER BY d.title;
            """, [.uuid(folderID)]).compactMap { r in
            guard let id = r.uuid(0), let title = r.string(1), let status = r.string(2) else { return nil }
            return DocumentSummary(id: id, title: title, status: status, detail: r.string(3), passageCount: Int(r.int(4) ?? 0))
        }
    }

    /// The stored content hash of a shelf document, so an unchanged file is not read again.
    public func contentHash(folderID: UUID, path: String) async throws -> String? {
        try await database.query("SELECT content_hash FROM reference_shelf_documents WHERE folder_id = ? AND path = ?;",
                                 [.uuid(folderID), .text(path)]).first?.string(0)
    }

    /// Writes (or rewrites) one shelf document and its passages in one savepoint.
    public func putDocument(folderID: UUID, path: String, title: String, contentHash: String,
                            status: String, detail: String?, passages: [(section: String?, text: String)]) async throws {
        try await database.withSavepoint("shelf_put") { db in
            let existing = try db.query("SELECT id FROM reference_shelf_documents WHERE folder_id = ? AND path = ?;",
                                        [.uuid(folderID), .text(path)]).first?.uuid(0)
            let docID = existing ?? UUID()
            if existing != nil {
                try db.exec("DELETE FROM reference_shelf_passages WHERE document_id = ?;", [.uuid(docID)])
                try db.exec("""
                    UPDATE reference_shelf_documents SET title = ?, content_hash = ?, status = ?, detail = ?, added_at = ? WHERE id = ?;
                    """, [.text(title), .text(contentHash), .text(status), .optionalText(detail), .date(Date()), .uuid(docID)])
            } else {
                try db.exec("""
                    INSERT INTO reference_shelf_documents (id, folder_id, path, title, content_hash, status, detail, added_at)
                    VALUES (?,?,?,?,?,?,?,?);
                    """, [.uuid(docID), .uuid(folderID), .text(path), .text(title), .text(contentHash), .text(status),
                          .optionalText(detail), .date(Date())])
            }
            for (i, p) in passages.enumerated() {
                try db.exec("""
                    INSERT INTO reference_shelf_passages (id, document_id, ordinal, section, text) VALUES (?,?,?,?,?);
                    """, [.uuid(UUID()), .uuid(docID), .integer(Int64(i)), .optionalText(p.section), .text(p.text)])
            }
        }
    }

    /// Full-text search over the shelf's passages (best first). The query is reduced to plain words,
    /// so no search syntax from the question reaches FTS.
    public func search(_ term: String, limit: Int = 5) async throws -> [Hit] {
        let words = term.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
            .prefix(12)
        guard !words.isEmpty else { return [] }
        let match = words.map { "\"\($0)\"" }.joined(separator: " OR ")
        return try await database.query("""
            SELECT p.id, d.title, p.section, p.text
            FROM reference_shelf_fts f
            JOIN reference_shelf_passages p ON p.rowid = f.rowid
            JOIN reference_shelf_documents d ON d.id = p.document_id
            WHERE reference_shelf_fts MATCH ?
            ORDER BY bm25(reference_shelf_fts) LIMIT ?;
            """, [.text(match), .integer(Int64(limit))]).compactMap { r in
            guard let id = r.uuid(0), let title = r.string(1), let text = r.string(3) else { return nil }
            return Hit(passageID: id, documentTitle: title, section: r.string(2), text: text)
        }
    }

    public func passageCount() async throws -> Int {
        Int(try await database.query("SELECT COUNT(*) FROM reference_shelf_passages;", []).first?.int(0) ?? 0)
    }
}
