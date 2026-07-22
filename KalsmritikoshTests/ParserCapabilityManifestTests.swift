//
//  ParserCapabilityManifestTests.swift
//  KalsmritikoshTests
//
//  PAR-001 — verifies the coverage matrix is generated from the real registry and
//  classifies formats honestly (FULL / PARTIAL / DEFERRED / PRESERVED-ONLY). This guards
//  against the advertised matrix drifting from what the code can actually parse.
//

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
        for t in ["txt", "docx", "doc", "xlsx", "xls", "mbox", "eml"] {
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
        for t in ["msg", "pst", "ppt", "keynote"] {
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
}
