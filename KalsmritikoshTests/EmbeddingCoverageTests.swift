//
//  EmbeddingCoverageTests.swift
//  KalsmritikoshTests
//
//  U-3.1 (W-6) — the four embedding states sum to the chunk total. Pure.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("U-3.1 embedding coverage")
struct EmbeddingCoverageTests {

    @Test func statesSumToTotal() {
        let c = EmbeddingCoverage(total: 100, embedded: 70, excluded: 5, failed: 3)
        #expect(c.pending == 22)
        #expect(c.embedded + c.pending + c.excluded + c.failed == c.total)
        #expect(c.isConsistent)
    }

    @Test func todayPendingIsTheRemainder() {
        // No exclusion/failure logging yet → pending == total − embedded.
        let c = EmbeddingCoverage(total: 716, embedded: 700)
        #expect(c.pending == 16)
        #expect(c.excluded == 0 && c.failed == 0)
    }

    @Test func emptyArchiveIsComplete() {
        let c = EmbeddingCoverage(total: 0, embedded: 0)
        #expect(c.pending == 0)
        #expect(c.embeddedFraction == 1.0)
    }

    @Test func inconsistentCountsAreFlagged() {
        let c = EmbeddingCoverage(total: 10, embedded: 20)
        #expect(!c.isConsistent)
        #expect(c.pending == 0)   // clamped, never negative
    }
}
