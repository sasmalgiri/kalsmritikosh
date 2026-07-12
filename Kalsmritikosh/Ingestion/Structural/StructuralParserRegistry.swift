//
//  StructuralParserRegistry.swift
//  Kalsmritikosh
//
//  A3 — dispatch table from SourceType to the StructuralParser that turns that
//  format into typed EvidenceBlocks. The ingest pipeline (A2) asks the registry
//  for a parser; when none is registered for a type it keeps the legacy
//  KnowledgeObject path (no regression during the incremental migration).
//

import Foundation

public struct StructuralParserRegistry: Sendable {
    private let parsers: [StructuralParser]

    public nonisolated init(parsers: [StructuralParser]) {
        self.parsers = parsers
    }

    /// Format parsers that need no injected dependency (pure, deterministic).
    private static let selfContainedParsers: [StructuralParser] = [
        PlainTextStructuralParser(),
        DocxStructuralParser(),
        CSVStructuralParser(),
        XLSXStructuralParser(),
        PPTXStructuralParser(),
        EPUBStructuralParser(),
        RTFStructuralParser(),
        ODTStructuralParser(),
        ODSStructuralParser(),
        EmailStructuralParser()
    ]

    /// The default v1 registry — every format with a dependency-free structural
    /// parser. Formats not listed here fall back to the legacy path. Use
    /// `standard(ocr:)` to additionally get OCR-backed formats (PDF, images).
    public static let standard = StructuralParserRegistry(parsers: selfContainedParsers)

    /// The full registry including formats that require an OCR engine: PDF
    /// (native page text with a per-page OCR fallback for scanned pages) and
    /// images (Vision OCR → text + table blocks). The app wires this with its
    /// real `VisionOCR`; tests that don't need OCR use `.standard`.
    public static func standard(ocr: any OCREngine) -> StructuralParserRegistry {
        StructuralParserRegistry(parsers: selfContainedParsers + [
            PDFStructuralParser(ocr: ocr),
            ImageStructuralParser(ocr: ocr)
        ])
    }

    /// The parser for a source type, or nil (→ legacy KnowledgeObject path).
    public nonisolated func parser(for type: SourceType) -> StructuralParser? {
        parsers.first { $0.supportedTypes.contains(type) }
    }

    public nonisolated var supportedTypes: Set<SourceType> {
        parsers.reduce(into: Set<SourceType>()) { $0.formUnion($1.supportedTypes) }
    }
}
