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
}

public struct NLEmbedder: Embedder {
    public let dimension: Int
    private let language: NLLanguage

    public init(language: NLLanguage = .english) {
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
