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
        let result = try await context.retrieve(
            for: intent,
            layers: [.memory, .timeline, .entity, .metadata, .summary, .vector]
        )

        // SEM — the deterministically-extracted domain facts that ride this
        // retrieval are ground truth (not model output), so they LEAD the
        // expert's claims on both paths, cited to their backing document.
        let factClaims = Self.factClaims(from: result)

        let frame = PromptTemplates.reasoningAnalysis(intent: intent, retrieval: result)
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
        var claims: [ExpertFindings.Claim] = []
        for f in result.genericFacts {
            // maySurface (not only assertive): inference and conflict REMAIN VISIBLE, framed
            // by their carried evaluation's presentation. Only `refuse` is dropped.
            guard let eval = evalByID[f.id], eval.decision.maySurface,
                  let obj = eval.evidence.first?.objectID, let presentation = eval.presentation else { continue }
            let field = f.field.prefix(1).uppercased() + f.field.dropFirst()
            let unit = f.unit.map { " \($0)" } ?? ""
            claims.append(ExpertFindings.Claim(
                statement: "\(Self.framePrefix(presentation))\(field): \(f.value)\(unit)",
                supportingObjectIDs: [obj],
                confidence: Confidence(f.confidence),
                evidenceGranularity: .coarse,
                evaluation: eval                      // carried unchanged
            ))
        }
        return claims
    }

    /// The framing prefix a claim's presentation requires — an attributed/user/inference/
    /// conflict claim is never rendered as a bare fact.
    nonisolated static func framePrefix(_ p: ClaimPresentation) -> String {
        switch p {
        case .fact, .corroborated, .derivation: return ""
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
