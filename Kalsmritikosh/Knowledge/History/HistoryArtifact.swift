//
//  HistoryArtifact.swift
//  Kalsmritikosh
//
//  HIST-060/061 (Universal History program, Phase 9). The persisted, versioned
//  history header. Every artifact is tied to a corpus snapshot + engine version;
//  a rebuild creates a NEW artifact and links the prior one via `supersededBy`
//  (nothing is overwritten — the old artifact stays replayable).
//

import Foundation

public struct HistoryArtifact: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let subjectKind: String
    public let subjectID: Entity.ID?
    public let subjectLabel: String
    public let corpusSnapshotID: UUID?
    public let engineVersion: String
    public let title: String
    public let summary: String?
    public let coverage: HistoryCoverage
    public let createdAt: Date
    public let supersededBy: UUID?
    /// P4-U1 — which door persisted it: "verified" (Dossier, the reviewed
    /// path) or "unreviewed" (a story persisted straight from a question,
    /// awaiting the review loop).
    public let reviewState: String
    /// P4-U1 — the dedup triple: the resolved anchor's identity key
    /// ("patentnumber|555489"), the request shape ("story"), and the ledger
    /// stamp observed at build time. NULL on pre-P4 artifacts.
    public let anchorKey: String?
    public let requestShape: String?
    public let ledgerStamp: String?

    public nonisolated init(
        id: UUID, subjectKind: String, subjectID: Entity.ID?, subjectLabel: String,
        corpusSnapshotID: UUID?, engineVersion: String, title: String, summary: String?,
        coverage: HistoryCoverage, createdAt: Date, supersededBy: UUID?,
        reviewState: String = "verified", anchorKey: String? = nil,
        requestShape: String? = nil, ledgerStamp: String? = nil
    ) {
        self.id = id; self.subjectKind = subjectKind; self.subjectID = subjectID
        self.subjectLabel = subjectLabel; self.corpusSnapshotID = corpusSnapshotID
        self.engineVersion = engineVersion; self.title = title; self.summary = summary
        self.coverage = coverage; self.createdAt = createdAt; self.supersededBy = supersededBy
        self.reviewState = reviewState; self.anchorKey = anchorKey
        self.requestShape = requestShape; self.ledgerStamp = ledgerStamp
    }

    public var isCurrent: Bool { supersededBy == nil }

    /// Stale = the ledger has changed since this artifact was built. Computed
    /// against the CURRENT stamp, never stored — so it can never lie about
    /// the present. An unstamped (pre-P4) artifact is treated as stale:
    /// honesty over flattery.
    public nonisolated func isStale(currentLedgerStamp: String) -> Bool {
        guard let ledgerStamp else { return true }
        return ledgerStamp != currentLedgerStamp
    }
}
