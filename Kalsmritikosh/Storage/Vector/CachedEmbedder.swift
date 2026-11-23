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

    /// Fix PERF-28 (owner 2026-11-23): the producer the underlying embedder would label a vector with now.
    public var expectedProducer: EmbeddingProducer? {
        get async { await underlying.expectedProducer }
    }

    /// The persistent-cache model key for a producer (nil = the legacy key this cache was made with).
    private func storeKey(_ producer: EmbeddingProducer?) -> String { producer?.cacheKey ?? modelID }

    public func embed(_ text: String) async -> [Float] {
        await embedBatchLabelled([text]).vectors.first ?? []
    }

    public func embedBatch(_ texts: [String]) async -> [[Float]] {
        await embedBatchLabelled(texts).vectors
    }

    /// Honours the cache per-text and only ships cache-misses through
    /// the underlying batch. Cache hits keep their original index.
    /// Fix PERF-28 (owner 2026-11-23): both tiers are keyed by the producer the underlying embedder would use NOW (its
    /// label + size), and a fresh vector is kept under the producer that actually made it — so a fallback vector is never
    /// served for the primary (the old key was "embedder-<fallback size>" for every embedder).
    public func embedBatchLabelled(_ texts: [String]) async -> LabelledEmbeddings {
        guard !texts.isEmpty else { return .unlabelled([]) }
        let expected = await underlying.expectedProducer
        let lookupKey = storeKey(expected)
        var results: [[Float]?] = Array(repeating: nil, count: texts.count)
        var producers: [EmbeddingProducer?] = Array(repeating: nil, count: texts.count)
        var missIndices: [Int] = []
        var missTexts: [String] = []
        // L1 pass.
        for (i, text) in texts.enumerated() {
            if let hit = await cache.value(for: memoryKey(lookupKey, text)), !hit.isEmpty,
               expected.map({ $0.dimension == hit.count }) ?? true {
                results[i] = hit
                producers[i] = expected
                await LLMCallCounters.shared.recordEmbedCacheHit()
                if Self.purityCheck { await auditPurity("L1", key: lookupKey, cached: hit, text: text) }
            } else {
                missIndices.append(i)
                missTexts.append(text)
            }
        }
        // L2 pass over the L1-misses — pull persisted vectors before
        // paying the underlying embedder for them.
        if let persistent, !missIndices.isEmpty {
            var stillMissIdx: [Int] = []
            var stillMissText: [String] = []
            // Speed PERF-34 torrent (owner 2026-11-23) — not tested yet: the whole batch's hashes in one query.
            let hashes = missTexts.map(EmbeddingCacheRepository.hash)
            let kept = await persistent.lookupMany(modelID: lookupKey, textHashes: hashes)
            for (k, idx) in missIndices.enumerated() {
                if let hit = kept[hashes[k]], !hit.isEmpty, expected.map({ $0.dimension == hit.count }) ?? true {
                    results[idx] = hit
                    producers[idx] = expected
                    await cache.set(memoryKey(lookupKey, missTexts[k]), hit)
                    await LLMCallCounters.shared.recordEmbedCacheHit()
                    if Self.purityCheck { await auditPurity("L2", key: lookupKey, cached: hit, text: missTexts[k]) }
                } else {
                    stillMissIdx.append(idx)
                    stillMissText.append(missTexts[k])
                }
            }
            missIndices = stillMissIdx
            missTexts = stillMissText
        }
        var transient = false
        if !missTexts.isEmpty {
            for _ in missTexts { await LLMCallCounters.shared.recordEmbedCacheMiss() }
            let fresh = await underlying.embedBatchLabelled(missTexts)
            transient = fresh.transientFailure
            for (k, idx) in missIndices.enumerated() {
                guard k < fresh.vectors.count else { break }
                let v = fresh.vectors[k]
                let p = k < fresh.producers.count ? fresh.producers[k] : nil
                results[idx] = v
                producers[idx] = p
                guard !v.isEmpty else { continue }   // nothing produced: nothing kept (retried next time)
                let key = storeKey(p)
                await cache.set(memoryKey(key, missTexts[k]), v)
                if let persistent {
                    await persistent.store(modelID: key, textHash: EmbeddingCacheRepository.hash(missTexts[k]), vector: v)
                }
            }
        }
        return LabelledEmbeddings(vectors: results.map { $0 ?? [] }, producers: producers, transientFailure: transient)
    }

    /// The in-memory key: the producer key + the normalised text (two embedders never share an entry).
    private nonisolated func memoryKey(_ producerKey: String, _ text: String) -> String {
        producerKey + "\u{1F}" + cacheKey(text)
    }

    private nonisolated func cacheKey(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
