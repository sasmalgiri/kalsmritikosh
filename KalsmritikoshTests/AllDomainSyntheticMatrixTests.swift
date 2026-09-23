//
//  AllDomainSyntheticMatrixTests.swift
//  KalsmritikoshTests
//
//  THE SWEEP (owner request 2026-09-23): every SourceType, synthetic input, one
//  table. Per-format suites prove depth; this proves NOTHING IS MISSING — it
//  iterates `SourceType.allCases` so a newly added type cannot slip in without
//  either a working parser probe or an explicit, honest non-coverage entry.
//
//  Two invariants per type:
//    • PARSED types  — a synthesized file carrying a sentinel fact comes back
//      `.complete` with the fact intact (fidelity), or `.partial` when the
//      format legitimately needs OCR we stub out.
//    • UNPARSED types — no structural parser is registered at all, so the type
//      is preserved honestly instead of silently claiming coverage.
//
//  Plus the anti-lie invariant that caught real bugs: a parser must NEVER report
//  `.complete` with zero blocks, and must NEVER crash or throw on junk bytes.
//

import Testing
import Foundation
import AppKit
import CoreGraphics
import CoreText
@testable import Kalsmritikosh

struct AllDomainSyntheticMatrixTests {

    private static let sentinel = "Patent 555489 granted to Riyaz Ahmed"

    private struct NoOCR: OCREngine {
        nonisolated var engineID: String { "matrix-stub" }
        func recognizePrinted(at url: URL) async -> [String] { ["Patent 555489 granted to Riyaz Ahmed"] }
        func recognizeHandwritten(at url: URL) async -> [String] { [] }
        func recognizeTable(at url: URL) async -> [[String]] { [] }
    }

    private func registry() -> StructuralParserRegistry {
        StructuralParserRegistry.standard(ocr: NoOCR())
    }

    // MARK: - Synthetic bytes per format

