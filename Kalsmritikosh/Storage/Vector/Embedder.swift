//
//  Embedder.swift
//  Kalsmritikosh
//
//  Embedding provider protocol + NLEmbedding baseline. The MLX-backed
//  sentence encoder swaps in at M3 via the ModelRegistry.
//
//  CONTRACT (T15): an EMPTY array is the "no embedding produced" sentinel.
//  Embedders MUST NEVER return a zero vector as a stand-in — a zero vector
//  makes every chunk equidistant under cosine similarity, silently turning
//  vector search into noise. That violates the project's core directive
//  ("no silent fallbacks — quality or nothing"). Callers MUST skip empty
//  results: never persist them (SQLiteVectorStore.upsert already guards),
//  and treat an empty QUERY embedding as "vector layer unavailable" so the
//  structured layers answer instead.
//

import Foundation
import NaturalLanguage
import OSLog
import os

/// Fix PERF-28 (owner 2026-11-23): the embedder that ACTUALLY produced a vector — the label it is stored under
/// (`chunk_embeddings.model_id`) and its dimension. Two embedders are never mixed under one label: a store refuses a vector
/// whose producer or size is not its own, and the cache keys every vector by its producer.
public nonisolated struct EmbeddingProducer: Sendable, Hashable {
    public let id: String
    public let dimension: Int
    public init(id: String, dimension: Int) { self.id = id; self.dimension = dimension }
    /// The key a cached vector is kept under (id + size, so a same-named embedder of another size is a miss).
    public var cacheKey: String { "\(id)#\(dimension)" }
}

/// Vectors in input order, each with the producer that made it (nil = not labelled by this embedder: the store's own
/// label applies, after its size check). `transientFailure` = the primary embedder failed after its retries and nothing
/// was produced: the caller retries later (the chunks stay pending), it is NOT "unembeddable".
public nonisolated struct LabelledEmbeddings: Sendable {
    public var vectors: [[Float]]
    public var producers: [EmbeddingProducer?]
    public var transientFailure: Bool
    public init(vectors: [[Float]], producers: [EmbeddingProducer?], transientFailure: Bool = false) {
        self.vectors = vectors; self.producers = producers; self.transientFailure = transientFailure
    }
    public static func unlabelled(_ vectors: [[Float]]) -> LabelledEmbeddings {
        LabelledEmbeddings(vectors: vectors, producers: vectors.map { _ in nil })
    }
}

public protocol Embedder: Sendable {
    var dimension: Int { get }
    /// Returns the embedding, or an EMPTY array when no embedding could be
    /// produced (no model, or no in-vocabulary tokens). Never returns zeros.
    func embed(_ text: String) async -> [Float]
    /// Batch variant. Default impl loops over `embed`; providers that
    /// support a real batch endpoint (Ollama, etc.) override.
    func embedBatch(_ texts: [String]) async -> [[Float]]
    /// Fix PERF-28 (owner 2026-11-23): the producer a vector made NOW would carry (nil = unlabelled embedder).
    var expectedProducer: EmbeddingProducer? { get async }
    /// Fix PERF-28 (owner 2026-11-23): the batch with each vector's real producer.
    func embedBatchLabelled(_ texts: [String]) async -> LabelledEmbeddings
}

extension Embedder {
    public var expectedProducer: EmbeddingProducer? { get async { nil } }

    public func embedBatchLabelled(_ texts: [String]) async -> LabelledEmbeddings {
        .unlabelled(await embedBatch(texts))
    }

    /// `embedAll` with labels: batches of `batchSize`, concatenated in input order.
    public func embedAllLabelled(_ texts: [String], batchSize: Int = 64) async -> LabelledEmbeddings {
        guard !texts.isEmpty, batchSize > 0 else { return .unlabelled([]) }
        var out = LabelledEmbeddings(vectors: [], producers: [])
        var i = 0
        while i < texts.count {
            let end = Swift.min(i + batchSize, texts.count)
            let r = await embedBatchLabelled(Array(texts[i..<end]))
            out.vectors.append(contentsOf: r.vectors)
            out.producers.append(contentsOf: r.producers)
            // Pad a short answer so positions stay aligned (a missing vector is empty = not produced).
            let short = (end - i) - r.vectors.count
            if short > 0 { out.vectors += Array(repeating: [], count: short); out.producers += Array(repeating: nil, count: short) }
            out.transientFailure = out.transientFailure || r.transientFailure
            i = end
        }
        return out
    }

    public func embedBatch(_ texts: [String]) async -> [[Float]] {
        var out: [[Float]] = []
        out.reserveCapacity(texts.count)
        for t in texts { out.append(await embed(t)) }
        return out
    }

