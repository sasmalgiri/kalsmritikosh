//
//  CachedEmbedder.swift
//  Kalsmritikosh
//
//  Wraps any Embedder with the in-memory LRU EmbeddingCache so identical
//  texts (questions, repeated chunk fragments) don't pay the full
//  embedding cost twice in a session.
//

import Foundation

public actor CachedEmbedder: Embedder {
    public let dimension: Int
    private let underlying: any Embedder
    private let cache: EmbeddingCache
    /// Optional persistent L2 (schema v29). When present, embeddings
    /// survive across launches and re-ingests. Model-scoped by
    /// `modelID` so switching embedders never returns a stale vector.
    private let persistent: EmbeddingCacheRepository?
    private let modelID: String

    public init(
        wrapping underlying: any Embedder,
        cache: EmbeddingCache = EmbeddingCache(),
        persistent: EmbeddingCacheRepository? = nil,
        modelID: String? = nil
    ) {
        self.underlying = underlying
        self.dimension = underlying.dimension
        self.cache = cache
        self.persistent = persistent
        // Default model id includes the dimension so a change of encoder
        // (e.g. NL 300-dim → BGE 1024-dim) is automatically a cache miss.
        self.modelID = modelID ?? "embedder-\(underlying.dimension)"
    }

    /// Unit-E purity check (env-gated, inert in production): on every cache
    /// hit, recompute fresh and compare at bitPattern level. The Ask-Scope
    /// Law's clause — purity is bitwise: same key → same BITS, or this is a
    /// value-mutating layer wearing memoization clothing.
    nonisolated private static let purityCheck = ProcessInfo.processInfo.environment["KALSMRITIKOSH_EMBED_PURITY"] == "1"

    private func auditPurity(_ label: String, key: String, cached: [Float], text: String) async {
        guard Self.purityCheck else { return }
        let fresh = await underlying.embed(text)
        let equal = cached.count == fresh.count
            && zip(cached, fresh).allSatisfy { $0.bitPattern == $1.bitPattern }
        print("EMBEDPURITY \(label) key=\(key.prefix(16)) \(equal ? "BITWISE-PURE" : "IMPURE") len=\(text.count)")
    }

    public func embed(_ text: String) async -> [Float] {
        let key = cacheKey(text)
        // L1 — in-memory LRU.
        if let cached = await cache.value(for: key) {
            await LLMCallCounters.shared.recordEmbedCacheHit()
            if Self.purityCheck { print("EMBEDHIT L1 key=\(key.prefix(16))"); await auditPurity("L1", key: key, cached: cached, text: text) }
            return cached
        }
        if Self.purityCheck { print("EMBEDMISS L1 key=\(key.prefix(16)) len=\(text.count)") }
        // L2 — persistent SQLite cache.
        if let persistent {
            let hash = EmbeddingCacheRepository.hash(text)
            if let hit = await persistent.lookup(modelID: modelID, textHash: hash), !hit.isEmpty {
                await LLMCallCounters.shared.recordEmbedCacheHit()
                await cache.set(key, hit)
                if Self.purityCheck { print("EMBEDHIT L2 key=\(key.prefix(16))"); await auditPurity("L2", key: key, cached: hit, text: text) }
                return hit
            }
            await LLMCallCounters.shared.recordEmbedCacheMiss()
            let vector = await underlying.embed(text)
            await cache.set(key, vector)
            await persistent.store(modelID: modelID, textHash: hash, vector: vector)
            return vector
        }
        await LLMCallCounters.shared.recordEmbedCacheMiss()
        let vector = await underlying.embed(text)
        await cache.set(key, vector)
        return vector
    }

    /// Honours the cache per-text and only ships cache-misses through
    /// the underlying batch. Cache hits keep their original index.
    public func embedBatch(_ texts: [String]) async -> [[Float]] {
        var results: [[Float]?] = Array(repeating: nil, count: texts.count)
        var missIndices: [Int] = []
        var missTexts: [String] = []
        var missKeys: [String] = []
        // L1 pass.
        for (i, text) in texts.enumerated() {
            let key = cacheKey(text)
            if let hit = await cache.value(for: key) {
                results[i] = hit
            } else {
                missIndices.append(i)
                missTexts.append(text)
                missKeys.append(key)
            }
        }
        // L2 pass over the L1-misses — pull persisted vectors before
        // paying the underlying embedder for them.
        if let persistent, !missIndices.isEmpty {
            var stillMissIdx: [Int] = []
            var stillMissText: [String] = []
            var stillMissKey: [String] = []
            for (k, idx) in missIndices.enumerated() {
                let hash = EmbeddingCacheRepository.hash(missTexts[k])
                if let hit = await persistent.lookup(modelID: modelID, textHash: hash), !hit.isEmpty {
                    results[idx] = hit
                    await cache.set(missKeys[k], hit)
                } else {
                    stillMissIdx.append(idx)
                    stillMissText.append(missTexts[k])
                    stillMissKey.append(missKeys[k])
                }
            }
            missIndices = stillMissIdx
            missTexts = stillMissText
            missKeys = stillMissKey
        }
        if !missTexts.isEmpty {
            let fresh = await underlying.embedBatch(missTexts)
            for (k, idx) in missIndices.enumerated() {
                guard k < fresh.count else { break }
                results[idx] = fresh[k]
                await cache.set(missKeys[k], fresh[k])
                if let persistent {
                    let hash = EmbeddingCacheRepository.hash(missTexts[k])
                    await persistent.store(modelID: modelID, textHash: hash, vector: fresh[k])
                }
            }
        }
        return results.map { $0 ?? [] }
    }

    private nonisolated func cacheKey(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
