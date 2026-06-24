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
        let result = try await context.retrieve(
            for: intent,
            layers: [.memory, .metadata, .entity, .timeline]
        )
        let contractEvents = result.events.filter {
            $0.kind == .contractSigned || $0.kind == .contractModified
        }

        let frame = PromptTemplates.legalAnalysis(intent: intent, retrieval: result)
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

        let claims = contractEvents.prefix(6).map { event in
            ExpertFindings.Claim(
                statement: "\(event.title) recorded on \(event.date.formatted(date: .abbreviated, time: .omitted))",
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
            notes: claims.isEmpty ? "No contractual events found." : nil,
            droppedUnverifiable: llm.dropped
        )
    }

    private func runLLM(
        frame: PromptFrame,
        capabilities: CapabilityRegistry
    ) async -> (claims: [ExpertFindings.Claim], dropped: Int) {
        let spec = CapabilitySpec.reasoning(contextTokens: 4_000, purpose: "expert.legal")
        guard let provider = try? await capabilities.resolve(spec) else {
            AtlasLog.brain.info("expert.legal LLM: no provider resolved for spec; using heuristic fallback")
            return ([], 0)
        }
        guard await provider.isAvailable() else {
            AtlasLog.brain.info("expert.legal LLM: provider=\(provider.id, privacy: .public) available=false; using heuristic fallback")
            return ([], 0)
        }
        AtlasLog.brain.info("expert.legal LLM: provider=\(provider.id, privacy: .public) available=true")
        // STRUCTURED-OUTPUT PATH (#7) — typed @Generable claims.
        if let fmProvider = provider as? FoundationModelsProvider {
            do {
                let typed = try await fmProvider.respondClaims(
                    prompt: frame.prompt,
                    systemPrompt: "You are Atlas. Use ONLY the evidence ids the prompt provides; never invent ids."
                )
                AtlasLog.brain.info("expert.legal LLM: produced \(typed.count) typed claims via @Generable")
                return (typed, 0)
            } catch {
                AtlasLog.brain.error("expert.legal LLM: typed path failed (\(String(describing: error), privacy: .public)); falling back to prompt-parse")
            }
        }
        do {
            let response = try await provider.generate(
                prompt: frame.prompt,
                options: GenerationOptions(maxTokens: 300, temperature: 0.2)
            )
            let parsed = ExpertResponseParser.parseClaims(from: response, evidenceMap: frame.evidenceMap)
            AtlasLog.brain.info("expert.legal LLM: provider=\(provider.id, privacy: .public) produced \(parsed.claims.count) claims, dropped \(parsed.dropped)")
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
            AtlasLog.brain.error("expert.legal LLM: provider=\(provider.id, privacy: .public) call failed → \(String(describing: error), privacy: .public)")
            return ([], 0)
        }
    }
}
