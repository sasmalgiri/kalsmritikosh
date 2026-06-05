//
//  LegalExpert.swift
//  Kalsmritikosh
//

import Foundation
import OSLog

public struct LegalExpert: Expert {
    public let id = "expert.legal"
    public let capabilities: Set<ExpertCapability> = [.contractAnalysis, .obligationAnalysis]
    public let domains: Set<ExpertDomain> = [.legal]
    public init() {}

    public func analyze(intent: UserIntent, context: ExpertContext) async throws -> ExpertFindings {
        let result = try await context.retriever.retrieve(
            for: intent,
            layers: [.memory, .metadata, .entity, .timeline]
        )
        let contractEvents = result.events.filter {
            $0.kind == .contractSigned || $0.kind == .contractModified
        }
        let supportingObjectIDs = Array(Set(contractEvents.map(\.sourceObjectID)))
        let supportingEventIDs = contractEvents.map(\.id)

        let prompt = PromptTemplates.legalAnalysis(intent: intent, retrieval: result)
        let llmClaims = await runLLM(
            prompt: prompt,
            capabilities: context.capabilities,
            supportingObjectIDs: supportingObjectIDs,
            supportingEventIDs: supportingEventIDs
        )
        if !llmClaims.isEmpty {
            return ExpertFindings(
                expertID: id,
                claims: llmClaims,
                confidence: Confidence.aggregate(
                    llmClaims.map(\.confidence),
                    agreement: 1.0,
                    diversity: 1.0,
                    contradictionPenalty: 0.0
                )
            )
        }

        let claims = contractEvents.prefix(6).map { event in
            ExpertFindings.Claim(
                statement: "\(event.title) recorded on \(event.date.formatted(date: .abbreviated, time: .omitted))",
                supportingObjectIDs: [event.sourceObjectID],
                supportingEventIDs: [event.id],
                confidence: event.confidence
            )
        }
        return ExpertFindings(
            expertID: id,
            claims: Array(claims),
            confidence: claims.isEmpty ? .zero : .medium,
            notes: claims.isEmpty ? "No contractual events found." : nil
        )
    }

    private func runLLM(
        prompt: String,
        capabilities: CapabilityRegistry,
        supportingObjectIDs: [KnowledgeObject.ID],
        supportingEventIDs: [Event.ID]
    ) async -> [ExpertFindings.Claim] {
        let spec = CapabilitySpec.reasoning(contextTokens: 4_000, purpose: "expert.legal")
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
                    supportingEventIDs: supportingEventIDs,
                    confidence: .medium
                )
            }
        } catch {
            AtlasLog.brain.error("LegalExpert LLM call failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }
}
