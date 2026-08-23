//
//  DerivedObject.swift
//  Kalsmritikosh
//
//  A persisted, provenance-carrying result of a query-time LLM extraction
//  (spec §16). Stored append-only in `derived_objects` (schema v35) so
//  minimum-LLM work compounds: an unchanged (sourceHash, extractorVersion)
//  can be REUSED instead of re-invoking the model. A correction never
//  overwrites — it inserts a new row and points the old row's
//  `supersededBy` at it.
//

import Foundation
import CryptoKit

public nonisolated struct DerivedObject: Sendable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case claim
        case event
        case relationship
        case contradiction
        case memory
        case timeline
    }

    public enum ReviewStatus: String, Sendable, Codable {
        case unreviewed
        case accepted
        case rejected
        case corrected
    }

    public let id: UUID
    public let kind: Kind
    public let content: String
    public let sourceEvidence: [KnowledgeObject.ID]
    public let sourceHash: String
    public let modelID: String?
    public let providerID: String?
    public let promptVersion: String?
    public let extractorVersion: String
    public let confidence: Double
    public let reviewStatus: ReviewStatus
    public let supersededBy: UUID?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: Kind,
        content: String,
        sourceEvidence: [KnowledgeObject.ID],
        modelID: String? = nil,
        providerID: String? = nil,
        promptVersion: String? = nil,
        extractorVersion: String,
        confidence: Double,
        reviewStatus: ReviewStatus = .unreviewed,
        supersededBy: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.content = content
        self.sourceEvidence = sourceEvidence
        self.sourceHash = DerivedObject.hash(content: content, evidence: sourceEvidence)
        self.modelID = modelID
        self.providerID = providerID
        self.promptVersion = promptVersion
        self.extractorVersion = extractorVersion
        self.confidence = confidence
        self.reviewStatus = reviewStatus
        self.supersededBy = supersededBy
        self.createdAt = createdAt
    }

    /// Stable content hash for reuse/dedup: content + sorted evidence IDs.
    public static func hash(content: String, evidence: [KnowledgeObject.ID]) -> String {
        let ids = evidence.map(\.uuidString).sorted().joined(separator: ",")
        let digest = SHA256.hash(data: Data("\(content)|\(ids)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
