//
//  EvidenceProjectionInvariantTests.swift
//  KalsmritikoshTests
//
//  EV-003 — the projection invariant (every chunk resolves to an evidence block) is measured
//  honestly; a gap is reported for backfill, not hidden.
//

import Testing
@testable import Kalsmritikosh

@Suite("EV-003 EvidenceProjectionInvariant")
struct EvidenceProjectionInvariantTests {

    @Test("Holds when all chunks are linked")
    func holds() {
        let inv = EvidenceProjectionInvariant(totalChunks: 100, linkedChunks: 100)
        #expect(inv.holds)
        #expect(inv.unlinkedChunks == 0)
        #expect(inv.linkedFraction == 1.0)
        #expect(inv.statusLine().contains("holds"))
    }

    @Test("Reports the gap when some chunks are unlinked")
    func gap() {
        let inv = EvidenceProjectionInvariant(totalChunks: 10710, linkedChunks: 10678)
        #expect(!inv.holds)
        #expect(inv.unlinkedChunks == 32)
        #expect(inv.statusLine().contains("backfill"))
    }

    @Test("Empty is trivially satisfied")
    func empty() {
        #expect(EvidenceProjectionInvariant(totalChunks: 0, linkedChunks: 0).holds)
    }

    @Test("linkedChunks is clamped to total (no >100%)")
    func clamp() {
        #expect(EvidenceProjectionInvariant(totalChunks: 5, linkedChunks: 9).linkedChunks == 5)
    }
}
