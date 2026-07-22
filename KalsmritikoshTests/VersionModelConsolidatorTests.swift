//
//  VersionModelConsolidatorTests.swift
//  KalsmritikoshTests
//
//  EV-006 — one active version model: canonical wins, legacy is flagged and never current,
//  duplicates aren't double-counted, and exactly one version is current.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Version model consolidation (EV-006)")
struct VersionModelConsolidatorTests {

    private let src = UUID()

    @Test("Canonical + legacy unify; legacy duplicate of a canonical hash is dropped")
    func dropsDuplicate() {
        let shared = "hashA"
        let canonical = [
            CanonicalVersionRecord(id: UUID(), logicalSourceID: src, contentHash: shared,
                                   validFrom: Date(timeIntervalSince1970: 200), isCurrent: true),
            CanonicalVersionRecord(id: UUID(), logicalSourceID: src, contentHash: "hashOld",
                                   validFrom: Date(timeIntervalSince1970: 100), isCurrent: false),
        ]
        let legacy = [
            LegacyVersionRecord(versionID: UUID(), fileID: src, contentHash: shared,
                                supersededAt: Date(timeIntervalSince1970: 150)),   // dup of canonical → drop
            LegacyVersionRecord(versionID: UUID(), fileID: src, contentHash: "hashLegacyOnly",
                                supersededAt: Date(timeIntervalSince1970: 50)),    // unique → keep, flagged
        ]
        let unified = VersionModelConsolidator.unify(canonical: canonical, legacy: legacy)
        #expect(unified.count == 3)   // 2 canonical + 1 legacy-only (shared dup dropped)
        #expect(unified.filter { $0.origin == .legacy }.map(\.contentHash) == ["hashLegacyOnly"])
        // Newest first.
        #expect(unified.first?.contentHash == shared)
    }

    @Test("Exactly one current, and no legacy row is ever current")
    func oneCurrent() {
        let canonical = [
            CanonicalVersionRecord(id: UUID(), logicalSourceID: src, contentHash: "a",
                                   validFrom: Date(timeIntervalSince1970: 300), isCurrent: true),
            CanonicalVersionRecord(id: UUID(), logicalSourceID: src, contentHash: "b",
                                   validFrom: Date(timeIntervalSince1970: 400), isCurrent: true), // drift: 2 current
        ]
        let legacy = [LegacyVersionRecord(versionID: UUID(), fileID: src, contentHash: "c",
                                          supersededAt: Date(timeIntervalSince1970: 10))]
        let unified = VersionModelConsolidator.unify(canonical: canonical, legacy: legacy)
        #expect(unified.filter(\.isCurrent).count == 1)                 // exactly one
        #expect(unified.first(where: \.isCurrent)?.contentHash == "b")  // newest validFrom wins
        #expect(unified.filter { $0.origin == .legacy }.allSatisfy { !$0.isCurrent })
    }

    @Test("Legacy rows without a content hash are skipped")
    func skipsHashless() {
        let unified = VersionModelConsolidator.unify(
            canonical: [],
            legacy: [LegacyVersionRecord(versionID: UUID(), fileID: src, contentHash: nil,
                                         supersededAt: Date())])
        #expect(unified.isEmpty)
    }
}
