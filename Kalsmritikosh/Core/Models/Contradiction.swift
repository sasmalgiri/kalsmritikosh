//
//  Contradiction.swift
//  Kalsmritikosh
//
//  System 3 — a persisted CONFLICT between two claims that the ledger
//  supports simultaneously (schema v31 `contradictions`). Per the
//  evidence-gate contract, conflicting evidence is NEVER averaged away —
//  it is surfaced to the user as a conflict with BOTH sources shown. This
//  model is the ledger's memory of such a conflict so it accumulates
//  instead of being recomputed per query.
//
//  A contradiction is not a factual claim about the world; it is a claim
//  about the ARCHIVE ("two ingested sources disagree"). It always carries
//  both claims and, where known, the evidence object behind each.
//

import Foundation

public struct Contradiction: Identifiable, Sendable, Hashable, Codable {
    public typealias ID = UUID

    /// How much the conflict matters. Derived from the size of the
    /// disagreement + how confident each side is.
    public enum Severity: String, Sendable, CaseIterable, Codable {
        case low
        case medium
        case high

        public var displayName: String {
            switch self {
            case .low:    return "Low"
            case .medium: return "Medium"
            case .high:   return "High"
            }
        }
    }

    /// Lifecycle of a surfaced conflict.
    public enum Status: String, Sendable, CaseIterable, Codable {
        /// Unresolved — still shown to the user.
        case open
        /// The user (or a later ingest) settled which side is right.
        case resolved
        /// The user judged it a non-issue.
        case dismissed
    }

    public let id: ID
    /// One-line human summary ("Conflicting dates for \"Kickoff call\"").
    public let description: String
    /// The two mutually-incompatible claims, verbatim.
    public let claimA: String
    public let claimB: String
    /// The KnowledgeObject each claim came from, when known.
    public let evidenceA: KnowledgeObject.ID?
    public let evidenceB: KnowledgeObject.ID?
    public let severity: Severity
    public let status: Status
    public let detectedAt: Date

    public nonisolated init(
        id: ID = UUID(),
        description: String,
        claimA: String,
        claimB: String,
        evidenceA: KnowledgeObject.ID? = nil,
        evidenceB: KnowledgeObject.ID? = nil,
        severity: Severity = .medium,
        status: Status = .open,
        detectedAt: Date = Date()
    ) {
        self.id = id
        self.description = description
        self.claimA = claimA
        self.claimB = claimB
        self.evidenceA = evidenceA
        self.evidenceB = evidenceB
        self.severity = severity
        self.status = status
        self.detectedAt = detectedAt
    }
}
