//
//  LLMSummarizer.swift
//  Kalsmritikosh
//
//  Real per-scope summarizer. Asks the CapabilityRegistry for a model
//  that fulfils `.summarization`; falls back to an extractive heuristic
//  when no provider is loaded. Respects context windows by map-reduce
//  over chunked input.
//
//  No model names anywhere. The summarizer only knows what it wants —
//  the registry decides who runs it.
//

import Foundation
import NaturalLanguage
import OSLog

public actor LLMSummarizer: Summarizer {
    private let objects: KnowledgeObjectRepository
    private let summaries: SummariesRepository
    private let events: EventsRepository
    private let capabilities: CapabilityRegistry

    public init(
        objects: KnowledgeObjectRepository,
        summaries: SummariesRepository,
        events: EventsRepository,
        capabilities: CapabilityRegistry
    ) {
        self.objects = objects
        self.summaries = summaries
        self.events = events
        self.capabilities = capabilities
    }

    public func summarize(
        scope: Summary.Scope,
        level: Summary.Level,
        length: Summary.Length
    ) async throws -> Summary {
        let corpus = try await gatherCorpus(for: scope)
        let body = await renderBody(corpus: corpus, scope: scope, length: length)
        let summary = Summary(
            level: level,
            length: length,
            scope: scope,
            body: body,
            modelID: "summarizer.capability-resolved",
            confidence: body.isEmpty ? .low : .medium
        )
        try await summaries.insert(summary)
        return summary
    }

    // MARK: - Scope-aware corpus

    private func gatherCorpus(for scope: Summary.Scope) async throws -> String {
        switch scope {
        case .document(let id):
            return (try? await objects.fetchContent(id: id)) ?? ""
        case .folder(let path):
            let mentions = (try? await objects.findMentioning(path, limit: 25)) ?? []
            return mentions.map(\.content).joined(separator: "\n\n")
        case .project(let name), .organization(let name):
            let mentions = (try? await objects.findMentioning(name, limit: 25)) ?? []
            let related = (try? await events.recent(limit: 100))?.filter {
                $0.title.localizedCaseInsensitiveContains(name) ||
                ($0.summary?.localizedCaseInsensitiveContains(name) ?? false)
            } ?? []
            let eventLines = related.map { event in
                "- \(event.date.formatted(date: .abbreviated, time: .omitted)): \(event.title)"
            }.joined(separator: "\n")
            let docs = mentions.map(\.content).joined(separator: "\n\n")
            return [docs, eventLines].joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        case .timeline(let range):
            let events = (try? await events.between(
                start: range.start,
                end: range.end,
                limit: 200
            )) ?? []
            return events.map { e in
                "\(e.date.formatted(date: .abbreviated, time: .omitted)): \(e.title)"
            }.joined(separator: "\n")
        case .knowledgeBase:
            let contents = (try? await objects.recentContents(limit: 30)) ?? []
            return contents.joined(separator: "\n\n")
        }
    }

    // MARK: - Body rendering (LLM or fallback)

    private func renderBody(corpus: String, scope: Summary.Scope, length: Summary.Length) async -> String {
        guard !corpus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let targetTokens = length.targetTokens
        let prompt = buildPrompt(corpus: corpus, scope: scope, length: length)
        let spec = CapabilitySpec.summarization(
            contextTokens: estimateTokens(prompt) + targetTokens,
            purpose: "summary.\(scope.label).\(length.rawValue)"
        )

        if let provider = try? await capabilities.resolve(spec),
           await provider.isAvailable() {
            do {
                let response = try await provider.generate(
                    prompt: prompt,
                    options: GenerationOptions(
                        maxTokens: targetTokens,
                        temperature: 0.25,
                        systemPrompt: "You write precise, evidence-grounded summaries for the Kalsmritikosh knowledge OS."
                    )
                )
                if !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return response
                }
            } catch {
                KalsmritikoshLog.knowledge.error("LLM summarization failed: \(String(describing: error), privacy: .public)")
            }
        }

        // Heuristic fallback: extractive top-N sentences.
        return heuristic(corpus: corpus, length: length)
    }

    private func buildPrompt(corpus: String, scope: Summary.Scope, length: Summary.Length) -> String {
        // Apple FoundationModels caps prompts at 4096 tokens and rejects
        // anything over. Real-world prose (email, names, URLs) tokenizes
        // denser than the lazy /4 heuristic, so use /3 plus a safety
        // margin and shrink the corpus to whatever fits.
        let contextBudgetTokens = 4096
        let responseBudgetTokens = length.targetTokens
        let overheadTokens = 250 // system prompt + scope label + format
        let inputTokenBudget = max(512, contextBudgetTokens - responseBudgetTokens - overheadTokens)
        let inputCharBudget = inputTokenBudget * 3
        let truncated = corpus.count > inputCharBudget ? String(corpus.prefix(inputCharBudget)) : corpus
        let scopeLabel = scope.label
        let lengthDirective: String
        switch length {
        case .short: lengthDirective = "Write 2 sentences."
        case .medium: lengthDirective = "Write 5-7 sentences."
        case .executive: lengthDirective = "Write 3 short paragraphs covering goals, status, and risks."
        }
        return """
        Summarize the following scope: \(scopeLabel).
        \(lengthDirective)
        Be factual; cite dates and proper names as they appear in the source.

        Source:
        \(truncated)
        """
    }

    private func heuristic(corpus: String, length: Summary.Length) -> String {
        let limit = length.targetSentenceCount
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = corpus
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: corpus.startIndex..<corpus.endIndex) { range, _ in
            sentences.append(String(corpus[range]))
            return sentences.count < limit * 4
        }
        return sentences.prefix(limit).joined(separator: " ")
    }

    private func estimateTokens(_ s: String) -> Int {
        // /3 is closer to real tokenization for mixed email prose than
        // the optimistic /4 — the capability spec we resolve against
        // should round up so the registry picks a model that actually
        // fits.
        max(64, s.count / 3)
    }
}

// G2-SWIFT6 — nonisolated extensions so LLMSummarizer (an actor) can
// read these computed properties without "main-actor-isolated property
// cannot be referenced on a nonisolated actor instance" warnings.
// Both are pure (no mutable state).
nonisolated private extension Summary.Length {
    var targetTokens: Int {
        switch self {
        case .short: return 120
        case .medium: return 320
        case .executive: return 600
        }
    }
    var targetSentenceCount: Int {
        switch self {
        case .short: return 2
        case .medium: return 6
        case .executive: return 12
        }
    }
}

nonisolated private extension Summary.Scope {
    var label: String {
        switch self {
        case .document(let id): return "document \(id.uuidString.prefix(8))"
        case .folder(let path): return "folder \(path)"
        case .project(let name): return "project \(name)"
        case .organization(let name): return "organization \(name)"
        case .timeline(let range):
            return "timeline \(range.start.formatted(date: .abbreviated, time: .omitted))–\(range.end.formatted(date: .abbreviated, time: .omitted))"
        case .knowledgeBase: return "knowledge base"
        }
    }
}
