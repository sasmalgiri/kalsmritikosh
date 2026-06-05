//
//  Summarizer.swift
//  Atlas chronica memora
//
//  Hierarchical summarization. M2 ships a heuristic extractive summarizer
//  (top-N sentences by token frequency) that lets the rest of the pipeline
//  develop. M3 swaps in an LLM summarizer via ModelRegistry.
//

import Foundation
import NaturalLanguage

public actor HeuristicSummarizer: Summarizer {
    private let objectsRepo: KnowledgeObjectRepository
    private let summariesRepo: SummariesRepository

    public init(
        objectsRepo: KnowledgeObjectRepository,
        summariesRepo: SummariesRepository
    ) {
        self.objectsRepo = objectsRepo
        self.summariesRepo = summariesRepo
    }

    public func summarize(
        scope: Summary.Scope,
        level: Summary.Level,
        length: Summary.Length
    ) async throws -> Summary {
        let body = try await materialize(scope: scope, length: length)
        let summary = Summary(
            level: level,
            length: length,
            scope: scope,
            body: body,
            modelID: "heuristic.extractive.v1",
            confidence: .low
        )
        try await summariesRepo.insert(summary)
        return summary
    }

    private func materialize(scope: Summary.Scope, length: Summary.Length) async throws -> String {
        let raw = try await fetchScopeText(scope)
        return condense(raw, length: length)
    }

    private func fetchScopeText(_ scope: Summary.Scope) async throws -> String {
        switch scope {
        case .document, .folder, .project, .organization, .timeline, .knowledgeBase:
            // Until per-scope queries land, summarize recently ingested
            // KnowledgeObject content as a placeholder corpus.
            let rows = try await objectsRepo.recent(limit: 30)
            return rows.map(\.preview).joined(separator: "\n\n")
        }
    }

    private func condense(_ text: String, length: Summary.Length) -> String {
        let limit: Int
        switch length {
        case .short: limit = 2
        case .medium: limit = 5
        case .executive: limit = 8
        }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            sentences.append(String(text[range]))
            return sentences.count < limit * 4
        }
        return sentences.prefix(limit).joined(separator: " ")
    }
}
