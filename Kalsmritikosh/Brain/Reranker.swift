//
//  Reranker.swift
//  Kalsmritikosh
//
//  G2-1 — closes the citation-precision gap at Gate 1 (lookup 0.33 → ≥ 0.6).
//  G2-1.5 — intent-aware scoring: the prompt now carries the intent
//  kind, the question shape (who/what/when/…), key entities pulled
//  from the question, and a snapshot of the session profile (recent
//  turns + recently-mentioned entities). The model first *restates*
//  what the user is asking for in one sentence, then scores each
//  passage against its own restatement. We log the restatement so
//  failures are debuggable instead of opaque.
//
//  Why both restate + score in one prompt: the field's "Lost in
//  Conversation" finding (~30-39% multi-turn quality drop) is driven
//  by early interpretation lock-in. Forcing the model to commit to a
//  meaning *before* it scores anchors the relevance judgment in that
//  meaning — and gives us a logged trace of the intent it used.
//
//  Implementation: prompted scoring via whichever provider resolves
//  `CapabilitySpec.reranking()`. Ollama (`provider.local.network`) is
//  the path on macOS 15.6; FoundationModels can plug in on macOS 26 if
//  it ever declares the capability. When NO provider resolves, the
//  reranker returns a constant 0.5 for every candidate — preserving
//  the existing `scoreByObject` order so behavior matches pre-G2-1
//  (no regression on heuristic-floor runs).
//

import Foundation
import OSLog

