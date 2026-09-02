//
//  ReasoningExpert.swift
//  Kalsmritikosh
//
//  Generalist member of the expert panel. Where the domain experts each
//  look at one slice (legal, financial, timeline…), this expert reasons
//  ACROSS all retrieved evidence — events + document snippets + entities —
//  to connect facts that span sources. It broadens the Mixture-of-Experts
//  toward large-model breadth on grounded questions while staying evidence-
//  bound (every claim cites E-ids). Same dual dispatch as the other
//  experts: typed @Generable path first, prompt-parse fallback, then a
//  deterministic chunk fallback when no model is available.
//

import Foundation
import OSLog

public struct ReasoningExpert: Expert {
    public let id = "expert.reasoning"
    public let capabilities: Set<ExpertCapability> = [.generalReasoning]
    public let domains: Set<ExpertDomain> = [.reasoning]
    public init() {}

    public func analyze(intent: UserIntent, context: ExpertContext) async throws -> ExpertFindings {
        let authorized = try await context.retrieveAuthorized(
            for: intent,
            layers: [.memory, .timeline, .entity, .metadata, .summary, .vector]
        )
        let result = authorized.result

        // SEM — the deterministically-extracted domain facts that ride this
        // retrieval are ground truth (not model output), so they LEAD the
        // expert's claims on both paths, cited to their backing document.
        let factClaims = Self.factClaims(from: result)

        let frame = PromptTemplates.reasoningAnalysis(intent: intent,
                                                      retrieval: await context.promptAuthorizer.authorize(authorized))
        let llm = await runLLM(frame: frame, capabilities: context.capabilities, context: context.llmContext)
        if !llm.claims.isEmpty {
            let claims = factClaims + llm.claims
            return ExpertFindings(
                expertID: id,
                claims: claims,
                confidence: Confidence.aggregate(
                    claims.map(\.confidence),
                    agreement: 1.0,
                    diversity: 1.0,
                    contradictionPenalty: 0.0
                ),
                droppedUnverifiable: llm.dropped
            )
        }

        // Deterministic fallback (no model): lead with the domain facts, then
        // surface the top retrieved snippets as coarse claims so the expert
        // still contributes offline.
        let snippetClaims = result.chunks.prefix(5).map { hit in
            ExpertFindings.Claim(
                statement: hit.chunk.text.isEmpty
                    ? "Relevant material via \(hit.viaLayer.rawValue)"
                    : String(hit.chunk.text.prefix(220)),
                supportingObjectIDs: [hit.chunk.objectID],
                confidence: Confidence(hit.score),
                evidenceGranularity: .coarse
            )
        }
        let claims = factClaims + Array(snippetClaims)
        return ExpertFindings(
            expertID: id,
            claims: claims,
            confidence: claims.isEmpty ? .zero : .low,
            notes: claims.isEmpty ? "No evidence to reason over." : nil,
            droppedUnverifiable: llm.dropped
        )
    }

