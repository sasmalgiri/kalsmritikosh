//
//  TimelineExpert.swift
//  Kalsmritikosh
//

import Foundation
import OSLog

public struct TimelineExpert: Expert {
    public let id = "expert.timeline"
    public let capabilities: Set<ExpertCapability> = [.eventReconstruction, .historyReconstruction]
    public let domains: Set<ExpertDomain> = [.timeline]
    public init() {}

    public func analyze(intent: UserIntent, context: ExpertContext) async throws -> ExpertFindings {
        let result = try await context.retriever.retrieve(
            for: intent,
            layers: [.memory, .timeline, .entity]
        )
        let supportingObjectIDs = Array(Set(result.events.map(\.sourceObjectID)))
        let supportingEventIDs = result.events.map(\.id)
        let supportingEntityIDs = Array(Set(result.events.flatMap(\.entityIDs)))

        let prompt = PromptTemplates.timelineAnalysis(intent: intent, retrieval: result)
        let llmClaims = await runLLM(
            prompt: prompt,
            capabilities: context.capabilities,
            supportingObjectIDs: supportingObjectIDs,
            supportingEventIDs: supportingEventIDs,
            supportingEntityIDs: supportingEntityIDs
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

        let claims = result.events.prefix(12).map { event in
            ExpertFindings.Claim(
                statement: "\(event.kind.rawValue.replacingOccurrences(of: "_", with: " ").capitalized): \(event.title) \u{2014} \(event.date.formatted(date: .abbreviated, time: .shortened))",
                supportingObjectIDs: [event.sourceObjectID],
                supportingEventIDs: [event.id],
                supportingEntityIDs: event.entityIDs,
                confidence: event.confidence
            )
        }
        return ExpertFindings(
            expertID: id,
            claims: Array(claims),
            confidence: claims.isEmpty ? .zero : .medium,
            notes: claims.isEmpty ? "No events in retrieved range." : nil
        )
    }

    private func runLLM(
        prompt: String,
        capabilities: CapabilityRegistry,
        supportingObjectIDs: [KnowledgeObject.ID],
        supportingEventIDs: [Event.ID],
        supportingEntityIDs: [Entity.ID]
    ) async -> [ExpertFindings.Claim] {
        let spec = CapabilitySpec.reasoning(contextTokens: 6_000, purpose: "expert.timeline")
        guard let provider = try? await capabilities.resolve(spec),
              await provider.isAvailable() else { return [] }
        do {
            let response = try await provider.generate(
                prompt: prompt,
                options: GenerationOptions(maxTokens: 500, temperature: 0.2)
            )
            return ExpertResponseParser.bullets(from: response).map { statement in
                ExpertFindings.Claim(
                    statement: statement,
                    supportingObjectIDs: supportingObjectIDs,
                    supportingEventIDs: supportingEventIDs,
                    supportingEntityIDs: supportingEntityIDs,
                    confidence: .medium
                )
            }
        } catch {
            AtlasLog.brain.error("TimelineExpert LLM call failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }
}
