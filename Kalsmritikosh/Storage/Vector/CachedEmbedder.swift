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

    public init(wrapping underlying: any Embedder, cache: EmbeddingCache = EmbeddingCache()) {
        self.underlying = underlying
        self.dimension = underlying.dimension
        self.cache = cache
    }

    public func embed(_ text: String) async -> [Float] {
        let key = cacheKey(text)
        if let cached = await cache.value(for: key) { return cached }
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
        if !missTexts.isEmpty {
            let fresh = await underlying.embedBatch(missTexts)
            for (k, idx) in missIndices.enumerated() {
                guard k < fresh.count else { break }
                results[idx] = fresh[k]
                await cache.set(missKeys[k], fresh[k])
            }
        }
        return results.map { $0 ?? [] }
    }

    private nonisolated func cacheKey(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
