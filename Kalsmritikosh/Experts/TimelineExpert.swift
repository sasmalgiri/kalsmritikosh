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
        let result = try await context.retrieve(
            for: intent,
            layers: [.memory, .timeline, .entity]
        )

        let frame = PromptTemplates.timelineAnalysis(intent: intent, retrieval: result)
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

        let claims = result.events.prefix(12).map { event in
            ExpertFindings.Claim(
                statement: "\(event.kind.rawValue.replacingOccurrences(of: "_", with: " ").capitalized): \(event.title) \u{2014} \(event.date.formatted(date: .abbreviated, time: .shortened))",
                supportingObjectIDs: [event.sourceObjectID],
                supportingEventIDs: [event.id],
                supportingEntityIDs: event.entityIDs,
                confidence: Confidence(event.confidence.value * event.dateConfidence),
                evidenceGranularity: .coarse
            )
        }
        return ExpertFindings(
            expertID: id,
            claims: Array(claims),
            confidence: claims.isEmpty ? .zero : .medium,
            notes: claims.isEmpty ? "No events in retrieved range." : nil,
            droppedUnverifiable: llm.dropped
        )
    }

    private func runLLM(
        frame: PromptFrame,
        capabilities: CapabilityRegistry,
        context: LLMRequestContext?
    ) async -> (claims: [ExpertFindings.Claim], dropped: Int) {
        let spec = CapabilitySpec.reasoning(contextTokens: 6_000, purpose: "expert.timeline")
        guard let provider = try? await capabilities.resolve(spec) else {
            KalsmritikoshLog.brain.info("expert.timeline LLM: no provider resolved for spec; using heuristic fallback")
            return ([], 0)
        }
        guard await provider.isAvailable() else {
            KalsmritikoshLog.brain.info("expert.timeline LLM: provider=\(provider.id, privacy: .public) available=false; using heuristic fallback")
            return ([], 0)
        }
        KalsmritikoshLog.brain.info("expert.timeline LLM: provider=\(provider.id, privacy: .public) available=true")
        // STRUCTURED-OUTPUT PATH (#7) — typed @Generable claims.
        if let fmProvider = provider as? FoundationModelsProvider {
            do {
                let typed = try await fmProvider.respondClaims(
                    prompt: frame.prompt,
                    systemPrompt: "You are Kalsmritikosh. Use ONLY the evidence ids the prompt provides; never invent ids."
                )
                KalsmritikoshLog.brain.info("expert.timeline LLM: produced \(typed.count) typed claims via @Generable")
                return (typed, 0)
            } catch {
                KalsmritikoshLog.brain.error("expert.timeline LLM: typed path failed (\(String(describing: error), privacy: .public)); falling back to prompt-parse")
            }
        }
        do {
            let response = try await provider.generate(
                prompt: frame.prompt,
                options: GenerationOptions(maxTokens: 500, temperature: 0.2),
                purpose: "expert.timeline",
                context: context
            )
            let parsed = ExpertResponseParser.parseClaims(from: response, evidenceMap: frame.evidenceMap)
            KalsmritikoshLog.brain.info("expert.timeline LLM: provider=\(provider.id, privacy: .public) produced \(parsed.claims.count) claims, dropped \(parsed.dropped)")
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
            KalsmritikoshLog.brain.error("expert.timeline LLM: provider=\(provider.id, privacy: .public) call failed → \(String(describing: error), privacy: .public)")
            return ([], 0)
        }
    }
}
