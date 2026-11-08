//
//  ParserCapabilityManifestTests.swift
//  KalsmritikoshTests
//
//  PAR-001 — verifies the coverage matrix is generated from the real registry and
//  classifies formats honestly (FULL / PARTIAL / DEFERRED / PRESERVED-ONLY). This guards
//  against the advertised matrix drifting from what the code can actually parse.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PAR-001 ParserCapabilityManifest")
struct ParserCapabilityManifestTests {

    private func entries() -> [ParserCapabilityEntry] {
        ParserCapabilityManifest.generate(registry: .standard(ocr: VisionOCR()))
    }

    private func entry(_ type: String) -> ParserCapabilityEntry? {
        entries().first { $0.sourceType == type }
    }

    @Test("Structural formats are FULL and name their parser")
    func fullFormats() {
        // msg / pst / nsf joined this list once their structural parsers landed
        // (2026-09-23): each has a reader (OLE2/PST/NSF), a loader branch, AND a
        // StructuralParser, so the manifest now truthfully advertises them FULL.
        for t in ["txt", "docx", "doc", "xlsx", "xls", "mbox", "eml", "msg", "pst", "nsf"] {
            let e = entry(t)
            #expect(e?.coverage == .full, "\(t) should be FULL")
            #expect(e?.parserName != nil)
        }
    }

    @Test("OCR-dependent formats are PARTIAL")
    func ocrPartial() {
        for t in ["pdf", "jpg", "png", "tiff"] {
            #expect(entry(t)?.coverage == .partial, "\(t) should be PARTIAL")
        }
    }

    @Test("Audio/video are DEFERRED")
    func mediaDeferred() {
        for t in ["mp3", "wav", "mp4", "mov"] {
            #expect(entry(t)?.coverage == .deferred, "\(t) should be DEFERRED")
        }
    }

    @Test("Unhandled document/email formats are PRESERVED-ONLY, not silently claimed")
    func preservedOnly() {
        // ppt / keynote still have no parser of any kind — they must stay
        // honestly preserved-only rather than claim coverage they don't have.
        for t in ["ppt", "keynote"] {
            #expect(entry(t)?.coverage == .preservedOnly, "\(t) should be PRESERVED-ONLY")
            #expect(entry(t)?.parserName == nil)
        }
    }

    @Test("Manifest is generated from code — every registry-supported type is FULL or PARTIAL")
    func generatedFromCode() {
        let reg = StructuralParserRegistry.standard(ocr: VisionOCR())
        let map = Dictionary(uniqueKeysWithValues: entries().map { ($0.sourceType, $0.coverage) })
        for t in reg.supportedTypes {
            let c = map[t.rawValue]
            #expect(c == .full || c == .partial, "\(t.rawValue) is parsed but not marked FULL/PARTIAL")
        }
    }

    // MARK: - IN-04 — processing matrix (native parsing · preview · recognition · original · processing)

    @MainActor
    private func processingRows() throws -> [ParserCapabilityManifest.ProcessingRow] {
        ParserCapabilityManifest.processingMatrix(registry: try UniversalParserRegistryBuilder.standard(ocr: VisionOCR()))
    }

    @Test("IN-04: every recognised format has exactly one row, plus a row for any unrecognised file that never claims to be read")
    @MainActor
    func processingMatrixCoversEveryFormat() throws {
        let rows = try processingRows()
        let formats = rows.map(\.format)
        for t in SourceType.allCases where t != .unknown {
            #expect(formats.filter { $0 == t.rawValue }.count == 1, "\(t.rawValue) must appear once")
        }
        let other = try #require(rows.last)
        #expect(other.format.hasPrefix("any other file"))
        #expect(other.processing.hasPrefix("UNSUPPORTED") && other.preview == .externalApp)
        // The original is accounted for on every row, including the unrecognised one.
        #expect(rows.allSatisfy { $0.original == ParserCapabilityManifest.originalAccounting })
    }

    @Test("IN-04: the columns are independent and honest — FULL needs structure, previews follow the source viewer, unreadable archives are unsupported")
    @MainActor
    func processingMatrixIsHonest() throws {
        let rows = Dictionary(uniqueKeysWithValues: try processingRows().map { ($0.format, $0) })
        for r in rows.values where r.processing == "FULL" { #expect(r.nativeParsing.hasPrefix("structured"), "\(r.format)") }
        #expect(rows["pdf"]?.preview == .pdfPages && rows["pdf"]?.recognition == "scanned pages" && rows["pdf"]?.processing == "PARTIAL")
        #expect(rows["png"]?.recognition == "images")
        #expect(rows["txt"]?.preview == .text && rows["txt"]?.processing == "FULL")
        // A DOCX is parsed natively but the inspector has no inline renderer for it: the columns disagree on purpose.
        #expect(rows["docx"]?.processing == "FULL" && rows["docx"]?.preview == .externalApp)
        #expect(rows["zip"]?.processing == "CONTAINER")
        #expect(rows["rar"]?.processing == "UNSUPPORTED")
        // A feature-gated reader that is switched off (iMessage by default) is recognised and kept, not read.
        #expect(rows["imessage"]?.processing == "PRESERVED-ONLY" && rows["imessage"]?.nativeParsing == "none")
        // Preview matches what SourceViewer renders inline, by extension.
        #expect(ParserCapabilityManifest.inlinePreview(pathExtension: "PDF") == .pdfPages)
        #expect(ParserCapabilityManifest.inlinePreview(pathExtension: "eml") == .text)
        #expect(ParserCapabilityManifest.inlinePreview(pathExtension: "xlsx") == .externalApp)
    }

    @Test("IN-04: the processing matrix committed in SUPPORTED_SOURCES.md equals the one generated from the registry")
    @MainActor
    func processingMatrixIsCommitted() throws {
        let generated = ParserCapabilityManifest.renderProcessingMarkdown(registry: try UniversalParserRegistryBuilder.standard(ocr: VisionOCR()))
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SUPPORTED_SOURCES.md")
        let doc = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        let begin = "<!-- processing-matrix:begin -->\n", end = "<!-- processing-matrix:end -->"
        guard let b = doc.range(of: begin), let e = doc.range(of: end, range: b.upperBound..<doc.endIndex) else {
            Issue.record("SUPPORTED_SOURCES.md has no processing-matrix markers"); return
        }
        let committed = String(doc[b.upperBound..<e.lowerBound])
        if committed != generated {
            Issue.record(Comment(rawValue: "SUPPORTED_SOURCES.md processing matrix is stale — replace the text between the markers with:\n" + generated))
        }
    }
}
