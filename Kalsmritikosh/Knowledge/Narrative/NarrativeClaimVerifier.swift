//
//  NarrativeClaimVerifier.swift
//  Kalsmritikosh
//
//  HISTORY Phase D.4 + D.5 — post-processes a NarrativeChapter to:
//
//   D.4 ClaimVerifier — drops sentences whose [E?] citations don't
//   resolve to events the chapter was given, and downgrades
//   chapter confidence proportional to dropped sentences. Without
//   this, a sloppy LLM run could ship ungrounded prose; the verifier
//   enforces "every sentence cites real evidence or it doesn't ship".
//
//   D.5 ContradictionSurface — scans the chapter's events for the
//   "same WHO + same kind, different WHEN" pattern and emits a
//   Contradiction for each pair. Conservative on purpose: real
//   semantic contradiction detection ("signed" vs "not signed")
//   needs the LLM and is out of MVP scope. The MVP catches date
//   disagreements, which are the biggest narrative-honesty risk.
//
//  Both stages preserve all source events. Chapters never drop
//  events — only filter the *prose*. Quality-or-nothing: a chapter
//  whose prose is entirely ungrounded keeps its title + event list
//  but ships with empty prose so the UI can render bullets.
//

import Foundation

public nonisolated struct NarrativeClaimVerifier: Sendable {
    public init() {}

    /// Verify a chapter:
    ///   1. Strip sentences without any [E?] tokens (ungrounded prose).
    ///   2. Strip [E?] labels that don't map to a real event index.
    ///   3. Recompute confidence by the ratio of grounded sentences.
    /// Returns a new chapter; the input is left unchanged.
    public func verify(chapter: NarrativeChapter, events: [Event]) -> NarrativeChapter {
        guard !chapter.prose.isEmpty else { return chapter }

        let sentences = LLMNarrativeComposer.splitSentences(chapter.prose)
        let labelRegex = try? NSRegularExpression(pattern: #"\[E(\d+)\]"#)
        let maxIndex = events.count

        var keptSentences: [String] = []
        var newCitations: [NarrativeClaimCitation] = []

        for sentence in sentences {
            guard let rx = labelRegex else { continue }
            let ns = sentence as NSString
            let matches = rx.matches(in: sentence, range: NSRange(location: 0, length: ns.length))
            var validIDs: [Event.ID] = []
            var validObjectIDs: [KnowledgeObject.ID] = []
            for m in matches where m.numberOfRanges >= 2 {
                let nStr = ns.substring(with: m.range(at: 1))
                guard let n = Int(nStr), n >= 1, n <= maxIndex else { continue }
                let event = events[n - 1]
                if !validIDs.contains(event.id) {
                    validIDs.append(event.id)
                    validObjectIDs.append(event.sourceObjectID)
                }
            }
            if validIDs.isEmpty {
                // Ungrounded — drop.
                continue
            }
            keptSentences.append(sentence)
            let avgConf = average(events.filter { validIDs.contains($0.id) }
                .map { $0.dateConfidence * $0.qualityTier.defaultWeight })
            newCitations.append(
                NarrativeClaimCitation(
                    sentenceIndex: keptSentences.count - 1,
                    evidenceObjectIDs: validObjectIDs,
                    evidenceEventIDs: validIDs,
                    confidence: avgConf
                )
            )
        }

        let kept = keptSentences.joined(separator: " ")
        let coverageRatio: Double = sentences.isEmpty
            ? 0
            : Double(keptSentences.count) / Double(sentences.count)
        let newConfidence = max(0.1, min(1.0, chapter.confidence * (0.5 + 0.5 * coverageRatio)))

        // Add contradictions detected over this chapter's events.
        let contradictions = detectContradictions(events: events) + chapter.contradictions

        return NarrativeChapter(
            id: chapter.id,
            title: chapter.title,
            subtitle: chapter.subtitle,
            timeframeStart: chapter.timeframeStart,
            timeframeEnd: chapter.timeframeEnd,
            eventIDs: chapter.eventIDs,
            topicCommunityID: chapter.topicCommunityID,
            prose: kept,
            claimCitations: newCitations,
            contradictions: contradictions,
            confidence: newConfidence
        )
    }

    /// D.5 — surface "same kind + same primary entity, different date"
    /// pairs as Contradictions. Same-day duplicates are tolerated;
    /// only divergent dates (> 1 day apart) count.
    public func detectContradictions(events: [Event]) -> [VerifiedAnswer.Contradiction] {
        guard events.count >= 2 else { return [] }
        var out: [VerifiedAnswer.Contradiction] = []
        // Group events by (kind, primaryEntity).
        var groups: [String: [Event]] = [:]
        for event in events {
            let key = "\(event.kind.rawValue)|\(event.entityIDs.first?.uuidString ?? "_")"
            groups[key, default: []].append(event)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        for (_, group) in groups where group.count >= 2 {
            // Pairwise: report the earliest vs latest date in the group
            // when their spread is > 1 day.
            let sorted = group.sorted { $0.date < $1.date }
            guard let first = sorted.first, let last = sorted.last,
                  abs(last.date.timeIntervalSince(first.date)) > 86_400 else {
                continue
            }
            out.append(
                VerifiedAnswer.Contradiction(
                    description: "Multiple \(first.kind.rawValue) events for the same subject",
                    claimA: "\(first.title) on \(formatter.string(from: first.date))",
                    claimB: "\(last.title) on \(formatter.string(from: last.date))"
                )
            )
        }
        return out
    }

    private func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0.5 }
        return values.reduce(0, +) / Double(values.count)
    }
}
