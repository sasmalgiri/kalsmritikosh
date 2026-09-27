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
            // A busy wait never checks Task.isCancelled — like a model mid-generation.
            let end = Date().addingTimeInterval(1.5)
            while Date() < end {}
            return "too late"
        }
        #expect(value == nil)
        #expect(Date().timeIntervalSince(started) < 1.0, "returned at the deadline, not when the work finished")
    }
}
