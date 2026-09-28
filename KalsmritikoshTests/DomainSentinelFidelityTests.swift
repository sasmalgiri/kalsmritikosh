//
//  DomainSentinelFidelityTests.swift
//  KalsmritikoshTests
//
//  Owner audit 2026-09-23 — WHOLE-FILE "known fact in → same fact out" fidelity
//  probes for the domains whose suites previously proved parts/helpers but not a
//  real file end to end: XLSX, PPTX, ODT, ODS, EPUB, RTF, and PDF (real PDF
//  bytes; PDFParserTests only exercised the paragraphize helper). Each probe
//  builds REAL bytes for the format containing one sentinel fact and asserts the
//  fact survives the structural parse intact — the property whose violation in
//  the email lane produced the truncated-address defect.
//

import Testing
import Foundation
import AppKit
import CoreGraphics
import CoreText
@testable import Kalsmritikosh

struct DomainSentinelFidelityTests {

    private static let sentinel = "Patent 555489 was granted to Riyaz Ahmed on 12 March 2024"

    /// The fact must survive verbatim in the parsed blocks (joined text).
    private func assertSentinel(in doc: ParsedDocument, _ label: String) {
        let text = doc.blocks.map(\.rawText).joined(separator: " ")
        #expect(doc.extractionStatus == .complete, "\(label): status \(doc.extractionStatus)")
        #expect(text.contains("555489"), "\(label): patent number lost — got: \(text.prefix(200))")
        #expect(text.contains("Riyaz Ahmed"), "\(label): person lost — got: \(text.prefix(200))")
    }

    // MARK: - XLSX (real ZIP: workbook + sharedStrings + sheet)

    @Test("XLSX whole-file: a shared-string cell fact survives the parse")
    func xlsxSentinel() async throws {
        var z = ZIPArchiveWriter()
        z.addFile(path: "xl/workbook.xml", text: """
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <sheets><sheet name="Facts" sheetId="1"/></sheets></workbook>
        """)
        z.addFile(path: "xl/sharedStrings.xml", text: """
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="1" uniqueCount="1">\
        <si><t>\(Self.sentinel)</t></si></sst>
        """)
        z.addFile(path: "xl/worksheets/sheet1.xml", text: """
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <sheetData><row r="1"><c r="A1" t="s"><v>0</v></c></row></sheetData></worksheet>
        """)
        let doc = try await XLSXStructuralParser().parse(
            data: z.build(), filename: "facts.xlsx", type: .xlsx,
            logicalSourceID: UUID(), sourceVersionID: UUID())
        assertSentinel(in: doc, "xlsx")
    }

    // MARK: - PPTX (real ZIP: one slide)

    @Test("PPTX whole-file: a slide text run fact survives the parse")
    func pptxSentinel() async throws {
        var z = ZIPArchiveWriter()
        z.addFile(path: "ppt/slides/slide1.xml", text: """
        <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><p:cSld><p:spTree>\
        <p:sp><p:txBody><a:p><a:r><a:t>\(Self.sentinel)</a:t></a:r></a:p></p:txBody></p:sp>\
        </p:spTree></p:cSld></p:sld>
        """)
        let doc = try await PPTXStructuralParser().parse(
            data: z.build(), filename: "deck.pptx", type: .pptx,
            logicalSourceID: UUID(), sourceVersionID: UUID())
        assertSentinel(in: doc, "pptx")
    }

    // MARK: - ODT / ODS (real ZIP: content.xml)

    @Test("ODT whole-file: a paragraph fact survives the parse")
    func odtSentinel() async throws {
        var z = ZIPArchiveWriter()
        z.addFile(path: "content.xml", text: """
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
        xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"><office:body><office:text>\
        <text:p>\(Self.sentinel).</text:p>\
        </office:text></office:body></office:document-content>
        """)
        let doc = try await ODTStructuralParser().parse(
            data: z.build(), filename: "note.odt", type: .odt,
            logicalSourceID: UUID(), sourceVersionID: UUID())
        assertSentinel(in: doc, "odt")
    }

    @Test("ODS whole-file: a table-cell fact survives the parse")
    func odsSentinel() async throws {
        var z = ZIPArchiveWriter()
        z.addFile(path: "content.xml", text: """
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
        xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" \
        xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"><office:body><office:spreadsheet>\
        <table:table table:name="Facts"><table:table-row>\
        <table:table-cell><text:p>\(Self.sentinel)</text:p></table:table-cell>\
        </table:table-row></table:table>\
        </office:spreadsheet></office:body></office:document-content>
        """)
        let doc = try await ODSStructuralParser().parse(
            data: z.build(), filename: "facts.ods", type: .ods,
            logicalSourceID: UUID(), sourceVersionID: UUID())
        assertSentinel(in: doc, "ods")
    }

    // MARK: - EPUB (real ZIP: container → OPF spine → chapter)

    @Test("EPUB whole-file: a spine-chapter fact survives the parse")
    func epubSentinel() async throws {
        var z = ZIPArchiveWriter()
        z.addFile(path: "META-INF/container.xml", text: """
        <?xml version="1.0"?><container version="1.0" \
        xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>\
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>\
        </rootfiles></container>
        """)
        z.addFile(path: "OEBPS/content.opf", text: """
        <?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0">\
        <metadata><dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">Probe Book</dc:title></metadata>\
        <manifest><item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/></manifest>\
        <spine><itemref idref="ch1"/></spine></package>
        """)
        z.addFile(path: "OEBPS/ch1.xhtml", text: """
        <?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>Ch1</title></head>\
        <body><h1>Chapter One</h1><p>\(Self.sentinel).</p></body></html>
        """)
        let doc = try await EPUBStructuralParser().parse(
            data: z.build(), filename: "probe.epub", type: .epub,
            logicalSourceID: UUID(), sourceVersionID: UUID())
        assertSentinel(in: doc, "epub")
    }

    // MARK: - RTF (real RTF bytes via the NSAttributedString importer)

    @Test("RTF whole-file: a paragraph fact survives the parse")
    func rtfSentinel() async throws {
        let rtf = "{\\rtf1\\ansi\\deff0 {\\fonttbl{\\f0 Helvetica;}}\\f0\\fs24 \(Self.sentinel).\\par}"
        let doc = try await RTFStructuralParser().parse(
            data: Data(rtf.utf8), filename: "note.rtf", type: .rtf,
            logicalSourceID: UUID(), sourceVersionID: UUID())
        assertSentinel(in: doc, "rtf")
    }

    // MARK: - PDF (REAL PDF bytes with a native text layer; OCR never consulted)

    private struct NoOCR: OCREngine {
        nonisolated var engineID: String { "probe-stub" }
        func recognizePrinted(at url: URL) async -> [String] { [] }
        func recognizeHandwritten(at url: URL) async -> [String] { [] }
        func recognizeTable(at url: URL) async -> [[String]] { [] }
    }

    @Test("PDF whole-file: a drawn text-layer fact survives the parse (native, no OCR)")
    func pdfSentinel() async throws {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
        ctx.beginPDFPage(nil)
        let attr = NSAttributedString(
            string: Self.sentinel + ".",
            attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 14, nil)])
        ctx.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        ctx.endPDFPage()
        ctx.closePDF()

        let doc = try await PDFStructuralParser(ocr: NoOCR()).parse(
            data: data as Data, filename: "probe.pdf", type: .pdf,
            logicalSourceID: UUID(), sourceVersionID: UUID())
        assertSentinel(in: doc, "pdf")
    }
}
