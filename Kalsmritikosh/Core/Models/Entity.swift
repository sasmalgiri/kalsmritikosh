//
//  Entity.swift
//  Kalsmritikosh
//
//  Entities are the noun layer of the knowledge graph: people, organizations,
//  projects, money, time, places. Each carries a source reference and a
//  confidence so the Verifier can audit any claim.
//

import Foundation

public struct Entity: Codable, Identifiable, Hashable, Sendable {
    public typealias ID = UUID

    public let id: ID
    public let kind: Kind
    public let value: String
    public let normalizedValue: String?
    public let sourceObjectID: KnowledgeObject.ID
    public let sourceRange: SourceRange?
    public let confidence: Confidence
    public let attributes: [String: AnyCodable]
    /// HISTORY Phase A — assigned by QualityTierClassifier at insert
    /// time. T1 = trusted structured fact; T2 = body NER; T3 = noise
    /// preserved on disk but demoted at retrieval. Defaults to T2 so
    /// pre-Phase-A call sites stay correct without modification.
    public let qualityTier: QualityTier

    public nonisolated init(
        id: ID = UUID(),
        kind: Kind,
        value: String,
        normalizedValue: String? = nil,
        sourceObjectID: KnowledgeObject.ID,
        sourceRange: SourceRange? = nil,
        confidence: Confidence = .medium,
        attributes: [String: AnyCodable] = [:],
        qualityTier: QualityTier = .t2
    ) {
        self.id = id
        self.kind = kind
        self.value = value
        self.normalizedValue = normalizedValue
        self.sourceObjectID = sourceObjectID
        self.sourceRange = sourceRange
        self.confidence = confidence
        self.attributes = attributes
        self.qualityTier = qualityTier
    }

    /// A5.4 — return a copy with extra attributes merged in (new keys win).
    /// Used to attach mention source-block provenance after extraction without
    /// threading it through every construction site.
    public nonisolated func addingAttributes(_ extra: [String: AnyCodable]) -> Entity {
        Entity(
            id: id, kind: kind, value: value, normalizedValue: normalizedValue,
            sourceObjectID: sourceObjectID, sourceRange: sourceRange, confidence: confidence,
            attributes: attributes.merging(extra) { _, new in new }, qualityTier: qualityTier
        )
    }

    public enum Kind: String, Codable, CaseIterable, Sendable {
        // People
        case person
        case emailAddress
        case phoneNumber

        // Organizations
        case organization
        case vendor
        case client

        // Financial
        case money
        case currency
        case invoiceNumber
        case paymentID

        // Time
        case date
        case deadline
        case milestone

        // Places
        case address
        case city
        case country
        case location

        // Projects
        case project
        case deliverable

        // V3 (C-8) — the anchor: a real-world subject identified by a canonical
        // identifier (patent/application/publication/invoice/case…). ONE case,
        // specialized by DATA: the registry field id rides in
        // attributes["anchorField"], so every identifier-anchored subject shares
        // this case while display + behavior specialize by field. Identity is
        // (anchorField, canonicalValue) — never conflated across fields.
        case identifierAnchor

        case other
    }
}
