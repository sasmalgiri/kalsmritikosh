//
//  LLMNarrativeComposer.swift
//  Kalsmritikosh
//
//  HISTORY Phase D.3 — generates chapter prose by feeding the
//  chronological plan into an LLM, one chapter at a time.
//
//  Strategy per chapter:
//    1. Render each event as a labeled 5W+H block: `[E1] WHO=… WHAT=…
//       WHEN=… …` so the model has structured facts to lean on.
//    2. Ask the model for 2–3 paragraphs of chronological prose
//       interleaving the labels — instruct it to wrap citations like
//       `[E3]` after each sentence that draws on event E3.
//    3. Parse `[E?]` tokens from the response into per-sentence
//       NarrativeClaimCitation rows pointing at the corresponding
//       Event.IDs (and their sourceObjectIDs).
//
//  Quality-or-nothing:
//    - No `.reasoning` capability available → return a downgrade
//      narrative whose chapters carry empty prose. The brain then
//      falls through to `RuleBasedNarrativeComposer` (Phase D.8).
//    - Model returns empty / un-parseable text for a chapter → that
//      chapter's prose stays empty; the rest of the narrative ships.
//    - Generated sentence has no `[E?]` token → the citation
//      verifier (Phase D.4) drops the sentence rather than letting
//      ungrounded prose ship.
//
//  Capability discipline: NO model names referenced. The composer
//  asks the registry for `.reasoning` and runs whatever provider
//  the privacy gate clears for that purpose.
//

import Foundation
import OSLog

