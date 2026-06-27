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
    /// G2-PROGRESSIVE Phase 1 — optional. When present, answerStream
    /// emits an `.instant` event before kicking off the full pipeline,
    /// IF the resolved subject has a distilled MemoryObject whose
    /// narrative is non-empty. The UI tags this read as "verifying…".
    private let memoryRepo: MemoryRepository?
    /// HISTORY Phase D.6 — optional. When present AND the intent is
    /// reconstructive (.reconstructTimeline / .reconstructProject /
    /// .reconstructRelationship), the brain runs the composer
    /// alongside the expert pipeline and emits chapter-shaped prose
    /// rather than just expert-finding bullets. Nil = legacy expert
    /// pipeline is the only path (existing eval and old UI still
    /// work unchanged).
    private let narrativeComposer: NarrativeComposer?
    /// HISTORY Phase D.6 — events repo so the brain can hydrate
    /// 5W+H slot bundles for the composer's input. Required when
    /// `narrativeComposer` is wired; ignored otherwise.
    private let eventsRepo: EventsRepository?

    public init(
        intentDetector: IntentDetector? = nil,
        router: Router? = nil,
        retriever: Retriever? = nil,
        executor: ParallelExecutor? = nil,
        capabilities: CapabilityRegistry? = nil,
        verifier: Verifier? = nil,
        weeklyBriefing: WeeklyBriefingGenerator? = nil,
        sessionProfile: SessionProfile? = nil,
        memoryRepo: MemoryRepository? = nil,
        narrativeComposer: NarrativeComposer? = nil,
        eventsRepo: EventsRepository? = nil
    ) {
        self.intentDetector = intentDetector
        self.router = router
        self.retriever = retriever
        self.executor = executor
        self.capabilities = capabilities
        self.verifier = verifier
        self.weeklyBriefing = weeklyBriefing
        self.sessionProfile = sessionProfile
        self.memoryRepo = memoryRepo
        self.narrativeComposer = narrativeComposer
        self.eventsRepo = eventsRepo
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

                // G2-PROGRESSIVE Phase 1 — emit an instant cached read
                // if a confident MemoryObject for the resolved subject
                // exists. The UI MUST tag this as "Quick read · verifying…"
                // and NEVER treat it as a verified answer (trust contract,
                // GATE2_ROADMAP §G2-PROGRESSIVE). The pipeline continues
                // regardless; Phase 4 is the locked answer.
                if let instant = await self.phase1Instant(question: question) {
                    continuation.yield(instant)
                }

                // HISTORY Phase D.7 — reconstructive intents route
                // through the narrative composer. Each chapter is
                // yielded as it lands so the UI can render the story
                // top-down; the terminal `.verified` carries the same
                // chapters folded into a VerifiedAnswer for legacy
                // callers (EvalKit, the chat-shaped path).
                if let reconstructed = await self.tryReconstructHistoryStreaming(
                    question: question,
                    yield: { continuation.yield($0) }
                ) {
                    continuation.yield(.verified(reconstructed))
                    continuation.finish()
                    return
                }

                let final = await self.computeVerified(question: question)
                continuation.yield(.verified(final))
                continuation.finish()
            }
        }
    }

    /// HISTORY Phase D.6 + D.7 — reconstructive intent fast-path.
    /// Returns nil when the intent isn't reconstructive OR when the
    /// composer isn't wired so the caller falls through to the
    /// legacy expert pipeline.
    private func tryReconstructHistoryStreaming(
        question: String,
        yield: @Sendable (AnswerUpdate) -> Void
    ) async -> VerifiedAnswer? {
        guard let narrativeComposer,
              let eventsRepo,
              let intentDetector,
              let router,
              let retriever else {
            return nil
        }
        guard let intent = try? await intentDetector.detect(question: question) else {
            return nil
        }
        switch intent.kind {
        case .reconstructTimeline, .reconstructProject, .reconstructRelationship:
            break
        default:
            return nil
        }

        await sessionProfile?.recordTurn(
            question: question,
            intentKind: intent.kind.rawValue,
            entityHints: intent.entityHints
        )

        let decision = (try? await router.route(intent: intent)) ?? RoutingDecision(
            answerSpec: CapabilitySpec.reasoning(contextTokens: 6_000, purpose: "history.narrative"),
            expertIDs: [],
            retrievalLayers: RetrievalLayer.priorityOrder,
            parallelism: 1,
            complexity: 4,
            rationale: "Reconstructive intent — narrative path"
        )

        let retrieval = (try? await retriever.retrieve(
            for: intent,
            layers: decision.retrievalLayers
        )) ?? RetrievalResult()

        // Hydrate 5W+H slot bundles for the composer's input.
        let slotBundles = (try? await eventsRepo.narrativeSlots(
            forEventIDs: retrieval.events.map(\.id)
        )) ?? [:]

        // HISTORY Phase D.10 — true streaming. Consume the
        // composer's AsyncStream so each chapter is yielded into
        // AnswerUpdate.chapterReady the instant it finishes
        // composing instead of waiting for the whole narrative.
        var narrative: ReconstructedNarrative?
        var failureReason: String?
        let stream = narrativeComposer.composeStreaming(
            intent: intent,
            retrieval: retrieval,
            eventSlots: slotBundles
        )
        for await event in stream {
            switch event {
            case .chapter(let chapter):
                yield(.chapterReady(chapter))
            case .completed(let result):
                narrative = result
            case .failed(let reason):
                failureReason = reason
            }
        }
        guard let narrative else {
            return VerifiedAnswer(
                body: "Atlas couldn't reconstruct that history.",
                citations: [],
                confidence: .zero,
                refused: true,
                refusalReason: "Composer failed: \(failureReason ?? "unknown")"
            )
        }

        // Fold the narrative into a VerifiedAnswer the legacy
        // callers (EvalKit, old UI) can consume unchanged.
        let body = Self.foldNarrativeToBody(narrative)
        let contradictions = narrative.chapters.flatMap(\.contradictions)
        let chapterConfs = narrative.chapters.map(\.confidence)
        let avgConf = chapterConfs.isEmpty ? 0.4
            : chapterConfs.reduce(0, +) / Double(chapterConfs.count)
        return VerifiedAnswer(
            body: body,
            answerText: body,
            intentKind: intent.kind.rawValue,
            citations: narrative.citations,
            confidence: Confidence(avgConf),
            contradictions: contradictions,
            refused: false,
            refusalReason: nil,
            report: nil,
            walkSteps: retrieval.walkSteps
        )
    }

    /// Fold a ReconstructedNarrative into a plain-text body for
    /// legacy `VerifiedAnswer.body` callers. The new NarrativeView
    /// (Phase E) renders from `narrative.chapters` directly and
    /// doesn't use this; EvalKit + the chat-shaped UI do.
    private static func foldNarrativeToBody(_ narrative: ReconstructedNarrative) -> String {
        var out: [String] = [narrative.title, "", narrative.summary]
        if !narrative.downgrades.isEmpty {
            out.append("")
            out.append("(\(narrative.downgrades.joined(separator: "; ")))")
        }
        for chapter in narrative.chapters {
            out.append("")
            out.append("## \(chapter.title)")
            if let subtitle = chapter.subtitle, !subtitle.isEmpty {
                out.append("_\(subtitle)_")
            }
            if !chapter.prose.isEmpty {
                out.append(chapter.prose)
            } else {
                out.append("(No prose available for this chapter — \(chapter.eventIDs.count) events recorded.)")
            }
            for contradiction in chapter.contradictions {
                out.append("⚠️ \(contradiction.description): \"\(contradiction.claimA)\" vs \"\(contradiction.claimB)\"")
            }
        }
        return out.joined(separator: "\n")
    }

    /// Phase 1 cache probe. Returns an `.instant` update only when:
    ///   1. A MemoryRepository is wired (caller opted in)
    ///   2. Intent detection produced a non-global scope
    ///   3. A MemoryObject for that subject exists AND its narrative
    ///      shares at least one entity hint with the question (a weak
    ///      relevance gate so stale memory doesn't pollute Phase 1)
    private func phase1Instant(question: String) async -> AnswerUpdate? {
        guard let memoryRepo, let intentDetector else { return nil }
        guard let intent = try? await intentDetector.detect(question: question) else {
            return nil
        }
        let resolved: (MemoryObject.SubjectKind, String)?
        switch intent.scope {
        case .project(let n): resolved = (.project, n)
        case .organization(let n): resolved = (.organization, n)
        case .person(let n): resolved = (.person, n)
        case .global, .folder: resolved = nil
        }
        guard let (kind, identifier) = resolved,
              let memory = try? await memoryRepo.current(forSubject: kind, identifier: identifier),
              !memory.narrative.isEmpty
        else { return nil }

        // Cache-match gate: require at least one entity-hint overlap
        // (case-insensitive) so a stale narrative doesn't pollute Phase 1.
        let narrativeLower = memory.narrative.lowercased()
        let hits = intent.entityHints.contains { hint in
            narrativeLower.contains(hint.lowercased())
        }
        guard hits || !intent.entityHints.isEmpty == false else { return nil }
        guard hits else { return nil }

        return .instant(body: memory.narrative, citations: [])
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
