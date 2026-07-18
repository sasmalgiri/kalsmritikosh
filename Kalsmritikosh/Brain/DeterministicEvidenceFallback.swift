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
        eventLinks: EventLinksRepository? = nil
    ) async -> VerifiedAnswer? {
        // Prefer dated events (the structured layer); fall back to top chunks.
        // P7.5 — the no-LLM reconstruction must read as a CHRONOLOGICAL timeline,
        // so sort the event cards by date ascending before rendering (retrieval
        // order is relevance-ranked, not temporal).
        let events = Array(retrieval.events.prefix(12)).sorted { $0.date < $1.date }
        let chunks = Array(retrieval.chunks.prefix(8))
        guard !events.isEmpty || !chunks.isEmpty else { return nil }

        var citations: [VerifiedAnswer.Citation] = []
        var seen = Set<KnowledgeObject.ID>()
        var supportLines: [String] = []

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
            guard snippet.count >= 20 else { continue }
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

        // Contradictions are found deterministically (no LLM).
        let contradictions = await MasterBrain.findCrossRetrievalContradictions(
            events: events, eventLinks: eventLinks
        )

        // Key passages first — the authoritative document text that most likely
        // holds the answer (grant date, patent number, clause). Then the dated
        // timeline for context.
        var md = ""
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
                walkSteps: retrieval.walkSteps.count
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
