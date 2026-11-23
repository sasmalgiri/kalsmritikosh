//
//  EmbeddingCacheRepository.swift
//  Kalsmritikosh
//
//  Persistent L2 for embeddings (schema v29). Keyed by
//  (model_id, text_hash) so repeated text — signatures, disclaimers,
//  quoted footers, and re-ingested files — doesn't pay the embedding
//  cost again across launches. Model-scoped so switching embedders
//  never returns a stale vector.
//
//  This is a cache, not ledger data: it's safe to clear wholesale.
//

import Foundation
import CryptoKit
import os

public actor EmbeddingCacheRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    /// Stable SHA-256 hash of the (trimmed, lowercased) text — the same
    /// normalization the in-memory cache uses so the two tiers agree.
    public nonisolated static func hash(_ text: String) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    public func lookup(modelID: String, textHash: String) async -> [Float]? {
        let rows = (try? await database.query("""
        SELECT dimension, vector FROM embedding_cache
        WHERE model_id = ? AND text_hash = ?;
        """, [.text(modelID), .text(textHash)])) ?? []
        guard let row = rows.first,
              let dim = row.int(0),
              let data = row.blob(1) else { return nil }
        return Self.floats(from: data, dimension: Int(dim))
    }

    /// Speed PERF-34 torrent (owner 2026-11-23) — not tested yet. Many vectors in one query (was one query per text), by
    /// text hash. The content-addressed tier of the embedding drain: a chunk text seen before is not embedded again.
    public func lookupMany(modelID: String, textHashes: [String]) async -> [String: [Float]] {
        let unique = Array(Set(textHashes))
        guard !unique.isEmpty else { return [:] }
        var out: [String: [Float]] = [:]
        do {
            for start in stride(from: 0, to: unique.count, by: 400) {
                let part = Array(unique[start..<min(unique.count, start + 400)])
                let json = String(data: try JSONSerialization.data(withJSONObject: part), encoding: .utf8) ?? "[]"
                for row in try await database.query("""
                    SELECT text_hash, dimension, vector FROM embedding_cache
                    WHERE model_id = ? AND text_hash IN (SELECT value FROM json_each(?));
                    """, [.text(modelID), .text(json)]) {
                    guard let h = row.string(0), let dim = row.int(1), let data = row.blob(2) else { continue }
                    let v = Self.floats(from: data, dimension: Int(dim))
                    if !v.isEmpty { out[h] = v }
                }
            }
        } catch {
            KalsmritikoshLog.storage.error("embedding cache not read (texts are embedded): \(String(describing: error), privacy: .public)")
            return [:]
        }
        return out
    }

    /// Speed PERF-34 torrent (owner 2026-11-23) — not tested yet. The hashes a chunk's vector may be kept under (its text,
    /// and its text with the context prefix the drain embeds) — what an erasure of the chunk's document removes.
    public nonisolated static func hashes(chunkText: String, contextPrefix: String?) -> [String] {
        var out = [hash(chunkText)]
        if let p = contextPrefix, !p.isEmpty { out.append(hash("\(p)\n---\n\(chunkText)")) }
        return out
    }

    public func store(modelID: String, textHash: String, vector: [Float], at when: Date = Date()) async {
        guard !vector.isEmpty else { return }
        let data = Self.data(from: vector)
        try? await database.exec("""
        INSERT INTO embedding_cache (model_id, text_hash, dimension, vector, created_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(model_id, text_hash) DO UPDATE SET
            dimension = excluded.dimension,
            vector = excluded.vector,
            created_at = excluded.created_at;
        """, [
            .text(modelID),
            .text(textHash),
            .integer(Int64(vector.count)),
            .blob(data),
            .real(when.timeIntervalSince1970)
        ])
    }

    public func count() async -> Int {
        let rows = (try? await database.query("SELECT COUNT(*) FROM embedding_cache;", [])) ?? []
        return Int(rows.first?.int(0) ?? 0)
    }

    /// Clear the whole cache (it rebuilds on demand).
    public func clear() async {
        try? await database.exec("DELETE FROM embedding_cache;", [])
    }

    // MARK: - Float32 BLOB (de)serialization

    private nonisolated static func data(from vector: [Float]) -> Data {
        vector.withUnsafeBytes { Data($0) }
    }

    private nonisolated static func floats(from data: Data, dimension: Int) -> [Float] {
        let count = min(dimension, data.count / MemoryLayout<Float>.size)
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self).prefix(count))
        }
    }
}
