//
//  EvidenceProjectionInvariant.swift
//  Kalsmritikosh
//
//  EV-003 — the projection invariant that makes chunks a derived view of evidence, not a
//  second source of truth (EV-001): every chunk must resolve to an EvidenceBlock. This
//  measures compliance (linked / total) and reports the unlinked chunks so a backfill can
//  repair them. Chunks with no block link are "orphan projections" — they must be re-derived
//  from their source, never trusted as standalone evidence.
//
//  Pure, deterministic. The repository provides the counts; this evaluates the invariant.
//

import Foundation

public struct EvidenceProjectionInvariant: Sendable, Hashable {
    public let totalChunks: Int
    public let linkedChunks: Int   // chunks with a non-null evidence_block_id

    public var unlinkedChunks: Int { max(0, totalChunks - linkedChunks) }
    public var linkedFraction: Double { totalChunks == 0 ? 1.0 : Double(linkedChunks) / Double(totalChunks) }
    /// The invariant holds when every chunk resolves to a block.
    public var holds: Bool { unlinkedChunks == 0 }

    public nonisolated init(totalChunks: Int, linkedChunks: Int) {
        self.totalChunks = totalChunks
        self.linkedChunks = min(linkedChunks, totalChunks)
    }

    /// A neutral status line for diagnostics / the audit view.
    public func statusLine() -> String {
        guard totalChunks > 0 else { return "No chunks." }
        let pct = Int((linkedFraction * 100).rounded())
        return holds
            ? "Projection invariant holds: \(linkedChunks)/\(totalChunks) chunks resolve to a block."
            : "Projection gap: \(unlinkedChunks) of \(totalChunks) chunks (\(100 - pct)%) have no evidence block — backfill needed."
    }
}
