//
//  ExpertCouncil.swift
//  Kalsmritikosh
//
//  An on-device emulation of a Mixtral-style Mixture-of-Experts, built from
//  parallelism + specialist "super-experts" over Apple's on-device model:
//
//     gate (top-k)  →  selected experts run IN PARALLEL  →  combine
//
//  Mixtral routes each token to its top-2 of 8 weight-level experts. We
//  can't touch Apple's weights, so we emulate the same SHAPE at the agent
//  level: a gate scores a roster of specialist reasoning personas against
//  the question, the top-k run concurrently (separate LanguageModelSessions,
//  which the framework allows to run in parallel), and their perspectives
//  are combined downstream by AnswerSynthesizer (draft → critique → refine).
//
//  Every persona is evidence-bound (it may only use the findings/evidence
//  passed in) so the council never invents facts. Each analysis is kept
//  short to fit Apple's fixed 4,096-token window and to bound cost.
//

import Foundation
import OSLog

public struct ExpertCouncil: Sendable {

    /// A specialist reasoning persona — a distinct lens over the same
    /// evidence. The `keywords` drive the top-k gate; `instruction` is the
    /// persona's system prompt.
    public struct SuperExpert: Sendable, Hashable {
        public let id: String
        public let title: String
        public let instruction: String
        public let keywords: [String]
        /// Always run regardless of gate score (the backbone experts).
        public let alwaysOn: Bool

        public init(id: String, title: String, instruction: String, keywords: [String], alwaysOn: Bool = false) {
            self.id = id
            self.title = title
            self.instruction = instruction
            self.keywords = keywords
            self.alwaysOn = alwaysOn
        }
    }

    public struct Perspective: Sendable {
        public let expertID: String
        public let title: String
        public let text: String
    }

    public init() {}

    // MARK: - Roster

    public static let roster: [SuperExpert] = [
        SuperExpert(
            id: "super.analyst",
            title: "Analyst",
            instruction: "You are the Analyst. State the single most direct, evidence-supported answer to the question. Cite nothing you can't ground in the evidence. Be terse.",
            keywords: [],
            alwaysOn: true
        ),
        SuperExpert(
            id: "super.skeptic",
            title: "Skeptic",
            instruction: "You are the Skeptic. Point out where the evidence is thin, contradictory, or missing for this question. If the evidence fully supports a clear answer, say 'No gaps.' Be terse.",
            keywords: ["why", "risk", "contradiction", "conflict", "sure", "certain", "verify"],
            alwaysOn: true
        ),
        SuperExpert(
            id: "super.historian",
            title: "Historian",
            instruction: "You are the Historian. Put the relevant events in chronological order and note cause/effect where the evidence shows it. Only use dated evidence. Be terse.",
            keywords: ["when", "timeline", "history", "sequence", "before", "after", "date", "order", "happened"]
        ),
        SuperExpert(
            id: "super.connector",
            title: "Connector",
            instruction: "You are the Connector. Identify links across sources — same people, orgs, projects, or references that tie the evidence together for this question. Be terse.",
            keywords: ["who", "relationship", "connected", "between", "involved", "related", "network", "parties"]
        ),
        SuperExpert(
            id: "super.quant",
            title: "Quant",
            instruction: "You are the Quant. Report the exact numbers, amounts, IDs, and dates from the evidence relevant to the question. Never alter or estimate a figure. Be terse.",
            keywords: ["how much", "amount", "total", "number", "cost", "price", "invoice", "payment", "sum", "count", "figure"]
        )
    ]

    // MARK: - Gate (top-k)

    /// Score each persona against the question and pick the top-k (always
    /// including the `alwaysOn` backbone). Keyword-overlap scoring — cheap,
    /// deterministic, no extra model call for routing (Mixtral's gate is
    /// also a tiny, fast network relative to the experts).
    public static func gate(question: String, k: Int = 3) -> [SuperExpert] {
        let q = question.lowercased()
        let scored = roster.map { expert -> (SuperExpert, Int) in
            let hits = expert.keywords.reduce(0) { $0 + (q.contains($1) ? 1 : 0) }
            return (expert, hits)
        }
        var selected = scored.filter { $0.0.alwaysOn }.map(\.0)
        let ranked = scored
            .filter { !$0.0.alwaysOn && $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        for e in ranked where selected.count < k {
            selected.append(e)
        }
        // If nothing scored beyond the backbone and k allows, add the
        // Connector as a sensible default third lens.
        if selected.count < k, let connector = roster.first(where: { $0.id == "super.connector" }),
           !selected.contains(connector) {
            selected.append(connector)
        }
        return Array(selected.prefix(max(k, selected.filter(\.alwaysOn).count)))
    }

    // MARK: - Parallel deliberation

    /// Run the gated experts CONCURRENTLY (each its own session) over the
    /// shared evidence. Returns their perspectives in roster order. Any
    /// expert that fails or has no model simply contributes nothing.
    public func deliberate(
        question: String,
        findings: String,
        evidence: String,
        capabilities: CapabilityRegistry,
        k: Int = 3
    ) async -> [Perspective] {
        let spec = CapabilitySpec.reasoning(contextTokens: 4_000, purpose: "moe.council")
        guard let provider = try? await capabilities.resolve(spec),
              await provider.isAvailable() else { return [] }

        let selected = Self.gate(question: question, k: k)
        let sharedPrompt = """
        Question: \(question)

        Verified findings (from domain experts):
        \(findings)

        Evidence:
        \(evidence)
        """

        let perspectives = await withTaskGroup(of: (Int, Perspective?).self) { group -> [Perspective] in
            for (i, expert) in selected.enumerated() {
                group.addTask {
                    let opts = GenerationOptions(maxTokens: 220, temperature: 0.2, systemPrompt: expert.instruction)
                    guard let raw = try? await provider.generate(prompt: sharedPrompt, options: opts) else {
                        return (i, nil)
                    }
                    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard text.count >= 2 else { return (i, nil) }
                    return (i, Perspective(expertID: expert.id, title: expert.title, text: text))
                }
            }
            var out = Array<Perspective?>(repeating: nil, count: selected.count)
            for await (i, p) in group { out[i] = p }
            return out.compactMap { $0 }
        }

        if !perspectives.isEmpty {
            KalsmritikoshLog.brain.info("ExpertCouncil: \(perspectives.count, privacy: .public) super-experts deliberated in parallel [\(selected.map(\.title).joined(separator: ","), privacy: .public)]")
        }
        return perspectives
    }
}
