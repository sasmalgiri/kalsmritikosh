//
//  EmailExpert.swift
//  Kalsmritikosh
//
//  Asks the CapabilityRegistry for a reasoning model and uses it to
//  produce thread/relationship analysis over the retrieved email events.
//  The LLM path emits strict-JSON claims with per-claim E-id evidence;
//  the heuristic fallback enumerates events with per-event evidence.
//  Never names a model.
//

import Foundation
import OSLog

public struct EmailExpert: Expert {
    public let id = "expert.email"
    public let capabilities: Set<ExpertCapability> = [.threadAnalysis, .relationshipAnalysis]
    public let domains: Set<ExpertDomain> = [.email]
    public init() {}

    public func analyze(intent: UserIntent, context: ExpertContext) async throws -> ExpertFindings {
        // G2-0 — use shared retrieval when MasterBrain pre-fetched it;
        // otherwise fall back to a fresh call with the expert's layers.
        let result = try await context.retrieve(
            for: intent,
            layers: [.memory, .entity, .timeline, .metadata]
        )
        let emailEvents = result.events.filter {
            $0.kind == .emailSent || $0.kind == .emailReceived
        }

        let frame = PromptTemplates.emailAnalysis(intent: intent, retrieval: result)
        let llm = await tryLLM(frame: frame, capabilities: context.capabilities)
        if !llm.claims.isEmpty {
            return ExpertFindings(
                expertID: id,
                claims: llm.claims,
                confidence: aggregateConfidence(llm.claims),
                droppedUnverifiable: llm.dropped
            )
        }

        // Heuristic fallback: enumerate the strongest events with their
        // own per-event evidence.
        let claims = emailEvents.prefix(8).map { event in
            ExpertFindings.Claim(
                statement: "Email: \(event.title) on \(event.date.formatted(date: .abbreviated, time: .shortened))",
                supportingObjectIDs: [event.sourceObjectID],
                supportingEventIDs: [event.id],
                supportingEntityIDs: event.entityIDs,
                // T9 close-out — weight by date_confidence so mtime-
                // fallback events contribute less than header-parsed ones.
                confidence: Confidence(event.confidence.value * event.dateConfidence),
                evidenceGranularity: .coarse
            )
        }
        return ExpertFindings(
            expertID: id,
            claims: Array(claims),
            confidence: claims.isEmpty ? .zero : .medium,
            notes: claims.isEmpty ? "No email evidence found in retrieved scope." : nil,
            droppedUnverifiable: llm.dropped
        )
    }

    private func tryLLM(
        frame: PromptFrame,
        capabilities: CapabilityRegistry
    ) async -> (claims: [ExpertFindings.Claim], dropped: Int) {
        let spec = CapabilitySpec.reasoning(contextTokens: 4_000, purpose: "expert.email")
        guard let provider = try? await capabilities.resolve(spec) else {
            AtlasLog.brain.info("expert.email LLM: no provider resolved for spec; using heuristic fallback")
            return ([], 0)
        }
        guard await provider.isAvailable() else {
            AtlasLog.brain.info("expert.email LLM: provider=\(provider.id, privacy: .public) available=false; using heuristic fallback")
            return ([], 0)
        }
        AtlasLog.brain.info("expert.email LLM: provider=\(provider.id, privacy: .public) available=true")
        // STRUCTURED-OUTPUT PATH (#7) — typed @Generable claims when
        // the resolved provider is FoundationModels.
        if let fmProvider = provider as? FoundationModelsProvider {
            do {
                let typed = try await fmProvider.respondClaims(
                    prompt: frame.prompt,
                    systemPrompt: "You are Atlas. Use ONLY the evidence ids the prompt provides; never invent ids."
                )
                AtlasLog.brain.info("expert.email LLM: produced \(typed.count) typed claims via @Generable")
                return (typed, 0)
            } catch {
                AtlasLog.brain.error("expert.email LLM: typed path failed (\(String(describing: error), privacy: .public)); falling back to prompt-parse")
            }
        }
        do {
            let response = try await provider.generate(
                prompt: frame.prompt,
                options: GenerationOptions(maxTokens: 400, temperature: 0.2)
            )
            let parsed = ExpertResponseParser.parseClaims(from: response, evidenceMap: frame.evidenceMap)
            AtlasLog.brain.info("expert.email LLM: provider=\(provider.id, privacy: .public) produced \(parsed.claims.count) claims, dropped \(parsed.dropped)")
            let claims = parsed.claims.map { parsedClaim in
                ExpertFindings.Claim(
                    statement: parsedClaim.text,
                    supportingObjectIDs: parsedClaim.citation.supportingObjectIDs,
                    supportingEventIDs: parsedClaim.citation.supportingEventIDs,
                    supportingEntityIDs: parsedClaim.citation.supportingEntityIDs,
                    confidence: .medium,
                    evidenceGranularity: .specific
                )
            }
            return (claims, parsed.dropped)
        } catch {
            AtlasLog.brain.error("expert.email LLM: provider=\(provider.id, privacy: .public) call failed → \(String(describing: error), privacy: .public)")
            return ([], 0)
        }
    }

    private func aggregateConfidence(_ claims: [ExpertFindings.Claim]) -> Confidence {
        Confidence.aggregate(
            claims.map(\.confidence),
            agreement: 1.0,
            diversity: 1.0,
            contradictionPenalty: 0.0
        )
    }
}