    /// Convenience: chunk `texts` into `batchSize` slices and call
    /// `embedBatch` once per slice. Used by ingest to avoid per-chunk
    /// round trips. Returns vectors in input order.
    public func embedAll(_ texts: [String], batchSize: Int = 64) async -> [[Float]] {
        guard !texts.isEmpty, batchSize > 0 else { return [] }
        var out: [[Float]] = []
        out.reserveCapacity(texts.count)
        var i = 0
        while i < texts.count {
            let end = Swift.min(i + batchSize, texts.count)
            let batch = Array(texts[i..<end])
            let result = await embedBatch(batch)
            out.append(contentsOf: result)
            i = end
        }
        return out
    }
}

/// Fix PERF-28 (owner 2026-11-23): the app-wide embedding health the screens read (Live dashboard, data health check).
/// `degraded` = the primary embedder is genuinely unavailable and vectors are being made by the fallback, stored under the
/// fallback's own label (never the primary's); the primary's gap stays queued and is re-embedded once it is back.
/// `retrying` = the primary failed transiently (load); nothing was stored, the work waits and is retried.
public nonisolated enum EmbeddingHealth {
    public enum State: Sendable, Equatable {
        case healthy
        case retrying(primary: String, since: Date, failures: Int)
        case degraded(primary: String, fallback: String, since: Date, reason: String)
    }
    private static let state = OSAllocatedUnfairLock(initialState: (State.healthy, 0))
    public static var current: State { state.withLock { $0.0 } }
    /// Bumped whenever the primary comes back after a degraded spell (the drain retries what it deferred).
    public static var recoveryEpoch: Int { state.withLock { $0.1 } }
    static func set(_ s: State) {
        state.withLock { v in
            if case .degraded = v.0, s == .healthy { v.1 += 1 }
            v.0 = s
        }
    }
    /// The health line shown to the person (nil when healthy).
    public static var line: String? { line(for: current) }
    public static func line(for s: State) -> String? {
        switch s {
        case .healthy: return nil
        case .retrying(_, let since, let failures):
            return "Embeddings waiting: the on-device embedder did not answer (\(failures) failed attempt(s) since \(since.formatted(date: .omitted, time: .shortened))). Nothing was stored with another embedder; the work is retried."
        case .degraded(_, let fallback, let since, let reason):
            return "Embeddings degraded since \(since.formatted(date: .omitted, time: .shortened)): \(reason). New vectors are made by the fallback embedder and kept under its own label (\(fallback)); searches do not mix them with the main index. Every passage is embedded again with the main embedder when it is back."
        }
    }
}

public struct NLEmbedder: Embedder {
    public let dimension: Int
    private let language: NLLanguage

    public nonisolated init(language: NLLanguage = .english) {
        self.language = language
        let model = NLEmbedding.wordEmbedding(for: language)
        self.dimension = model?.dimension ?? 300
    }

    public func embed(_ text: String) async -> [Float] {
        guard let model = NLEmbedding.wordEmbedding(for: language) else {
            // No embedding model on this device. Emit the empty sentinel
            // (NOT zeros) so nothing downstream persists or searches noise.
            KalsmritikoshLog.storage.error("NLEmbedder: no word-embedding model available — returning empty (no embedding produced)")
            return []
        }
        var accumulator = [Double](repeating: 0, count: model.dimension)
        var count = 0
        text.lowercased().enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: .byWords
        ) { word, _, _, _ in
            guard let word else { return }
            if let v = model.vector(for: word) {
                for i in 0..<accumulator.count { accumulator[i] += v[i] }
                count += 1
            }
        }
        // No in-vocabulary tokens → averaging would produce a zero vector.
        // Return the empty sentinel instead of manufacturing noise.
        guard count > 0 else { return [] }
        for i in 0..<accumulator.count { accumulator[i] /= Double(count) }
        return accumulator.map { Float($0) }
    }

    /// Speed PERF-26 (owner 2026-11-23) — not tested yet. A true batch: the word model is looked up ONCE for the whole
    /// batch (was once per text), and each text is averaged exactly as `embed` does (same vectors, same order).
    public func embedBatch(_ texts: [String]) async -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        guard let model = NLEmbedding.wordEmbedding(for: language) else {
            KalsmritikoshLog.storage.error("NLEmbedder: no word-embedding model available — returning empty (no embedding produced)")
            return texts.map { _ in [] }
        }
        return texts.map { Self.average(text: $0, model: model) }
    }

    private static func average(text: String, model: NLEmbedding) -> [Float] {
        var accumulator = [Double](repeating: 0, count: model.dimension)
        var count = 0
        text.lowercased().enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, _, _, _ in
            guard let word, let v = model.vector(for: word) else { return }
            for i in 0..<accumulator.count { accumulator[i] += v[i] }
            count += 1
        }
        guard count > 0 else { return [] }
        for i in 0..<accumulator.count { accumulator[i] /= Double(count) }
        return accumulator.map { Float($0) }
    }
}
