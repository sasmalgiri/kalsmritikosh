//
//  InvestigationPlanner.swift
//  Kalsmritikosh
//
//  Phase H — LLM-driven decomposition of a complex user question into
//  2-5 focused sub-questions ("Plan-and-Solve"). Each sub-question is
//  later answered independently by the existing single-turn brain
//  pipeline; the runner then synthesizes the sub-answers into a final
//  reply.
//
//  Quality-or-nothing: when no `.reasoning` provider clears the
//  privacy gate, the planner returns nil and the runner refuses
//  rather than substituting a heuristic decomposition. The single-turn
//  pipeline is still available as a fallback in the UI.
//
//  Conservative prompting:
//    1. Cap sub-questions at 5 — beyond that the synthesis becomes
//       lossy and the per-step latency cost explodes.
//    2. Each sub-question MUST end in "?". Easy to validate; rejects
//       LLM responses that drifted into bullet titles or instructions.
//    3. NEVER invent context the user did not provide. Lower
//       temperature (0.2) keeps the planner from inventing entities
//       the archive doesn't contain.
//

import Foundation
import OSLog

public struct InvestigationPlanner: Sendable {
    // Nonisolated init so callers in nonisolated/actor contexts can
    // use the default-argument expression without bouncing through
    // MainActor (Swift 6 strict-concurrency requirement).
    public nonisolated init() {}

    /// Maximum number of sub-questions the planner will emit. Caps the
    /// runner's per-investigation cost.
    public static let maxSteps: Int = 5

    /// Decompose `question` into sub-question steps. Returns nil when
    /// no reasoning provider is available; the runner surfaces a
    /// `.failed` update in that case.
    public func plan(
        question: String,
        capabilities: CapabilityRegistry
    ) async -> Investigation? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let spec = CapabilitySpec.reasoning(
            contextTokens: 2_000,
            purpose: "investigation.planner.decompose"
        )
        let provider: any ModelProvider
        do {
            provider = try await capabilities.resolve(spec)
        } catch {
            AtlasLog.app.info("InvestigationPlanner: no reasoning provider — \(String(describing: error), privacy: .public)")
            return nil
        }
        guard await provider.isAvailable() else {
            AtlasLog.app.info("InvestigationPlanner: provider \(provider.id, privacy: .public) unavailable")
            return nil
        }

        let prompt = Self.decompositionPrompt(question: trimmed)
        let raw: String
        do {
            raw = try await provider.generate(
                prompt: prompt,
                options: GenerationOptions(
                    maxTokens: 512,
                    temperature: 0.2,
                    topP: 0.95,
                    stopSequences: [],
                    systemPrompt: Self.systemPrompt
                )
            )
        } catch {
            AtlasLog.app.error("InvestigationPlanner: generate failed — \(String(describing: error), privacy: .public)")
            return nil
        }

        let subs = Self.parseSubQuestions(raw)
        guard !subs.isEmpty else {
            AtlasLog.app.info("InvestigationPlanner: parser found no sub-questions in response")
            return nil
        }
        let steps = subs.prefix(Self.maxSteps).map { InvestigationStep(question: $0) }
        return Investigation(question: trimmed, steps: Array(steps))
    }

    // MARK: - Prompt + parser

    static let systemPrompt: String = """
    You are a research assistant decomposing a complex question into focused \
    sub-questions. The sub-questions will be answered against the user's \
    private archive of emails, documents, and PDFs. Each sub-question must be \
    answerable independently. Do NOT invent entities, people, projects, or \
    timeframes the user did not provide. If the question is already simple, \
    return it as the single sub-question.
    """

    static func decompositionPrompt(question: String) -> String {
        """
        QUESTION:
        \(question)

        Output 1-\(maxSteps) sub-questions as a JSON array of strings. Each \
        sub-question must end in a question mark. Do not wrap the JSON in \
        code fences or commentary. Example:

        ["What was the timeline of Project Delta's funding?", "Which suppliers were involved in 2023?"]

        Respond now with ONLY the JSON array:
        """
    }

    /// Robust extractor: handles bare JSON, fenced code blocks, and
    /// LLM responses that prefix the array with commentary.
    static func parseSubQuestions(_ raw: String) -> [String] {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip ```json ... ``` fences if the model wrapped them.
        if let lower = s.range(of: "```", options: .literal) {
            s.removeSubrange(s.startIndex..<lower.upperBound)
            if let upper = s.range(of: "```", options: [.literal, .backwards]) {
                s = String(s[s.startIndex..<upper.lowerBound])
            }
            if s.lowercased().hasPrefix("json") {
                s = String(s.dropFirst(4))
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Find the first '[' and matching ']' — handles "Sure, here you go: [...]".
        guard let openIdx = s.firstIndex(of: "["),
              let closeIdx = s.lastIndex(of: "]"),
              openIdx < closeIdx else {
            return []
        }
        let jsonSlice = String(s[openIdx...closeIdx])
        guard let data = jsonSlice.data(using: .utf8) else { return [] }
        if let arr = try? JSONDecoder().decode([String].self, from: data) {
            return arr
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= 6 && $0.hasSuffix("?") }
        }
        return []
    }
}
