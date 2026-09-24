//
//  DeterministicEvidenceFallback.swift
//  Kalsmritikosh
//
//  The zero-LLM answer of last resort (spec §13). When the request budget is
//  exhausted, no provider is available, narrative/synthesis failed, or a
//  further generative fallback would breach the call ceiling, we still owe the
//  user a grounded, citation-carrying answer — assembled deterministically
//  from the retrieval set. It never calls an LLM and never invents: it lists
//  what the archive supports, the contradictions already detected, and states
//  the budget limitation plainly.
//

import Foundation

public enum DeterministicEvidenceFallback {

    /// Build a grounded VerifiedAnswer from the retrieval set alone — no LLM.
    /// Returns nil only when there is genuinely nothing to show (no events and
    /// no chunks), in which case the caller keeps its honest refusal.
    public static func build(
        question: String,
        intent: UserIntent,
        retrieval: RetrievalResult,
        eventLinks: EventLinksRepository? = nil,
        topics: [MemoryObject] = []
    ) async -> VerifiedAnswer? {
        // Prefer dated events (the structured layer); fall back to top chunks.
        // P7.5 — the no-LLM reconstruction must read as a CHRONOLOGICAL timeline,
        // so sort the event cards by date ascending before rendering (retrieval
        // order is relevance-ranked, not temporal).
        // Answer-quality W4 — everything shown here must be RELEVANT to the
        // question. The live diagnostic showed this last-resort composer dumping
        // every riding fact (Role: Director / Hearingdate … ×30) and unrelated
        // documents (a patent timeline for "who signed the lease?"). Gate each
        // section by shared content terms; when nothing relevant survives, return
        // nil so the caller keeps its honest not-found. Empty question ⇒ keep all.
        let relevanceSelector = PassageAnswerSelector()
        let qTerms = relevanceSelector.contentTerms(question)
        func relevant(_ text: String) -> Bool {
            guard !qTerms.isEmpty else { return true }
            return !qTerms.isDisjoint(with: relevanceSelector.contentTerms(text))
        }

        // Topic-Ledger U7 — LEAD with a built topic when one is relevant, so the
        // answer composes from the deterministic topic rollup (memory object)
        // rather than the raw fact/passage pile. Pick the topic whose subject or
        // narrative shares the most content terms with the question.
        var leadTopic: MemoryObject?
        var leadOverlap = 0
        for t in topics {
            let terms = relevanceSelector.contentTerms(t.subjectIdentifier + " " + t.narrative)
            let overlap = qTerms.intersection(terms).count
            guard overlap > 0 || qTerms.isEmpty else { continue }
            if leadTopic == nil || overlap > leadOverlap {
                leadTopic = t
                leadOverlap = overlap
            }
        }

        let events = Array(retrieval.events.prefix(12))
            .filter { relevant($0.title) }
            .sorted { $0.date < $1.date }
        let chunks = Array(retrieval.chunks.prefix(8))
        guard !events.isEmpty || !chunks.isEmpty || leadTopic != nil else { return nil }

        var citations: [VerifiedAnswer.Citation] = []
        var seen = Set<KnowledgeObject.ID>()
        var supportLines: [String] = []

        // U7 — the built topic's contributing documents become citations so the
        // leading topic section is grounded and reopenable.
        if let leadTopic {
            for objectID in leadTopic.sourceObjectIDs where seen.insert(objectID).inserted {
                citations.append(VerifiedAnswer.Citation(objectID: objectID, snippet: leadTopic.subjectIdentifier))
            }
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "d MMM yyyy"
        for event in events {
            let when = dateFormatter.string(from: event.date)
            supportLines.append("- **\(when)** — \(event.title)")
            if seen.insert(event.sourceObjectID).inserted {
                citations.append(VerifiedAnswer.Citation(
                    objectID: event.sourceObjectID,
                    eventID: event.id,
                    snippet: event.title
                ))
            }
        }
        // ALWAYS surface the top authoritative passages — not only when there
        // are no events. The decisive fact for a factual question (a grant date,
        // a patent number, a clause) lives in a DOCUMENT chunk, not in an email
        // "event"; the previous `if events.isEmpty` gate meant an email-heavy
        // archive (hundreds of emailReceived events) hid the one certificate/
        // intimation passage that answers the question. Verbatim + cited.
        var passageLines: [String] = []
        for hit in chunks {
            let snippet = hit.chunk.text
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
                .prefix(300)
            guard snippet.count >= 20, relevant(String(snippet)) else { continue }
            passageLines.append("- \(snippet)")
            if seen.insert(hit.chunk.objectID).inserted {
                citations.append(VerifiedAnswer.Citation(
                    objectID: hit.chunk.objectID,
                    chunkID: hit.chunk.id,
                    eventID: nil,
                    snippet: String(snippet)
                ))
            }
        }

        // SEM — the domain-pack facts that ride this retrieval (already filtered
        // to assertable statuses by the retriever) are the most decisive, fully
        // deterministic items we can show. Render them first, and cite each via
        // the surfaced chunk that shares its evidence block so the source stays
        // clickable. No fact is shown without a backing chunk in this set.
        var blockToChunk: [UUID: RetrievedChunk] = [:]
        for c in retrieval.chunks {
            if let b = c.chunk.evidenceBlockID, blockToChunk[b] == nil { blockToChunk[b] = c }
        }
        var factLines: [String] = []
        var seenFacts = Set<String>()          // W4 — dedup: the same field+value
        for fact in retrieval.genericFacts {
            guard let backing = fact.sourceBlockIDs.lazy.compactMap({ blockToChunk[$0] }).first
            else { continue }   // only facts whose evidence is in THIS surfaced set
            // W4 — relevance gate + dedup + cap: never dump every riding fact or
            // repeat the same one. Skip facts the question did not ask about, and
            // collapse duplicate field+value rows.
            //
            // A fact counts as relevant when the question's terms overlap EITHER
            // the fact itself OR THE PASSAGE IT WAS EXTRACTED FROM. The second
            // clause is not a loosening — it is what makes the gate correct.
            // Comparing a question against `field + value` alone asks the user to
            // have guessed the ledger's field NAME: "where did they work?" yields
            // the term "work", while the fact reads `employer = Orchid Pharma`,
            // so the one fact that answers the question was dropped — while the
            // chunk "Worked at Orchid Pharma as a chemist.", which states the
            // very same thing, was shown. A fact is a distillation of its
            // passage; if the question surfaced the passage as relevant, the
            // fact drawn from it is relevant too.
            //
            // This does NOT reopen the dump this gate was added to stop. The
            // backing chunk must still be in the surfaced set (above) AND share
            // terms with the question, so the witnessed junk — Role: Director /
            // Hearingdate ×30 riding a "who signed the lease?" ask — stays out:
            // those facts' passages are the unrelated documents the same gate
            // already excludes.
            guard relevant(fact.field + " " + fact.value) || relevant(backing.chunk.text)
            else { continue }
            let dedupKey = "\(fact.field.lowercased())|\(fact.value.lowercased())"
            guard seenFacts.insert(dedupKey).inserted else { continue }
            guard factLines.count < 12 else { break }
            let field = fact.field.prefix(1).uppercased() + fact.field.dropFirst()
            let unit = fact.unit.map { " \($0)" } ?? ""
            factLines.append("- **\(field):** \(fact.value)\(unit)")
            if seen.insert(backing.chunk.objectID).inserted {
                citations.append(VerifiedAnswer.Citation(
                    objectID: backing.chunk.objectID,
                    chunkID: backing.chunk.id,
                    eventID: nil,
                    snippet: String(backing.chunk.text.prefix(160))
                ))
            }
        }

        // W4 abstention — if nothing relevant to the question survived the gates,
        // return nil so the caller keeps its honest not-found instead of dumping
        // an unrelated fact/timeline pile. A relevant built topic (U7) also counts.
        guard leadTopic != nil || !factLines.isEmpty || !passageLines.isEmpty || !events.isEmpty else { return nil }

        // Contradictions are found deterministically (no LLM).
        let contradictions = await MasterBrain.findCrossRetrievalContradictions(
            events: events, eventLinks: eventLinks
        )

        // Key passages first — the authoritative document text that most likely
        // holds the answer (grant date, patent number, clause). Then the dated
        // timeline for context.
        var md = ""
        // U7 — lead with the built topic (deterministic rollup) when relevant.
        if let leadTopic {
            md += "## Topic\n\n\(leadTopic.narrative)\n\n"
        }
        if !factLines.isEmpty {
            md += "## Extracted facts (from your evidence)\n\n"
            md += factLines.joined(separator: "\n") + "\n\n"
        }
        if !passageLines.isEmpty {
            md += "## Key passages from your documents\n\n"
            md += passageLines.joined(separator: "\n") + "\n\n"
        }
        if !events.isEmpty {
            md += "## Timeline (from your evidence)\n\n"
            md += supportLines.joined(separator: "\n") + "\n"
        } else if passageLines.isEmpty {
            md += "## What the archive supports\n\n- (no directly citable items)\n"
        }

        if !contradictions.isEmpty {
            md += "\n## Contradictions\n\n"
            for c in contradictions {
                md += "- \(c.description): \"\(c.claimA)\" vs \"\(c.claimB)\"\n"
            }
        }

        md += "\n## Missing evidence\n\n"
        md += "- A fully-reasoned answer to \"\(question)\" would need corroborating documents the analysis could not read within the current budget.\n"

        md += "\n## Limitation\n\n"
        md += "A supported narrative could not be generated within the current analysis budget. The items above are drawn directly from your archive; verify them against the cited sources.\n"

        let trace = ReasoningTrace(
            pathTaken: ReasoningTrace.pathChunkRAG,
            intent: intent.kind.rawValue,
            queryCategory: QueryCategoryClassifier().classify(question: question, intent: intent).rawValue,
            retrievalLayers: retrieval.layersUsed.map(\.rawValue),
            shortCircuitedAt: retrieval.shortCircuitedAt?.rawValue,
            expertIDs: [],
            llmPurposes: [],
            retrievalCounts: ReasoningTrace.RetrievalCounts(
                events: retrieval.events.count,
                entities: retrieval.entities.count,
                chunks: retrieval.chunks.count,
                relationships: retrieval.relationships.count,
                summaries: retrieval.summaries.count,
                walkSteps: retrieval.walkSteps.count,
                genericFacts: retrieval.genericFacts.count
            ),
            assumptions: ["Rendered deterministically (no LLM) — analysis budget exhausted or no provider available."],
            uncertainties: contradictions.map(\.description)
        )

        return VerifiedAnswer(
            body: md,
            answerText: md,
            intentKind: intent.kind.rawValue,
            citations: citations,
            confidence: Confidence(citations.isEmpty ? 0.2 : 0.4),
            contradictions: contradictions,
            refused: false,
            refusalReason: nil,
            report: nil,
            walkSteps: retrieval.walkSteps,
            source: .ragFallback,
            reasoningTrace: trace
        )
    }
}
