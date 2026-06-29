//
//  IMessageEpochTests.swift
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("IMessageLoader — Apple Mach epoch conversion")
struct IMessageEpochTests {
    /// macOS Messages stores date as nanoseconds since 2001-01-01.
    /// Apple's reference: kCFAbsoluteTimeIntervalSince1970 = 978307200.
    /// Some legacy schemas used seconds; the loader auto-detects.
    @Test("nanoseconds branch — modern column")
    func nanoseconds() {
        // 2025-01-01 00:00:00 UTC == 1735689600 unix.
        // That's 1735689600 - 978307200 = 757382400 seconds past Mach epoch.
        // Modern column = 757382400 * 1_000_000_000 ns.
        let ns: Int64 = 757_382_400 * 1_000_000_000
        let date = IMessageLoader.dateFromAppleNanoseconds(ns)
        let expected = Date(timeIntervalSince1970: 1_735_689_600)
        #expect(abs(date.timeIntervalSince(expected)) < 1)
    }

    @Test("seconds branch — legacy column")
    func seconds() {
        let secs: Int64 = 757_382_400  // same point in time, but seconds.
        let date = IMessageLoader.dateFromAppleNanoseconds(secs)
        let expected = Date(timeIntervalSince1970: 1_735_689_600)
        #expect(abs(date.timeIntervalSince(expected)) < 1)
    }
}
