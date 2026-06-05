//
//  DeterministicRouter.swift
//  Kalsmritikosh
//
//  Builds a RoutingDecision deterministically: picks experts from
//  ExpertRegistry, picks retrieval layers from the locked priority order,
//  produces a CapabilitySpec describing what the brain needs from a model
//  (resolved later by the CapabilityRegistry). NEVER names a model.
//

import Foundation

public actor DeterministicRouter: Router {
    private let expertRegistry: ExpertRegistry
    private let complexity: any ComplexityAnalyzer

    public init(
        expertRegistry: ExpertRegistry,
        complexity: any ComplexityAnalyzer = HeuristicComplexityAnalyzer()
    ) {
        self.expertRegistry = expertRegistry
        self.complexity = complexity
    }

    public func route(intent: UserIntent) async throws -> RoutingDecision {
        let score = await complexity.score(intent)
        let experts = await expertRegistry.experts(for: intent).map(\.id)
        let layers = retrievalLayers(for: intent.kind)
        let parallelism = max(1, min(experts.count, max(2, score.value)))
        let spec = answerSpec(for: intent, score: score)

        return RoutingDecision(
            answerSpec: spec,
            expertIDs: experts,
            retrievalLayers: layers,
            parallelism: parallelism,
            complexity: score.value,
            rationale: "complexity=\(score.value) [\(score.contributors.joined(separator: ","))]"
        )
    }

    private func retrievalLayers(for kind: UserIntent.Kind) -> [RetrievalLayer] {
        switch kind {
        case .reconstructTimeline, .reconstructProject, .reconstructRelationship:
            return [.memory, .timeline, .entity, .graph, .summary, .metadata, .vector]
        case .executiveBriefing:
            return [.memory, .summary, .timeline, .entity, .metadata, .graph, .vector]
        case .factualLookup, .semanticSearch:
            return [.memory, .entity, .metadata, .summary, .timeline, .graph, .vector]
        case .riskDetection, .missingInformation:
            return [.memory, .timeline, .entity, .metadata, .summary, .graph, .vector]
        case .unknown:
            return RetrievalLayer.priorityOrder
        }
    }

    /// Build a CapabilitySpec scaled to the complexity score. Lower scores
    /// ask for cheaper/faster capabilities; higher scores ask for reasoning
    /// + long context. The Router never names a model — only what's needed.
    private func answerSpec(for intent: UserIntent, score: ComplexityScore) -> CapabilitySpec {
        var requires: Set<ModelCapability> = [.textGeneration]
        var prefers: Set<ModelCapability> = [.structuredOutput]
        var latency: LatencyHint = .background
        var ctx = 4_000

        switch score.value {
        case 1, 2:
            requires.insert(.classification)
            prefers.insert(.routerSmall)
            latency = .interactive
            ctx = 1_500
        case 3:
            requires.insert(.reasoning)
            prefers.insert(.summarization)
            ctx = 4_000
        case 4:
            requires.insert(.reasoning)
            requires.insert(.summarization)
            prefers.insert(.longContext)
            prefers.insert(.expertLarge)
            ctx = 8_000
        default:
            requires.insert(.reasoning)
            requires.insert(.summarization)
            requires.insert(.longContext)
            prefers.insert(.expertLarge)
            ctx = 12_000
        }

        return CapabilitySpec(
            requires: requires,
            prefers: prefers,
            maxLatency: latency,
            privacy: .onDevice,
            estimatedContextTokens: ctx,
            purpose: "answer:\(intent.kind.rawValue)"
        )
    }
}
