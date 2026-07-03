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
    /// Phase J.2 — typed causal links repo. Optional; when present
    /// the global ContradictionFinder runs over the retrieval set's
    /// links so cross-chapter conflicts (cycles, opposing claims)
    /// surface alongside per-chapter contradictions. Nil = the
    /// finder only sees date conflicts (degraded but still useful).
    private let eventLinks: EventLinksRepository?
    /// Ledger-first on-demand memory warming. When present, the brain
    /// distills the memory for the entities a question is ABOUT — in the
    /// background, fire-and-forget — so the next ask about them has a
    /// memory object. This is the complement to ingest-time distillation
    /// being off: cold data stays cheap, asked-about data warms lazily.
    private let onDemandDistiller: MemoryDistiller?
    /// Entities already warmed this session, so repeated questions about
    /// the same subject don't re-distill it.
    private var warmedEntities: Set<String> = []

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
        eventsRepo: EventsRepository? = nil,
        eventLinks: EventLinksRepository? = nil,
        onDemandDistiller: MemoryDistiller? = nil
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
        self.eventLinks = eventLinks
        self.onDemandDistiller = onDemandDistiller
    }

    /// Fire-and-forget: warm memory for the question's entities (once per
    /// session each). No latency to the current answer — the ledger
    /// layers already cover it; this just enriches future asks. Skips
    /// automatically when the reasoning provider is on cooldown.
    private func warmMemoryOnDemand(for hints: [String]) {
        guard let onDemandDistiller, !hints.isEmpty else { return }
        let fresh = hints.filter { !warmedEntities.contains($0.lowercased()) }
        guard !fresh.isEmpty else { return }
        fresh.forEach { warmedEntities.insert($0.lowercased()) }
        Task.detached(priority: .utility) {
            _ = try? await onDemandDistiller.distillSubjects(forEntities: fresh)
        }
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
            // Composer crashed outright — try the chunk RAG fallback
            // before refusing. Gives the user the "normal AI" answer
            // shape even when structured reconstruction can't fire.
            if let rag = await chunkBasedFallback(
                question: question, intent: intent, retrieval: retrieval
            ) {
                return rag
            }
            return VerifiedAnswer(
                body: "Atlas couldn't reconstruct that history.",
                citations: [],
                confidence: .zero,
                refused: true,
                refusalReason: "Composer failed: \(failureReason ?? "unknown")"
            )
        }

        // Quality gate: if the composer produced no chapters OR every
        // chapter has empty prose (verifier stripped everything),
        // fall through to the chunk RAG path so the user gets a
        // grounded answer instead of a header-only narrative.
        let hasUsefulChapters = narrative.chapters.contains { !$0.prose.isEmpty }
        if !hasUsefulChapters {
            if let rag = await chunkBasedFallback(
                question: question, intent: intent, retrieval: retrieval
            ) {
                return rag
            }
        }

        // Fold the narrative into a VerifiedAnswer the legacy
        // callers (EvalKit, old UI) can consume unchanged.
        let body = Self.foldNarrativeToBody(narrative)
        // Phase J.2 — global Contradiction Finder. Runs over the
        // retrieval set + the causal links touching it so date
        // conflicts that cross chapter boundaries, causal cycles,
        // and opposing causal claims all surface alongside the
        // per-chapter contradictions the verifier already caught.
        let perChapter = narrative.chapters.flatMap(\.contradictions)
        let crossChapter = await Self.findCrossRetrievalContradictions(
            events: retrieval.events,
            eventLinks: eventLinks
        )
        let contradictions = Self.dedupeContradictions(perChapter + crossChapter)
        let chapterConfs = narrative.chapters.map(\.confidence)
        let avgConf = chapterConfs.isEmpty ? 0.4
            : chapterConfs.reduce(0, +) / Double(chapterConfs.count)
        // Phase J.1 — capture the reasoning trace. The fields the brain
        // already knows about (intent, retrieval shape, walk steps,
        // contradictions, downgrades) feed the trace verbatim; the
        // path label is the canonical "historical reconstruction".
        let category = QueryCategoryClassifier().classify(question: question, intent: intent)
        let trace = ReasoningTrace(
            pathTaken: ReasoningTrace.pathHistorical,
            intent: intent.kind.rawValue,
            queryCategory: category.rawValue,
            retrievalLayers: retrieval.layersUsed.map(\.rawValue),
            shortCircuitedAt: retrieval.shortCircuitedAt?.rawValue,
            expertIDs: decision.expertIDs,
            llmPurposes: [
                "history.narrative",
                "history.community.summary",
                "history.slot.extract"
            ],
            retrievalCounts: ReasoningTrace.RetrievalCounts(
                events: retrieval.events.count,
                entities: retrieval.entities.count,
                chunks: retrieval.chunks.count,
                relationships: retrieval.relationships.count,
                summaries: retrieval.summaries.count,
                walkSteps: retrieval.walkSteps.count
            ),
            assumptions: Self.assumptionsFromNarrative(narrative),
            uncertainties: contradictions.map(\.description)
        )
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
            walkSteps: retrieval.walkSteps,
            source: .historical,
            reasoningTrace: trace
        )
    }

    /// Phase J.2 — call the ContradictionFinder on the retrieval set
    /// + the causal links touching it. Static so the call site can
    /// be `await Self.findCrossRetrievalContradictions(...)` from
    /// within actor-isolated code without re-entry; the actual work
    /// is async only because the link fetch is.
    nonisolated static func findCrossRetrievalContradictions(
        events: [Event],
        eventLinks: EventLinksRepository?
    ) async -> [VerifiedAnswer.Contradiction] {
        guard !events.isEmpty else { return [] }
        let links: [CausalLink]
        if let eventLinks {
            links = (try? await eventLinks.links(in: events.map(\.id))) ?? []
        } else {
            links = []
        }
        let finder = ContradictionFinder()
        return finder.find(events: events, links: links)
    }

    /// De-dupe contradictions by their (description, claimA, claimB)
    /// triple so the per-chapter + cross-chapter passes can be
    /// concatenated without showing the same conflict twice.
    nonisolated static func dedupeContradictions(
        _ contradictions: [VerifiedAnswer.Contradiction]
    ) -> [VerifiedAnswer.Contradiction] {
        var seen: Set<String> = []
        return contradictions.filter { c in
            let key = "\(c.description)|\(c.claimA)|\(c.claimB)"
            return seen.insert(key).inserted
        }
    }

    /// Pull free-text assumptions / downgrades from the composed
    /// narrative. These surface in the trace's "what we noticed"
    /// list so the user understands the answer's edges.
    nonisolated private static func assumptionsFromNarrative(
        _ narrative: ReconstructedNarrative
    ) -> [String] {
        var out: [String] = []
        let empties = narrative.chapters.filter { $0.prose.isEmpty }
        if !empties.isEmpty {
            out.append("\(empties.count) chapter(s) had no grounded prose and were rendered as bullets only")
        }
        let lowConf = narrative.chapters.filter { $0.confidence < 0.5 }
        if !lowConf.isEmpty {
            out.append("\(lowConf.count) chapter(s) shipped with < 50% confidence")
        }
        if !narrative.downgrades.isEmpty {
            out.append(contentsOf: narrative.downgrades)
        }
        if narrative.coverage.largestGapDays > 365 {
            out.append("Largest temporal gap is \(narrative.coverage.largestGapDays) days — coverage is sparse")
        }
        return out
    }

    /// "Normal AI" RAG fallback. When the structured composer can't
    /// produce useful chapters (no events match, or every chapter's
    /// prose got stripped by the verifier), we still want to give
    /// the user *something* grounded in their archive — the same
    /// thing a generic ChatGPT-with-files setup would do.
    ///
    /// Strategy: take the top retrieved chunks, label them `[C1]`,
    /// `[C2]`, …, hand them to the reasoning provider with strict
    /// "answer only from these chunks, cite labels inline, refuse
    /// honestly if you can't" instructions. Parse the labels back
    /// out into `VerifiedAnswer.Citation` rows keyed on chunk + KO
    /// so the UI's source-clickthrough still works.
    ///
    /// Quality-or-nothing: returns nil when no provider is available
    /// or no chunks were retrieved. The caller falls back to the
    /// existing "Atlas couldn't reconstruct" refusal in those cases.
    private func chunkBasedFallback(
        question: String,
        intent: UserIntent,
        retrieval: RetrievalResult
    ) async -> VerifiedAnswer? {
        guard let capabilities else { return nil }
        let spec = CapabilitySpec.reasoning(
            contextTokens: 8_000,
            purpose: "history.chunk.fallback"
        )
        let provider: any ModelProvider
        do {
            provider = try await capabilities.resolve(spec)
        } catch {
            return nil
        }
        guard await provider.isAvailable() else { return nil }

        // Top chunks first; cap at 12 to leave room in the prompt
        // budget for instruction + answer tokens.
        let topChunks = Array(retrieval.chunks.prefix(12))
        guard !topChunks.isEmpty else { return nil }

        let blocks = topChunks.enumerated().map { idx, c -> String in
            let label = "[C\(idx + 1)]"
            let snippet = c.chunk.text
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(600)
            return "\(label) \(snippet)"
        }.joined(separator: "\n\n")

        let prompt = """
        Question: \(question)

        Use ONLY the chunks below to answer. After every fact, cite the chunk label like [C3]. If the chunks don't contain enough information to answer, say "I don't have enough in your archive to answer this confidently." — do not invent.

        Chunks:
        \(blocks)

        Answer:
        """
        let options = GenerationOptions(
            maxTokens: 500,
            temperature: 0.2,
            systemPrompt: "You are an evidence-grounded research assistant. Cite chunk labels inline like [C3]. Refuse honestly when the chunks lack the answer."
        )

        let response: String
        do {
            response = try await provider.generate(prompt: prompt, options: options)
        } catch {
            return nil
        }
        let body = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }

        // Map [C?] labels back to chunk + KO ids for clickable
        // citations. De-duped by chunk id so the UI doesn't show
        // the same source twice.
        var citations: [VerifiedAnswer.Citation] = []
        var seenChunks: Set<Chunk.ID> = []
        if let regex = try? NSRegularExpression(pattern: #"\[C(\d+)\]"#) {
            let ns = body as NSString
            for m in regex.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
                guard m.numberOfRanges >= 2 else { continue }
                let nStr = ns.substring(with: m.range(at: 1))
                guard let n = Int(nStr), n >= 1, n <= topChunks.count else { continue }
                let chunk = topChunks[n - 1]
                guard seenChunks.insert(chunk.chunk.id).inserted else { continue }
                citations.append(
                    VerifiedAnswer.Citation(
                        objectID: chunk.chunk.objectID,
                        chunkID: chunk.chunk.id,
                        eventID: nil,
                        snippet: String(chunk.chunk.text.prefix(160))
                    )
                )
            }
        }

        let refusedShape = body.lowercased().contains("don't have enough")
            || body.lowercased().contains("not enough")
        let conf: Double = {
            if refusedShape { return 0.2 }
            if citations.isEmpty { return 0.3 }
            return 0.55
        }()
        let category = QueryCategoryClassifier().classify(question: question, intent: intent)
        let trace = ReasoningTrace(
            pathTaken: ReasoningTrace.pathChunkRAG,
            intent: intent.kind.rawValue,
            queryCategory: category.rawValue,
            retrievalLayers: retrieval.layersUsed.map(\.rawValue),
            shortCircuitedAt: retrieval.shortCircuitedAt?.rawValue,
            expertIDs: [],
            llmPurposes: ["history.chunk.fallback"],
            retrievalCounts: ReasoningTrace.RetrievalCounts(
                events: retrieval.events.count,
                entities: retrieval.entities.count,
                chunks: retrieval.chunks.count,
                relationships: retrieval.relationships.count,
                summaries: retrieval.summaries.count,
                walkSteps: retrieval.walkSteps.count
            ),
            assumptions: [
                "Used the chunk-RAG fallback because structured reconstruction produced no usable chapters.",
                citations.isEmpty
                    ? "No chunk labels in the response — the model didn't cite."
                    : "\(citations.count) chunk(s) cited inline."
            ],
            uncertainties: refusedShape
                ? ["Model said the archive lacks the answer."]
                : []
        )
        return VerifiedAnswer(
            body: body,
            answerText: body,
            intentKind: intent.kind.rawValue,
            citations: citations,
            confidence: Confidence(conf),
            contradictions: [],
            refused: refusedShape && citations.isEmpty,
            refusalReason: refusedShape ? "Chunk RAG fallback couldn't ground an answer." : nil,
            report: nil,
            walkSteps: retrieval.walkSteps,
            source: .ragFallback,
            reasoningTrace: trace
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

        // Ledger-first: warm memory for what the user actually asked
        // about, in the background. Complements ingest-time distillation
        // being off — cold entities stay cheap; asked-about ones enrich.
        warmMemoryOnDemand(for: intent.entityHints)

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

        let verified: VerifiedAnswer
        do {
            verified = try await verifier.verify(
                intent: intent,
                findings: findings,
                retrieval: retrievalForVerifier
            )
        } catch {
            // Verifier itself crashed — chunk RAG fallback so we
            // still hand the user *something* instead of a refusal.
            if let rag = await chunkBasedFallback(
                question: question, intent: intent, retrieval: retrievalForVerifier
            ) {
                return rag
            }
            return VerifiedAnswer(
                body: "Atlas couldn't verify a response.",
                citations: [],
                confidence: .zero,
                refused: true,
                refusalReason: "Verification failed: \(error)"
            )
        }

        // If the expert pipeline returned a refusal OR landed with
        // zero citations, try the chunk RAG fallback. Mimics the
        // generic AI-with-files experience: when structured experts
        // can't ground a claim, fall through to chunks. Only kicks
        // in when the verifier explicitly refused or surfaced no
        // sources — confident answers with citations pass through.
        if verified.refused || verified.citations.isEmpty {
            if let rag = await chunkBasedFallback(
                question: question, intent: intent, retrieval: retrievalForVerifier
            ), !rag.refused {
                return rag
            }
        }
        // Tag the expert-pipeline answer with `.experts` so the UI
        // can distinguish it from the historical / RAG paths. The
        // existing Verifier doesn't set `source`, so we re-emit
        // the value with the field stamped in.
        let category = QueryCategoryClassifier().classify(question: question, intent: intent)
        let trace = ReasoningTrace(
            pathTaken: ReasoningTrace.pathExpertPipeline,
            intent: intent.kind.rawValue,
            queryCategory: category.rawValue,
            retrievalLayers: sharedRetrieval.layersUsed.map(\.rawValue),
            shortCircuitedAt: sharedRetrieval.shortCircuitedAt?.rawValue,
            expertIDs: decision.expertIDs,
            llmPurposes: findings.map { "expert.\($0.expertID)" },
            retrievalCounts: ReasoningTrace.RetrievalCounts(
                events: sharedRetrieval.events.count,
                entities: sharedRetrieval.entities.count,
                chunks: sharedRetrieval.chunks.count,
                relationships: sharedRetrieval.relationships.count,
                summaries: sharedRetrieval.summaries.count,
                walkSteps: sharedRetrieval.walkSteps.count
            ),
            assumptions: Self.assumptionsFromExpertReport(verified),
            uncertainties: verified.contradictions.map(\.description)
        )

        // Apple AI is the brain: when a generative model resolves (i.e. NOT
        // the fully-private no-LLM mode), let it compose the final answer
        // prose from the experts' verified findings — the experts are the
        // helpers that supply grounded facts + citations, the model only
        // presents them. Offline / no model → keep the deterministic body.
        var synthesizedBody: String? = nil
        if FeatureFlags.llmAnswerSynthesisValue(),
           !verified.refused, !verified.citations.isEmpty {
            synthesizedBody = await AnswerSynthesizer().synthesize(
                question: question,
                verifiedBody: verified.body,
                citations: verified.citations,
                capabilities: capabilities
            )
        }
        return Self.tag(verified, as: .experts, trace: trace, bodyOverride: synthesizedBody)
    }

    /// Pull free-text assumptions / downgrades from the verifier's
    /// ConfidenceReport when present. Mirrors `assumptionsFromNarrative`
    /// for the expert-pipeline path.
    nonisolated private static func assumptionsFromExpertReport(_ a: VerifiedAnswer) -> [String] {
        var out: [String] = []
        if let report = a.report {
            if report.droppedUnverifiable > 0 {
                out.append("\(report.droppedUnverifiable) LLM claim(s) dropped — their cited evidence didn't resolve against the retrieval set.")
            }
            if report.distinctSourceObjectIDs < 2 {
                out.append("Only \(report.distinctSourceObjectIDs) distinct source(s) backed the answer — corroboration is thin.")
            }
            if report.agreementScore < 0.6 && report.sourceCount > 1 {
                out.append(String(format: "Cross-source agreement was %.0f%% — the verifier softened confidence.", report.agreementScore * 100))
            }
        }
        if a.citations.isEmpty {
            out.append("No citations attached — answer is ungrounded.")
        }
        return out
    }

    private static func tag(_ a: VerifiedAnswer, as source: AnswerSource, trace: ReasoningTrace? = nil, bodyOverride: String? = nil) -> VerifiedAnswer {
        VerifiedAnswer(
            body: bodyOverride ?? a.body,
            answerText: a.answerText,
            intentKind: a.intentKind,
            citations: a.citations,
            confidence: a.confidence,
            contradictions: a.contradictions,
            refused: a.refused,
            refusalReason: a.refusalReason,
            report: a.report,
            walkSteps: a.walkSteps,
            source: source,
            reasoningTrace: trace ?? a.reasoningTrace,
            answerState: a.answerState == .unknown ? deriveAnswerState(a) : a.answerState
        )
    }

    /// Ledger-AI v28 answerability gate — resolve the closed-corpus
    /// answer state from the verified answer's evidence shape. Pure and
    /// deterministic (no extra LLM): the contract is "no citation, no
    /// factual claim", so an answer with no citations is NOT_FOUND
    /// regardless of how fluent the prose is.
    ///
    ///  - refused / zero citations        → notFound
    ///  - conflicting sources             → contradicted
    ///  - corpus materially un-indexed    → insufficientlyIndexed
    ///  - ≥2 distinct sources + confident → supported
    ///  - otherwise                       → partiallySupported
    nonisolated private static func deriveAnswerState(_ a: VerifiedAnswer) -> AnswerState {
        if a.refused || a.citations.isEmpty { return .notFound }
        if !a.contradictions.isEmpty { return .contradicted }
        if let report = a.report, report.ingestCoverage < 0.85 {
            return .insufficientlyIndexed
        }
        let distinctSources = a.report?.distinctSourceObjectIDs
            ?? Set(a.citations.map(\.objectID)).count
        if distinctSources >= 2 && a.confidence.value >= 0.6 {
            return .supported
        }
        return .partiallySupported
    }
}
