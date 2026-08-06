//
//  ExportEngineTests.swift
//  KalsmritikoshTests
//
//  #147 — the file-producing export engine. Proves the dependency-free ZIP container, the OOXML DOCX/XLSX
//  writers, the native PDF writer, and the WorkProductExportService facade all render a composed
//  ExportableDocument faithfully and deterministically, and that the optional redaction layer removes protected
//  terms and FAILS CLOSED (refuses the export) if any term would survive in the rendered projection.
//  Pure/offline; synthetic documents only.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("Export engine", .serialized)
struct ExportEngineTests {

    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func manifest(limitations: [String] = []) -> ExportManifest {
        ExportManifest(exportedAt: Self.t0, appVersion: "test", schemaVersion: 102,
                       workspaceTitle: "Matter", sourceVersionIDs: ["v1"], sourceHashes: [String(repeating: "a", count: 64)],
                       selectedFindingCount: 1, knownLimitations: limitations)
    }

    private func sampleDoc(sectionText: String = "Alpha finding text", limitations: [String] = []) -> ExportableDocument {
        ExportableDocument(
            title: "Sample Report",
            subtitle: "A subtitle",
            sections: [ExportSection(title: "Findings", paragraphs: [sectionText, "Second paragraph"])],
            table: ExportTable(title: "Ledger", columns: ["Date", "Amount"], rows: [["2020-01-01", "5.00"], ["2020-02-01", "7.50"]]),
            citations: [],
            disclaimer: "Not legal advice.",
            manifest: manifest(limitations: limitations))
    }

    private func contains(_ data: Data, _ s: String) -> Bool { data.range(of: Data(s.utf8)) != nil }
    private func hasPrefix(_ data: Data, _ bytes: [UInt8]) -> Bool { Array(data.prefix(bytes.count)) == bytes }

    // MARK: - ZIP container

    @Test("The ZIP writer emits a valid archive with correct CRC-32 and stored (recoverable) content")
    func zipStructureAndCRC() {
        // Standard CRC-32 check value for the ASCII string "123456789".
        #expect(ZIPArchiveWriter.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
        var z = ZIPArchiveWriter()
        z.addFile(path: "hello.txt", text: "123456789")
        z.addFile(path: "dir/second.xml", text: "<x/>")
        let data = z.build()
        #expect(hasPrefix(data, [0x50, 0x4b, 0x03, 0x04]))           // local file header
        #expect(contains(data, "hello.txt") && contains(data, "dir/second.xml"))
        #expect(contains(data, "123456789") && contains(data, "<x/>"))   // STORE ⇒ content is recoverable
        #expect(data.range(of: Data([0x50, 0x4b, 0x01, 0x02])) != nil)   // central directory
        #expect(data.range(of: Data([0x50, 0x4b, 0x05, 0x06])) != nil)   // end of central directory
    }

    @Test("The ZIP writer is deterministic — same inputs, identical bytes")
    func zipDeterministic() {
        func make() -> Data { var z = ZIPArchiveWriter(); z.addFile(path: "a.txt", text: "content"); return z.build() }
        #expect(make() == make())
    }

    // MARK: - DOCX / XLSX (OOXML)

    @Test("DOCX is a ZIP package carrying the document parts and the work-product text verbatim")
    func docxIsValidPackage() {
        let data = DOCXExporter.render(sampleDoc())
        #expect(hasPrefix(data, [0x50, 0x4b, 0x03, 0x04]))
        #expect(contains(data, "[Content_Types].xml") && contains(data, "word/document.xml"))
        #expect(contains(data, "Sample Report") && contains(data, "Alpha finding text"))
        #expect(contains(data, "Ledger") && contains(data, "Amount") && contains(data, "2020-02-01"))
        #expect(DOCXExporter.render(sampleDoc()) == data)   // deterministic
    }

