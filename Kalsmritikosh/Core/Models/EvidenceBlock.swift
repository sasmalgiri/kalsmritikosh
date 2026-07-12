//
//  EvidenceBlock.swift
//  Kalsmritikosh
//
//  A1 (spec §6.1 / P3.0b) — one atomic, independently-citable unit of a parsed
//  source: a heading, a body paragraph, an email header, a spreadsheet cell, a
//  transcript segment. Blocks preserve type, order, hierarchy and an exact
//  SourceLocator, so the ledger keeps a file's real structure instead of the
//  flattened `KnowledgeObject.content` string.
//

import Foundation

public nonisolated struct EvidenceBlock: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    /// The ParsedDocument this block belongs to.
    public let documentID: UUID
    /// The source VERSION that produced it (A2 versioning); nil until wired.
    public let sourceVersionID: UUID?
    /// Hierarchy: the containing block (section→paragraph, table→row→cell).
    public let parentBlockID: UUID?
    /// Position within the document in original reading order.
    public let ordinal: Int
    public let kind: EvidenceBlockKind
    /// Verbatim source text (may be empty for image/table container blocks).
    public let rawText: String
    /// Cleaned text used for indexing (whitespace-normalized, de-hyphenated).
    public let normalizedText: String
    public let locator: SourceLocator
    public let extractionMethod: ExtractionMethod
    /// 0…1 confidence in the extracted text (1 for native, lower for OCR/ASR).
    public let extractionConfidence: Double
    /// BCP-47 language tag when detected.
    public let language: String?
    /// Format-specific extras (heading level, cell number-format, MIME, …).
    public let attributes: [String: AnyCodable]

    public nonisolated init(
        id: UUID = UUID(),
        documentID: UUID,
        sourceVersionID: UUID? = nil,
        parentBlockID: UUID? = nil,
        ordinal: Int,
        kind: EvidenceBlockKind,
        rawText: String,
        normalizedText: String? = nil,
        locator: SourceLocator = SourceLocator(),
        extractionMethod: ExtractionMethod = .native,
        extractionConfidence: Double = 1.0,
        language: String? = nil,
        attributes: [String: AnyCodable] = [:]
    ) {
        self.id = id
        self.documentID = documentID
        self.sourceVersionID = sourceVersionID
        self.parentBlockID = parentBlockID
        self.ordinal = ordinal
        self.kind = kind
        self.rawText = rawText
        self.normalizedText = normalizedText ?? EvidenceBlock.normalize(rawText)
        self.locator = locator
        self.extractionMethod = extractionMethod
        self.extractionConfidence = max(0, min(1, extractionConfidence))
        self.language = language
        self.attributes = attributes
    }

    /// Deterministic normalization: collapse runs of whitespace, join broken
    /// hyphenation at line ends, trim. No meaning is destroyed (A1 §Normalize).
    public nonisolated static func normalize(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "-\n", with: "")   // de-hyphenate
        s = s.replacingOccurrences(of: "\r\n", with: "\n")
        let collapsed = s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
