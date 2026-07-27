//
//  SourceReliabilityAssessment.swift
//  Kalsmritikosh
//
//  OPS-006 — shared Source Reliability Assessment (schema v74).
//
//  ONE canonical assessment per source version, shared across all personas
//  (Investigator, Researcher, Journalist, and any others). This is NOT a
//  per-persona copy or a fork of the evidence-assessment vocabulary.
//
//  Reassessments are append-only: calling assess() for an already-assessed
//  source version supersedes the prior row (via superseded_by_id) and inserts
//  a new active row. The full chain is queryable via history().
//
//  superseded_by_id is a SOFT reference — no SQL FK constraint — to preserve
//  the audit chain even if a superseding assessment were ever hard-deleted.
//

import Foundation

public nonisolated enum ReliabilityRating: String, Codable, Sendable, CaseIterable {
    case high    = "high"
    case medium  = "medium"
    case low     = "low"
    case unknown = "unknown"
}

public nonisolated enum IndependenceStatus: String, Codable, Sendable, CaseIterable {
    case independent       = "independent"
    case affiliated        = "affiliated"
    case potentialConflict = "potential_conflict"
    case unknown           = "unknown"
}

public nonisolated struct SourceReliabilityAssessment: Sendable, Identifiable {
    public typealias ID = UUID
    public let id: ID
    public let sourceVersionID: UUID
    public let reliability: ReliabilityRating
    public let independence: IndependenceStatus
    public let rationale: String?
    public let assessedBy: String?
    public let assessedAt: Date
    public let createdAt: Date
    /// Non-nil when this assessment has been superseded by a newer one.
    public let supersededByID: UUID?

    public init(
        id: ID = UUID(),
        sourceVersionID: UUID,
        reliability: ReliabilityRating,
        independence: IndependenceStatus,
        rationale: String? = nil,
        assessedBy: String? = nil,
        assessedAt: Date,
        createdAt: Date,
        supersededByID: UUID? = nil
    ) {
        self.id              = id
        self.sourceVersionID = sourceVersionID
        self.reliability     = reliability
        self.independence    = independence
        self.rationale       = rationale
        self.assessedBy      = assessedBy
        self.assessedAt      = assessedAt
        self.createdAt       = createdAt
        self.supersededByID  = supersededByID
    }
}
