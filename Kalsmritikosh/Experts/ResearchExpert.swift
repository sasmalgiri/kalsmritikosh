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
        let result = try await context.retriever.retrieve(
            for: intent,
            layers: [.memory, .metadata, .summary, .entity]
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
        guard let provider = try? await capabilities.resolve(spec),
              await provider.isAvailable() else { return ([], 0) }
        do {
            let response = try await provider.generate(
                prompt: frame.prompt,
                options: GenerationOptions(maxTokens: 300, temperature: 0.2)
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
            AtlasLog.brain.error("ResearchExpert LLM call failed: \(String(describing: error), privacy: .public)")
            return ([], 0)
        }
    }
}