    @Test("XLSX is a ZIP package with a worksheet carrying the table grid verbatim")
    func xlsxIsValidPackage() {
        let data = XLSXExporter.render(sampleDoc())
        #expect(hasPrefix(data, [0x50, 0x4b, 0x03, 0x04]))
        #expect(contains(data, "xl/workbook.xml") && contains(data, "xl/worksheets/sheet1.xml"))
        #expect(contains(data, "Date") && contains(data, "Amount") && contains(data, "2020-01-01") && contains(data, "7.50"))
        #expect(XLSXExporter.render(sampleDoc()) == data)   // deterministic
    }

    @Test("Spreadsheet column letters follow the A…Z, AA… convention")
    func columnLetters() {
        #expect(XLSXExporter.columnLetters(0) == "A")
        #expect(XLSXExporter.columnLetters(25) == "Z")
        #expect(XLSXExporter.columnLetters(26) == "AA")
        #expect(XLSXExporter.columnLetters(27) == "AB")
    }

    // MARK: - PDF

    @Test("PDF renders a valid, non-trivial document")
    func pdfIsValid() {
        let data = PDFReportWriter.render(sampleDoc())
        #expect(hasPrefix(data, Array("%PDF-".utf8)))
        #expect(contains(data, "%%EOF"))
        #expect(data.count > 500)
    }

    // MARK: - Service facade

    @Test("Text formats pass through the existing renderer byte-for-byte")
    func serviceTextPassthrough() throws {
        let svc = WorkProductExportService()
        let doc = sampleDoc()
        for f in [ExportDeliverableFormat.markdown, .html, .csv, .json, .rtf] {
            let got = try svc.data(for: doc, format: f)
            let expected = Data(WorkProductExporter.render(doc, as: f.textFormat!).utf8)
            #expect(got == expected, "\(f.rawValue) passthrough")
        }
    }

    @Test("Binary formats produce their expected container magic")
    func serviceBinaryMagic() throws {
        let svc = WorkProductExportService()
        let doc = sampleDoc()
        #expect(hasPrefix(try svc.data(for: doc, format: .pdf), Array("%PDF-".utf8)))
        #expect(hasPrefix(try svc.data(for: doc, format: .docx), [0x50, 0x4b, 0x03, 0x04]))
        #expect(hasPrefix(try svc.data(for: doc, format: .xlsx), [0x50, 0x4b, 0x03, 0x04]))
    }

    @Test("Redaction removes a protected term from the exported bytes and inserts the token")
    func redactionRemovesTerm() throws {
        let svc = WorkProductExportService()
        let doc = sampleDoc(sectionText: "The account SECRET1234 was flagged")
        let policy = RedactionPolicy(customTerms: ["SECRET1234"])
        let docx = try svc.data(for: doc, format: .docx, redaction: policy)
        #expect(!contains(docx, "SECRET1234"))
        #expect(contains(docx, "[REDACTED]"))
        // And the same holds for a text format.
        let md = try svc.data(for: doc, format: .markdown, redaction: policy)
        #expect(!contains(md, "SECRET1234") && contains(md, "[REDACTED]"))
    }

    @Test("Redaction fails closed: a protected term surviving in the manifest refuses the export")
    func redactionFailsClosed() throws {
        let svc = WorkProductExportService()
        // The term lives only in the manifest's known-limitations (not redacted at the doc level) — verification
        // of the rendered projection must catch it and refuse, rather than emit a leaking file.
        let doc = sampleDoc(sectionText: "clean text", limitations: ["review blocked on SECRET1234"])
        let policy = RedactionPolicy(customTerms: ["SECRET1234"])
        #expect(throws: WorkProductExportError.self) {
            _ = try svc.data(for: doc, format: .pdf, redaction: policy)
        }
    }

    @Test("Writing to disk yields a file whose bytes equal the rendered data")
    func writeToDisk() throws {
        let svc = WorkProductExportService()
        let doc = sampleDoc()
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("export-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try svc.write(doc, format: .docx, to: url)
        let onDisk = try Data(contentsOf: url)
        #expect(onDisk == (try svc.data(for: doc, format: .docx)))
        #expect(hasPrefix(onDisk, [0x50, 0x4b, 0x03, 0x04]))
    }
}
