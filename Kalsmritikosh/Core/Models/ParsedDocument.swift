//
//  ParsedDocument.swift
//  Kalsmritikosh
//
//  A1 (spec §6.1 / §6 / P3.0a) — the universal output every format-specific
//  parser produces: a file turned into typed, ordered, exactly-located
//  EvidenceBlocks plus parse provenance. This is the authoritative
//  representation the ledger builds on; legacy `KnowledgeObject`/`Chunk` become
//  compatibility projections of it (A1 §6.4).
//

import Foundation

public nonisolated struct ParsedDocument: Sendable {
    public let id: UUID
    /// The logical source (stable across versions of the same file).
    public let logicalSourceID: UUID
    /// This specific version (A2 versioning).
    public let sourceVersionID: UUID
    public let filename: String
    public let detectedType: SourceType
    public let mimeType: String?
    public let contentHash: String
    public let metadata: [String: AnyCodable]
    public let blocks: [EvidenceBlock]
    public let warnings: [ParserWarning]
    public let extractionStatus: ExtractionStatus

    public nonisolated init(
        id: UUID = UUID(),
        logicalSourceID: UUID,
        sourceVersionID: UUID,
        filename: String,
        detectedType: SourceType,
        mimeType: String? = nil,
        contentHash: String,
        metadata: [String: AnyCodable] = [:],
        blocks: [EvidenceBlock],
        warnings: [ParserWarning] = [],
        extractionStatus: ExtractionStatus = .complete
    ) {
        self.id = id
        self.logicalSourceID = logicalSourceID
        self.sourceVersionID = sourceVersionID
        self.filename = filename
        self.detectedType = detectedType
        self.mimeType = mimeType
        self.contentHash = contentHash
        self.metadata = metadata
        self.blocks = blocks
        self.warnings = warnings
        self.extractionStatus = extractionStatus
    }

    /// Reconstruct the document text in original reading order (A1 acceptance:
    /// "source text can be reconstructed in original order"). Excludes empty
    /// container blocks.
    public var reconstructedText: String {
        blocks
            .sorted { $0.ordinal < $1.ordinal }
            .map(\.rawText)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// The non-boilerplate, substantive blocks in reading order — the basis for
    /// the deterministic DocumentProfile's "first meaningful block".
    public var meaningfulBlocks: [EvidenceBlock] {
        blocks
            .filter { !$0.kind.isBoilerplate && $0.normalizedText.count >= 3 }
            .sorted { $0.ordinal < $1.ordinal }
    }
}
