//
//  SequenceGapDetectorTests.swift
//  KalsmritikoshTests
//
//  v1.0-rc4 runtime witness regression — detectSequenceGaps materialized the
//  FULL lo...hi integer range before its sparseness guard, so one label with
//  a large embedded integer (a 12-digit account ID, a timestamp) iterated
//  billions of values on the main actor and starved Ask for hours. The
//  sparseness verdict must be computed arithmetically first; the range walk
//  is only permitted once it is provably ≤ 2 × the present count.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Sequence gap detector (rc4 starvation regression)")
struct SequenceGapDetectorTests {

    @Test("A label with a huge embedded integer returns instantly, not after hours")
    func hugeIntegerRangeIsRejectedArithmetically() {
        let detector = GapDetector()
        let clock = ContinuousClock()
        let start = clock.now
        // lo=1, hi≈10^12 — the old code iterated the whole span.
        let gaps = detector.detectSequenceGaps(
            labels: ["Invoice 1", "Invoice 2", "Invoice 3", "Ref 987654321098"],
            kindHint: "Invoice")
        let elapsed = clock.now - start
        #expect(gaps.isEmpty, "a sparse astronomic range is not a sequence")
        #expect(elapsed < .seconds(5), "must be decided arithmetically, not by iteration")
    }

    @Test("A genuine numbered-sequence hole is still detected")
    func genuineHoleStillDetected() {
        let detector = GapDetector()
        let gaps = detector.detectSequenceGaps(
            labels: ["Invoice 401", "Invoice 403", "Invoice 404"],
            kindHint: "Invoice")
        #expect(gaps.count == 1)
        #expect(gaps.first?.description.contains("#402") == true)
    }
}
