//
//  KnowledgeObjectRepository+Batch.swift
//  Kalsmritikosh
//
//  Speed PERF-29/30 (owner 2026-11-23) — not tested yet. Batched reads of many knowledge objects in one IN query per
//  500 ids (SQLite's bind limit stays far away), replacing per-id `load(id:)` / `fetchContent(id:)` loops (N+1).
//

import Foundation
import os

extension KnowledgeObjectRepository {
    /// The content of each id that exists (missing ids map to nothing). One query per 500 ids.
    public func fetchContents(ids: [KnowledgeObject.ID]) async throws -> [KnowledgeObject.ID: String] {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return [:] }
        var out: [KnowledgeObject.ID: String] = [:]
        out.reserveCapacity(unique.count)
        for start in stride(from: 0, to: unique.count, by: 500) {
            let batch = unique[start..<min(start + 500, unique.count)]
            let marks = batch.map { _ in "?" }.joined(separator: ",")
            let rows = try await database.query("SELECT id, content FROM knowledge_objects WHERE id IN (\(marks));",
                                                batch.map { SQLValue.uuid($0) })
            for row in rows { if let id = row.uuid(0), let c = row.string(1) { out[id] = c } }
        }
        return out
    }

    /// Full objects for `ids` (as `load(id:)` builds them, joined with files for the source URL), keyed by id. One query
    /// per 500 ids.
    public func loadMany(ids: [KnowledgeObject.ID]) async throws -> [KnowledgeObject.ID: KnowledgeObject] {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return [:] }
        let decoder = JSONDecoder()
        var out: [KnowledgeObject.ID: KnowledgeObject] = [:]
        out.reserveCapacity(unique.count)
        for start in stride(from: 0, to: unique.count, by: 500) {
            let batch = unique[start..<min(start + 500, unique.count)]
            let marks = batch.map { _ in "?" }.joined(separator: ",")
            let rows = try await database.query("""
            SELECT k.id, k.source_type, k.content, k.metadata_json, k.confidence,
                   k.created_at, k.updated_at, f.url
            FROM knowledge_objects k
            JOIN files f ON f.id = k.file_id
            WHERE k.id IN (\(marks));
            """, batch.map { SQLValue.uuid($0) })
            for row in rows {
                guard let objID = row.uuid(0), let typeRaw = row.string(1), let type = SourceType(rawValue: typeRaw),
                      let content = row.string(2), let conf = row.double(4), let createdAt = row.date(5),
                      let updatedAt = row.date(6), let urlString = row.string(7) else { continue }
                var metadata: [String: AnyCodable] = [:]
                if let metaJSON = row.string(3), let data = metaJSON.data(using: .utf8) {
                    do { metadata = try decoder.decode([String: AnyCodable].self, from: data) } catch {
                        KalsmritikoshLog.storage.error("loadMany: metadata unreadable: \(String(describing: error), privacy: .private)")
                    }
                }
                out[objID] = KnowledgeObject(
                    id: objID, sourceFile: URL(string: urlString) ?? URL(fileURLWithPath: urlString), sourceType: type,
                    content: content, metadata: metadata, confidence: Confidence(conf), createdAt: createdAt, updatedAt: updatedAt)
            }
        }
        return out
    }
}
