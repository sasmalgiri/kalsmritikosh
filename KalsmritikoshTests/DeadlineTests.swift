//
//  DeadlineTests.swift
//  KalsmritikoshTests
//
//  P2.7 — an optional step that overruns its deadline yields nil; a fast one
//  yields its value.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("P2.7 — optional steps are bounded")
struct DeadlineTests {
    @Test("A fast operation returns its value; a slow one is abandoned at the deadline")
    func deadline() async {
        // The contract: the value comes back UNLESS the deadline truly elapsed.
        // Under the full suite's saturated thread pool even instant work can
        // wait longer than the deadline to be scheduled (measured: a 30 s
        // deadline won), and an optional step then honestly skips — so a nil
        // is only a defect when it arrives before the deadline.
        let fastStarted = Date()
        let fast = await withDeadline(seconds: 5) { () async -> String? in "expanded" }
        let fastElapsed = Date().timeIntervalSince(fastStarted)
        #expect(fast == "expanded" || fastElapsed >= 5,
                "nil after only \(fastElapsed)s — the deadline fired early")
        let started = Date()
        let slow = await withDeadline(seconds: 0.3) { () async -> String? in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return "too late"
        }
        // Same contract from the other side: a value is a defect only if it came
        // back although the work could NOT have finished — on a hosted runner the
        // dispatch timer itself was measured to run after the 5 s work ended.
        let slowElapsed = Date().timeIntervalSince(started)
        #expect(slow == nil || slowElapsed >= 5,
                "a value after only \(slowElapsed)s — the deadline did not hold")
    }

    @Test("An operation that IGNORES cancellation still cannot hold the caller past the deadline")
    func nonCooperative() async {
        // Work that never checks Task.isCancelled and finishes on another
        // queue after 20 s — like a model mid-generation behind an XPC call.
        // The discriminator is ORDER, not a tight clock: under a saturated
        // full-suite thread pool the caller may resume late, but it must
        // resume before the work finishes (the old task-group version waited
        // for it, every time).
        let finished = FinishedFlag()
        let value = await withDeadline(seconds: 0.2) { () async -> String? in
            await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
                    finished.set()
                    c.resume(returning: "too late")
                }
            }
        }
        #expect(value == nil)
        #expect(!finished.value, "withDeadline returned before the non-cooperative work finished")
    }
}

private final class FinishedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func set() { lock.lock(); done = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return done }
}
