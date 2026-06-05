//
//  EmailExpert.swift
//  Kalsmritikosh
//
//  Asks the CapabilityRegistry for a reasoning model and uses it to
//  produce thread/relationship analysis over the retrieved email events.
//  Falls back to a deterministic event-listing finding when no model
//  resolves. Never names a model.
//

import Foundation
import OSLog

public struct EmailExpert: Expert {
    public let id = "expert.email"
    public let capabilities: Set<ExpertCapability> = [.threadAnalysis, .relationshipAnalysis]
    public let domains: Set<ExpertDomain> = [.email]
    public init() {}

    public func analyze(intent: UserIntent, context: ExpertContext) async throws -> ExpertFindings {
        let result = try await context.retriever.retrieve(
            for: intent,
            layers: [.memory, .entity, .timeline, .metadata]
        )
        let emailEvents = result.events.filter {
            $0.kind == .emailSent || $0.kind == .emailReceived
        }
        let supportingObjectIDs = Array(Set(emailEvents.map(\.sourceObjectID)))
        let supportingEventIDs = emailEvents.map(\.id)
        let supportingEntityIDs = Array(Set(emailEvents.flatMap(\.entityIDs)))

        let prompt = PromptTemplates.emailAnalysis(intent: intent, retrieval: result)
        let llmClaims = await tryLLM(
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
                confidence: aggregateConfidence(llmClaims)
            )
        }

        // Heuristic fallback: enumerate the strongest events.
        let claims = emailEvents.prefix(8).map { event in
            ExpertFindings.Claim(
                statement: "Email: \(event.title) on \(event.date.formatted(date: .abbreviated, time: .shortened))",
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
            notes: claims.isEmpty ? "No email evidence found in retrieved scope." : nil
        )
    }

    private func tryLLM(
        prompt: String,
        capabilities: CapabilityRegistry,
        supportingObjectIDs: [KnowledgeObject.ID],
        supportingEventIDs: [Event.ID],
        supportingEntityIDs: [Entity.ID]
    ) async -> [ExpertFindings.Claim] {
        let spec = CapabilitySpec.reasoning(contextTokens: 4_000, purpose: "expert.email")
        guard let provider = try? await capabilities.resolve(spec),
              await provider.isAvailable() else { return [] }
        do {
            let response = try await provider.generate(
                prompt: prompt,
                options: GenerationOptions(maxTokens: 400, temperature: 0.2)
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
            AtlasLog.brain.error("EmailExpert LLM call failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    private func aggregateConfidence(_ claims: [ExpertFindings.Claim]) -> Confidence {
        guard !claims.isEmpty else { return .zero }
        return claims.map(\.confidence).reduce(.zero) { $0.combined(with: $1) }
    }
}
