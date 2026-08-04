//
//  CooperativeBackgroundLoopTests.swift
//  KalsmritikoshTests
//
//  SHELL-003 — the cooperative bounded-batch loop and atomic-refresh helper. Proves a worker runs
//  batches while the gate permits, pauses within one batch when the gate flips (the idle-preemption
//  fix), never resumes abandoned work by itself, respects a batch limit, and that an interrupted /
//  failed refresh preserves the previous durable result. Uses a scripted mock gate.
//

import Foundation
import Testing
@testable import Kalsmritikosh

/// A gate whose permit answers are scripted, so a test can flip permission between batches.
private actor ScriptedGate: BackgroundWorkGating {
    private let answers: [Bool]
    private var index = 0
    init(_ answers: [Bool]) { self.answers = answers }
    func permits(_ priority: BackgroundWorkPriority) async -> Bool {
        defer { index += 1 }
        if index < answers.count { return answers[index] }
        return answers.last ?? false
    }
}

private actor Counter { private(set) var n = 0; func inc() { n += 1 } }

@Suite("SHELL-003 — cooperative loop + atomic refresh")
struct CooperativeBackgroundLoopTests {

    @Test("The loop runs batches until the batch signals done")
    func completesOnDone() async {
        let gate = ScriptedGate([true, true, true, true])
        let counter = Counter()
        let result = await CooperativeBackgroundLoop.run(priority: .optionalMaintenance, gate: gate) {
            await counter.inc()
            return await counter.n >= 3 ? .done : .moreWork
        }
        #expect(result == .completed)
        #expect(await counter.n == 3)
    }

    @Test("The loop pauses immediately when the gate denies from the start (no batch runs)")
    func pausesFromStart() async {
        let gate = ScriptedGate([false])
        let counter = Counter()
        let result = await CooperativeBackgroundLoop.run(priority: .optionalMaintenance, gate: gate) {
            await counter.inc(); return .moreWork
        }
        #expect(result == .pausedByGate)
        #expect(await counter.n == 0)   // never started
    }

    @Test("The loop pauses within one batch when the gate flips (idle-preemption); abandoned work is not resumed")
    func pausesWhenGateFlips() async {
        let gate = ScriptedGate([true, true, false])   // permit, permit, then deny
        let counter = Counter()
        let result = await CooperativeBackgroundLoop.run(priority: .optionalMaintenance, gate: gate) {
            await counter.inc(); return .moreWork
        }
        #expect(result == .pausedByGate)
        #expect(await counter.n == 2)   // exactly the two permitted batches; the loop did not resume on its own
    }

    @Test("The loop stops at the batch limit for later resumption")
    func reachesBatchLimit() async {
        let gate = ScriptedGate([true])   // always permits
        let counter = Counter()
        let result = await CooperativeBackgroundLoop.run(priority: .optionalMaintenance, gate: gate, maxBatches: 3) {
            await counter.inc(); return .moreWork
        }
        #expect(result == .reachedBatchLimit)
        #expect(await counter.n == 3)
    }

    // MARK: - Atomic refresh

    @Test("A permitted, successful refresh atomically replaces the old result")
    func refreshReplacesOnSuccess() async {
        let gate = ScriptedGate([true, true])
        let result = await AtomicProjectionRefresh.refresh(current: "old", priority: .requiredDeferred, gate: gate) { "new" }
        #expect(result == "new")
    }

    @Test("A refresh denied before it starts keeps the old durable result")
    func refreshDeniedKeepsOld() async {
        let gate = ScriptedGate([false])
        var built = false
        let result = await AtomicProjectionRefresh.refresh(current: "old", priority: .requiredDeferred, gate: gate) { built = true; return "new" }
        #expect(result == "old")
        #expect(!built)   // build never ran
    }

    @Test("A refresh whose build throws keeps the old durable result")
    func refreshThrowsKeepsOld() async {
        struct Boom: Error {}
        let gate = ScriptedGate([true])
        let result = await AtomicProjectionRefresh.refresh(current: "old", priority: .requiredDeferred, gate: gate) { throw Boom() }
        #expect(result == "old")
    }

    @Test("A refresh interrupted (gate flips before the swap) keeps the old durable result")
    func refreshInterruptedKeepsOld() async {
        let gate = ScriptedGate([true, false])   // permitted to build, denied before replacement
        let result = await AtomicProjectionRefresh.refresh(current: "old", priority: .requiredDeferred, gate: gate) { "new" }
        #expect(result == "old")
    }
}
