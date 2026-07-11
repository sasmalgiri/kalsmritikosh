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
        let events = Array(retrieval.events.prefix(12))
        let chunks = Array(retrieval.chunks.prefix(8))
        guard !events.isEmpty || !chunks.isEmpty else { return nil }

        var citations: [VerifiedAnswer.Citation] = []
        var seen = Set<KnowledgeObject.ID>()
        var supportLines: [String] = []

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "d MMM yyyy"
        for event in events {
            let when = dateFormatter.string(from: event.date)
            supportLines.append("- \(event.title) — \(when)")
            if seen.insert(event.sourceObjectID).inserted {
                citations.append(VerifiedAnswer.Citation(
                    objectID: event.sourceObjectID,
                    eventID: event.id,
                    snippet: event.title
                ))
            }
        }
        if events.isEmpty {
            for hit in chunks {
                let snippet = hit.chunk.text
                    .replacingOccurrences(of: "\n", with: " ")
                    .prefix(160)
                supportLines.append("- \(snippet)")
                if seen.insert(hit.chunk.objectID).inserted {
                    citations.append(VerifiedAnswer.Citation(
                        objectID: hit.chunk.objectID,
                        chunkID: hit.chunk.id,
                        eventID: nil,
                        snippet: String(snippet)
                    ))
                }
            }
        }

        // Contradictions are found deterministically (no LLM).
        let contradictions = await MasterBrain.findCrossRetrievalContradictions(
            events: events, eventLinks: eventLinks
        )

        var md = "## What the archive supports\n\n"
        md += supportLines.isEmpty ? "- (no directly citable items)\n" : supportLines.joined(separator: "\n") + "\n"

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
