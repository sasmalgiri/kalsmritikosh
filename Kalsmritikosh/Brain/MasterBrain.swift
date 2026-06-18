//
//  MasterBrain.swift
//  Kalsmritikosh
//
//  Final orchestrator. Detects intent, routes (capabilities + experts +
//  retrieval layers + parallelism), fans out work in parallel, verifies
//  findings, emits an answer with citations.
//
//  Hard rules:
//  - Holds no FileManager / URL.
//  - Holds no specific ModelProvider. Resolves capabilities through
//    CapabilityRegistry — the only entry point any caller uses to obtain
//    a model.
//

import Foundation

public actor MasterBrain {
    private let intentDetector: IntentDetector?
    private let router: Router?
    private let retriever: Retriever?
    private let executor: ParallelExecutor?
    private let capabilities: CapabilityRegistry?
    private let verifier: Verifier?
    private let weeklyBriefing: WeeklyBriefingGenerator?

    public init(
        intentDetector: IntentDetector? = nil,
        router: Router? = nil,
        retriever: Retriever? = nil,
        executor: ParallelExecutor? = nil,
        capabilities: CapabilityRegistry? = nil,
        verifier: Verifier? = nil,
        weeklyBriefing: WeeklyBriefingGenerator? = nil
    ) {
        self.intentDetector = intentDetector
        self.router = router
        self.retriever = retriever
        self.executor = executor
        self.capabilities = capabilities
        self.verifier = verifier
        self.weeklyBriefing = weeklyBriefing
    }

    public func answer(question: String) async -> VerifiedAnswer {
        guard
            let intentDetector,
            let router,
            let retriever,
            let executor,
            let capabilities,
            let verifier
        else {
            return VerifiedAnswer(
                body: "Atlas hasn't finished booting yet.",
                citations: [],
                confidence: .zero,
                refused: true,
                refusalReason: "Brain dependencies missing."
            )
        }

        let intent: UserIntent
        do {
            intent = try await intentDetector.detect(question: question)
        } catch {
            return VerifiedAnswer(
                body: "Atlas couldn't parse that question.",
                citations: [],
                confidence: .zero,
                refused: true,
                refusalReason: "Intent detection failed: \(error)"
            )
        }

        // Short-circuit "what changed" briefings if a WeeklyBriefingGenerator
        // is wired and the question is temporal-delta shaped. The matcher
        // is intentionally narrow so "new project" / "new supplier" don't
        // hijack the regular expert pipeline.
        let q = question.lowercased()
        let temporalDeltaShape =
            q.contains("what changed")
            || q.contains("changes this week")
            || q.contains("changes this month")
            || q.contains("what's new") || q.contains("whats new")
            || q.contains("what is new")
        if let weeklyBriefing,
           intent.kind == .executiveBriefing,
           temporalDeltaShape {
            do {
                let period: WeeklyBriefingGenerator.Period =
                    question.localizedCaseInsensitiveContains("month") ? .lastMonth : .lastWeek
                let briefing = try await weeklyBriefing.briefing(period: period)
                let confidence: Confidence = briefing.perSubject.isEmpty ? .low : .medium
                return VerifiedAnswer(
                    body: briefing.narrative,
                    citations: [],
                    confidence: confidence,
                    refused: false,
                    refusalReason: nil
                )
            } catch {
                // Fall through to the regular expert pipeline.
            }
        }

        let decision: RoutingDecision
        do {
            decision = try await router.route(intent: intent)
        } catch {
            return VerifiedAnswer(
                body: "Atlas couldn't route that question.",
                citations: [],
                confidence: .zero,
                refused: true,
                refusalReason: "Routing failed: \(error)"
            )
        }

        // G2-0 — one retrieval per question, shared across every expert
        // AND the verifier. Was: N+1 retrieval calls per question (one
        // per expert + one for the verifier), each repeating the same
        // SQL + vector traffic. Wall-clock saving is N retrieval round
        // trips per question; for `factualLookup` (which routes to all
        // experts) that's ~7× fewer retrieval passes per question.
        let sharedRetrieval = (try? await retriever.retrieve(
            for: intent,
            layers: decision.retrievalLayers
        )) ?? RetrievalResult()

        let context = ExpertContext(
            retriever: retriever,
            capabilities: capabilities,
            sharedRetrieval: sharedRetrieval
        )
        let findings = await executor.execute(
            intent: intent,
            decision: decision,
            context: context
        )

        let retrievalForVerifier = sharedRetrieval

        do {
            return try await verifier.verify(
                intent: intent,
                findings: findings,
                retrieval: retrievalForVerifier
            )
        } catch {
            return VerifiedAnswer(
                body: "Atlas couldn't verify a response.",
                citations: [],
                confidence: .zero,
                refused: true,
                refusalReason: "Verification failed: \(error)"
            )
        }
    }
}
