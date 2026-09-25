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
    /// `notMeasured` exists because the alternative is a LIE: an invariant that
    /// was never evaluated used to render as a green tick, so a fresh install
    /// or a just-erased ledger reported "All checks passing" having checked
    /// nothing. Absence of a measurement is its own state.
    public enum Status: String, Sendable { case pass, warn, fail, notMeasured }
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
/// Every field is OPTIONAL and defaults to nil, meaning "not measured".
/// Previously they defaulted to passing values (0 ghosts, consistent
/// embeddings), so any caller that forgot to populate one got a green tick for
/// an invariant nobody had evaluated — and `HealthInputs()` produced a
/// clean bill of health from no data at all.
public struct HealthInputs: Sendable, Equatable {
    public var maxCausalLinksPerEvent: Int?
    /// Policy, not a measurement, so this one stays concrete.
    public var causalBudget: Int
    public var ghostAnchorCount: Int?
    public var staleRowsBehindEra: Int?
    public var gatedRegisterJunkCount: Int?
    public var anchorsUnthreaded: Int?
    public var frontierOpenCount: Int?
    public var backfillPending: Int?
    public var embeddingConsistent: Bool?

    public init(maxCausalLinksPerEvent: Int? = nil, causalBudget: Int = 3,
                ghostAnchorCount: Int? = nil, staleRowsBehindEra: Int? = nil,
                gatedRegisterJunkCount: Int? = nil, anchorsUnthreaded: Int? = nil,
                frontierOpenCount: Int? = nil, backfillPending: Int? = nil,
                embeddingConsistent: Bool? = nil) {
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
    /// WHEN this report was taken. The panel is a snapshot rendered beside
    /// live-polling cards, and without a visible age a stale snapshot is
    /// indistinguishable from a current measurement.
    ///
    /// OWNER WITNESS 2026-09-25: the dashboard showed "Chunks 9,611" in the
    /// cards and "chunks: 0" in this panel's Coverage rows at the same moment.
    /// The panel had been built once at view-appear, racing the metrics poller,
    /// so it captured the first empty sample and never refreshed. Nothing on
    /// screen said it was old.
    public let generatedAt: Date
    /// Nil when the live sample was unavailable at build time — the coverage
    /// rows are then absent rather than zero, because "not sampled yet" and
    /// "measured zero" are different facts.
    public let sampleCapturedAt: Date?

    public init(coverage: [HealthCoverageRow], invariants: [HealthInvariant],
                generatedAt: Date = Date(), sampleCapturedAt: Date? = nil) {
        self.coverage = coverage
        self.invariants = invariants
        self.generatedAt = generatedAt
        self.sampleCapturedAt = sampleCapturedAt
    }

    /// The panel is RED when any invariant failed, AMBER when only warnings.
    /// When NOTHING was actually measured the panel is `notMeasured`, never
    /// green: "all checks passing" over zero checks is the false-green this
    /// type exists to prevent.
    public var worstStatus: HealthInvariant.Status {
        if invariants.contains(where: { $0.status == .fail }) { return .fail }
        if invariants.contains(where: { $0.status == .warn }) { return .warn }
        if invariants.contains(where: { $0.status == .pass }) { return .pass }
        return .notMeasured
    }

    /// How many invariants were actually evaluated — the number the panel's
    /// summary quotes, so "passing" always comes with "out of how many".
    public var measuredCount: Int {
        invariants.filter { $0.status != .notMeasured }.count
    }

    /// Pure invariant evaluation — the core the acceptance test drives.
    public nonisolated static func evaluateInvariants(_ i: HealthInputs) -> [HealthInvariant] {
        /// `ok == nil` means the quantity was never measured, which is
        /// reported as such rather than resolved either way.
        func check(_ id: String, _ title: String, _ ok: Bool?, _ detail: String,
                   warnNotFail: Bool = false) -> HealthInvariant {
            guard let ok else {
                return HealthInvariant(id: id, title: title, status: .notMeasured,
                                       detail: "not measured")
            }
            return HealthInvariant(id: id, title: title,
                                   status: ok ? .pass : (warnNotFail ? .warn : .fail),
                                   detail: detail)
        }
        /// Detail text for a count, only reached when the count exists.
        func described(_ value: Int?, _ text: (Int) -> String) -> String {
            value.map(text) ?? "not measured"
        }
        return [
            check("causal-budget", "Causal links within budget",
                  i.maxCausalLinksPerEvent.map { $0 <= i.causalBudget },
                  described(i.maxCausalLinksPerEvent) {
                      "max \($0) grounded links on one event (budget \(i.causalBudget))" }),
            check("ghost-anchors", "No ghost anchors",
                  i.ghostAnchorCount.map { $0 == 0 },
                  described(i.ghostAnchorCount) { "\($0) ghost anchor(s)" }),
            check("era-current", "No rows behind the current era",
                  i.staleRowsBehindEra.map { $0 == 0 },
                  described(i.staleRowsBehindEra) { "\($0) row(s) behind the producer era" }),
            check("register-clean", "No junk in the gated register",
                  i.gatedRegisterJunkCount.map { $0 == 0 },
                  described(i.gatedRegisterJunkCount) { "\($0) junk row(s) in the register" }),
            check("anchors-threaded", "Every anchor threaded",
                  i.anchorsUnthreaded.map { $0 == 0 },
                  described(i.anchorsUnthreaded) { "\($0) anchor(s) not on a chain" }),
            check("frontiers-empty", "Maintenance frontiers empty",
                  i.frontierOpenCount.map { $0 == 0 },
                  described(i.frontierOpenCount) { "\($0) frontier item(s) open" },
                  warnNotFail: true),
            check("backfill-done", "Backfill pending is zero",
                  i.backfillPending.map { $0 == 0 },
                  described(i.backfillPending) { "\($0) item(s) awaiting backfill" },
                  warnNotFail: true),
            check("embedding-consistent", "Embedding states sum to total",
                  i.embeddingConsistent,
                  i.embeddingConsistent == true
                      ? "consistent" : "counts do not sum to the chunk total"),
        ]
    }

    // MARK: - Live-path invariants (pure, so the vacuous-pass gating is provable)
    //
    // The live builder used to construct these inline, which is how three
    // false greens got in: each check reads as PASS on an empty ledger, where
    // the honest verdict is that there was nothing to check. Keeping the
    // decision here makes it testable without an AppState.

    /// Embedding states sum to the chunk total — meaningless with no chunks.
    public nonisolated static func embeddingInvariant(_ coverage: EmbeddingCoverage)
    -> HealthInvariant {
        guard coverage.hasContent else {
            return HealthInvariant(id: "embedding-consistent",
                                   title: "Embedding states sum to total",
                                   status: .notMeasured, detail: "no chunks to check yet")
        }
        return HealthInvariant(
            id: "embedding-consistent", title: "Embedding states sum to total",
            status: coverage.isConsistent ? .pass : .fail,
            detail: coverage.isConsistent ? "consistent"
                                          : "counts do not sum to the chunk total")
    }

    /// Grounded causal links per event within budget. `totalLinks == 0` means no
    /// event has any links, so "the busiest event is within budget" is vacuous.
    public nonisolated static func causalBudgetInvariant(
        maxPerEvent: Int, totalLinks: Int, budget: Int = 3) -> HealthInvariant {
        guard totalLinks > 0 else {
            return HealthInvariant(id: "causal-budget", title: "Causal links within budget",
                                   status: .notMeasured,
                                   detail: "no grounded causal links recorded yet")
        }
        return HealthInvariant(
            id: "causal-budget", title: "Causal links within budget",
            status: maxPerEvent <= budget ? .pass : .fail,
            detail: "max \(maxPerEvent) grounded links on one event (budget \(budget))")
    }

    /// Backfill drained. "Done" only means something once there was work.
    public nonisolated static func backfillInvariant(
        id: String, title: String, pending: Int, hasWork: Bool) -> HealthInvariant {
        if pending > 0 {
            return HealthInvariant(id: id, title: title, status: .warn,
                                   detail: "\(pending) chunk(s) pending")
        }
        guard hasWork else {
            return HealthInvariant(id: id, title: title, status: .notMeasured,
                                   detail: "no chunks to backfill yet")
        }
        return HealthInvariant(id: id, title: title, status: .pass, detail: "done")
    }

    public nonisolated static func make(coverage: [HealthCoverageRow], inputs: HealthInputs) -> HealthReport {
        HealthReport(coverage: coverage, invariants: evaluateInvariants(inputs))
    }
}
