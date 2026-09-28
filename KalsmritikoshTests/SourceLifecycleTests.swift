//
//  SourceLifecycleTests.swift
//  KalsmritikoshTests
//
//  A2 — the pure per-source lifecycle derivation: priority-ordered, deterministic,
//  and honest about omission.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite struct SourceLifecycleTests {

    @Test("Indexed + no omission → searchable")
    func searchable() {
        let s = SourceLifecycle.derive(.init(index: .indexed))
        #expect(s == .searchable)
        #expect(s.isAnswerable)
        #expect(!s.disclosesOmission)
    }

    @Test("Encrypted wins over an index status and discloses omission")
    func needsPassword() {
        let s = SourceLifecycle.derive(.init(index: .indexed, passwordProtected: true))
        #expect(s == .needsPassword)
        #expect(s.disclosesOmission)
        #expect(!s.isAnswerable)
    }

    @Test("Excluded is the highest-priority state")
    func excludedWins() {
        let s = SourceLifecycle.derive(.init(index: .indexed, passwordProtected: true,
                                             failed: true, excluded: true))
        #expect(s == .excluded)
    }

    @Test("A limited scan is partial and answerable, and discloses limits")
    func limitedScanPartial() {
        let s = SourceLifecycle.derive(.init(index: .limitedScan))
        #expect(s == .partial)
        #expect(s.isAnswerable)
        #expect(s.disclosesOmission)
    }

    @Test("Indexed but with omitted members → partial")
    func partialOmission() {
        let s = SourceLifecycle.derive(.init(index: .expanded, partialOmission: true))
        #expect(s == .partial)
    }

    @Test("No classification yet: processing when in-flight, else queued")
    func queuedVsProcessing() {
        #expect(SourceLifecycle.derive(.init(inFlight: true)) == .processing)
        #expect(SourceLifecycle.derive(.init()) == .queued)
    }

    @Test("Unsupported classification → failed")
    func unsupportedFailed() {
        #expect(SourceLifecycle.derive(.init(index: .unsupported)) == .failed)
    }
}
