//
//  FinancialExpert.swift
//  Kalsmritikosh
//

import Foundation
import OSLog

public struct FinancialExpert: Expert {
    public let id = "expert.financial"
    public let capabilities: Set<ExpertCapability> = [.revenueAnalysis, .costAnalysis]
    public let domains: Set<ExpertDomain> = [.financial]
    public init() {}

    public func analyze(intent: UserIntent, context: ExpertContext) async throws -> ExpertFindings {
        let result = try await context.retriever.retrieve(
            for: intent,
            layers: [.memory, .entity, .timeline, .metadata]
        )
        let financialEvents = result.events.filter {
            $0.kind == .invoiceIssued || $0.kind == .invoicePaid
        }
        let supportingObjectIDs = Array(Set(financialEvents.map(\.sourceObjectID)))
        let supportingEventIDs = financialEvents.map(\.id)

        let prompt = PromptTemplates.financialAnalysis(intent: intent, retrieval: result)
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

        let claims = financialEvents.prefix(8).map { event in
            ExpertFindings.Claim(
                statement: "\(event.title) \u{2014} \(event.date.formatted(date: .abbreviated, time: .omitted))",
                supportingObjectIDs: [event.sourceObjectID],
                supportingEventIDs: [event.id],
                confidence: event.confidence
            )
        }
        return ExpertFindings(
            expertID: id,
            claims: Array(claims),
            confidence: claims.isEmpty ? .zero : .medium,
            notes: claims.isEmpty ? "No invoice or payment events found." : nil
        )
    }

    private func runLLM(
        prompt: String,
        capabilities: CapabilityRegistry,
        supportingObjectIDs: [KnowledgeObject.ID],
        supportingEventIDs: [Event.ID]
    ) async -> [ExpertFindings.Claim] {
        let spec = CapabilitySpec.reasoning(contextTokens: 4_000, purpose: "expert.financial")
        guard let provider = try? await capabilities.resolve(spec),
              await provider.isAvailable() else { return [] }
        do {
            let response = try await provider.generate(
                prompt: prompt,
                options: GenerationOptions(maxTokens: 350, temperature: 0.2)
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
            AtlasLog.brain.error("FinancialExpert LLM call failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }
}
