//
//  RetrievalSelfEval.swift
//  Kalsmritikosh
//
//  Label-free retrieval quality on the user's OWN data: for a sample of stored
//  chunks, query the vector index with text drawn from each chunk and measure
//  how often the index returns that chunk near the top (recall@k). It answers
//  "can the system find what it indexed?" without any human ground truth.
//
//  HONEST SCOPE: this is a RETRIEVAL self-check, NOT the human-labelled
//  answer-accuracy benchmark (P6.1). It's a real, complementary IR signal —
//  a low recall@k here means embeddings/index are weak; a high one is necessary
//  but not sufficient for good answers.
//

import Foundation

public struct RetrievalSelfEvalReport: Sendable {
    public let sampled: Int          // chunks drawn
    public let evaluated: Int        // chunks whose query produced an embedding
    public let recallAt1: Double
    public let recallAt5: Double
    public let recallAt10: Double
    public let embedderDimension: Int

    public var summary: String {
        guard evaluated > 0 else { return "No embeddable chunks to evaluate." }
        func pct(_ d: Double) -> String { String(format: "%.0f%%", d * 100) }
        return "recall@1 \(pct(recallAt1)) · @5 \(pct(recallAt5)) · @10 \(pct(recallAt10)) over \(evaluated) chunk(s), dim \(embedderDimension)"
    }
}

public enum RetrievalSelfEval {

    /// Fraction of targets whose 1-based rank is ≤ k. `ranks[i]` is nil when the
    /// target chunk wasn't in the returned results at all. Pure — unit-tested.
    public static func recall(ranks: [Int?], k: Int) -> Double {
        let evaluated = ranks.count
        guard evaluated > 0 else { return 0 }
        let hits = ranks.filter { $0 != nil && $0! <= k }.count
        return Double(hits) / Double(evaluated)
    }

    /// A fair query drawn from a chunk: the leading slice (first ~120 chars, cut
    /// at a word boundary) — enough signal to retrieve, not the whole passage.
    public static func query(from text: String, maxChars: Int = 120) -> String {
        let clean = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > maxChars else { return clean }
        let cut = clean.index(clean.startIndex, offsetBy: maxChars)
        let slice = clean[..<cut]
        if let lastSpace = slice.lastIndex(of: " ") {
            return String(slice[..<lastSpace])
        }
        return String(slice)
    }

    /// Run the self-eval: sample chunks, query with each chunk's leading text,
    /// and see where its own id lands in the vector results.
    public static func run(
        chunks: ChunksRepository,
        embedder: any Embedder,
        vectors: any VectorStore,
        sampleSize: Int = 200,
        maxK: Int = 10,
        progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil
    ) async -> RetrievalSelfEvalReport {
        let sample = (try? await chunks.sample(limit: sampleSize)) ?? []
        progress?(0, sample.count)
        var ranks: [Int?] = []
        for (i, chunk) in sample.enumerated() {
            let q = query(from: chunk.text)
            guard q.count >= 8 else { progress?(i + 1, sample.count); continue }
            let vector = await embedder.embed(q)
            guard !vector.isEmpty else { progress?(i + 1, sample.count); continue }
            let hits = (try? await vectors.nearest(to: vector, limit: maxK)) ?? []
            if let idx = hits.firstIndex(where: { $0.chunkID == chunk.id }) {
                ranks.append(idx + 1)   // 1-based rank
            } else {
                ranks.append(nil)       // not retrieved
            }
            progress?(i + 1, sample.count)
        }
        return RetrievalSelfEvalReport(
            sampled: sample.count,
            evaluated: ranks.count,
            recallAt1: recall(ranks: ranks, k: 1),
            recallAt5: recall(ranks: ranks, k: 5),
            recallAt10: recall(ranks: ranks, k: 10),
            embedderDimension: embedder.dimension
        )
    }
}
