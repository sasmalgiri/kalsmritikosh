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

    public init(
        planner: ChronologicalPlanner,
        verifier: NarrativeClaimVerifier = NarrativeClaimVerifier(),
        maxChapters: Int = 8
    ) {
        self.planner = planner
        self.verifier = verifier
        self.maxChapters = maxChapters
    }

    public func compose(
        intent: UserIntent,
        retrieval: RetrievalResult,
        eventSlots: [Event.ID: EventNarrativeSlots]
    ) async throws -> ReconstructedNarrative {
        let scope = LLMNarrativeComposer.scope(from: intent)
        let planned = await planner.plan(events: retrieval.events)
        let limited = Array(planned.prefix(maxChapters))

        var chapters: [NarrativeChapter] = []
        for chapter in limited {
            let composed = composeChapter(planned: chapter, slots: eventSlots)
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
    ) -> NarrativeChapter {
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
            confidence: conf
        )
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