public actor Reranker {
    public let id = "brain.reranker"

    /// Optional scoring context — when supplied, the prompt becomes
    /// intent-aware (G2-1.5). When nil, the prompt falls back to the
    /// G2-1 question-only form so callers that don't track session
    /// state still work.
    public struct Context: Sendable {
        public let intentKind: String
        public let questionShape: String
        public let keyEntities: [String]
        /// Most-recent-first. Empty on turn 1.
        public let recentTurns: [String]
        /// Recency-ordered entities accumulated across the session.
        public let mentionedEntities: [String]

        public init(
            intentKind: String,
            questionShape: String,
            keyEntities: [String],
            recentTurns: [String],
            mentionedEntities: [String]
        ) {
            self.intentKind = intentKind
            self.questionShape = questionShape
            self.keyEntities = keyEntities
            self.recentTurns = recentTurns
            self.mentionedEntities = mentionedEntities
        }
    }

    private let capabilities: CapabilityRegistry

    public init(capabilities: CapabilityRegistry) {
        self.capabilities = capabilities
    }

    /// G2-1 entry point — preserved so callers without session
    /// context still work. Delegates to the context-aware overload
    /// with `context: nil`.
    public func score(
        question: String,
        candidates: [String]
    ) async -> [Double] {
        await score(question: question, context: nil, candidates: candidates)
    }

    /// G2-1.5 — context-aware scoring. When `context` is supplied the
    /// prompt asks the model to first restate the intent (using the
    /// session snapshot to resolve "it"/"that"/"the same X") and
    /// then score against that restatement.
    public func score(
        question: String,
        context: Context?,
        candidates: [String]
    ) async -> [Double] {
        guard !candidates.isEmpty else { return [] }
        let spec = CapabilitySpec.reranking(purpose: "brain.reranker")
        guard let provider = try? await capabilities.resolve(spec) else {
            AtlasLog.brain.info("reranker: no provider resolved for spec; identity scoring \(candidates.count, privacy: .public) candidates")
            return Array(repeating: 0.5, count: candidates.count)
        }
        guard await provider.isAvailable() else {
            AtlasLog.brain.info("reranker: provider=\(provider.id, privacy: .public) available=false; identity scoring \(candidates.count, privacy: .public) candidates")
            return Array(repeating: 0.5, count: candidates.count)
        }
        let prompt = buildPrompt(question: question, context: context, candidates: candidates)
        let options = GenerationOptions(
            maxTokens: 280,
            temperature: 0.0,
            systemPrompt: "You are a precise relevance scorer. First restate the user's intent in one sentence, then score each passage 0–1 against that restatement. Reply with one JSON object only."
        )
        do {
            let response = try await provider.generate(prompt: prompt, options: options)
            let parsed = Self.parse(response, expectedCount: candidates.count)
            if let restated = parsed.intent, !restated.isEmpty {
                AtlasLog.brain.info("reranker: intent=\"\(restated, privacy: .public)\" scored=\(parsed.scores.count, privacy: .public)")
            } else {
                AtlasLog.brain.info("reranker: provider=\(provider.id, privacy: .public) scored \(parsed.scores.count, privacy: .public) candidates (no restated intent)")
            }
            return parsed.scores
        } catch {
            AtlasLog.brain.error("reranker: provider=\(provider.id, privacy: .public) call failed → \(String(describing: error), privacy: .public); identity scoring")
            return Array(repeating: 0.5, count: candidates.count)
        }
    }

    /// Opening-word shape for the question. Used by EvidenceVerifier
    /// to fill `Context.questionShape` without dragging NLTagger in
    /// just for one token check.
    public static func questionShape(_ question: String) -> String {
        let trimmed = question
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let first = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        switch first {
        case "who": return "who"
        case "what": return "what"
        case "when": return "when"
        case "where": return "where"
        case "why": return "why"
        case "how": return "how"
        case "which": return "which"
        case "is", "are", "was", "were", "do", "does", "did", "can", "could", "should", "will", "would": return "yes-no"
        case "list", "show", "give", "find", "name", "tell": return "list"
        default: return "statement"
        }
    }

    private func buildPrompt(
        question: String,
        context: Context?,
        candidates: [String]
    ) -> String {
        var lines: [String] = []
        for (i, c) in candidates.enumerated() {
            let snippet = String(c.prefix(400))
                .replacingOccurrences(of: "\n", with: " ")
            lines.append("[\(i + 1)] \(snippet)")
        }
        let block = lines.joined(separator: "\n")

        var header = "USER QUESTION: \(question)\n"
        if let context {
            header += "INTENT KIND: \(context.intentKind)\n"
            header += "QUESTION SHAPE: \(context.questionShape)\n"
            if !context.keyEntities.isEmpty {
                header += "KEY ENTITIES: \(context.keyEntities.prefix(8).joined(separator: ", "))\n"
            }
            if !context.recentTurns.isEmpty {
                let turns = context.recentTurns.prefix(3)
                    .enumerated()
                    .map { "  - \($0.element)" }
                    .joined(separator: "\n")
                header += "RECENT TURNS (most recent first):\n\(turns)\n"
            }
            if !context.mentionedEntities.isEmpty {
                header += "MENTIONED THIS SESSION: \(context.mentionedEntities.prefix(8).joined(separator: ", "))\n"
            }
        }

        let instructions: String
        if context != nil {
            instructions = """
            Step 1: In one sentence, restate what the user is asking for. Resolve any pronouns or short references ("it", "that", "the same one") using RECENT TURNS and MENTIONED THIS SESSION. Stay literal — do not invent details.
            Step 2: Score each passage [0,1] for how strongly it answers your Step-1 restatement. 0 = irrelevant, 1 = directly answers it.

            Reply with ONE JSON object only, in this exact form:
            {"intent": "<your one-sentence restatement>", "scores": [<\(candidates.count) numbers in passage order>]}
            """
        } else {
            instructions = """
            Rate how strongly each numbered passage supports answering the question.
            Give a single decimal number between 0 (irrelevant) and 1 (directly answers it) per passage.
            Reply with ONE JSON array of \(candidates.count) numbers in passage order, nothing else.
            """
        }

        return """
        \(header)
        Passages:
        \(block)

        \(instructions)
        """
    }

    /// Parsed reranker output: optional restated intent + scores
    /// aligned to candidate order. Returns identity (0.5 × N) on any
    /// parse failure — never throws.
    struct Parsed {
        let intent: String?
        let scores: [Double]
    }

    static func parse(_ response: String, expectedCount: Int) -> Parsed {
        // Prefer the G2-1.5 object form: {"intent": "...", "scores": [...]}
        if let object = extractFirstJSONObject(from: response),
           let data = object.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let intent = (dict["intent"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let raw = dict["scores"] as? [Any] {
                let scores = sizeScores(raw.compactMap(Self.scoreOf), to: expectedCount)
                return Parsed(intent: intent, scores: scores)
            }
        }
        // G2-1 fallback — bare JSON array of scores.
        if let arrayText = extractFirstJSONArray(from: response),
           let data = arrayText.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            let scores = sizeScores(parsed.compactMap(Self.scoreOf), to: expectedCount)
            return Parsed(intent: nil, scores: scores)
        }
        return Parsed(intent: nil, scores: Array(repeating: 0.5, count: expectedCount))
    }

    /// Back-compat shim. Older tests / callers may still reference
    /// `parseScores`; preserve behavior (scores only, no intent).
    static func parseScores(_ response: String, expectedCount: Int) -> [Double] {
        parse(response, expectedCount: expectedCount).scores
    }

    private static func scoreOf(_ element: Any) -> Double? {
        if let d = element as? Double { return clamp01(d) }
        if let n = element as? NSNumber { return clamp01(n.doubleValue) }
        if let s = element as? String, let d = Double(s) { return clamp01(d) }
        return nil
    }

    private static func sizeScores(_ scores: [Double], to expectedCount: Int) -> [Double] {
        var s = scores
        if s.count < expectedCount {
            s.append(contentsOf: Array(repeating: 0.5, count: expectedCount - s.count))
        } else if s.count > expectedCount {
            s = Array(s.prefix(expectedCount))
        }
        return s
    }

    private static func extractFirstJSONObject(from response: String) -> String? {
        guard let start = response.firstIndex(of: "{") else { return nil }
        var depth = 0
        var cursor = start
        while cursor < response.endIndex {
            let ch = response[cursor]
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return String(response[start...cursor])
                }
            }
            cursor = response.index(after: cursor)
        }
        return nil
    }

    private static func extractFirstJSONArray(from response: String) -> String? {
        guard let start = response.firstIndex(of: "[") else { return nil }
        var depth = 0
        var cursor = start
        while cursor < response.endIndex {
            let ch = response[cursor]
            if ch == "[" { depth += 1 }
            else if ch == "]" {
                depth -= 1
                if depth == 0 {
                    return String(response[start...cursor])
                }
            }
            cursor = response.index(after: cursor)
        }
        return nil
    }

    private static func clamp01(_ x: Double) -> Double {
        if x.isNaN { return 0.5 }
        return min(1, max(0, x))
    }
}
