//
//  ParallelExecutor.swift
//  Atlas chronica memora
//
//  Hands a RoutingDecision and ExpertContext to the WorkerPool, then
//  folds the expert findings into a single sorted list with conflict
//  scoring for the Verifier.
//

import Foundation

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
        let resolved = await experts.all().filter { decision.expertIDs.contains($0.id) }
        let tasks: [@Sendable () async throws -> ExpertFindings] = resolved.map { expert in
            { try await expert.analyze(intent: intent, context: context) }
        }
        let results = await pool.run(tasks)
        return results.compactMap { try? $0.get() }
    }
}