    /// SEM — turn the assertable GenericFacts that ride `result` into deterministic
    /// `.coarse` claims, each cited to the document whose evidence block produced it
    /// (first backing chunk in the retrieved set). Facts whose block isn't among the
    /// surfaced chunks are skipped, so every claim's supporting id is in the retrieval
    /// set (the claim–evidence contract holds). Pure + testable.
    nonisolated static func factClaims(from result: RetrievalResult) -> [ExpertFindings.Claim] {
        // Consume the retrieval-produced ClaimEvaluations UNCHANGED (do not re-evaluate or
        // re-resolve evidence). Join with the surfaced facts by ledger id for field/value.
        let evalByID = Dictionary(result.claimEvaluations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // The per-object retrieval score — the SAME signal EvidenceVerifier ranks
        // citations by (best chunk score per KnowledgeObject). The claim's single
        // representative is chosen by this relevance, so a fact's citation anchor
        // is its most-relevant evidence object, deterministically — not an
        // arbitrary array position (`.first`) and not a relevance-blind key.
        var scoreByObject: [KnowledgeObject.ID: Double] = [:]
        for rc in result.chunks {
            let id = rc.chunk.objectID
            scoreByObject[id] = max(scoreByObject[id] ?? -.infinity, rc.score)
        }
        var claims: [ExpertFindings.Claim] = []
        for f in result.genericFacts {
            // maySurface (not only assertive): inference and conflict REMAIN VISIBLE, framed
            // by their carried evaluation's presentation. Only `refuse` is dropped.
            guard let eval = evalByID[f.id], eval.decision.maySurface,
                  let obj = Self.stableRepresentative(eval.evidence, scoreByObject: scoreByObject),
                  let presentation = eval.presentation else { continue }
            // D-12 — humanize the ledger field id ("applicationnumber" →
            // "Application number") and render money canonically; the raw
            // capitalize-first produced "Applicationnumber: …" run-ons.
            let field = SlotFieldResolver.humanLabel(forFieldID: f.field)
            // ORDERED-EVIDENCE PROBE (owner 2026-09-02, Q2 branch discriminator):
            // the claim's supporting object is eval.evidence.FIRST — a POSITIONAL
            // read of an array whose fingerprint is order-INDEPENDENT by design.
            // Dump .first + the order-independent fingerprint + the full evidence
            // set so a per-ask `.first` flip resolves to same-members-order-varies
            // (fingerprint STABLE) vs members-vary (fingerprint VARIES). Env-gated.
            if ProcessInfo.processInfo.environment["KALSMRITIKOSH_DUMP_EVIDENCE_ORDER"] == "1",
               eval.evidence.count > 1 {
                let all = eval.evidence.map { String($0.objectID.uuidString.prefix(8)) }.joined(separator: ",")
                print("EVFIRST field=\(f.field) n=\(eval.evidence.count) first=\(String(obj.uuidString.prefix(8))) fp=\(String(eval.evidenceFingerprint.prefix(12))) all=[\(all)]")
            }
            claims.append(ExpertFindings.Claim(
                statement: "\(Self.framePrefix(presentation))\(field): \(SlotAnswerComposer.renderValue(f))",
                supportingObjectIDs: [obj],
                confidence: Confidence(f.confidence),
                evidenceGranularity: .coarse,
                evaluation: eval                      // carried unchanged
            ))
        }
        return claims
    }

    /// V2 determinism — the TIE-INCLUSIVE CUT LAW's single-representative form
    /// (owner ruling 2026-09-02). A factClaim carries ONE supporting object, and
    /// `eval.evidence` is an order-INDEPENDENT set by design (its fingerprint
    /// sorts before hashing). Reading it positionally with `.first` let an
    /// order flip at ingest/retrieval pick a different co-equal evidence object
    /// per ask — the representative wobbled, and with it distinctSourceObjectIDs
    /// and the answer's confidence (the seal-#3 Q2 residual, traced to a peripheral
    /// email tying with the real evidence for a date fact). The representative is
    /// now chosen by a CRITERION, never by position: the MOST-RELEVANT evidence
    /// object (highest retrieval score), ties broken by least objectID. Stable,
    /// order-independent, keeps nobj=1. The relevance key (not a bare objectID)
    /// matters — EvidenceVerifier ranks CITATIONS by the same per-object score,
    /// so the highest-score representative keeps a fact's citation anchor its
    /// most-relevant document; a bare least-objectID key would deterministically
    /// promote an arbitrary (often low-relevance) co-evidence object and shift
    /// citations on aggregation questions. The companion to unit A's total order
    /// — that governs what a cut keeps IN ORDER; this governs which single equal
    /// a claim keeps AT ALL.
    nonisolated static func stableRepresentative(
        _ evidence: [AssertabilityEvidence],
        scoreByObject: [KnowledgeObject.ID: Double] = [:]
    ) -> KnowledgeObject.ID? {
        evidence.map(\.objectID).max { a, b in
            let sa = scoreByObject[a] ?? -.infinity
            let sb = scoreByObject[b] ?? -.infinity
            if sa != sb { return sa < sb }               // higher score is "greater" (preferred)
            return a.uuidString > b.uuidString           // tie: least objectID is "greater" (preferred)
        }
    }

    /// The framing prefix a claim's presentation requires — an attributed/user/inference/
    /// conflict claim is never rendered as a bare fact.
    nonisolated static func framePrefix(_ p: ClaimPresentation) -> String {
        switch p {
        case .fact:           return ""                    // a directly-observed fact stands unframed
        case .corroborated:   return "Corroborated: "
        case .derivation:     return "Derived: "
        case .attributed:     return "Reported: "
        case .userAttributed: return "User-confirmed: "
        case .inference:      return "Inference: "
        case .conflict:       return "Conflicting accounts: "
        }
    }

    private func runLLM(
        frame: PromptFrame,
        capabilities: CapabilityRegistry,
        context: LLMRequestContext?
    ) async -> (claims: [ExpertFindings.Claim], dropped: Int) {
        let spec = CapabilitySpec.reasoning(contextTokens: 4_000, purpose: "expert.reasoning")
        guard let provider = try? await capabilities.resolve(spec),
              await provider.isAvailable() else {
            return ([], 0)
        }
        // STRUCTURED-OUTPUT PATH — typed @Generable claims.
        if let fmProvider = provider as? FoundationModelsProvider {
            do {
                let typed = try await fmProvider.respondClaims(
                    prompt: frame.prompt,
                    systemPrompt: "You are Kalsmritikosh. Reason across the evidence; use ONLY the evidence ids the prompt provides; never invent ids."
                )
                return (typed, 0)
            } catch {
                KalsmritikoshLog.brain.error("expert.reasoning typed path failed (\(String(describing: error), privacy: .public)); prompt-parse fallback")
            }
        }
        do {
            let response = try await provider.generate(
                prompt: frame.prompt,
                options: GenerationOptions(maxTokens: 320, temperature: 0.2),
                purpose: "expert.reasoning",
                context: context
            )
            let parsed = ExpertResponseParser.parseClaims(from: response, evidenceMap: frame.evidenceMap)
            let claims = parsed.claims.map { p in
                ExpertFindings.Claim(
                    statement: p.text,
                    supportingObjectIDs: p.citation.supportingObjectIDs,
                    supportingEventIDs: p.citation.supportingEventIDs,
                    supportingEntityIDs: p.citation.supportingEntityIDs,
                    confidence: .medium,
                    evidenceGranularity: .specific
                )
            }
            return (claims, parsed.dropped)
        } catch {
            KalsmritikoshLog.brain.error("expert.reasoning LLM call failed → \(String(describing: error), privacy: .public)")
            return ([], 0)
        }
    }
}
