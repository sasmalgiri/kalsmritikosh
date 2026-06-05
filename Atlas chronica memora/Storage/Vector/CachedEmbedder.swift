//
//  CachedEmbedder.swift
//  Atlas chronica memora
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
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let cached = await cache.value(for: key) { return cached }
        let vector = await underlying.embed(text)
        await cache.set(key, vector)
        return vector
    }
}
