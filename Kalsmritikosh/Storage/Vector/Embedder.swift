//
//  Embedder.swift
//  Kalsmritikosh
//
//  Embedding provider protocol + NLEmbedding baseline. The MLX-backed
//  sentence encoder swaps in at M3 via the ModelRegistry. Falls back
//  to an all-zeros vector when no embedding is available so the
//  rest of the retrieval pipeline still functions.
//

import Foundation
import NaturalLanguage

public protocol Embedder: Sendable {
    var dimension: Int { get }
    func embed(_ text: String) async -> [Float]
    /// Batch variant. Default impl loops over `embed`; providers that
    /// support a real batch endpoint (Ollama, etc.) override.
    func embedBatch(_ texts: [String]) async -> [[Float]]
}

extension Embedder {
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
            return Array(repeating: 0, count: dimension)
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
        if count > 0 {
            for i in 0..<accumulator.count { accumulator[i] /= Double(count) }
        }
        return accumulator.map { Float($0) }
    }
}
