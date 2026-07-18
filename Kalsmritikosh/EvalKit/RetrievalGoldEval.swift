//
//  RetrievalGoldEval.swift
//  Kalsmritikosh
//
//  A labeled RETRIEVAL-recall eval over the 60-question gold set: for each
//  question it runs the HybridRetriever and asks "did the expected source
//  file(s) surface in the retrieved chunk set?" — recall by class. Unlike the
//  full EvalKitRunner it does NOT invoke the LLM answer path, so it runs in
//  seconds and is a fast, deterministic regression guard for retrieval-order /
//  fusion / index changes (it caught the confined-vector + stale-ANN bugs that
//  pinned lookup recall at 0.07).
//
//  Complements RetrievalSelfEval (label-free "can the index find what it
//  stored") and GoldEvalGate (answer-level, LLM). This one measures the middle
//  layer: does retrieval put the right evidence in front of the experts.
//

import Foundation

public struct RetrievalGoldEval: Sendable {

    public struct ClassRecall: Sendable {
        public let className: String
        public let recall: Double      // mean per-question source-file recall
        public let count: Int
    }

    public struct Report: Sendable {
        public let byClass: [ClassRecall]
        public let overall: Double
        public let total: Int

        public func renderLine() -> String {
            let parts = byClass.map { String(format: "%@ %.3f", $0.className, $0.recall) }
            return "retrieval recall — overall \(String(format: "%.3f", overall)) (n=\(total)); " + parts.joined(separator: ", ")
        }
    }

    public init() {}

    /// Score retrieval recall for every gold question. `intentKind` is held
    /// constant so pre/post comparisons are controlled.
    public func run(
        retriever: HybridRetriever,
        objects: KnowledgeObjectRepository,
        questions: [EvalKitRunner.Question],
        scope: UserIntent.Scope = .project("Project Delta")
    ) async -> Report {
        var sums: [String: (hit: Double, n: Int)] = [:]
        for q in questions {
            let intent = UserIntent(
                kind: .factualLookup, scope: scope, timeframe: nil,
                entityHints: [], rawQuestion: q.text
            )
            let ids: Set<KnowledgeObject.ID>
            if let res = try? await retriever.retrieve(for: intent, layers: []) {
                ids = Set(res.chunks.map(\.chunk.objectID))
            } else {
                ids = []
            }
            let names = Set(((try? await objects.sourceFilenames(for: ids)) ?? [:]).values)
            let expected = Set(q.expectedSourceFiles)
            let recall = expected.isEmpty ? 0 : Double(names.intersection(expected).count) / Double(expected.count)
            sums[q.class, default: (0, 0)].hit += recall
            sums[q.class, default: (0, 0)].n += 1
        }
        let order = ["lookup", "aggregation", "temporal", "multihop"]
        var byClass: [ClassRecall] = []
        for c in order where sums[c] != nil {
            let v = sums[c]!
            byClass.append(ClassRecall(className: c, recall: v.n == 0 ? 0 : v.hit / Double(v.n), count: v.n))
        }
        for (c, v) in sums where !order.contains(c) {
            byClass.append(ClassRecall(className: c, recall: v.n == 0 ? 0 : v.hit / Double(v.n), count: v.n))
        }
        let totalHit = sums.values.reduce(0.0) { $0 + $1.hit }
        let totalN = sums.values.reduce(0) { $0 + $1.n }
        return Report(byClass: byClass, overall: totalN == 0 ? 0 : totalHit / Double(totalN), total: totalN)
    }
}
