//
//  SourceReadinessSummary.swift
//  Kalsmritikosh
//
//  UX-002 (data layer) / ING-007 — honest, MULTI-DIMENSIONAL source readiness. The locked
//  contract forbids "a single vague readiness percentage": the user must see how many sources
//  are searchable now, how many are preserved-but-not-searchable, deferred, or need attention
//  (encrypted/corrupt/failed). This aggregates per-source ParseCoverageReports (PAR-002) into
//  those honest buckets, plus a search-readiness fraction that only counts truly searchable
//  sources.
//
//  Pure value type. The SwiftUI Sources view renders this; the numbers never overstate.
//

import Foundation

public struct SourceReadinessSummary: Sendable, Hashable {
    public let total: Int
    public let searchable: Int          // FULL + PARTIAL
    public let preservedOnly: Int
    public let deferred: Int
    public let needsAttention: Int      // encrypted + corrupt + failed
    public let byState: [String: Int]

    /// Fraction of sources that are actually searchable NOW (not "processed" hand-waving).
    public var searchableFraction: Double {
        total == 0 ? 0 : Double(searchable) / Double(total)
    }

    /// True only when nothing is deferred or needs attention — a real "done" signal.
    public var isFullyProcessed: Bool { deferred == 0 && needsAttention == 0 }

    /// Honest one-line status (no single misleading percentage).
    public var headline: String {
        guard total > 0 else { return "No sources added yet." }
        var parts = ["\(searchable)/\(total) searchable"]
        if preservedOnly > 0 { parts.append("\(preservedOnly) preserved") }
        if deferred > 0 { parts.append("\(deferred) pending") }
        if needsAttention > 0 { parts.append("\(needsAttention) need attention") }
        return parts.joined(separator: " · ")
    }

    public nonisolated init(reports: [ParseCoverageReport]) {
        self.total = reports.count
        var counts: [String: Int] = [:]
        var searchable = 0, preserved = 0, deferred = 0, attention = 0
        for r in reports {
            counts[r.state.rawValue, default: 0] += 1
            if r.state.isSearchable { searchable += 1 }
            switch r.state {
            case .preservedOnly: preserved += 1
            case .deferred: deferred += 1
            case .encrypted, .corrupt, .failed: attention += 1
            default: break
            }
        }
        self.searchable = searchable
        self.preservedOnly = preserved
        self.deferred = deferred
        self.needsAttention = attention
        self.byState = counts
    }
}
