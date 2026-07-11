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
//  Adaptive depth (ledger-first minimum-LLM, Phase 4). MasterBrain's
//  escalation ladder decides how much LLM the answer is worth; this type
//  spends exactly that and no more, each pass its own session budgeted to
//  Apple's fixed 4,096-token window:
//
//     .refine        — DRAFT only (1 call). Moderate questions.
//     .deep          — DRAFT + one evidence-checked REFINE (2 calls) that
//                      drops unsupported claims and reconciles contradictions.
//                      Complex / contradictory / high-risk questions.
//     .investigation — adds the parallel super-expert council before the
//                      draft. Explicitly-requested deep analysis only.
//
//  An ordinary question never reaches this type at all — the brain ships the
//  verifier's grounded body without a synthesis call. Contract-safe: facts +
//  CITATIONS remain the verifier's output; the model only presents/checks.
//  Any failure or offline (no generative provider) returns the best text so
//  far — or nil so the caller keeps the deterministic body.
//

import Foundation
import OSLog

public struct AnswerSynthesizer: Sendable {
    public init() {}

    /// Adaptive synthesis depth — how much LLM the answer is worth. Set by
    /// MasterBrain's escalation ladder so an ordinary question never pays for
    /// depth it doesn't need (ledger-first minimum-LLM, Phase 4).
    public enum Depth: Sendable {
        /// Moderate: one draft pass. 1 LLM call.
        case refine
        /// Complex (contradiction / high-risk): draft + one evidence-checked
        /// refine pass. 2 LLM calls.
        case deep
        /// Exceptional (explicitly-requested deep analysis): adds the parallel
        /// super-expert council before the draft. Bounded so the whole answer
        /// still respects the hard 5-call ceiling.
        case investigation
    }

    public func synthesize(
        question: String,
        verifiedBody: String,
        citations: [VerifiedAnswer.Citation],
        capabilities: CapabilityRegistry,
        depth: Depth = .refine,
        context: LLMRequestContext? = nil
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
        if depth == .investigation, FeatureFlags.moeCouncilValue() {
            let perspectives = await ExpertCouncil().deliberate(
                question: question,
                findings: boundedFindings,
                evidence: evidence,
                capabilities: capabilities,
                k: 2,
                context: context
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
        // Budget gate before every stage (§10): if the shared allowance is
        // already spent, ship the best answer so far rather than overspend.
        if let context, await !context.budget.canSpend() { return nil }
        guard let draftRaw = await Self.respond(
            provider: provider, prompt: draftPrompt, system: draftSystem, maxTokens: 700,
            purpose: "answer.draft", context: context
        ) else { return nil }
        var answer = draftRaw

        // ── Evidence-checked refine — deep / investigation only ──
        // ONE pass that both flags unsupported/contradictory statements and
        // rewrites. Collapsing the old critique+refine into a single call
        // keeps a complex answer at draft+refine (2 synthesis calls) so the
        // whole question stays within the hard LLM-call ceiling. Moderate
        // (.refine) answers ship the draft as-is — no extra call.
        let refineAllowed: Bool
        if let context {
            refineAllowed = await context.budget.canSpend()
        } else {
            refineAllowed = true
        }
        if (depth == .deep || depth == .investigation), refineAllowed {
            let refineSystem = """
            You are a strict evidence editor. Rewrite the DRAFT so every \
            statement is supported by the findings/evidence: drop or correct \
            anything unsupported, reconcile any contradictions by presenting \
            BOTH sides rather than silently picking one, and add any important \
            finding the draft omitted. Add no new fact, name, number, or date. \
            Keep it concise. Output only the revised answer.
            """
            let refinePrompt = """
            Question: \(question)

            Verified findings:
            \(boundedFindings)

            Evidence:
            \(evidence)

            DRAFT answer:
            \(answer)
            """
            if let refined = await Self.respond(
                provider: provider, prompt: refinePrompt, system: refineSystem, maxTokens: 700,
                purpose: "answer.refine", context: context
            ), refined.count >= 2 {
                KalsmritikoshLog.brain.info("AnswerSynthesizer: applied evidence-checked refine (depth=\(String(describing: depth), privacy: .public))")
                answer = refined
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
        maxTokens: Int,
        purpose: String,
        context: LLMRequestContext?
    ) async -> String? {
        guard let raw = try? await provider.generate(
            prompt: prompt,
            options: GenerationOptions(maxTokens: maxTokens, temperature: 0.2, systemPrompt: system),
            purpose: purpose,
            context: context
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
}
