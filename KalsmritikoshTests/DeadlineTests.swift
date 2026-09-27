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
        let started = Date()
        let value = await withDeadline(seconds: 0.2) { () async -> String? in
            // Work that never checks Task.isCancelled and finishes on another
            // queue — like a model mid-generation behind an XPC call. (Not a
            // busy wait: that hogs a cooperative thread and, under a full-suite
            // load, measures the scheduler instead of the deadline.)
            await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { c.resume(returning: "too late") }
            }
        }
        #expect(value == nil)
        #expect(Date().timeIntervalSince(started) < 2.0, "returned at the deadline, not when the work finished (3 s)")
    }
}
