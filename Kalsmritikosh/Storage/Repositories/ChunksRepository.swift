//
//  ChunksRepository.swift
//  Kalsmritikosh
//

import Foundation

public actor ChunksRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func insertBatch(_ chunks: [Chunk]) async throws {
        for chunk in chunks {
            try await database.exec("""
            INSERT INTO chunks (id, object_id, ordinal, text, char_start, char_end, page_number, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """, [
                .uuid(chunk.id),
                .uuid(chunk.objectID),
                .integer(Int64(chunk.ordinal)),
                .text(chunk.text),
                .integer(Int64(chunk.characterRange.lowerBound)),
                .integer(Int64(chunk.characterRange.upperBound)),
                chunk.pageNumber.map { .integer(Int64($0)) } ?? .null,
                .date(chunk.createdAt)
            ])
        }
    }

    public func count(forObject id: KnowledgeObject.ID) async throws -> Int {
        let rows = try await database.query(
            "SELECT COUNT(*) FROM chunks WHERE object_id = ?;",
            [.uuid(id)]
        )
        return Int(rows.first?.int(0) ?? 0)
    }

    public func findByIDs(_ ids: [Chunk.ID]) async throws -> [Chunk] {
        guard !ids.isEmpty else { return [] }
        var chunks: [Chunk] = []
        for id in ids {
            let rows = try await database.query("""
            SELECT id, object_id, ordinal, text, char_start, char_end, page_number, created_at
            FROM chunks WHERE id = ? LIMIT 1;
            """, [.uuid(id)])
            if let row = rows.first, let chunk = decode(row) {
                chunks.append(chunk)
            }
        }
        return chunks
    }

    public func searchFTS(_ query: String, limit: Int = 50) async throws -> [Chunk] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let rows = try await database.query("""
        SELECT c.id, c.object_id, c.ordinal, c.text, c.char_start, c.char_end, c.page_number, c.created_at
        FROM chunks c
        JOIN chunks_fts ON chunks_fts.rowid = c.rowid
        WHERE chunks_fts.text MATCH ?
        ORDER BY rank
        LIMIT ?;
        """, [.text(query), .integer(Int64(limit))])
        return rows.compactMap(decode)
    }

    private func decode(_ row: SQLRow) -> Chunk? {
        guard
            let id = row.uuid(0),
            let objectID = row.uuid(1),
            let ordinal = row.int(2),
            let text = row.string(3),
            let start = row.int(4),
            let end = row.int(5),
            let created = row.date(7)
        else { return nil }
        return Chunk(
            id: id,
            objectID: objectID,
            ordinal: Int(ordinal),
            text: text,
            characterRange: Int(start)..<Int(end),
            pageNumber: row.int(6).map(Int.init),
            createdAt: created
        )
    }
}
