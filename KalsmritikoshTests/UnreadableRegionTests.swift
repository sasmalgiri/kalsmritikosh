//
//  UnreadableRegionTests.swift
//  KalsmritikoshTests
//
//  A5.7 — GapDetector.detectUnreadableRegions: sources whose structural parse
//  wasn't clean surface as unreadable-region gaps with a status-specific,
//  non-accusatory reason. Add to the test target to run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct UnreadableRegionTests {

    @Test func eachIssueBecomesAReasonedGap() {
        let gaps = GapDetector().detectUnreadableRegions(regions: [
            (filename: "scan.pdf", status: "partial", warningCount: 2),
            (filename: "locked.pdf", status: "encrypted", warningCount: 0)
        ])
        #expect(gaps.count == 2)
        #expect(gaps.allSatisfy { $0.kind == .unreadableRegion })
        let partial = gaps.first { $0.description.contains("scan.pdf") }
        #expect(partial?.reason.contains("only part") == true)
        #expect(partial?.reason.contains("2 parser warning") == true)
        // Non-accusatory framing is required by the spec.
        #expect(partial?.reason.contains("not wrongdoing") == true)
        let encrypted = gaps.first { $0.description.contains("locked.pdf") }
        #expect(encrypted?.reason.contains("encrypted") == true)
    }

    @Test func emptyInputYieldsNoGaps() {
        #expect(GapDetector().detectUnreadableRegions(regions: []).isEmpty)
    }
}
