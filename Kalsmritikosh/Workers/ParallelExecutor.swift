//
//  ParallelExecutor.swift
//  Kalsmritikosh
//
//  Hands a RoutingDecision and ExpertContext to the WorkerPool, then
//  folds the expert findings into a single sorted list with conflict
//  scoring for the Verifier.
//

import Foundation
import OSLog

public actor ParallelExecutor {
    private let pool: WorkerPool
    private let experts: ExpertRegistry

    public init(pool: WorkerPool, experts: ExpertRegistry) {
        self.pool = pool
        self.experts = experts
    }

    public func execute(
        intent: UserIntent,
        decision: RoutingDecision,
        context: ExpertContext
    ) async -> [ExpertFindings] {
        var resolved = await experts.all().filter { decision.expertIDs.contains($0.id) }
        // MoE gating — trim experts with no evidence for their domain (they
        // would produce nothing). Conservative: only when we have retrieval
        // to score against and more than a handful are in play; never starves.
        if FeatureFlags.expertRelevanceGatingValue(),
           let retrieval = context.sharedRetrieval,
           resolved.count > 3 {
            let selected = ExpertRelevanceScorer.select(from: resolved, intent: intent, retrieval: retrieval)
            if selected.count < resolved.count {
                KalsmritikoshLog.brain.info("MoE gating: \(resolved.count, privacy: .public) → \(selected.count, privacy: .public) experts [\(selected.map(\.id).joined(separator: ","), privacy: .public)]")
                resolved = selected
            }
        }
        let tasks: [@Sendable () async throws -> ExpertFindings] = resolved.map { expert in
            { try await expert.analyze(intent: intent, context: context) }
        }
        let results = await pool.run(tasks)
        return results.compactMap { try? $0.get() }
    }
}
