//
//  LLMCallBudget.swift
//  Kalsmritikosh
//
//  One hard, request-scoped LLM-call allowance. Created once per user action
//  (MasterBrain / InvestigationRunner) from the request's LLMQueryClass, then
//  shared — via LLMRequestContext — by every nested operation: routed experts,
//  answer synthesis, council members, narrative chapters, investigation
//  planning + steps + synthesis, query-time extraction, chunk-RAG fallback,
//  and any optional LLM reranking.
//
//  Enforcement contract (§4):
//    - reserve() before every generative call; throws once the limit is hit.
//    - a FAILED provider request still consumes a call (compute/network was
//      attempted) — never auto-refunded.
//    - retries consume additional calls, so runaway retries become visible.
//

import Foundation

public enum LLMCallBudgetError: Error, Sendable {
    case exhausted(limit: Int, attemptedPurpose: String)
}

public actor LLMCallBudget {

    public struct Entry: Sendable, Codable {
        public let sequence: Int
        public let purpose: String
        public let providerID: String?
        public let timestamp: Date
        public var status: Status

        public enum Status: String, Sendable, Codable {
            case reserved
            case completed
            case failed
            case cancelled
        }
    }

    public struct Snapshot: Sendable {
        public let limit: Int
        public let used: Int
        public let remaining: Int
        public let entries: [Entry]
    }

    private let limit: Int
    private var entries: [Entry] = []

    public init(limit: Int) {
        self.limit = max(0, limit)
    }

    /// Reserve one call before inference. Throws `.exhausted` when the ceiling
    /// is reached — the caller must degrade to a deterministic path, never
    /// silently make the call anyway.
    @discardableResult
    public func reserve(purpose: String, providerID: String?) throws -> Int {
        guard entries.count < limit else {
            throw LLMCallBudgetError.exhausted(limit: limit, attemptedPurpose: purpose)
        }
        let sequence = entries.count + 1
        entries.append(
            Entry(
                sequence: sequence,
                purpose: purpose,
                providerID: providerID,
                timestamp: Date(),
                status: .reserved
            )
        )
        return sequence
    }

    /// Mark a reserved call's terminal state. The call still counts against the
    /// budget regardless of status (failed/cancelled included).
    public func finish(sequence: Int, status: Entry.Status) {
        guard let index = entries.firstIndex(where: { $0.sequence == sequence }) else { return }
        entries[index].status = status
    }

    /// Whether `count` more calls fit under the ceiling. Used by callers to
    /// check remaining budget BEFORE committing to an expensive stage.
    public func canSpend(_ count: Int = 1) -> Bool {
        entries.count + max(0, count) <= limit
    }

    public func snapshot() -> Snapshot {
        Snapshot(
            limit: limit,
            used: entries.count,
            remaining: max(0, limit - entries.count),
            entries: entries
        )
    }
}
