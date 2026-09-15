//
//  HealthReport.swift
//  Kalsmritikosh
//
//  U-3.3 (W-6) — the Health & Self-check panel's DATA MODEL, replacing the
//  old live-pipeline strip's ad-hoc numbers with (a) coverage rows and
//  (b) INVARIANT CHECKS that are pass / warn / fail. The evaluator is PURE
//  so CI proves the panel goes red exactly when an invariant is violated
//  (the acceptance) without booting the app.
//
//  Invariants (each a fixture can trip in a debug build):
//    · causal budget — grounded links per event ≤ budget
//    · ghost anchors = 0
//    · stale rows behind the current producer era = 0
//    · junk in the gated register = 0
//    · every anchor threaded onto exactly one chain (H3)
//    · frontiers empty
//    · backfill pending = 0
//    · embedding coverage consistent (states sum to total)
//

import Foundation

/// One coverage row — a named breakdown with per-state counts.
public struct HealthCoverageRow: Sendable, Equatable, Identifiable {
    public let id: String        // stable key ("facts", "anchors", …)
    public let title: String
    public let states: [(label: String, count: Int)]

    public init(id: String, title: String, states: [(label: String, count: Int)]) {
        self.id = id
        self.title = title
        self.states = states
    }

    public static func == (lhs: HealthCoverageRow, rhs: HealthCoverageRow) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title
            && lhs.states.map(\.label) == rhs.states.map(\.label)
            && lhs.states.map(\.count) == rhs.states.map(\.count)
    }

    public var total: Int { states.reduce(0) { $0 + $1.count } }
}

/// One invariant check.
public struct HealthInvariant: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable { case pass, warn, fail }
    public let id: String
    public let title: String
    public let status: Status
    public let detail: String

    public init(id: String, title: String, status: Status, detail: String) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
    }
}

/// The raw numbers the evaluator turns into invariant verdicts. Gathered
/// from repositories by the async builder; kept separate so the verdict
/// logic is a pure function of these inputs.
public struct HealthInputs: Sendable, Equatable {
    public var maxCausalLinksPerEvent: Int
    public var causalBudget: Int
    public var ghostAnchorCount: Int
    public var staleRowsBehindEra: Int
    public var gatedRegisterJunkCount: Int
    public var anchorsUnthreaded: Int
    public var frontierOpenCount: Int
    public var backfillPending: Int
    public var embeddingConsistent: Bool

    public init(maxCausalLinksPerEvent: Int = 0, causalBudget: Int = 3,
                ghostAnchorCount: Int = 0, staleRowsBehindEra: Int = 0,
                gatedRegisterJunkCount: Int = 0, anchorsUnthreaded: Int = 0,
                frontierOpenCount: Int = 0, backfillPending: Int = 0,
                embeddingConsistent: Bool = true) {
        self.maxCausalLinksPerEvent = maxCausalLinksPerEvent
        self.causalBudget = causalBudget
        self.ghostAnchorCount = ghostAnchorCount
        self.staleRowsBehindEra = staleRowsBehindEra
        self.gatedRegisterJunkCount = gatedRegisterJunkCount
        self.anchorsUnthreaded = anchorsUnthreaded
        self.frontierOpenCount = frontierOpenCount
        self.backfillPending = backfillPending
        self.embeddingConsistent = embeddingConsistent
    }
}

public struct HealthReport: Sendable, Equatable {
    public let coverage: [HealthCoverageRow]
    public let invariants: [HealthInvariant]

    public init(coverage: [HealthCoverageRow], invariants: [HealthInvariant]) {
        self.coverage = coverage
        self.invariants = invariants
    }

    /// The panel is RED when any invariant failed, AMBER when only warnings.
    public var worstStatus: HealthInvariant.Status {
        if invariants.contains(where: { $0.status == .fail }) { return .fail }
        if invariants.contains(where: { $0.status == .warn }) { return .warn }
        return .pass
    }

    /// Pure invariant evaluation — the core the acceptance test drives.
    public nonisolated static func evaluateInvariants(_ i: HealthInputs) -> [HealthInvariant] {
        func check(_ id: String, _ title: String, _ ok: Bool, _ detail: String,
                   warnNotFail: Bool = false) -> HealthInvariant {
            HealthInvariant(id: id, title: title,
                            status: ok ? .pass : (warnNotFail ? .warn : .fail),
                            detail: detail)
        }
        return [
            check("causal-budget", "Causal links within budget",
                  i.maxCausalLinksPerEvent <= i.causalBudget,
                  "max \(i.maxCausalLinksPerEvent) grounded links on one event (budget \(i.causalBudget))"),
            check("ghost-anchors", "No ghost anchors",
                  i.ghostAnchorCount == 0,
                  "\(i.ghostAnchorCount) ghost anchor(s)"),
            check("era-current", "No rows behind the current era",
                  i.staleRowsBehindEra == 0,
                  "\(i.staleRowsBehindEra) row(s) behind the producer era"),
            check("register-clean", "No junk in the gated register",
                  i.gatedRegisterJunkCount == 0,
                  "\(i.gatedRegisterJunkCount) junk row(s) in the register"),
            check("anchors-threaded", "Every anchor threaded",
                  i.anchorsUnthreaded == 0,
                  "\(i.anchorsUnthreaded) anchor(s) not on a chain"),
            check("frontiers-empty", "Maintenance frontiers empty",
                  i.frontierOpenCount == 0,
                  "\(i.frontierOpenCount) frontier item(s) open", warnNotFail: true),
            check("backfill-done", "Backfill pending is zero",
                  i.backfillPending == 0,
                  "\(i.backfillPending) item(s) awaiting backfill", warnNotFail: true),
            check("embedding-consistent", "Embedding states sum to total",
                  i.embeddingConsistent,
                  i.embeddingConsistent ? "consistent" : "counts do not sum to the chunk total"),
        ]
    }

    public nonisolated static func make(coverage: [HealthCoverageRow], inputs: HealthInputs) -> HealthReport {
        HealthReport(coverage: coverage, invariants: evaluateInvariants(inputs))
    }
}
