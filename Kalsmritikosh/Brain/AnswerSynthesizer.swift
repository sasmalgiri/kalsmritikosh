//
//  AnswerSynthesizer.swift
//  Kalsmritikosh
//
//  "Apple AI is the brain; the experts help him." After the domain experts
//  produce grounded, verified claims and the verifier assembles a
//  deterministic answer body, this optional pass lets the resolved
//  generative model (Apple on-device first, via CapabilityRegistry) compose
//  the FINAL prose from those verified findings — the experts are the
//  helpers that supply the facts; the model only presents them.
//
//  Contract-safe: the facts and CITATIONS remain exactly what the verifier
//  produced (citations are passed through untouched); the model only
//  rewrites the already-grounded body into a clearer answer and is
//  instructed to add nothing. If no generative model resolves — e.g. the
//  fully-private `PrivacyGate.offlineNoLLM` switch is on, or Apple
//  Intelligence isn't available — this returns nil and the caller keeps the
//  deterministic body. That is the LLM ↔ deterministic substitution.
//

import Foundation
import OSLog

public struct AnswerSynthesizer: Sendable {
    public init() {}

    public func synthesize(
        question: String,
        verifiedBody: String,
        citations: [VerifiedAnswer.Citation],
        capabilities: CapabilityRegistry
    ) async -> String? {
        let findings = verifiedBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard findings.count >= 2 else { return nil }

        let spec = CapabilitySpec.reasoning(contextTokens: 4_000, purpose: "answer.synthesis")
        guard let provider = try? await capabilities.resolve(spec),
              await provider.isAvailable() else { return nil }

        // Fit the Apple 4,096-token window: reserve ~700 for the answer +
        // ~250 for instructions, leaving ~3,000 for findings + evidence.
        // Findings take priority; evidence fills the remainder.
        let boundedFindings = TokenBudget.clamp(findings, maxTokens: 1_800)
        let evidenceBudgetChars = TokenBudget.approxChars(tokens: 1_000)
        var evidence = ""
        for (i, c) in citations.prefix(8).enumerated() {
            let line = "[\(i + 1)] \(c.snippet)\n"
            if evidence.count + line.count > evidenceBudgetChars { break }
            evidence += line
        }
        evidence = evidence.trimmingCharacters(in: .whitespacesAndNewlines)

        let system = """
        You are the answering brain of a closed-corpus knowledge system. Domain \
        experts have already extracted and verified the findings below. Compose a \
        clear, direct answer to the user's question using ONLY those findings and \
        the supporting evidence. Hard rules:
        - Introduce NO fact, name, number, date, or claim that isn't in the findings.
        - Do not contradict the findings; if they are thin or uncertain, say so plainly.
        - Be concise and well-structured. Do not invent or renumber citations.
        Output only the answer prose.
        """
        let prompt = """
        Question: \(question)

        Verified findings (from the domain experts):
        \(boundedFindings)

        Supporting evidence snippets:
        \(evidence.isEmpty ? "(none)" : evidence)
        """

        guard let raw = try? await provider.generate(
            prompt: prompt,
            options: GenerationOptions(maxTokens: 700, temperature: 0.2, systemPrompt: system)
        ) else { return nil }

        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.count >= 2 else { return nil }
        AtlasLog.brain.info("AnswerSynthesizer: composed final answer via \(provider.id, privacy: .public)")
        return body
    }
}
