//
//  SourceReadinessSummaryTests.swift
//  KalsmritikoshTests
//
//  UX-002 / ING-007 — honest multi-dimensional readiness: searchable vs preserved vs
//  deferred vs needs-attention; the searchable fraction only counts truly searchable sources.
//

import Testing
@testable import Kalsmritikosh

@Suite("UX-002 SourceReadinessSummary")
struct SourceReadinessSummaryTests {

    private func report(_ state: SourceCoverageState) -> ParseCoverageReport {
        ParseCoverageReport(filename: "f", detectedType: "t", state: state, blockCount: 1, reason: "")
    }

    @Test("Buckets are counted honestly")
    func buckets() {
        let s = SourceReadinessSummary(reports: [
            report(.full), report(.full), report(.partial),
            report(.preservedOnly), report(.deferred),
            report(.encrypted), report(.corrupt)
        ])
        #expect(s.total == 7)
        #expect(s.searchable == 3)          // 2 full + 1 partial
        #expect(s.preservedOnly == 1)
        #expect(s.deferred == 1)
        #expect(s.needsAttention == 2)      // encrypted + corrupt
    }

    @Test("Searchable fraction only counts searchable sources (no hand-waving)")
    func fraction() {
        let s = SourceReadinessSummary(reports: [report(.full), report(.preservedOnly), report(.deferred), report(.failed)])
        #expect(s.searchableFraction == 0.25)
        #expect(!s.isFullyProcessed)   // deferred + failed present
    }

    @Test("Fully processed only when nothing is pending or needs attention")
    func fullyProcessed() {
        #expect(SourceReadinessSummary(reports: [report(.full), report(.preservedOnly)]).isFullyProcessed)
        #expect(!SourceReadinessSummary(reports: [report(.full), report(.deferred)]).isFullyProcessed)
    }

    @Test("Headline is honest and omits a single vague percentage")
    func headline() {
        let s = SourceReadinessSummary(reports: [report(.full), report(.deferred), report(.encrypted)])
        #expect(s.headline.contains("1/3 searchable"))
        #expect(s.headline.contains("need attention"))
    }

    @Test("Empty corpus states it plainly")
    func empty() {
        #expect(SourceReadinessSummary(reports: []).headline.contains("No sources"))
    }
}