    /// Synthetic input for every type we claim to parse. `nil` = this type has
    /// no parser by design (media / legacy / proprietary containers).
    private func synthetic(for type: SourceType) -> Data? {
        let s = Self.sentinel
        switch type {
        case .txt, .markdown, .log:
            return Data("# Note\n\n\(s).\n".utf8)
        case .html:
            return Data("<html><body><h1>Note</h1><p>\(s).</p></body></html>".utf8)
        case .json:
            return Data("{\"note\":\"\(s).\"}".utf8)
        case .xml:
            return Data("<root><note>\(s).</note></root>".utf8)
        case .csv:
            return Data("subject,detail\nGrant,\"\(s).\"\n".utf8)

        case .docx:
            var z = ZIPArchiveWriter()
            z.addFile(path: "word/document.xml", text: """
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
            <w:body><w:p><w:r><w:t>\(s).</w:t></w:r></w:p></w:body></w:document>
            """)
            return z.build()
        case .xlsx:
            var z = ZIPArchiveWriter()
            z.addFile(path: "xl/workbook.xml", text: """
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
            <sheets><sheet name="S1" sheetId="1"/></sheets></workbook>
            """)
            z.addFile(path: "xl/sharedStrings.xml", text: """
            <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><t>\(s)</t></si></sst>
            """)
            z.addFile(path: "xl/worksheets/sheet1.xml", text: """
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
            <sheetData><row r="1"><c r="A1" t="s"><v>0</v></c></row></sheetData></worksheet>
            """)
            return z.build()
        case .pptx:
            var z = ZIPArchiveWriter()
            z.addFile(path: "ppt/slides/slide1.xml", text: """
            <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" \
            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><p:cSld><p:spTree>\
            <p:sp><p:txBody><a:p><a:r><a:t>\(s)</a:t></a:r></a:p></p:txBody></p:sp>\
            </p:spTree></p:cSld></p:sld>
            """)
            return z.build()
        case .odt:
            var z = ZIPArchiveWriter()
            z.addFile(path: "content.xml", text: """
            <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
            xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"><office:body><office:text>\
            <text:p>\(s).</text:p></office:text></office:body></office:document-content>
            """)
            return z.build()
        case .ods:
            var z = ZIPArchiveWriter()
            z.addFile(path: "content.xml", text: """
            <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
            xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" \
            xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"><office:body><office:spreadsheet>\
            <table:table table:name="T"><table:table-row><table:table-cell><text:p>\(s)</text:p>\
            </table:table-cell></table:table-row></table:table>\
            </office:spreadsheet></office:body></office:document-content>
            """)
            return z.build()
        case .epub:
            var z = ZIPArchiveWriter()
            z.addFile(path: "META-INF/container.xml", text: """
            <?xml version="1.0"?><container version="1.0" \
            xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>\
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>\
            </rootfiles></container>
            """)
            z.addFile(path: "OEBPS/content.opf", text: """
            <?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0">\
            <metadata/><manifest><item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>\
            </manifest><spine><itemref idref="c1"/></spine></package>
            """)
            z.addFile(path: "OEBPS/c1.xhtml", text: """
            <?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><body><p>\(s).</p></body></html>
            """)
            return z.build()
        case .rtf:
            return Data("{\\rtf1\\ansi\\deff0 {\\fonttbl{\\f0 Helvetica;}}\\f0\\fs24 \(s).\\par}".utf8)

        case .eml:
            return Data("""
            From: Riyaz Ahmed <riyaz@example.com>
            To: sasmalgiri@gmail.com
            Subject: Grant
            Content-Transfer-Encoding: quoted-printable

            \(s).
            """.utf8)
        case .mbox:
            return Data("""
            From riyaz@example.com Mon Jan 01 00:00:00 2024
            From: Riyaz Ahmed <riyaz@example.com>
            Subject: Grant

            \(s).
            """.utf8)
        case .appleMail:
            let msg = """
            From: Riyaz Ahmed <riyaz@example.com>
            Subject: Grant

            \(s).
            """
            // .emlx = byte-count line, then the message, then a plist trailer.
            return Data("\(msg.utf8.count)\n\(msg)".utf8)
        case .msg:
            return CFBFixtureWriter().build([
                CFBFixtureWriter.unicodeProperty(id: .subject, "Grant"),
                CFBFixtureWriter.unicodeProperty(id: .senderName, "Riyaz Ahmed"),
                CFBFixtureWriter.unicodeProperty(id: .body, "\(s).")
            ])
        case .nsf:
            var text = "Lotus Notes NSF database\n" + String(repeating: "-", count: 300) + "\n"
            text += """
            Form: Memo
            From: Riyaz Ahmed <riyaz@example.com>
            SendTo: sasmalgiri@gmail.com
            Subject: Grant
            Body: \(s).
            """
            return Data(text.utf8)

        case .plist:
            // HOST-1 — binary, because that is the format that used to yield nothing.
            return try? PropertyListSerialization.data(
                fromPropertyList: ["Note": "\(s)."], format: .binary, options: 0)
        case .registryHive:
            // HOST-2 — a real REGF hive carrying the sentinel as a REG_SZ value.
            return RegistryHiveFixtureWriter().build(
                root: .init("ROOT", lastWritten: Date(timeIntervalSince1970: 1_773_480_413),
                            values: [.sz("Note", "\(s).")]))

        case .pdf:
            let out = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            guard let consumer = CGDataConsumer(data: out as CFMutableData),
                  let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
            ctx.beginPDFPage(nil)
            let attr = NSAttributedString(
                string: "\(s).",
                attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 14, nil)])
            ctx.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
            ctx.endPDFPage(); ctx.closePDF()
            return out as Data
        // Types this GENERIC generator can't faithfully synthesize — each is
        // owned by a dedicated suite with a proper fixture (see coveredElsewhere).
        case .sqlite, .doc, .xls, .png, .jpg, .heic, .tiff, .webp, .pst:
            return nil

