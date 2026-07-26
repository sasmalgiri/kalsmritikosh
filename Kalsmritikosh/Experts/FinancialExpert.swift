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
        let authorized = try await context.retrieveAuthorized(
            for: intent,
            layers: [.memory, .entity, .timeline, .metadata]
        )
        let result = authorized.result
        let financialEvents = result.events.filter {
            $0.kind == .invoiceIssued || $0.kind == .invoicePaid
        }

        let frame = PromptTemplates.financialAnalysis(intent: intent,
                                                      retrieval: await context.promptAuthorizer.authorize(authorized))
        let llm = await runLLM(frame: frame, capabilities: context.capabilities, context: context.llmContext)
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

        let claims = financialEvents.prefix(8).map { event in
            ExpertFindings.Claim(
                statement: "\(event.title) \u{2014} \(event.date.formatted(date: .abbreviated, time: .omitted))",
                supportingObjectIDs: [event.sourceObjectID],
                supportingEventIDs: [event.id],
                confidence: Confidence(event.confidence.value * event.dateConfidence),
                evidenceGranularity: .coarse
            )
        }
        return ExpertFindings(
            expertID: id,
            claims: Array(claims),
            confidence: claims.isEmpty ? .zero : .medium,
            notes: claims.isEmpty ? "No invoice or payment events found." : nil,
            droppedUnverifiable: llm.dropped
        )
    }

    private func runLLM(
        frame: PromptFrame,
        capabilities: CapabilityRegistry,
        context: LLMRequestContext?
    ) async -> (claims: [ExpertFindings.Claim], dropped: Int) {
        let spec = CapabilitySpec.reasoning(contextTokens: 4_000, purpose: "expert.financial")
        guard let provider = try? await capabilities.resolve(spec) else {
            KalsmritikoshLog.brain.info("expert.financial LLM: no provider resolved for spec; using heuristic fallback")
            return ([], 0)
        }
        guard await provider.isAvailable() else {
            KalsmritikoshLog.brain.info("expert.financial LLM: provider=\(provider.id, privacy: .public) available=false; using heuristic fallback")
            return ([], 0)
        }
        KalsmritikoshLog.brain.info("expert.financial LLM: provider=\(provider.id, privacy: .public) available=true")
        // STRUCTURED-OUTPUT PATH (#7) — typed @Generable claims.
        if let fmProvider = provider as? FoundationModelsProvider {
            do {
                let typed = try await fmProvider.respondClaims(
                    prompt: frame.prompt,
                    systemPrompt: "You are Kalsmritikosh. Use ONLY the evidence ids the prompt provides; never invent ids."
                )
                KalsmritikoshLog.brain.info("expert.financial LLM: produced \(typed.count) typed claims via @Generable")
                return (typed, 0)
            } catch {
                KalsmritikoshLog.brain.error("expert.financial LLM: typed path failed (\(String(describing: error), privacy: .public)); falling back to prompt-parse")
            }
        }
        do {
            let response = try await provider.generate(
                prompt: frame.prompt,
                options: GenerationOptions(maxTokens: 350, temperature: 0.2),
                purpose: "expert.financial",
                context: context
            )
            let parsed = ExpertResponseParser.parseClaims(from: response, evidenceMap: frame.evidenceMap)
            KalsmritikoshLog.brain.info("expert.financial LLM: provider=\(provider.id, privacy: .public) produced \(parsed.claims.count) claims, dropped \(parsed.dropped)")
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
            KalsmritikoshLog.brain.error("expert.financial LLM: provider=\(provider.id, privacy: .public) call failed → \(String(describing: error), privacy: .public)")
            return ([], 0)
        }
    }
}
