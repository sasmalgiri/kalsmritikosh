//
//  UndatedOrderRepository.swift
//  Kalsmritikosh
//
//  Unified path TIME-11 (owner 2026-11-22) — not tested yet.
//
//  Reads where a cited passage sits in its source — the logical source, when that version was
//  recorded, and the passage's position — so UndatedOrder can order undated events by thread /
//  document order and source-version order. Read-only; it never writes a date anywhere.
//

import Foundation

public actor UndatedOrderRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    /// Keys for cited passages (evidence block ids) and, for citations without a passage, for their
    /// source versions. Unknown ids are simply absent from the result.
    public func documentKeys(blockIDs: Set<UUID>, versionIDs: Set<UUID>) async throws -> [UUID: UndatedOrder.DocumentKey] {
        var out: [UUID: UndatedOrder.DocumentKey] = [:]
        for chunk in Array(blockIDs).undatedOrderChunks(200) where !chunk.isEmpty {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try await database.query("""
                SELECT b.id, sv.logical_source_id, sv.valid_from, b.ordinal
                FROM evidence_blocks b JOIN source_versions sv ON sv.id = b.source_version_id
                WHERE b.id IN (\(marks));
                """, chunk.map { .uuid($0) })
            for r in rows {
                guard let id = r.uuid(0), let source = r.uuid(1) else { continue }
                out[id] = .init(sourceID: source, versionRecordedAt: r.double(2), position: r.int(3).map(Int.init))
            }
        }
        for chunk in Array(versionIDs).undatedOrderChunks(200) where !chunk.isEmpty {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try await database.query("""
                SELECT id, logical_source_id, valid_from FROM source_versions WHERE id IN (\(marks));
                """, chunk.map { .uuid($0) })
            for r in rows {
                guard let id = r.uuid(0), let source = r.uuid(1) else { continue }
                out[id] = .init(sourceID: source, versionRecordedAt: r.double(2), position: nil)
            }
        }
        return out
    }
}

private extension Array {
    func undatedOrderChunks(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
