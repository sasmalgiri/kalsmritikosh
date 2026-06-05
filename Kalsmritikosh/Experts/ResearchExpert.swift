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
        let supportingObjectIDs = Array(Set(result.chunks.map(\.chunk.objectID)))

        let prompt = PromptTemplates.researchAnalysis(intent: intent, retrieval: result)
        let llmClaims = await runLLM(
            prompt: prompt,
            capabilities: context.capabilities,
            supportingObjectIDs: supportingObjectIDs
        )
        if !llmClaims.isEmpty {
            return ExpertFindings(
                expertID: id,
                claims: llmClaims,
                confidence: llmClaims.map(\.confidence).reduce(.zero) { $0.combined(with: $1) }
            )
        }

        let claims = result.chunks.prefix(5).map { hit in
            ExpertFindings.Claim(
                statement: hit.chunk.text.isEmpty
                    ? "Relevant chunk via \(hit.viaLayer.rawValue)"
                    : String(hit.chunk.text.prefix(220)),
                supportingObjectIDs: [hit.chunk.objectID],
                confidence: Confidence(hit.score)
            )
        }
        return ExpertFindings(
            expertID: id,
            claims: Array(claims),
            confidence: claims.isEmpty ? .zero : .low,
            notes: claims.isEmpty ? "No research-style chunks found." : nil
        )
    }

    private func runLLM(
        prompt: String,
        capabilities: CapabilityRegistry,
        supportingObjectIDs: [KnowledgeObject.ID]
    ) async -> [ExpertFindings.Claim] {
        let spec = CapabilitySpec.reasoning(contextTokens: 4_000, purpose: "expert.research")
        guard let provider = try? await capabilities.resolve(spec),
              await provider.isAvailable() else { return [] }
        do {
            let response = try await provider.generate(
                prompt: prompt,
                options: GenerationOptions(maxTokens: 300, temperature: 0.2)
            )
            return ExpertResponseParser.bullets(from: response).map { statement in
                ExpertFindings.Claim(
                    statement: statement,
                    supportingObjectIDs: supportingObjectIDs,
                    confidence: .medium
                )
            }
        } catch {
            AtlasLog.brain.error("ResearchExpert LLM call failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }
}
