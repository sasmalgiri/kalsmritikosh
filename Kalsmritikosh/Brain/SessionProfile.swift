//
//  SessionProfile.swift
//  Kalsmritikosh
//
//  G2-1.5 — per-session, in-memory question-meaning context.
//
//  Why: multi-turn benchmarks (mtRAG, MTRAG, "Lost in Conversation")
//  show LLMs lose 30–39% of single-turn quality across follow-ups
//  because they commit to an interpretation on turn 1 and never
//  revise. A small session snapshot — last N turns + recency-ordered
//  entities — lets the Reranker (and a future query rewriter)
//  resolve anaphora ("the same supplier"), ellipsis ("by when?"),
//  and topic-return jumps without re-asking the user.
//
//  Privacy: in-memory only. Nothing here is persisted; the ledger
//  remains the single store of record. Resets on app relaunch or
//  explicit `reset()`.
//

import Foundation

public actor SessionProfile {
    public struct Turn: Sendable {
        public let rawQuestion: String
        public let intentKind: String
        public let entityHints: [String]
        public let recordedAt: Date
    }

    /// Sendable view the Reranker / future query rewriter reads
    /// without re-entering the actor.
    public struct Snapshot: Sendable {
        public let recentTurns: [Turn]
        /// Deduped, recency-first — most recently mentioned entity is
        /// first. Reranker uses this to resolve "it" / "that one" /
        /// "the same supplier" without an extra LLM round-trip.
        public let mentionedEntities: [String]
        public let lastIntentKind: String?

        public var isEmpty: Bool { recentTurns.isEmpty }
    }

    private let maxTurns: Int
    private var turns: [Turn] = []

    public init(maxTurns: Int = 5) {
        self.maxTurns = max(1, maxTurns)
    }

    public func recordTurn(question: String, intentKind: String, entityHints: [String]) {
        let turn = Turn(
            rawQuestion: question,
            intentKind: intentKind,
            entityHints: entityHints,
            recordedAt: Date()
        )
        turns.append(turn)
        if turns.count > maxTurns {
            turns.removeFirst(turns.count - maxTurns)
        }
    }

    public func snapshot() -> Snapshot {
        var seen = Set<String>()
        var entities: [String] = []
        for turn in turns.reversed() {
            for hint in turn.entityHints where !hint.isEmpty {
                let key = hint.lowercased()
                if seen.insert(key).inserted {
                    entities.append(hint)
                }
            }
        }
        return Snapshot(
            recentTurns: turns,
            mentionedEntities: entities,
            lastIntentKind: turns.last?.intentKind
        )
    }

    public func reset() {
        turns.removeAll()
    }
}
