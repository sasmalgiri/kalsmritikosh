//
//  ProjectExpert.swift
//  Kalsmritikosh
//

import Foundation
import OSLog

public struct ProjectExpert: Expert {
    public let id = "expert.project"
    public let capabilities: Set<ExpertCapability> = [.projectReconstruction, .stakeholderMapping]
    public let domains: Set<ExpertDomain> = [.project]
    public init() {}

    public func analyze(intent: UserIntent, context: ExpertContext) async throws -> ExpertFindings {
        let result = try await context.retriever.retrieve(
            for: intent,
            layers: [.memory, .entity, .timeline, .graph, .summary]
        )
        let supportingObjectIDs = Array(Set(result.events.map(\.sourceObjectID)))
        let supportingEventIDs = result.events.map(\.id)
        let supportingEntityIDs = Array(Set(result.events.flatMap(\.entityIDs) + result.entities.map(\.id)))

        let prompt = PromptTemplates.projectAnalysis(intent: intent, retrieval: result)
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
                confidence: llmClaims.map(\.confidence).reduce(.zero) { $0.combined(with: $1) }
            )
        }

        var claims: [ExpertFindings.Claim] = []
        for event in result.events.prefix(8) {
            claims.append(.init(
                statement: "Project event: \(event.title) \u{2014} \(event.date.formatted(date: .abbreviated, time: .omitted))",
                supportingObjectIDs: [event.sourceObjectID],
                supportingEventIDs: [event.id],
                supportingEntityIDs: event.entityIDs,
                confidence: event.confidence
            ))
        }
        let stakeholders = result.entities.filter { $0.kind == .person || $0.kind == .organization }
        if !stakeholders.isEmpty {
            let names = stakeholders.prefix(8).map(\.value).joined(separator: ", ")
            claims.append(.init(
                statement: "Stakeholders: \(names)",
                supportingEntityIDs: stakeholders.map(\.id),
                confidence: .medium
            ))
        }
        return ExpertFindings(
            expertID: id,
            claims: claims,
            confidence: claims.isEmpty ? .zero : .medium,
            notes: claims.isEmpty ? "No project signal in retrieved scope." : nil
        )
    }

    private func runLLM(
        prompt: String,
        capabilities: CapabilityRegistry,
        supportingObjectIDs: [KnowledgeObject.ID],
        supportingEventIDs: [Event.ID],
        supportingEntityIDs: [Entity.ID]
    ) async -> [ExpertFindings.Claim] {
        let spec = CapabilitySpec.reasoning(contextTokens: 6_000, purpose: "expert.project")
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
            AtlasLog.brain.error("ProjectExpert LLM call failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }
}