public actor LLMNarrativeComposer: NarrativeComposer {
    private let planner: ChronologicalPlanner
    private let capabilities: CapabilityRegistry
    private let objectsRepo: KnowledgeObjectRepository?
    private let maxChapters: Int
    private let verifier: NarrativeClaimVerifier
    /// Phase G.5 — optional. When wired, the composer pulls the
    /// causal links touching each chapter's events and stamps them
    /// on the resulting NarrativeChapter so the UI surface can
    /// render the causal-chain badge. Nil = no causal text.
    private let links: EventLinksRepository?

    public init(
        planner: ChronologicalPlanner,
        capabilities: CapabilityRegistry,
        objectsRepo: KnowledgeObjectRepository? = nil,
        maxChapters: Int = 8,
        verifier: NarrativeClaimVerifier = NarrativeClaimVerifier(),
        links: EventLinksRepository? = nil
    ) {
        self.planner = planner
        self.capabilities = capabilities
        self.objectsRepo = objectsRepo
        self.maxChapters = maxChapters
        self.verifier = verifier
        self.links = links
    }

    /// HISTORY Phase D.7 true-streaming entry point. Yields each
    /// chapter as the LLM finishes it (instead of batching them
    /// all at the end like the default protocol implementation).
    /// The brain re-emits via `AnswerUpdate.chapterReady`.
    public nonisolated func composeStreaming(
        intent: UserIntent,
        retrieval: RetrievalResult,
        eventSlots: [Event.ID: EventNarrativeSlots]
    ) -> AsyncStream<NarrativeStreamEvent> {
        AsyncStream { continuation in
            Task {
                let result = await self.runStreaming(
                    intent: intent,
                    retrieval: retrieval,
                    eventSlots: eventSlots,
                    yield: { continuation.yield($0) }
                )
                continuation.yield(.completed(result))
                continuation.finish()
            }
        }
    }

    /// Body of the streaming entry — runs inside the actor so we can
    /// touch `planner` and `verifier`. Yields each chapter via the
    /// passed-in closure right after it finishes verifying.
    private func runStreaming(
        intent: UserIntent,
        retrieval: RetrievalResult,
        eventSlots: [Event.ID: EventNarrativeSlots],
        yield: @Sendable (NarrativeStreamEvent) -> Void
    ) async -> ReconstructedNarrative {
        let scope = Self.scope(from: intent)
        var downgrades: [String] = []

        let plannedChapters = await planner.plan(events: retrieval.events)
        let limited = Array(plannedChapters.prefix(maxChapters))
        if plannedChapters.count > maxChapters {
            downgrades.append("Capped at \(maxChapters) of \(plannedChapters.count) chapters")
        }

        let spec = CapabilitySpec.reasoning(
            contextTokens: 6_000,
            purpose: "history.narrative.compose"
        )
        let provider: (any ModelProvider)?
        do {
            let p = try await capabilities.resolve(spec)
            provider = await p.isAvailable() ? p : nil
        } catch {
            provider = nil
        }
        if provider == nil {
            downgrades.append("No reasoning provider available — chapters ship without LLM prose")
        }

        var chapters: [NarrativeChapter] = []
        for planned in limited {
            let composed = await composeChapter(
                planned: planned,
                eventSlots: eventSlots,
                provider: provider,
                scope: scope
            )
            let verified = verifier.verify(chapter: composed, events: planned.events)
            chapters.append(verified)
            // Yield right after verification so the UI gets the
            // chapter the instant it's safe to show.
            yield(.chapter(verified))
        }

        let coverage = Self.coverage(over: chapters)
        let title = Self.title(for: scope, chapters: chapters)
        let summary = Self.summary(chapters: chapters, scope: scope)
        let citations = Self.flattenCitations(chapters: chapters, slots: eventSlots)
        return ReconstructedNarrative(
            title: title,
            summary: summary,
            scope: scope,
            chapters: chapters,
            coverage: coverage,
            citations: citations,
            downgrades: downgrades
        )
    }

    public func compose(
        intent: UserIntent,
        retrieval: RetrievalResult,
        eventSlots: [Event.ID: EventNarrativeSlots]
    ) async throws -> ReconstructedNarrative {

        let scope = Self.scope(from: intent)
        var downgrades: [String] = []

        // Plan chapters from the retrieved events.
        let plannedChapters = await planner.plan(events: retrieval.events)
        let limited = Array(plannedChapters.prefix(maxChapters))
        if plannedChapters.count > maxChapters {
            downgrades.append("Capped at \(maxChapters) of \(plannedChapters.count) chapters")
        }

        // Resolve the .reasoning provider once.
        let spec = CapabilitySpec.reasoning(
            contextTokens: 6_000,
            purpose: "history.narrative.compose"
        )
        let provider: (any ModelProvider)?
        do {
            let p = try await capabilities.resolve(spec)
            provider = await p.isAvailable() ? p : nil
        } catch {
            provider = nil
        }
        if provider == nil {
            downgrades.append("No reasoning provider available — chapters ship without LLM prose")
        }

        // Compose chapter by chapter, verifying citations + surfacing
        // contradictions immediately so each chapter ships in a
        // self-contained verified state (matters for D.7 streaming).
        var chapters: [NarrativeChapter] = []
        for planned in limited {
            let composed = await composeChapter(
                planned: planned,
                eventSlots: eventSlots,
                provider: provider,
                scope: scope
            )
            let verified = verifier.verify(chapter: composed, events: planned.events)
            chapters.append(verified)
        }

        // Build coverage diagnostics.
        let coverage = Self.coverage(over: chapters)
        let title = Self.title(for: scope, chapters: chapters)
        let summary = Self.summary(chapters: chapters, scope: scope)
        let citations = Self.flattenCitations(chapters: chapters, slots: eventSlots)

        return ReconstructedNarrative(
            title: title,
            summary: summary,
            scope: scope,
            chapters: chapters,
            coverage: coverage,
            citations: citations,
            downgrades: downgrades
        )
    }

    // MARK: - Chapter composition

    private func composeChapter(
        planned: ChronologicalPlanner.PlannedChapter,
        eventSlots: [Event.ID: EventNarrativeSlots],
        provider: (any ModelProvider)?,
        scope: NarrativeScope
    ) async -> NarrativeChapter {
        let title = Self.chapterTitle(planned: planned)
        let subtitle = planned.topicTitle
        let eventIDs = planned.events.map(\.id)

        // Build labeled blocks for the model.
        let blocks = planned.events.enumerated().map { (idx, event) -> String in
            let label = "[E\(idx + 1)]"
            let slots = eventSlots[event.id] ?? .empty
            return Self.renderEventBlock(label: label, event: event, slots: slots)
        }
        let blockText = blocks.joined(separator: "\n\n")

        // No provider → empty prose, but ship the chapter.
        guard let provider else {
            return NarrativeChapter(
                title: title,
                subtitle: subtitle,
                timeframeStart: planned.timeframeStart,
                timeframeEnd: planned.timeframeEnd,
                eventIDs: eventIDs,
                topicCommunityID: planned.topicCommunityID,
                prose: "",
                claimCitations: [],
                contradictions: [],
                confidence: 0.2
            )
        }

        let prompt = Self.prompt(
            scope: scope,
            chapterTitle: title,
            subtitle: subtitle,
            timeframeStart: planned.timeframeStart,
            timeframeEnd: planned.timeframeEnd,
            blockText: blockText,
            eventCount: planned.events.count
        )
        let options = GenerationOptions(
            maxTokens: 360,
            temperature: 0.25,
            systemPrompt: "You are a precise narrative historian. Ground every sentence in the events provided. Cite each fact inline like [E3]. Do not invent facts not present in the events."
        )

        let response: String
        do {
            response = try await provider.generate(prompt: prompt, options: options)
        } catch {
            AtlasLog.knowledge.error("LLMNarrativeComposer: generate failed — \(String(describing: error), privacy: .public)")
            return NarrativeChapter(
                title: title,
                subtitle: subtitle,
                timeframeStart: planned.timeframeStart,
                timeframeEnd: planned.timeframeEnd,
                eventIDs: eventIDs,
                topicCommunityID: planned.topicCommunityID,
                prose: "",
                claimCitations: [],
                contradictions: [],
                confidence: 0.2
            )
        }

        let prose = Self.cleanProse(response)
        if prose.isEmpty {
            return NarrativeChapter(
                title: title,
                subtitle: subtitle,
                timeframeStart: planned.timeframeStart,
                timeframeEnd: planned.timeframeEnd,
                eventIDs: eventIDs,
                topicCommunityID: planned.topicCommunityID,
                prose: "",
                claimCitations: [],
                contradictions: [],
                confidence: 0.2
            )
        }

        let claimCitations = Self.parseClaimCitations(
            prose: prose,
            events: planned.events,
            slots: eventSlots
        )
        let confidence = Self.chapterConfidence(
            events: planned.events,
            slots: eventSlots,
            citationCoverage: claimCitations.count
        )

        // Phase G.5 — read causal links touching this chapter's events
        // so the UI badge surface can render the chain. We don't
        // splice a causal coda into the LLM prose (the model already
        // wrote prose using the events directly); the badge lives on
        // the chapter struct and is shown next to the citation row.
        var chapterCausalLinks: [CausalLink] = []
        if let links {
            let chapterEventSet = Set(eventIDs)
            let raw = (try? await links.links(in: eventIDs)) ?? []
            chapterCausalLinks = raw.filter {
                chapterEventSet.contains($0.sourceEventID)
                && chapterEventSet.contains($0.targetEventID)
            }.sorted { $0.confidence > $1.confidence }
        }

        return NarrativeChapter(
            title: title,
            subtitle: subtitle,
            timeframeStart: planned.timeframeStart,
            timeframeEnd: planned.timeframeEnd,
            eventIDs: eventIDs,
            topicCommunityID: planned.topicCommunityID,
            prose: prose,
            claimCitations: claimCitations,
            contradictions: [],
            causalLinks: chapterCausalLinks,
            confidence: confidence
        )
    }

    // MARK: - Pure helpers (testable, no I/O)

    nonisolated static func renderEventBlock(
        label: String,
        event: Event,
        slots: EventNarrativeSlots
    ) -> String {
        var lines: [String] = ["\(label) \(event.title) (\(event.kind.rawValue))"]
        let date = ISO8601DateFormatter().string(from: event.date)
        lines.append("  WHEN: \(date)")
        if !slots.who.isEmpty {
            lines.append("  WHO: \(slots.who.map(\.text).joined(separator: ", "))")
        }
        if !slots.what.isEmpty {
            lines.append("  WHAT: \(slots.what.map(\.text).joined(separator: "; "))")
        }
        if !slots.whereAt.isEmpty {
            lines.append("  WHERE: \(slots.whereAt.map(\.text).joined(separator: ", "))")
        }
        if !slots.why.isEmpty {
            lines.append("  WHY: \(slots.why.map(\.text).joined(separator: "; "))")
        }
        if !slots.how.isEmpty {
            lines.append("  HOW: \(slots.how.map(\.text).joined(separator: ", "))")
        }
        if let summary = event.summary, !summary.isEmpty {
            lines.append("  SUMMARY: \(summary.prefix(200))")
        }
        return lines.joined(separator: "\n")
    }

    nonisolated static func prompt(
        scope: NarrativeScope,
        chapterTitle: String,
        subtitle: String?,
        timeframeStart: Date,
        timeframeEnd: Date,
        blockText: String,
        eventCount: Int
    ) -> String {
        let scopeLabel = Self.scopeLabel(scope)
        let topicLine = subtitle.map { "Topic: \($0)\n" } ?? ""
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let start = formatter.string(from: timeframeStart)
        let end = formatter.string(from: timeframeEnd)
        return """
        You are writing chapter "\(chapterTitle)" of a reconstructed history about \(scopeLabel).
        Timeframe: \(start) — \(end)
        \(topicLine)
        Use ONLY the \(eventCount) events below. After every sentence, place the labels (e.g. [E1] or [E2][E3]) of the events that sentence draws on. Do not invent people, dates, or outcomes that are not in the events. If two events disagree, mention the disagreement rather than picking one side.

        Events:
        \(blockText)

        Write 2–3 short paragraphs of chronological prose. Every sentence must end with at least one citation label. Skip any sentence you can't ground.
        """
    }

    private nonisolated static func scopeLabel(_ scope: NarrativeScope) -> String {
        switch scope {
        case .global: return "the user's archive"
        case .project(let name): return "the \(name) project"
        case .person(let name): return name
        case .organization(let name): return name
        case .folder(let name): return "the \(name) folder"
        case .topic(_, let title): return title
        }
    }

    nonisolated static func cleanProse(_ response: String) -> String {
        // Strip code fences and stray quotes; keep [E?] tokens.
        var out = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.hasPrefix("```") {
            out = String(out.drop { $0 != "\n" }).trimmingCharacters(in: .whitespacesAndNewlines)
            if let end = out.range(of: "```") {
                out = String(out[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return out
    }

    /// Walk the prose sentence-by-sentence, pulling `[E?]` tokens
    /// after each terminal punctuation. Maps to the chapter's
    /// `planned.events` by 1-based index.
    nonisolated static func parseClaimCitations(
        prose: String,
        events: [Event],
        slots: [Event.ID: EventNarrativeSlots]
    ) -> [NarrativeClaimCitation] {
        guard !prose.isEmpty, !events.isEmpty else { return [] }
        let sentences = splitSentences(prose)
        var out: [NarrativeClaimCitation] = []
        let labelRegex = try? NSRegularExpression(pattern: #"\[E(\d+)\]"#)
        for (idx, sentence) in sentences.enumerated() {
            guard let rx = labelRegex else { continue }
            let ns = sentence as NSString
            let matches = rx.matches(in: sentence, range: NSRange(location: 0, length: ns.length))
            var evIDs: [Event.ID] = []
            var objIDs: [KnowledgeObject.ID] = []
            for m in matches where m.numberOfRanges >= 2 {
                let nStr = ns.substring(with: m.range(at: 1))
                guard let n = Int(nStr), n >= 1, n <= events.count else { continue }
                let event = events[n - 1]
                if !evIDs.contains(event.id) {
                    evIDs.append(event.id)
                    objIDs.append(event.sourceObjectID)
                }
            }
            guard !evIDs.isEmpty else { continue }
            // Confidence: average of the cited events' dateConfidence
            // damped by quality tier weight.
            let confs = evIDs.compactMap { id -> Double? in
                guard let e = events.first(where: { $0.id == id }) else { return nil }
                return e.dateConfidence * e.qualityTier.defaultWeight
            }
            let avgConf = confs.isEmpty ? 0.5 : (confs.reduce(0, +) / Double(confs.count))
            out.append(
                NarrativeClaimCitation(
                    sentenceIndex: idx,
                    evidenceObjectIDs: objIDs,
                    evidenceEventIDs: evIDs,
                    confidence: avgConf
                )
            )
            _ = slots
        }
        return out
    }

    /// Sentence splitter: terminal punctuation (.!?) followed by
    /// whitespace, end-of-string, or a citation token. The
    /// whitespace check is critical — without it, periods INSIDE
    /// filenames ("Investigation.pdf") and inside paren-nested
    /// abbreviations (".com", "e.g.") split the sentence and the
    /// verifier downstream then strips the leading half as
    /// ungrounded because it lacks the citation token. Real-data
    /// audit (2026-06-28) caught this on forensic-PDF events whose
    /// titles end in ".pdf" — the prose rendered as "pdf) via
    /// email [E1]." with the leading half thrown away.
    ///
    /// Also tracks paren depth so periods inside `(...)` (file paths,
    /// inline asides) never split.
    nonisolated static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        var parenDepth = 0
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            current.append(c)
            if c == "(" || c == "[" || c == "{" { parenDepth += 1 }
            if c == ")" || c == "]" || c == "}" { parenDepth = max(0, parenDepth - 1) }
            if parenDepth == 0, c == "." || c == "!" || c == "?" {
                // Look ahead: only split when the next non-space char
                // is end-of-string, a newline, or a capital letter
                // (start of a new sentence) — NOT a lowercase letter
                // (filename / abbreviation) or a citation token.
                let next: Character? = (i + 1 < chars.count) ? chars[i + 1] : nil
                let isBoundary: Bool = {
                    guard let n = next else { return true }
                    if n.isWhitespace || n.isNewline { return true }
                    return false
                }()
                if isBoundary {
                    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { sentences.append(trimmed) }
                    current = ""
                }
            }
            i += 1
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }

    nonisolated static func chapterTitle(planned: ChronologicalPlanner.PlannedChapter) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        let start = formatter.string(from: planned.timeframeStart)
        let end = formatter.string(from: planned.timeframeEnd)
        let timePart = (start == end) ? start : "\(start) – \(end)"
        if let topic = planned.topicTitle, !topic.isEmpty {
            return "\(timePart) — \(topic)"
        }
        return timePart
    }

    nonisolated static func chapterConfidence(
        events: [Event],
        slots: [Event.ID: EventNarrativeSlots],
        citationCoverage: Int
    ) -> Double {
        guard !events.isEmpty else { return 0.0 }
        let avgDateConf = events.map(\.dateConfidence).reduce(0, +) / Double(events.count)
        let avgTier = events.map { $0.qualityTier.defaultWeight }.reduce(0, +) / Double(events.count)
        // Coverage: fraction of events that got cited at all. >0.5 is healthy.
        let coverage = events.isEmpty ? 0.0 : min(1.0, Double(citationCoverage) / Double(events.count))
        let slotDensity = events
            .map { slots[$0.id]?.filledSlotCount ?? 0 }
            .reduce(0, +)
        let densityBoost = min(0.2, Double(slotDensity) / Double(events.count * 6) * 0.4)
        let raw = (avgDateConf * 0.4) + (avgTier * 0.3) + (coverage * 0.2) + densityBoost
        return max(0.1, min(1.0, raw))
    }

    nonisolated static func coverage(over chapters: [NarrativeChapter]) -> NarrativeCoverage {
        let totalEvents = chapters.reduce(0) { $0 + $1.eventIDs.count }
        let earliest = chapters.map(\.timeframeStart).min()
        let latest = chapters.map(\.timeframeEnd).max()
        var largestGap = 0
        if chapters.count > 1 {
            let sorted = chapters.sorted { $0.timeframeStart < $1.timeframeStart }
            for i in 1..<sorted.count {
                let gap = Calendar.current.dateComponents(
                    [.day],
                    from: sorted[i - 1].timeframeEnd,
                    to: sorted[i].timeframeStart
                ).day ?? 0
                if gap > largestGap { largestGap = gap }
            }
        }
        return NarrativeCoverage(
            earliest: earliest,
            latest: latest,
            totalEvents: totalEvents,
            chapterCount: chapters.count,
            largestGapDays: largestGap
        )
    }

    nonisolated static func title(for scope: NarrativeScope, chapters: [NarrativeChapter]) -> String {
        let label = scopeLabel(scope)
        return chapters.isEmpty ? "No history found for \(label)" : "History of \(label)"
    }

    nonisolated static func summary(chapters: [NarrativeChapter], scope: NarrativeScope) -> String {
        guard !chapters.isEmpty else {
            return "No events matched the requested scope."
        }
        let count = chapters.reduce(0) { $0 + $1.eventIDs.count }
        let label = scopeLabel(scope)
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        let first = chapters.first?.timeframeStart.map(formatter.string(from:)) ?? ""
        let last = chapters.last?.timeframeEnd.map(formatter.string(from:)) ?? ""
        let span = (first == last) ? first : "\(first) – \(last)"
        return "Reconstructed \(count) events about \(label) across \(chapters.count) chapter\(chapters.count == 1 ? "" : "s") (\(span))."
    }

    nonisolated static func flattenCitations(
        chapters: [NarrativeChapter],
        slots: [Event.ID: EventNarrativeSlots]
    ) -> [VerifiedAnswer.Citation] {
        var seen: Set<UUID> = []
        var out: [VerifiedAnswer.Citation] = []
        for chapter in chapters {
            for claim in chapter.claimCitations {
                for (objID, evID) in zip(claim.evidenceObjectIDs, claim.evidenceEventIDs) {
                    let key = objID
                    if seen.insert(key).inserted {
                        out.append(
                            VerifiedAnswer.Citation(
                                objectID: objID,
                                chunkID: nil,
                                eventID: evID,
                                snippet: chapter.title
                            )
                        )
                    }
                    _ = slots
                }
            }
        }
        return out
    }

    nonisolated static func scope(from intent: UserIntent) -> NarrativeScope {
        switch intent.scope {
        case .global: return .global
        case .project(let n): return .project(n)
        case .person(let n): return .person(n)
        case .organization(let n): return .organization(n)
        case .folder(let n): return .folder(n)
        }
    }
}

private extension Date {
    /// Tiny helper so `chapters.first?.timeframeStart.map(formatter.string(from:))`
    /// reads cleanly. (Date doesn't have a built-in `map`.)
    nonisolated func map<T>(_ transform: (Date) -> T) -> T {
        transform(self)
    }
}
