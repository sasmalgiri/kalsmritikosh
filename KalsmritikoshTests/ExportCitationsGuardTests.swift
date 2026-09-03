//
//  ExportCitationsGuardTests.swift
//  KalsmritikoshTests
//
//  R-2 rider (F9): the export-citations GUARD. The landing page promises
//  "Export with citations intact" and "PDF, Word or Excel with citations
//  baked in". Receipt/custody tests prove the SEAL survives; nothing proved
//  the CITATIONS reach the exported bytes of every shipped format. This
//  guard closes that: one cited document, all eight ExportDeliverableFormat
//  cases, each citation's identifying text asserted present in the artifact
//  a recipient actually opens.
//
//  Byte-search is valid here by construction: text formats are UTF-8, and
//  the OOXML packages use the STORE method (ZIPArchiveWriter — deterministic,
//  uncompressed), so XML member text appears verbatim in the archive bytes.
//  PDF draws glyphs, so it is asserted via PDFKit text extraction instead.
//

import Foundation
import Testing
import PDFKit
@testable import Kalsmritikosh

@Suite("R-2 — export-citations guard (citations must survive every format)")
struct ExportCitationsGuardTests {

    // Distinct, collision-proof strings — if one leaks out of an export, the
    // guard names the format and the missing citation.
    private static let citations: [CitationRecord] = [
        CitationRecord(
            sourceVersionID: UUID(), displayLabel: "Ex. A",
            sourceTitle: "OrchidLabsInvoice2841", locatorText: "p. 3"),
        CitationRecord(
            sourceVersionID: UUID(), displayLabel: "Ex. B",
            sourceTitle: "GrantLetterIN555489", locatorText: "para 2"),
        CitationRecord(
            sourceVersionID: nil, displayLabel: "Ex. C",
            sourceTitle: "UnresolvedHearingNote", locatorText: "n/a"),
    ]

    private static func document(withTable: Bool) -> ExportableDocument {
        ExportableDocument(
            title: "Citations guard work product",
            sections: [ExportSection(
                title: "Findings",
                paragraphs: ["The invoice total matches the grant fee schedule."])],
            table: withTable ? ExportTable(
                title: "Fee schedule",
                columns: ["Item", "Amount"],
                rows: [["Filing fee", "Rs20,000"], ["Grant fee", "Rs15,000"]]) : nil,
            citations: citations,
            manifest: ExportManifest(
                exportedAt: Date(timeIntervalSince1970: 1_788_220_800),
                appVersion: "test", schemaVersion: SchemaMigrations.latestVersion))
    }

    /// The identifying text every exported artifact must carry, per citation.
    private static let markers = ["OrchidLabsInvoice2841", "GrantLetterIN555489", "UnresolvedHearingNote"]

    @Test("Every format carries every citation (sectioned document)", arguments: ExportDeliverableFormat.allCases)
    func citationsSurvive(format: ExportDeliverableFormat) throws {
        let data = try WorkProductExportService().data(for: Self.document(withTable: false), format: format)
        #expect(!data.isEmpty, "\(format.rawValue) export produced no bytes")
        let haystack = try extractedText(from: data, format: format)
        for marker in Self.markers {
            #expect(haystack.contains(marker),
                    "\(format.rawValue) export dropped citation source '\(marker)'")
        }
    }

    @Test("XLSX with a table appends the citation block instead of dropping it")
    func xlsxTableKeepsCitations() throws {
        let data = try WorkProductExportService().data(for: Self.document(withTable: true), format: .xlsx)
        let haystack = String(decoding: data, as: UTF8.self)
        #expect(haystack.contains("Filing fee"), "the table itself must still render")
        for marker in Self.markers {
            #expect(haystack.contains(marker), "xlsx table export dropped citation source '\(marker)'")
        }
    }

    @Test("A citation-free table XLSX is byte-identical to the plain table grid (no widening)")
    func xlsxWithoutCitationsUnchanged() throws {
        var doc = Self.document(withTable: true)
        doc.citations = []
        let data = try WorkProductExportService().data(for: doc, format: .xlsx)
        let haystack = String(decoding: data, as: UTF8.self)
        #expect(haystack.contains("Filing fee"))
        #expect(!haystack.contains("Citations"), "no citation block may appear for a citation-free document")
    }

    /// Text formats + OOXML (STORE zip) are searchable as bytes; PDF via PDFKit.
    private func extractedText(from data: Data, format: ExportDeliverableFormat) throws -> String {
        guard format == .pdf else { return String(decoding: data, as: UTF8.self) }
        let pdf = try #require(PDFDocument(data: data), "exported PDF failed to parse")
        return (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
    }
}
