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

        let frame = PromptTemplates.projectAnalysis(intent: intent, retrieval: result)
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

        var claims: [ExpertFindings.Claim] = []
        for event in result.events.prefix(8) {
            claims.append(.init(
                statement: "Project event: \(event.title) \u{2014} \(event.date.formatted(date: .abbreviated, time: .omitted))",
                supportingObjectIDs: [event.sourceObjectID],
                supportingEventIDs: [event.id],
                supportingEntityIDs: event.entityIDs,
                confidence: Confidence(event.confidence.value * event.dateConfidence),
                evidenceGranularity: .coarse
            ))
        }
        let stakeholders = result.entities.filter { $0.kind == .person || $0.kind == .organization }
        if !stakeholders.isEmpty {
            let names = stakeholders.prefix(8).map(\.value).joined(separator: ", ")
            claims.append(.init(
                statement: "Stakeholders: \(names)",
                supportingEntityIDs: stakeholders.prefix(8).map(\.id),
                confidence: .medium,
                evidenceGranularity: .coarse
            ))
        }
        return ExpertFindings(
            expertID: id,
            claims: claims,
            confidence: claims.isEmpty ? .zero : .medium,
            notes: claims.isEmpty ? "No project signal in retrieved scope." : nil,
            droppedUnverifiable: llm.dropped
        )
    }

    private func runLLM(
        frame: PromptFrame,
        capabilities: CapabilityRegistry
    ) async -> (claims: [ExpertFindings.Claim], dropped: Int) {
        let spec = CapabilitySpec.reasoning(contextTokens: 6_000, purpose: "expert.project")
        guard let provider = try? await capabilities.resolve(spec) else {
            AtlasLog.brain.info("expert.project LLM: no provider resolved for spec; using heuristic fallback")
            return ([], 0)
        }
        guard await provider.isAvailable() else {
            AtlasLog.brain.info("expert.project LLM: provider=\(provider.id, privacy: .public) available=false; using heuristic fallback")
            return ([], 0)
        }
        AtlasLog.brain.info("expert.project LLM: provider=\(provider.id, privacy: .public) available=true")
        do {
            let response = try await provider.generate(
                prompt: frame.prompt,
                options: GenerationOptions(maxTokens: 500, temperature: 0.2)
            )
            let parsed = ExpertResponseParser.parseClaims(from: response, evidenceMap: frame.evidenceMap)
            AtlasLog.brain.info("expert.project LLM: provider=\(provider.id, privacy: .public) produced \(parsed.claims.count) claims, dropped \(parsed.dropped)")
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
            AtlasLog.brain.error("expert.project LLM: provider=\(provider.id, privacy: .public) call failed → \(String(describing: error), privacy: .public)")
            return ([], 0)
        }
    }
}
