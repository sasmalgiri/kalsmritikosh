//
//  LegacyOfficeParserTests.swift
//  KalsmritikoshTests
//
//  Phase 2 — regression coverage for the legacy OLE2 Office parsers
//  (DocStructuralParser for Word 97–2003 .doc, XlsStructuralParser for Excel
//  97–2003 .xls) and the underlying OLE2Reader directory fix.
//
//  Fixtures live in Fixtures/LegacyOffice/ (regenerate with
//  scripts/gen-legacy-fixtures.sh). Add this file to the test target to run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct LegacyOfficeParserTests {

    private func fixture(_ name: String) throws -> Data {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/LegacyOffice", isDirectory: true)
        return try Data(contentsOf: dir.appendingPathComponent(name))
    }

    // MARK: - OLE2 directory tree

    @Test func ole2ReaderFindsStreamsInStandardCompoundFile() throws {
        let data = try fixture("sample.doc")
        let reader = try OLE2Reader(data: data)
        let names = Set(reader.rootChildren().map {
            $0.name.trimmingCharacters(in: CharacterSet(charactersIn: "\u{0000}\u{0001}\u{0005}"))
        })
        // The child pointer is at directory-entry offset +76; a regression to
        // +68 (the left-sibling) makes this set empty.
        #expect(names.contains("WordDocument"))
    }

    // MARK: - Word .doc

    @Test func docParserReconstructsTextIntoTypedBlocks() async throws {
        let data = try fixture("sample.doc")
        let doc = try await DocStructuralParser().parse(
            data: data, filename: "sample.doc", type: .doc,
            logicalSourceID: UUID(), sourceVersionID: UUID()
        )
        #expect(doc.extractionStatus == .complete)
        #expect(!doc.blocks.isEmpty)
        let text = doc.blocks.map(\.rawText).joined(separator: " ")
        #expect(text.contains("Supplier ABC"))
        #expect(text.contains("1,800,000"))
        #expect(text.contains("2024-11-29"))
        // Ordinals strictly increasing; every block links a paragraph locator.
        #expect(doc.blocks.map(\.ordinal) == Array(0..<doc.blocks.count))
    }

    @Test func docParserRejectsNonOLE2AsUnsupportedNotCrash() async throws {
        let doc = try await DocStructuralParser().parse(
            data: Data("<html>not a real doc</html>".utf8), filename: "fake.doc", type: .doc,
            logicalSourceID: UUID(), sourceVersionID: UUID()
        )
        #expect(doc.extractionStatus == .unsupported)
        #expect(doc.blocks.isEmpty)
        #expect(doc.warnings.contains { $0.code == "doc.notOLE2" })
    }

    // MARK: - Excel .xls

    @Test func xlsParserRecoversSheetsRowsAndValues() async throws {
        let data = try fixture("sample.xls")
        let doc = try await XlsStructuralParser().parse(
            data: data, filename: "sample.xls", type: .xls,
            logicalSourceID: UUID(), sourceVersionID: UUID()
        )
        #expect(doc.extractionStatus == .complete)
        let sheets = doc.blocks.filter { $0.kind == .spreadsheetSheet }
        let rows = doc.blocks.filter { $0.kind == .spreadsheetRow }
        #expect(sheets.count == 2)          // Delivery + Notes
        #expect(rows.count >= 4)
        let text = doc.blocks.map(\.rawText).joined(separator: " ")
        #expect(text.contains("Supplier ABC"))   // shared string
        #expect(text.contains("1800000"))         // RK/NUMBER decode
        #expect(text.contains("540000"))
        #expect(text.contains("2024-11-29"))      // second sheet
        // Row blocks carry a (sheet,row) locator.
        #expect(rows.allSatisfy { $0.locator.sheet != nil && $0.locator.row != nil })
    }

    @Test func xlsParserMarksNonOLE2Unsupported() async throws {
        let doc = try await XlsStructuralParser().parse(
            data: Data("col1,col2\n1,2".utf8), filename: "fake.xls", type: .xls,
            logicalSourceID: UUID(), sourceVersionID: UUID()
        )
        #expect(doc.extractionStatus == .unsupported)
        #expect(doc.warnings.contains { $0.code == "xls.notOLE2" })
    }
}
