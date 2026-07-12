//
//  StructuralParser.swift
//  Kalsmritikosh
//
//  A3 — the contract every format parser migrates to: a file's bytes become a
//  ParsedDocument of typed, ordered, exactly-located EvidenceBlocks (A1). This
//  replaces the "flatten to KnowledgeObject.content" path incrementally, one
//  format at a time, behind this common interface.
//

import Foundation

public protocol StructuralParser: Sendable {
    /// Source types this parser handles.
    nonisolated var supportedTypes: Set<SourceType> { get }
    nonisolated var parserName: String { get }
    nonisolated var parserVersion: String { get }

    /// Parse raw bytes into a ParsedDocument. Implementations never throw for
    /// merely-empty or partial input — they set `extractionStatus` and add
    /// warnings so source health stays explicit (A1/§7.7).
    func parse(
        data: Data,
        filename: String,
        type: SourceType,
        logicalSourceID: UUID,
        sourceVersionID: UUID
    ) async throws -> ParsedDocument
}
