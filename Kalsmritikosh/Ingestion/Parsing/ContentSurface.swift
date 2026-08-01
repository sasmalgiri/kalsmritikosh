//
//  ContentSurface.swift
//  Kalsmritikosh
//
//  USF-004 — universal content surfaces describe WHAT a parser actually recovered from a source
//  (text, metadata, structure, tables, images, attachments, transcript, typed fields). They are an
//  advisory parser OUTPUT, deliberately NOT a second readiness system: coverage is only
//  complete/partial/notApplicable, never ready/blocked/failed/unsupported/deferred — those
//  semantics belong to ExtractionStatus and SourceReadiness. Durable readiness still derives from
//  committed proof (StructuralPersistenceReceipt + ftsCoverage), never from a surface.
//

import Foundation

/// The closed set of content surfaces a parser can report.
public nonisolated enum ContentSurfaceKind: String, Sendable, Codable, CaseIterable, Hashable {
    case text
    case metadata
    case structure
    case tables
    case images
    case attachments
    case transcript
    case typedFields
}

/// How completely a surface was recovered. Intentionally MINIMAL — it is not a readiness state.
public nonisolated enum ContentSurfaceCoverage: String, Sendable, Codable, CaseIterable, Hashable {
    case complete
    case partial
    case notApplicable
}

/// One recovered surface. `basisBlockIDs` ties the surface to the exact EvidenceBlocks it came from
/// (empty when the surface is notApplicable or derived from non-block sources like doc metadata).
public nonisolated struct ContentSurfaceReceipt: Sendable, Codable, Hashable {
    public let kind: ContentSurfaceKind
    public let coverage: ContentSurfaceCoverage
    public let unitCount: Int
    public let basisBlockIDs: [UUID]
    public let detail: String?

    public nonisolated init(kind: ContentSurfaceKind, coverage: ContentSurfaceCoverage,
                            unitCount: Int, basisBlockIDs: [UUID] = [], detail: String? = nil) {
        self.kind = kind
        self.coverage = coverage
        self.unitCount = unitCount
        self.basisBlockIDs = basisBlockIDs
        self.detail = detail
    }
}
