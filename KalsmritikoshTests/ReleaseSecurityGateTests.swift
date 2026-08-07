//
//  ReleaseSecurityGateTests.swift
//  KalsmritikoshTests
//
//  Release gates S3 (redaction) + S4 (temporary exports) — macro D closure.
//  S3's shipped promise is: redaction of GENERATED exports, applied BEFORE
//  rendering and verified fail-closed (source-document visual/binary
//  redaction is NOT a shipped v1 capability — RED-002, gated separately).
//  These tests prove the promise at the strongest honest level: for every
//  shipping format the OUTPUT REPRESENTATION itself is inspected — raw bytes
//  for the text formats and STORE-mode OOXML packages, extracted page text
//  for PDF — so a protected term cannot survive rendering in any format.
//

import Foundation
import Testing
import PDFKit
@testable import Kalsmritikosh

@Suite("Release security gates S3/S4 — export redaction + temp hygiene", .serialized)
struct ReleaseSecurityGateTests {

    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private static let secret = "SECRETTERM9876"

    private func manifest() -> ExportManifest {
        ExportManifest(exportedAt: Self.t0, appVersion: "test", schemaVersion: 102,
                       workspaceTitle: "Matter", sourceVersionIDs: ["v1"],
                       sourceHashes: [String(repeating: "a", count: 64)],
                       selectedFindingCount: 1, knownLimitations: [])
    }

    /// The protected term rides in a section paragraph, the subtitle AND a
    /// table row, so every format (prose-carrying and table-only alike)
    /// renders it somewhere.
    private func leakyDoc() -> ExportableDocument {
        ExportableDocument(
            title: "Sample Report",
            subtitle: "About \(Self.secret)",
            sections: [ExportSection(title: "Findings",
                                     paragraphs: ["The account \(Self.secret) was flagged.", "Second paragraph."])],
            table: ExportTable(title: "Ledger", columns: ["Date", "Note"],
                               rows: [["2020-01-01", "wire to \(Self.secret)"], ["2020-02-01", "clean row"]]),
            citations: [],
            disclaimer: "Not legal advice.",
            manifest: manifest())
    }

    private func contains(_ data: Data, _ s: String) -> Bool { data.range(of: Data(s.utf8)) != nil }

    // MARK: - S3: every shipping format, output representation inspected

    @Test("Redaction holds in the output representation of EVERY shipping format (markdown/html/csv/json/rtf/docx/xlsx bytes)")
    func redactionAcrossAllByteInspectableFormats() throws {
        let svc = WorkProductExportService()
        let policy = RedactionPolicy(customTerms: [Self.secret])
        // Text formats render prose directly; DOCX/XLSX are STORE-mode ZIP
        // packages, so a surviving term would be byte-visible in the package.
        for format in [ExportDeliverableFormat.markdown, .html, .csv, .json, .rtf, .docx, .xlsx] {
            let bytes = try svc.data(for: leakyDoc(), format: format, redaction: policy)
            #expect(!contains(bytes, Self.secret), "\(format.rawValue): protected term survived in output bytes")
            #expect(contains(bytes, "[REDACTED]"), "\(format.rawValue): redaction token missing from output")
        }
    }

    @Test("Redaction holds in the PDF's extracted page text — post-render content inspection, not just the projection gate")
    func redactionHoldsInRenderedPDFText() throws {
        let svc = WorkProductExportService()
        let policy = RedactionPolicy(customTerms: [Self.secret])
        let bytes = try svc.data(for: leakyDoc(), format: .pdf, redaction: policy)
        let pdf = try #require(PDFDocument(data: bytes), "rendered PDF must be parseable")
        var text = ""
        for i in 0..<pdf.pageCount { text += pdf.page(at: i)?.string ?? "" }
        #expect(!text.isEmpty, "PDF text extraction produced nothing — inspection would be vacuous")
        #expect(!text.contains(Self.secret), "protected term survived in rendered PDF text")
        #expect(text.contains("[REDACTED]"))
        // Belt-and-braces: the raw bytes must not carry the term either.
        #expect(!contains(bytes, Self.secret))
    }

    @Test("One policy redacts emails, phones and custom terms together")
    func redactionCombinesAllChannels() throws {
        let svc = WorkProductExportService()
        let doc = ExportableDocument(
            title: "Sample",
            sections: [ExportSection(title: "S", paragraphs: [
                "Contact jane.doe@example.com or +1 555 123 4567 about \(Self.secret)."])],
            citations: [], manifest: manifest())
        let policy = RedactionPolicy(redactEmails: true, redactPhones: true, customTerms: [Self.secret])
        let md = try svc.data(for: doc, format: .markdown, redaction: policy)
        #expect(!contains(md, "jane.doe@example.com"))
        #expect(!contains(md, "555 123 4567"))
        #expect(!contains(md, Self.secret))
        #expect(contains(md, "[REDACTED]"))
    }

    @Test("A protected term inside a citation cannot leak: redaction never rewrites the custody chain, so the export fails closed")
    func citationLeakFailsClosed() throws {
        let svc = WorkProductExportService()
        var doc = leakyDoc()
        doc = ExportableDocument(
            title: doc.title, subtitle: nil,
            sections: [ExportSection(title: "S", paragraphs: ["clean text"])],
            table: nil,
            citations: [CitationRecord(sourceVersionID: UUID(),
                                       displayLabel: "Exhibit A",
                                       sourceTitle: "Letter about \(Self.secret)")],
            disclaimer: nil, manifest: manifest())
        let policy = RedactionPolicy(customTerms: [Self.secret])
        // Citations are custody metadata — the redactor must not rewrite them,
        // and the fail-closed verification gate must therefore refuse the
        // export rather than ship a leak.
        #expect(throws: WorkProductExportError.self) {
            _ = try svc.data(for: doc, format: .markdown, redaction: policy)
        }
    }

    // MARK: - S4: export write failure leaves no orphan artifacts

    @Test("S4 — a failed export write leaves no partial or temporary file behind")
    func failedWriteLeavesNoOrphan() throws {
        let svc = WorkProductExportService()
        let missingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)", isDirectory: true)
        let dest = missingDir.appendingPathComponent("report.docx")
        #expect(throws: (any Error).self) {
            _ = try svc.write(leakyDoc(), format: .docx, to: dest)
        }
        // Neither the destination nor any staging remnant may exist.
        #expect(!FileManager.default.fileExists(atPath: dest.path))
        #expect(!FileManager.default.fileExists(atPath: missingDir.path))
    }
}
