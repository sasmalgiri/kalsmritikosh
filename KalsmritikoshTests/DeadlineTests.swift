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
        let fast = await withDeadline(seconds: 2) { () async -> String? in "expanded" }
        #expect(fast == "expanded")
        let started = Date()
        let slow = await withDeadline(seconds: 0.3) { () async -> String? in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return "too late"
        }
        #expect(slow == nil)
        #expect(Date().timeIntervalSince(started) < 2, "the caller is not held for the slow operation")
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
