//
//  InvestigationRunner.swift
//  Kalsmritikosh
//
//  Phase H — drives a planned investigation through the single-turn
//  brain pipeline and synthesizes a final reply.
//
//  Flow per `investigate(question:)`:
//
//   1. Planner decomposes the question (LLM call). If nil, emit
//      `.failed`.
//   2. Emit `.planReady(plan)` so the UI can render skeleton rows.
//   3. For each step: emit `.stepStarted`, run `brain.answer(...)`,
//      emit `.stepCompleted` with the verified answer.
//   4. Emit `.synthesizing`. Call the LLM with the sub-question +
//      sub-answer transcript and ask for a faithful synthesis. Never
//      invent claims beyond what the sub-answers said.
//   5. Emit `.finished(investigation)` with the synthesis text.
//
//  Sequential per-step (not parallel) on purpose: sub-questions often
//  reference each other's findings ("now that we know X, what about Y?"),
//  and the LLM-bound single-turn pipeline is the bottleneck regardless.
//  The runner can be evolved to parallelize independent steps once
//  the planner emits a step dependency graph.
//

import Foundation
import OSLog

public actor InvestigationRunner {
    private let planner: InvestigationPlanner
    private let brain: MasterBrain
    private let capabilities: CapabilityRegistry
    /// Optional persistence — when supplied, every `.finished`
    /// investigation is auto-saved so the Notebook tab can replay it.
    private let investigations: InvestigationsRepository?

    public init(
        planner: InvestigationPlanner = InvestigationPlanner(),
        brain: MasterBrain,
        capabilities: CapabilityRegistry,
        investigations: InvestigationsRepository? = nil
    ) {
        self.planner = planner
        self.brain = brain
        self.capabilities = capabilities
        self.investigations = investigations
    }

    /// Stream of progress updates for the investigation. Caller awaits
    /// the stream and renders each update in the UI.
    public nonisolated func investigate(question: String) -> AsyncStream<InvestigationUpdate> {
        AsyncStream { continuation in
            Task { [planner, brain, capabilities, investigations] in
                // ONE hard budget for the whole investigation (spec §12): the
                // planner call, every nested brain.answer step, and the final
                // synthesis all reserve from this shared ≤5-call allowance.
                // Nested answers get it via child(), so they never mint a
                // fresh five-call budget of their own.
                let llmContext = LLMRequestContext(
                    budget: LLMCallBudget(limit: LLMQueryClass.investigation.callLimit),
                    queryClass: .investigation
                )

                guard let initialPlan = await planner.plan(
                    question: question,
                    capabilities: capabilities,
                    context: llmContext
                ) else {
                    continuation.yield(.failed(reason: "No reasoning provider available, or the planner could not decompose the question."))
                    continuation.finish()
                    return
                }
                continuation.yield(.planReady(initialPlan))

                var completedSteps: [InvestigationStep] = []
                for step in initialPlan.steps {
                    // Reserve one call for the final synthesis; stop stepping
                    // when the shared budget can't cover a step + synthesis.
                    guard await llmContext.budget.canSpend(2) else {
                        KalsmritikoshLog.app.info("InvestigationRunner: budget reserved for synthesis — deferring remaining steps")
                        break
                    }
                    continuation.yield(.stepStarted(stepID: step.id))
                    let answer = await brain.answer(question: step.question, context: llmContext,
                                                   access: SensitiveAccessContext(scope: .globalOwnerRetrieval()))
                    var withAnswer = step
                    withAnswer.answer = answer
                    completedSteps.append(withAnswer)
                    continuation.yield(.stepCompleted(stepID: step.id, answer: answer))
                }

                continuation.yield(.synthesizing)
                let synthesis = await Self.synthesize(
                    question: question,
                    steps: completedSteps,
                    capabilities: capabilities,
                    context: llmContext
                )
                var finalInvestigation = initialPlan
                finalInvestigation.steps = completedSteps
                finalInvestigation.synthesis = synthesis
                // Phase I.B — auto-save before yielding `.finished` so
                // the Notebook tab sees the row by the time the UI
                // reacts to the terminal update.
                if let investigations {
                    do {
                        try await investigations.save(finalInvestigation)
                    } catch {
                        KalsmritikoshLog.app.error("InvestigationRunner: persist failed — \(String(describing: error), privacy: .public)")
                    }
                }
                continuation.yield(.finished(finalInvestigation))
                continuation.finish()
            }
        }
    }

    // MARK: - Synthesis

    /// LLM-driven synthesis. Builds a transcript of (sub-question, body)
    /// pairs and asks the reasoning model to produce a 4-8 sentence
    /// answer to the original question that is faithful to the
    /// sub-answers. When no provider is available we return a
    /// deterministic fallback that concatenates the sub-answers — not
    /// glamorous but informative, and never hallucinates.
    nonisolated static func synthesize(
        question: String,
        steps: [InvestigationStep],
        capabilities: CapabilityRegistry,
        context: LLMRequestContext? = nil
    ) async -> String {
        let nonEmpty = steps.compactMap { step -> (String, String)? in
            guard let answer = step.answer else { return nil }
            let body = (answer.answerText ?? answer.body)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            return (step.question, body)
        }
        guard !nonEmpty.isEmpty else {
            return "The sub-questions produced no answers."
        }
        let spec = CapabilitySpec.reasoning(
            contextTokens: 4_000,
            purpose: "investigation.runner.synthesize"
        )
        let provider: any ModelProvider
        do {
            provider = try await capabilities.resolve(spec)
        } catch {
            KalsmritikoshLog.app.info("InvestigationRunner.synthesize: no reasoning provider — falling back to concatenation")
            return Self.deterministicFallback(question: question, pairs: nonEmpty)
        }
        guard await provider.isAvailable() else {
            return Self.deterministicFallback(question: question, pairs: nonEmpty)
        }

        let transcript = nonEmpty.enumerated().map { idx, pair in
            "Sub-question \(idx + 1): \(pair.0)\nAnswer: \(pair.1)"
        }.joined(separator: "\n\n")

        let prompt = """
        ORIGINAL QUESTION:
        \(question)

        SUB-QUESTION TRANSCRIPT:
        \(transcript)

        Write a 4-8 sentence synthesis that answers the original question \
        using only what the sub-answers state. If the sub-answers contradict \
        each other, name the conflict explicitly. Do NOT invent facts, \
        entities, or dates not present in the sub-answers. If the \
        sub-answers do not cover part of the question, say so.

        SYNTHESIS:
        """

        do {
            let raw = try await provider.generate(
                prompt: prompt,
                options: GenerationOptions(
                    maxTokens: 600,
                    temperature: 0.3,
                    topP: 0.95,
                    stopSequences: [],
                    systemPrompt: "You are a careful research analyst. Cite only the evidence in the transcript. Refuse to invent."
                ),
                purpose: "investigation.synthesis",
                context: context
            )
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty
                ? Self.deterministicFallback(question: question, pairs: nonEmpty)
                : cleaned
        } catch {
            KalsmritikoshLog.app.error("InvestigationRunner.synthesize: generate failed — \(String(describing: error), privacy: .public)")
            return Self.deterministicFallback(question: question, pairs: nonEmpty)
        }
    }

    /// Plain-prose fallback: list the sub-answer bodies labeled by
    /// their sub-question. No invention; just a flat readout.
    nonisolated static func deterministicFallback(
        question: String,
        pairs: [(String, String)]
    ) -> String {
        var out = "Synthesis unavailable; the sub-question answers were:\n\n"
        for (i, pair) in pairs.enumerated() {
            out += "\(i + 1). \(pair.0)\n   \(pair.1)\n\n"
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
