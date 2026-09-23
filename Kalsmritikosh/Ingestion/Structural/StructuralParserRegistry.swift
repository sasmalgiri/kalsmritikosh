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
        DocStructuralParser(),        // Phase 2 — legacy Word 97–2003 .doc
        CSVStructuralParser(),
        XLSXStructuralParser(),
        XlsStructuralParser(),        // Phase 2 — legacy Excel 97–2003 .xls (BIFF8)
        PPTXStructuralParser(),
        EPUBStructuralParser(),
        RTFStructuralParser(),
        ODTStructuralParser(),
        ODSStructuralParser(),
        EmailStructuralParser(),
        MBOXStructuralParser(),
        EMLXStructuralParser(),
        MSGStructuralParser(),       // Outlook .msg (OLE2/MAPI) — typed email blocks
        PSTStructuralParser(),       // Outlook .pst/.ost (NDB) — typed blocks per message
        NSFStructuralParser(),       // Lotus/HCL Notes .nsf — typed blocks per mail note
        StructuredTextStructuralParser(),  // PAR-008 — HTML / JSON / XML / log
        SQLiteStructuralParser(),          // PAR-009 — read-only SQLite tables
        PlistStructuralParser(),           // HOST-1 — binary / XML / OpenStep plists
        RegistryHiveStructuralParser(),    // HOST-2 — Windows registry hives (REGF)
        DiscussionStructuralParser(),      // DISC-1 — discussion-platform exports
        KnowledgeCStructuralParser(),      // HOST-7 — Apple CoreDuet activity store
        CustodyManifestStructuralParser(), // HOST-8 — examiner chain of custody
        ExtractionManifestStructuralParser(), // HOST-8b — iOS backup inventory
        EVTXStructuralParser()             // HOST-3 — Windows event logs (EVTX)
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

    /// PAR-001 — per-parser capability, read straight from the registered parsers so
    /// the coverage matrix is GENERATED FROM CODE and cannot drift from reality.
    public nonisolated var capabilities: [(name: String, version: String, types: Set<SourceType>)] {
        parsers.map { ($0.parserName, $0.parserVersion, $0.supportedTypes) }
    }
}
