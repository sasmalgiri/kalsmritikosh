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
    // USF-002 durable dimensions — populated when built from SourceReadinessSnapshots (the
    // authoritative source). Distinct, honest counts; NEVER collapsed to one percentage.
    public let evidenceReady: Int
    public let analyticallyReady: Int
    public let encrypted: Int
    public let corrupt: Int
    public let unsupported: Int
    public let failed: Int
    public let byCompletionState: [String: Int]
    public let byDimensionState: [String: Int]

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
        self.evidenceReady = 0; self.analyticallyReady = 0
        self.encrypted = 0; self.corrupt = 0; self.unsupported = 0; self.failed = 0
        self.byCompletionState = [:]; self.byDimensionState = [:]
    }

    /// USF-002 — aggregate the DURABLE authority: per-source-version readiness snapshots. Every
    /// count is independent (searchable ≠ evidence-ready ≠ analytically ready); there is no single
    /// overall percentage. This is the honest form the Sources view consumes.
    public nonisolated init(snapshots: [SourceReadinessSnapshot]) {
        self.total = snapshots.count
        var searchable = 0, evidence = 0, analytical = 0, preserved = 0
        var deferred = 0, encrypted = 0, corrupt = 0, unsupported = 0, failed = 0
        var byCompletion: [String: Int] = [:]
        var byDimension: [String: Int] = [:]
        for s in snapshots {
            if s.isSearchReady { searchable += 1 }
            if s.isEvidenceReady { evidence += 1 }
            if s.isAnalyticallyReady { analytical += 1 }
            byCompletion[s.completionState.rawValue, default: 0] += 1
            switch s.completionState {
            case .preservedOnly: preserved += 1
            case .deferred: deferred += 1
            case .encrypted: encrypted += 1
            case .corrupt: corrupt += 1
            case .unsupported: unsupported += 1
            case .failed: failed += 1
            case .evidenceReady, .searchablePartial: break
            }
            for d in s.dimensions { byDimension[d.state.rawValue, default: 0] += 1 }
        }
        self.searchable = searchable
        self.evidenceReady = evidence
        self.analyticallyReady = analytical
        self.preservedOnly = preserved
        self.deferred = deferred
        self.encrypted = encrypted
        self.corrupt = corrupt
        self.unsupported = unsupported
        self.failed = failed
        self.needsAttention = encrypted + corrupt + failed
        self.byCompletionState = byCompletion
        self.byDimensionState = byDimension
        self.byState = byCompletion
    }
}