        // No parser by design — preserved-only or deferred.
        case .ppt, .keynote, .zip, .rar, .sevenZip,
             .mp3, .wav, .m4a, .aac, .aiff, .caf, .flac, .threegp, .mp4, .mov,
             .imessage, .chatExport, .safariHistory, .chromeHistory, .unknown:
            return nil
        }
    }

    /// Types whose parse legitimately reports `.partial` (OCR-dependent).
    private static let ocrDependent: Set<SourceType> = [.pdf, .png, .jpg, .heic, .tiff, .webp]

    /// Types that HAVE a parser but whose faithful fixture lives in a dedicated
    /// suite, because this generic generator can't produce valid bytes for them.
    /// Listed with the suite that owns each, so coverage stays traceable rather
    /// than silently dropped.
    private static let coveredElsewhere: [SourceType: String] = [
        .doc: "LegacyOfficeParserTests (real OLE2 .doc fixture)",
        .xls: "LegacyOfficeParserTests (real OLE2 .xls fixture)",
        .sqlite: "SQLiteStructuralParserTests (real DB built via the engine)",
        .png: "ImageParserTests (stub-OCR fixture)",
        .jpg: "ImageParserTests (stub-OCR fixture)",
        .heic: "ImageParserTests (stub-OCR fixture)",
        .tiff: "ImageParserTests (stub-OCR fixture)",
        .webp: "ImageParserTests (stub-OCR fixture)",
        .pst: "PSTNSFParserTests (field-mapping layer; NDB B-trees are not synthesizable without a PST writer)"
    ]

    /// Types with no structural parser BY DESIGN — asserted to stay uncovered.
    private static let intentionallyUnparsed: Set<SourceType> = [
        .ppt, .keynote,                                   // legacy Office, no reader
        .rar, .sevenZip,                                  // proprietary compression (3rd-party)
        .zip,                                             // container lane, not structural
        .mp3, .wav, .m4a, .aac, .aiff, .caf, .flac, .threegp, .mp4, .mov,   // media deferred
        .imessage, .chatExport, .safariHistory, .chromeHistory,             // feature-gated
        .unknown
    ]

    // MARK: - The sweep

    /// COMPLETENESS INVARIANT: every SourceType falls in exactly ONE bucket —
    /// (a) probed here with synthetic bytes, (b) parsed but owned by a named
    /// suite, or (c) intentionally unparsed. A newly added type belongs to none
    /// of them and fails this test, which is the point: coverage can't silently
    /// regress when the format list grows.
    @Test("Every SourceType is accounted for in exactly one coverage bucket")
    func everyTypeAccountedFor() {
        let reg = registry()
        for type in SourceType.allCases {
            let hasParser = reg.parser(for: type) != nil
            let hasFixture = synthetic(for: type) != nil
            let elsewhere = Self.coveredElsewhere[type]
            let unparsed = Self.intentionallyUnparsed.contains(type)

            // Exactly one bucket.
            let buckets = [hasFixture, elsewhere != nil, unparsed].filter { $0 }.count
            #expect(buckets == 1,
                    "\(type.rawValue): must be in exactly one bucket (fixture/elsewhere/unparsed), got \(buckets)")

            if unparsed {
                #expect(!hasParser,
                        "\(type.rawValue) is listed unparsed but HAS a parser — update the list")
            } else {
                #expect(hasParser,
                        "\(type.rawValue) claims coverage but no structural parser is registered")
            }
        }
    }

    @Test("Every synthesizable format round-trips its sentinel fact", arguments: SourceType.allCases)
    func sentinelSurvives(type: SourceType) async throws {
        let reg = registry()
        guard let data = synthetic(for: type), let parser = reg.parser(for: type) else { return }

        let doc = try await parser.parse(
            data: data, filename: "probe.\(type.rawValue)", type: type,
            logicalSourceID: UUID(), sourceVersionID: UUID())

        // Anti-lie invariant: never "complete" with nothing to show.
        if doc.extractionStatus == .complete {
            #expect(!doc.blocks.isEmpty, "\(type.rawValue): complete but produced no blocks")
        }
        let expected: Set<ExtractionStatus> = Self.ocrDependent.contains(type)
            ? [.complete, .partial] : [.complete]
        #expect(expected.contains(doc.extractionStatus),
                "\(type.rawValue): status \(doc.extractionStatus)")

        let text = doc.blocks.map(\.rawText).joined(separator: " ")
        #expect(text.contains("555489"),
                "\(type.rawValue): sentinel lost — got: \(text.prefix(160))")
        // Ordinals are contiguous and strictly increasing for every format.
        #expect(doc.blocks.map(\.ordinal) == Array(0..<doc.blocks.count),
                "\(type.rawValue): ordinals not contiguous")
    }

    @Test("No parser crashes or fakes success on junk bytes", arguments: SourceType.allCases)
    func junkIsHonest(type: SourceType) async throws {
        let reg = registry()
        guard let parser = reg.parser(for: type) else { return }
        // Random-ish bytes that are valid for no format.
        let junk = Data((0..<900).map { UInt8(($0 * 7 + 13) % 251) })
        let doc = try await parser.parse(
            data: junk, filename: "junk.\(type.rawValue)", type: type,
            logicalSourceID: UUID(), sourceVersionID: UUID())
        if doc.extractionStatus == .complete {
            #expect(!doc.blocks.isEmpty,
                    "\(type.rawValue): claimed complete on junk with no blocks")
        }
        // Anything non-complete must say why.
        if doc.extractionStatus != .complete {
            #expect(!doc.warnings.isEmpty || doc.blocks.isEmpty,
                    "\(type.rawValue): non-complete status with no warning and no empty result")
        }
    }
}
