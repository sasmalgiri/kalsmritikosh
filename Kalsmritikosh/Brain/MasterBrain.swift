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
    /// G2-1.5 — shared with the EvidenceVerifier. MasterBrain records
    /// each turn here right after intent detection; the verifier reads
    /// the snapshot when scoring citations so follow-ups inherit the
    /// prior turn's entities + topic frame.
    private let sessionProfile: SessionProfile?

    public init(
        intentDetector: IntentDetector? = nil,
        router: Router? = nil,
        retriever: Retriever? = nil,
        executor: ParallelExecutor? = nil,
        capabilities: CapabilityRegistry? = nil,
        verifier: Verifier? = nil,
        weeklyBriefing: WeeklyBriefingGenerator? = nil,
        sessionProfile: SessionProfile? = nil
    ) {
        self.intentDetector = intentDetector
        self.router = router
        self.retriever = retriever
        self.executor = executor
        self.capabilities = capabilities
        self.verifier = verifier
        self.weeklyBriefing = weeklyBriefing
        self.sessionProfile = sessionProfile
    }

    /// Clear the in-memory SessionProfile. The eval harness calls this
    /// between independent questions so question N+1 isn't scored
    /// against entities from questions 1..N. In real usage the session
    /// IS persistent across follow-ups, so callers MUST NOT invoke
    /// this in the user-facing flow.
    public func resetSession() async {
        await sessionProfile?.reset()
    }

    /// G2-PROGRESSIVE — streaming answer stream. Emits phase events as
    /// the pipeline produces them; terminal event for a non-refused
    /// answer is `.verified(VerifiedAnswer)`. For refusals, only the
    /// terminal `.verified` is emitted (no Phase 1-3 events).
    ///
    /// **Current implementation scope:** Phase 4 (verified) is wired.
    /// Phases 1-3 are reserved in the enum for the follow-on commit
    /// that wires Memory cache + streaming tokens + per-expert events.
    /// Today's stream therefore yields exactly one `.verified` event;
    /// shipping the API surface now keeps future phase additions from
    /// breaking callers.
    public func answerStream(question: String) -> AsyncStream<AnswerUpdate> {
        AsyncStream { continuation in
            Task { [weak self] in
                guard let self else { continuation.finish(); return }
                let final = await self.computeVerified(question: question)
                continuation.yield(.verified(final))
                continuation.finish()
            }
        }
    }

    /// Legacy synchronous-ish entry point. Reads the terminal
    /// `.verified` from `answerStream` so both code paths share one
    /// pipeline. EvalKit and existing UI buttons keep working
    /// unchanged.
    public func answer(question: String) async -> VerifiedAnswer {
        for await update in answerStream(question: question) {
            if case .verified(let answer) = update {
                return answer
            }
        }
        // Stream finished without emitting .verified — defensive.
        return VerifiedAnswer(
            body: "Atlas produced no terminal answer.",
            citations: [],
            confidence: .zero,
            refused: true,
            refusalReason: "answerStream closed without .verified event."
        )
    }

    /// G2-PROGRESSIVE — the previous body of `answer(question:)`, now
    /// shared between the stream wrapper and any future per-phase
    /// emitter. Returns the terminal `VerifiedAnswer`.
    private func computeVerified(question: String) async -> VerifiedAnswer {
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

        // G2-1.5 — record this turn before anything else runs. The
        // verifier reads the snapshot during citation reranking, so
        // even on this very turn the prompt sees the current entities
        // (helpful when the same name appears in retrieval candidates).
        // Failed intent detection above skips the record on purpose —
        // we only want well-formed turns in the session log.
        await sessionProfile?.recordTurn(
            question: question,
            intentKind: intent.kind.rawValue,
            entityHints: intent.entityHints
        )

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
