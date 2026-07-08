//
//  ResearchExpert.swift
//  Kalsmritikosh
//

import Foundation
import OSLog

public struct ResearchExpert: Expert {
    public let id = "expert.research"
    public let capabilities: Set<ExpertCapability> = [.citationAnalysis, .literatureAnalysis]
    public let domains: Set<ExpertDomain> = [.research]
    public init() {}

    public func analyze(intent: UserIntent, context: ExpertContext) async throws -> ExpertFindings {
        // UPDATE_13 Item 1 — include .vector. Without it, ResearchExpert
        // starves on a corpus where chunks_fts has no entries yet (the
        // metadata layer is the only chunk source in the previous layer
        // list), so chunks would never reach the LLM and the expert
        // would silently produce zero claims. .vector ensures the
        // semantic-ranked chunks (including contract.md) reach the prompt.
        let result = try await context.retrieve(
            for: intent,
            layers: [.memory, .metadata, .summary, .entity, .vector]
        )

        let frame = PromptTemplates.researchAnalysis(intent: intent, retrieval: result)
        let llm = await runLLM(frame: frame, capabilities: context.capabilities)
        if !llm.claims.isEmpty {
            return ExpertFindings(
                expertID: id,
                claims: llm.claims,
                confidence: Confidence.aggregate(
                    llm.claims.map(\.confidence),
                    agreement: 1.0,
                    diversity: 1.0,
                    contradictionPenalty: 0.0
                ),
                droppedUnverifiable: llm.dropped
            )
        }

        let claims = result.chunks.prefix(5).map { hit in
            ExpertFindings.Claim(
                statement: hit.chunk.text.isEmpty
                    ? "Relevant chunk via \(hit.viaLayer.rawValue)"
                    : String(hit.chunk.text.prefix(220)),
                supportingObjectIDs: [hit.chunk.objectID],
                confidence: Confidence(hit.score),
                evidenceGranularity: .coarse
            )
        }
        return ExpertFindings(
            expertID: id,
            claims: Array(claims),
            confidence: claims.isEmpty ? .zero : .low,
            notes: claims.isEmpty ? "No research-style chunks found." : nil,
            droppedUnverifiable: llm.dropped
        )
    }

    private func runLLM(
        frame: PromptFrame,
        capabilities: CapabilityRegistry
    ) async -> (claims: [ExpertFindings.Claim], dropped: Int) {
        let spec = CapabilitySpec.reasoning(contextTokens: 4_000, purpose: "expert.research")
        // UPDATE_13 Item 0 — log whether an LLM actually executes for
        // this expert. On macOS 15.6 FoundationModels is unavailable
        // (#available(macOS 26.0,*) fails) so without another provider
        // every expert runs on heuristic fallback. The eval log will
        // show that explicitly now.
        guard let provider = try? await capabilities.resolve(spec) else {
            KalsmritikoshLog.brain.info("expert.research LLM: no provider resolved for spec; using heuristic fallback")
            return ([], 0)
        }
        guard await provider.isAvailable() else {
            KalsmritikoshLog.brain.info("expert.research LLM: provider=\(provider.id, privacy: .public) available=false; using heuristic fallback")
            return ([], 0)
        }
        KalsmritikoshLog.brain.info("expert.research LLM: provider=\(provider.id, privacy: .public) available=true")
        // STRUCTURED-OUTPUT PATH (#7) — typed @Generable claims.
        if let fmProvider = provider as? FoundationModelsProvider {
            do {
                let typed = try await fmProvider.respondClaims(
                    prompt: frame.prompt,
                    systemPrompt: "You are Kalsmritikosh. Use ONLY the evidence ids the prompt provides; never invent ids."
                )
                KalsmritikoshLog.brain.info("expert.research LLM: produced \(typed.count) typed claims via @Generable")
                return (typed, 0)
            } catch {
                KalsmritikoshLog.brain.error("expert.research LLM: typed path failed (\(String(describing: error), privacy: .public)); falling back to prompt-parse")
            }
        }
        do {
            let response = try await provider.generate(
                prompt: frame.prompt,
                options: GenerationOptions(maxTokens: 300, temperature: 0.2)
            )
            let parsed = ExpertResponseParser.parseClaims(from: response, evidenceMap: frame.evidenceMap)
            KalsmritikoshLog.brain.info("expert.research LLM: provider=\(provider.id, privacy: .public) produced \(parsed.claims.count) claims, dropped \(parsed.dropped)")
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
            KalsmritikoshLog.brain.error("expert.research LLM: provider=\(provider.id, privacy: .public) call failed → \(String(describing: error), privacy: .public)")
            return ([], 0)
        }
    }
}
