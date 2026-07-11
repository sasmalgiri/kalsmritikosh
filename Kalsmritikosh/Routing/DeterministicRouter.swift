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
        let allExperts = await expertRegistry.experts(for: intent).map(\.id)
        // Ledger-first HARD budget (spec §9): the query class sets the expert
        // ceiling — ordinary/moderate 1, complex/investigation ≤2, and
        // reconstruction routes to the narrative composer (0 experts), never a
        // full fan-out. This bounds the expert calls BEFORE synthesis, so a
        // complex question can't blow its 3-call budget on experts alone.
        let queryClass = LLMQueryClassifier.classify(question: intent.rawQuestion, intent: intent)
        let experts = Self.minimalExpertSet(from: allExperts, queryClass: queryClass)
        let layers = retrievalLayers(for: intent.kind)
        let parallelism = max(1, min(max(1, experts.count), max(2, score.value)))
        let spec = answerSpec(for: intent, score: score)

        return RoutingDecision(
            answerSpec: spec,
            expertIDs: experts,
            retrievalLayers: layers,
            parallelism: parallelism,
            complexity: score.value,
            rationale: "class=\(queryClass.rawValue) budget=\(queryClass.callLimit) experts=\(experts.count) complexity=\(score.value) [\(score.contributors.joined(separator: ","))]"
        )
    }

    /// Cap the expert panel to the query class's `expertLimit` (spec §9),
    /// preferring the cross-evidence ReasoningExpert so the first call reasons
    /// across every retrieved layer, then filling with the intent's domain
    /// experts up to the ceiling. Reconstruction returns [] — that path is the
    /// narrative composer, not the expert fan-out.
    static func minimalExpertSet(from ids: [String], queryClass: LLMQueryClass) -> [String] {
        let limit = queryClass.expertLimit
        guard limit > 0, !ids.isEmpty else { return [] }
        var ordered: [String] = []
        if let generalist = ids.first(where: { $0 == "expert.reasoning" }) {
            ordered.append(generalist)
        }
        for id in ids where id != "expert.reasoning" && ordered.count < limit {
            ordered.append(id)
        }
        return Array(ordered.prefix(limit))
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
