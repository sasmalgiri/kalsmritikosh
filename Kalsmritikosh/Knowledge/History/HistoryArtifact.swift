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

    public nonisolated init(
        id: UUID, subjectKind: String, subjectID: Entity.ID?, subjectLabel: String,
        corpusSnapshotID: UUID?, engineVersion: String, title: String, summary: String?,
        coverage: HistoryCoverage, createdAt: Date, supersededBy: UUID?
    ) {
        self.id = id; self.subjectKind = subjectKind; self.subjectID = subjectID
        self.subjectLabel = subjectLabel; self.corpusSnapshotID = corpusSnapshotID
        self.engineVersion = engineVersion; self.title = title; self.summary = summary
        self.coverage = coverage; self.createdAt = createdAt; self.supersededBy = supersededBy
    }

    public var isCurrent: Bool { supersededBy == nil }
}
