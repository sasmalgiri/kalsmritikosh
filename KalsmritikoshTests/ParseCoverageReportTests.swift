//
//  ParseCoverageReportTests.swift
//  KalsmritikoshTests
//
//  PAR-002 — per-source coverage classification into the locked support states; nothing is
//  silently dropped (unsupported/encrypted/corrupt/failed all get an honest state).
//

import Testing
@testable import Kalsmritikosh

@Suite("PAR-002 ParseCoverageReport")
struct ParseCoverageReportTests {

    @Test("Complete with blocks → FULL and searchable")
    func fullState() {
        let (s, _) = ParseCoverageReport.classify(status: .complete, meaningfulBlocks: 5, hasError: false)
        #expect(s == .full)
        #expect(s.isSearchable)
    }

    @Test("Complete but empty → PRESERVED-ONLY (not counted as searchable)")
    func emptyComplete() {
        let (s, _) = ParseCoverageReport.classify(status: .complete, meaningfulBlocks: 0, hasError: false)
        #expect(s == .preservedOnly)
        #expect(!s.isSearchable)
    }

    @Test("Each failure mode maps to its honest, non-dropped state")
    func failureModes() {
        #expect(ParseCoverageReport.classify(status: .partial, meaningfulBlocks: 2, hasError: false).0 == .partial)
        #expect(ParseCoverageReport.classify(status: .unsupported, meaningfulBlocks: 0, hasError: false).0 == .preservedOnly)
        #expect(ParseCoverageReport.classify(status: .encrypted, meaningfulBlocks: 0, hasError: false).0 == .encrypted)
        #expect(ParseCoverageReport.classify(status: .corrupt, meaningfulBlocks: 0, hasError: false).0 == .corrupt)
        #expect(ParseCoverageReport.classify(status: .deferred, meaningfulBlocks: 0, hasError: false).0 == .deferred)
        #expect(ParseCoverageReport.classify(status: .failed, meaningfulBlocks: 0, hasError: true).0 == .failed)
    }

    @Test("Only FULL/PARTIAL are searchable; everything else is preserved but honest")
    func searchability() {
        #expect(SourceCoverageState.full.isSearchable)
        #expect(SourceCoverageState.partial.isSearchable)
        for s in [SourceCoverageState.preservedOnly, .deferred, .encrypted, .corrupt, .failed] {
            #expect(!s.isSearchable)
            #expect(!s.userLabel.isEmpty)
        }
    }
}
