//
//  AnswerSynthesizer.swift
//  Kalsmritikosh
//
//  "Apple AI is the brain; the experts help him." After the domain experts
//  produce grounded, verified claims and the verifier assembles a
//  deterministic body, the resolved generative model (Apple on-device first)
//  composes the FINAL answer FROM those verified findings — experts supply
//  the facts, the model presents them.
//
//  MoE depth (toward rivaling a much larger cloud model on grounded Q&A):
//  the answer is produced in up to three on-device passes, each its own
//  session, each budgeted to Apple's fixed 4,096-token window:
//
//     1. DRAFT   — compose the answer from findings + evidence.
//     2. CRITIQUE — a fact-checker pass lists claims not supported by the
//                   findings, contradictions, or important omissions
//                   (or replies "OK").
//     3. REFINE  — rewrite the draft to fix the critique, still grounded.
//
//  This self-verification is where small models otherwise lose to big ones
//  (faithfulness), recovered here at ~2-3× calls. Contract-safe: facts +
//  CITATIONS remain the verifier's output; the model only presents/checks.
//  Any failure or offline (no generative provider) returns the best text so
//  far — or nil so the caller keeps the deterministic body.
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

        // Budget the shared context so DRAFT + a later pass that ALSO carries
        // the draft still fit the 4,096-token window with room for output.
        let boundedFindings = TokenBudget.clamp(findings, maxTokens: 1_500)
        let evidence = Self.evidenceBlock(citations, maxTokens: 800)

        // ── MoE gate → top-k super-experts deliberate IN PARALLEL ──
        // Their perspectives advise the draft; facts stay bound to the
        // findings/evidence. (Mixtral-style: gate → parallel experts →
        // combine — combination happens in the draft/refine below.)
        var councilBlock = ""
        if FeatureFlags.moeCouncilValue() {
            let perspectives = await ExpertCouncil().deliberate(
                question: question,
                findings: boundedFindings,
                evidence: evidence,
                capabilities: capabilities,
                k: 3
            )
            if !perspectives.isEmpty {
                councilBlock = "\n\nSpecialist perspectives (advisory — still ground every statement in the findings/evidence above):\n"
                    + perspectives.map { "• \($0.title): \($0.text)" }.joined(separator: "\n")
            }
        }

        // ── Stage 1: DRAFT ──
        let draftSystem = """
        You are the answering brain of a closed-corpus knowledge system. Domain \
        experts have already extracted and verified the findings below. Compose a \
        clear, direct answer to the question using ONLY those findings and evidence. \
        Introduce NO fact, name, number, or date not present in them; if they are \
        thin, say so plainly. Be concise. Output only the answer.
        """
        let draftPrompt = """
        Question: \(question)

        Verified findings (from the domain experts):
        \(boundedFindings)

        Supporting evidence snippets:
        \(evidence)\(councilBlock)
        """
        guard let draftRaw = await Self.respond(
            provider: provider, prompt: draftPrompt, system: draftSystem, maxTokens: 700
        ) else { return nil }
        var answer = draftRaw

        // ── Stages 2 & 3: self-critique → refine (optional) ──
        if FeatureFlags.llmSelfCritiqueValue() {
            let criticSystem = """
            You are a strict fact-checker. Compare the DRAFT answer against the \
            verified findings and evidence. List ONLY concrete problems as short \
            bullets: statements not supported by the findings, contradictions, or \
            important findings the draft omitted. If the draft is fully supported \
            and complete, reply with exactly: OK
            """
            let criticPrompt = """
            Question: \(question)

            Verified findings:
            \(boundedFindings)

            Evidence:
            \(evidence)

            DRAFT answer:
            \(answer)
            """
            if let critique = await Self.respond(
                provider: provider, prompt: criticPrompt, system: criticSystem, maxTokens: 300
            ), Self.critiqueHasIssues(critique) {
                let refineSystem = """
                Revise the DRAFT to fix the listed issues. Use ONLY the findings and \
                evidence; add no new fact, name, number, or date; drop anything \
                unsupported; keep it concise. Output only the revised answer.
                """
                let refinePrompt = """
                Question: \(question)

                Verified findings:
                \(boundedFindings)

                Evidence:
                \(evidence)

                DRAFT answer:
                \(answer)

                Issues to fix:
                \(critique)
                """
                if let refined = await Self.respond(
                    provider: provider, prompt: refinePrompt, system: refineSystem, maxTokens: 700
                ), refined.count >= 2 {
                    AtlasLog.brain.info("AnswerSynthesizer: refined draft after self-critique")
                    answer = refined
                }
            }
        }

        let final = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard final.count >= 2 else { return nil }
        return final
    }

    // MARK: - Helpers

    private static func respond(
        provider: any ModelProvider,
        prompt: String,
        system: String,
        maxTokens: Int
    ) async -> String? {
        guard let raw = try? await provider.generate(
            prompt: prompt,
            options: GenerationOptions(maxTokens: maxTokens, temperature: 0.2, systemPrompt: system)
        ) else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func evidenceBlock(_ citations: [VerifiedAnswer.Citation], maxTokens: Int) -> String {
        let budget = TokenBudget.approxChars(tokens: maxTokens)
        var out = ""
        for (i, c) in citations.prefix(8).enumerated() {
            let line = "[\(i + 1)] \(c.snippet)\n"
            if out.count + line.count > budget { break }
            out += line
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(none)" : trimmed
    }

    /// The critic replies "OK" when the draft is clean; anything else that
    /// isn't a trivial no-op is treated as issues to refine against.
    private static func critiqueHasIssues(_ critique: String) -> Bool {
        let t = critique.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if t == "ok" || t.hasPrefix("ok\n") || t.hasPrefix("ok.") || t.hasPrefix("ok ") { return false }
        if t.contains("no issues") || t.contains("no problems") || t.contains("fully supported") || t.contains("no changes") { return false }
        return true
    }
}
