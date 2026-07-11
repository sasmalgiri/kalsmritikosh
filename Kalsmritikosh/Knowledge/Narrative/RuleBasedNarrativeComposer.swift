//
//  RuleBasedNarrativeComposer.swift
//  Kalsmritikosh
//
//  HISTORY Phase D.8 — deterministic narrative composer that runs
//  WITHOUT an LLM. It assembles each chapter's prose by stitching
//  together templated sentences from the events' 5W+H slots.
//
//  Used when:
//    - No `.reasoning` provider is available (privacy gate clears
//      nothing, all models offline, fresh install).
//    - The LLM composer ran but every chapter dropped to empty
//      prose (verifier stripped all sentences).
//    - The MasterBrain wants a baseline to compare against the LLM
//      output during Phase F evaluation.
//
//  Quality-or-nothing still applies: events missing a WHO or WHAT
//  slot get rendered as bullet-style "On YYYY-MM-DD, an event of
//  kind K occurred" rather than fabricated narrative. The output is
//  blander than the LLM's but ALWAYS grounded.
//
//  Every produced sentence carries its own [E?] citation tag so the
//  verifier (D.4) leaves the prose alone — the rule composer is
//  effectively its own verifier.
//

import Foundation

public actor RuleBasedNarrativeComposer: NarrativeComposer {
    private let planner: ChronologicalPlanner
    private let verifier: NarrativeClaimVerifier
    private let maxChapters: Int
    /// Phase G.5 — optional. When wired, the composer looks up
    /// causal links touching each chapter's events and renders them
    /// as an inline coda ("This led to …"). Nil = no causal text;
    /// existing prose unchanged.
    private let links: EventLinksRepository?

    public init(
        planner: ChronologicalPlanner,
        verifier: NarrativeClaimVerifier = NarrativeClaimVerifier(),
        maxChapters: Int = 8,
        links: EventLinksRepository? = nil
    ) {
        self.planner = planner
        self.verifier = verifier
        self.maxChapters = maxChapters
        self.links = links
    }

    public func compose(
        intent: UserIntent,
        retrieval: RetrievalResult,
        eventSlots: [Event.ID: EventNarrativeSlots],
        context: LLMRequestContext? = nil
    ) async throws -> ReconstructedNarrative {
        // Rule-based composer makes NO LLM calls, so it ignores the budget.
        _ = context
        let scope = LLMNarrativeComposer.scope(from: intent)
        let planned = await planner.plan(events: retrieval.events)
        let limited = Array(planned.prefix(maxChapters))

        var chapters: [NarrativeChapter] = []
        for chapter in limited {
            let composed = await composeChapter(planned: chapter, slots: eventSlots)
            let verified = verifier.verify(chapter: composed, events: chapter.events)
            chapters.append(verified)
        }

        let coverage = LLMNarrativeComposer.coverage(over: chapters)
        let title = LLMNarrativeComposer.title(for: scope, chapters: chapters)
        let summary = LLMNarrativeComposer.summary(chapters: chapters, scope: scope)
        let citations = LLMNarrativeComposer.flattenCitations(chapters: chapters, slots: eventSlots)
        let downgrades = [
            "Rule-based composer used (no LLM call). Prose is templated."
        ]
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

    // MARK: - Per-chapter templating

    private func composeChapter(
        planned: ChronologicalPlanner.PlannedChapter,
        slots: [Event.ID: EventNarrativeSlots]
    ) async -> NarrativeChapter {
        let title = LLMNarrativeComposer.chapterTitle(planned: planned)
        let subtitle = planned.topicTitle

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"

        var sentences: [String] = []
        var claimCitations: [NarrativeClaimCitation] = []

        for (idx, event) in planned.events.enumerated() {
            let label = "[E\(idx + 1)]"
            let bundle = slots[event.id] ?? .empty
            let sentence = Self.render(event: event, slots: bundle, label: label, formatter: formatter)
            sentences.append(sentence)
            claimCitations.append(
                NarrativeClaimCitation(
                    sentenceIndex: sentences.count - 1,
                    evidenceObjectIDs: [event.sourceObjectID],
                    evidenceEventIDs: [event.id],
                    confidence: event.dateConfidence * event.qualityTier.defaultWeight
                )
            )
        }

        // Phase G.5 — pull causal links touching this chapter's events
        // and render a one-sentence coda summarizing the strongest
        // ones in causal-verb form. Composer reads at most 4 inline
        // (top-confidence first); the rest stay on the chapter for
        // the UI's expand-on-tap surface.
        var causalLinks: [CausalLink] = []
        if let links {
            let raw = (try? await links.links(in: planned.events.map(\.id))) ?? []
            // Restrict to links whose BOTH endpoints are inside this
            // chapter — inter-chapter links surface elsewhere.
            let chapterEventSet = Set(planned.events.map(\.id))
            causalLinks = raw.filter {
                chapterEventSet.contains($0.sourceEventID)
                && chapterEventSet.contains($0.targetEventID)
            }.sorted { $0.confidence > $1.confidence }
        }
        if !causalLinks.isEmpty,
           let coda = Self.renderCausalCoda(
            chapterEvents: planned.events,
            links: causalLinks,
            startSentenceIndex: sentences.count
           ) {
            sentences.append(coda.sentence)
            claimCitations.append(coda.citation)
        }

        let prose = sentences.joined(separator: " ")
        let conf = LLMNarrativeComposer.chapterConfidence(
            events: planned.events,
            slots: slots,
            citationCoverage: claimCitations.count
        )

        return NarrativeChapter(
            title: title,
            subtitle: subtitle,
            timeframeStart: planned.timeframeStart,
            timeframeEnd: planned.timeframeEnd,
            eventIDs: planned.events.map(\.id),
            topicCommunityID: planned.topicCommunityID,
            prose: prose,
            claimCitations: claimCitations,
            contradictions: [],
            causalLinks: causalLinks,
            confidence: conf
        )
    }

    /// Build a one-sentence causal coda from the chapter's strongest
    /// links. Returns nil when nothing meaningful surfaces.
    nonisolated static func renderCausalCoda(
        chapterEvents: [Event],
        links: [CausalLink],
        startSentenceIndex: Int
    ) -> (sentence: String, citation: NarrativeClaimCitation)? {
        guard !links.isEmpty else { return nil }
        let idxByID: [Event.ID: Int] = Dictionary(
            uniqueKeysWithValues: chapterEvents.enumerated().map { ($1.id, $0 + 1) }
        )
        var phrases: [String] = []
        var citedObjectIDs: [KnowledgeObject.ID] = []
        var citedEventIDs: [Event.ID] = []
        for link in links.prefix(4) {
            guard let si = idxByID[link.sourceEventID],
                  let ti = idxByID[link.targetEventID] else { continue }
            phrases.append("[E\(si)] \(link.relation.renderVerb) [E\(ti)]")
            citedObjectIDs.append(contentsOf: link.evidenceObjectIDs)
            citedEventIDs.append(link.sourceEventID)
            citedEventIDs.append(link.targetEventID)
        }
        guard !phrases.isEmpty else { return nil }
        let sentence = "Causal chain: " + phrases.joined(separator: "; ") + "."
        let citation = NarrativeClaimCitation(
            sentenceIndex: startSentenceIndex,
            evidenceObjectIDs: Array(Set(citedObjectIDs)),
            evidenceEventIDs: Array(Set(citedEventIDs)),
            confidence: links.map(\.confidence).reduce(0, +) / Double(links.count)
        )
        return (sentence, citation)
    }

    /// Build one sentence per event from its 5W+H slots. Falls back
    /// to bare "On DATE, kind K" when slots are empty.
    ///
    /// Phase G.2 — date phrasing reads `event.datePrecision`:
    ///   .instant → "On Mar 14, 2025 at 09:12 UTC, …"
    ///   .day     → "On Mar 14, 2025, …"
    ///   .month   → "In March 2025, …"
    ///   .quarter → "In Q1 2025, …"
    ///   .year    → "During 2025, …"
    ///   .decade  → "In the 2020s, …"
    ///   .unknown → "At an unknown time, …"
    /// Critical anti-pattern guarded: we NEVER render a time component
    /// for an event whose precision is coarser than .minute. That kept
    /// the old composer claiming "00:00" on month-precision events.
    nonisolated static func render(
        event: Event,
        slots: EventNarrativeSlots,
        label: String,
        formatter: DateFormatter
    ) -> String {
        let dateText = event.datePrecision.renderPhrase(date: event.date)
        // dateText is already lowercased and begins with a preposition
        // ("on …", "in …", "during …"). Capitalize the first letter
        // for sentence-start.
        let datePhrase = dateText.prefix(1).uppercased() + dateText.dropFirst()
        if slots.isEmpty {
            return "\(datePhrase), a \(humanize(event.kind)) was recorded: \(event.title) \(label)."
        }
        var parts: [String] = []
        parts.append("\(datePhrase),")
        if let who = slots.who.first?.text {
            // Strip any embedded email "<addr>" so the prose stays readable.
            let cleanedWho = who.replacingOccurrences(of: #"\s*<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanedWho.isEmpty {
                parts.append(cleanedWho)
            }
        }
        let action = humanize(event.kind)
        parts.append(action)
        if let what = slots.what.first?.text, !what.isEmpty,
           what.lowercased() != event.title.lowercased() {
            parts.append("— \(what)")
        } else {
            parts.append("(\(event.title))")
        }
        if let how = slots.how.first?.text, !how.isEmpty {
            parts.append("via \(how)")
        }
        let sentence = parts.joined(separator: " ")
        // Trim duplicate spaces from any cleaning above.
        let collapsed = sentence.replacingOccurrences(of: "  ", with: " ", options: .regularExpression)
        return "\(collapsed) \(label)."
    }

    nonisolated static func humanize(_ kind: Event.Kind) -> String {
        switch kind {
        case .emailSent:         return "sent an email"
        case .emailReceived:     return "received an email"
        case .contractSigned:    return "signed a contract"
        case .contractModified:  return "amended a contract"
        case .invoiceIssued:     return "issued an invoice"
        case .invoicePaid:       return "paid an invoice"
        case .meetingHeld:       return "held a meeting"
        case .taskAssigned:      return "took on a task"
        case .deliveryDelayed:   return "saw a delivery delay"
        case .deliveryCompleted: return "completed a delivery"
        case .other:             return "recorded an event"
        }
    }
}
