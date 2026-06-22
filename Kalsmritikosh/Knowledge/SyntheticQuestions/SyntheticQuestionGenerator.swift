//
//  SyntheticQuestionGenerator.swift
//  Kalsmritikosh
//
//  G2-SYNTHETIC-QUESTIONS — hypothetical questions per chunk.
//
//  Per UPDATE_18 §3 (chatmind-pipeline's biggest validated lift): at
//  ingest time, for each chunk, generate top-k hypothetical questions
//  the chunk *answers*. Store them; embed them; at query time, the
//  user's question vector matches **question-shaped projections** of
//  the corpus, not just statement-shaped chunk text. Question-to-
//  question similarity outperforms question-to-statement on retrieval
//  benchmarks because it sidesteps the question/answer surface gap.
//
//  This file ships the protocol + a heuristic (no-LLM) generator + a
//  capability-routed LLM generator that resolves through the existing
//  `.extraction` spec — no model names in this file.
//
//  Storage + retrieval wiring are deferred: the chunks table needs a
//  `synthetic_questions` column (or a sidecar table), and the vector
//  store needs to embed these alongside chunk text. That's a separate
//  follow-on with a schema migration; this scaffolding can land safely
//  ahead of it.
//

import Foundation
import NaturalLanguage

/// A single generated question with a confidence score in [0, 1].
public struct SyntheticQuestion: Sendable, Codable, Hashable {
    public let text: String
    public let confidence: Double
    public init(text: String, confidence: Double) {
        self.text = text
        self.confidence = max(0, min(1, confidence))
    }
}

/// Produces hypothetical questions a chunk can answer. Implementations
/// are expected to be CHEAP (single ingest pass adds ~30% overhead in
/// chatmind's numbers; we should match or beat that).
public protocol SyntheticQuestionGenerator: Sendable {
    /// Stable id surfaced in logs.
    var id: String { get }

    /// Generate up to `topK` questions for the chunk. May return fewer
    /// if the chunk is too small or doesn't contain question-worthy
    /// content (e.g. raw boilerplate).
    func generate(
        for chunk: Chunk,
        documentContext: String,
        topK: Int
    ) async -> [SyntheticQuestion]
}

/// Free deterministic fallback — uses NLTagger to lift named entities
/// + nouns and forms basic "What/When/Who about X" questions. Produces
/// low-confidence (0.4-0.5) questions; useful as a base layer when the
/// LLM-backed generator isn't available, and as a sanity prior the
/// stronger generator's output can be checked against.
public struct HeuristicSyntheticQuestionGenerator: SyntheticQuestionGenerator {
    public let id = "synthq.heuristic"
    public init() {}

    public func generate(
        for chunk: Chunk,
        documentContext: String,
        topK: Int
    ) async -> [SyntheticQuestion] {
        let text = chunk.text
        guard text.count >= 40 else { return [] }

        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var entities: Set<String> = []
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, range in
            guard let tag,
                  tag == .personalName || tag == .organizationName || tag == .placeName
            else { return true }
            let value = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2 { entities.insert(value) }
            return true
        }

        var out: [SyntheticQuestion] = []
        // Whatever entities we found, ask Who/What about them.
        for name in entities.prefix(topK / 2 + 1) {
            out.append(.init(text: "What is \(name) about?", confidence: 0.4))
            if out.count >= topK { break }
            out.append(.init(text: "When was \(name) mentioned?", confidence: 0.4))
            if out.count >= topK { break }
        }
        // Fall back to a generic question if the chunk has no entities
        // — the chunk's first sentence still earns a "what does this
        // describe" question.
        if out.isEmpty,
           let firstSentence = text.split(separator: ".").first,
           firstSentence.count > 10 {
            out.append(.init(
                text: "What does the document say about \(firstSentence.prefix(60))?",
                confidence: 0.3
            ))
        }
        return Array(out.prefix(topK))
    }
}

/// LLM-backed generator routed through the EXTRACTION capability spec.
/// CLAUDE.md / capability discipline: no model name appears in this
/// file — the registry picks the provider. Apple Foundation Models on
/// macOS 26+, Ollama (llama3 / mistral / etc.) on older OS.
///
/// Falls back to the heuristic generator on provider failure so a
/// flaky reasoning provider never blocks ingest.
public struct CapabilitySyntheticQuestionGenerator: SyntheticQuestionGenerator {
    public let id = "synthq.capability"
    private let capabilities: CapabilityRegistry
    private let fallback: HeuristicSyntheticQuestionGenerator

    public init(capabilities: CapabilityRegistry) {
        self.capabilities = capabilities
        self.fallback = HeuristicSyntheticQuestionGenerator()
    }

    public func generate(
        for chunk: Chunk,
        documentContext: String,
        topK: Int
    ) async -> [SyntheticQuestion] {
        // Synthetic-question generation is summarization-shaped (read
        // chunk, emit short structured-output questions) — route through
        // the .summarization spec rather than .reasoning. Either would
        // resolve, but summarization is the closer semantic fit.
        let spec = CapabilitySpec.summarization(contextTokens: 2_000, purpose: "knowledge.synthq")
        guard let provider = try? await capabilities.resolve(spec),
              await provider.isAvailable() else {
            return await fallback.generate(for: chunk, documentContext: documentContext, topK: topK)
        }
        let prompt = """
        Below is a chunk of a document. Generate up to \(topK) short
        natural-language questions that this chunk DIRECTLY answers.
        Reply with one JSON array of question strings, nothing else.

        Document context: \(documentContext.prefix(200))
        Chunk:
        \(chunk.text.prefix(1200))

        Questions (JSON array):
        """
        let options = GenerationOptions(
            maxTokens: 220,
            temperature: 0.3,
            systemPrompt: "You generate short, specific questions a passage answers. Reply with a JSON array of strings only."
        )
        do {
            let response = try await provider.generate(prompt: prompt, options: options)
            let parsed = parseQuestions(from: response, cap: topK)
            return parsed.isEmpty
                ? await fallback.generate(for: chunk, documentContext: documentContext, topK: topK)
                : parsed
        } catch {
            return await fallback.generate(for: chunk, documentContext: documentContext, topK: topK)
        }
    }

    /// Pulls the first JSON array of strings out of the model's reply.
    /// Tolerates code fences, prose preambles, and trailing commentary.
    private func parseQuestions(from response: String, cap: Int) -> [SyntheticQuestion] {
        guard let start = response.firstIndex(of: "[") else { return [] }
        var depth = 0
        var end = start
        var cursor = start
        while cursor < response.endIndex {
            let ch = response[cursor]
            if ch == "[" { depth += 1 }
            else if ch == "]" {
                depth -= 1
                if depth == 0 { end = cursor; break }
            }
            cursor = response.index(after: cursor)
        }
        guard depth == 0, end > start else { return [] }
        let arrayText = String(response[start...end])
        guard let data = arrayText.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return [] }
        let questions = parsed.compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 5 && $0.count <= 200 }
            .prefix(cap)
        return questions.map { SyntheticQuestion(text: $0, confidence: 0.7) }
    }
}
