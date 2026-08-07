//
//  DocxParserTests.swift
//  KalsmritikoshTests
//
//  Release gate F1 (macro E) — DOCX is an ADVERTISED structural format but had
//  no dedicated fixture suite in the parser-fixtures gate. Proves the full
//  parse path on a synthetic OOXML package (built with the in-module
//  ZIPArchiveWriter): headings with section paths, list items, paragraphs,
//  tables with rows, header/footer boilerplate, and honest failure states for
//  a corrupt package and a package with no word/document.xml.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct DocxParserTests {

    /// A minimal DOCX: a ZIP with the given WordprocessingML as its document part.
    private func docx(_ documentXML: String, extraParts: [(String, String)] = []) -> Data {
        var z = ZIPArchiveWriter()
        z.addFile(path: "[Content_Types].xml",
                  text: #"<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>"#)
        z.addFile(path: "word/document.xml", text: documentXML)
        for (path, xml) in extraParts { z.addFile(path: path, text: xml) }
        return z.build()
    }

    private func parse(_ data: Data) async throws -> ParsedDocument {
        try await DocxStructuralParser().parse(
            data: data, filename: "fixture.docx", type: .docx,
            logicalSourceID: UUID(), sourceVersionID: UUID())
    }

    @Test("Headings, list items, paragraphs and tables become typed blocks in reading order")
    func typedBlocksInOrder() async throws {
        let xml = """
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\
        <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Contract Review</w:t></w:r></w:p>\
        <w:p><w:r><w:t>Opening paragraph.</w:t></w:r></w:p>\
        <w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t>Payment Terms</w:t></w:r></w:p>\
        <w:p><w:pPr><w:numPr/></w:pPr><w:r><w:t>Net 30 days</w:t></w:r></w:p>\
        <w:tbl><w:tr><w:tc><w:p><w:r><w:t>Date</w:t></w:r></w:p></w:tc>\
        <w:tc><w:p><w:r><w:t>Amount</w:t></w:r></w:p></w:tc></w:tr>\
        <w:tr><w:tc><w:p><w:r><w:t>2020-01-01</w:t></w:r></w:p></w:tc>\
        <w:tc><w:p><w:r><w:t>5.00</w:t></w:r></w:p></w:tc></w:tr></w:tbl>\
        </w:body></w:document>
        """
        let doc = try await parse(docx(xml))
        #expect(doc.extractionStatus == .complete)
        #expect(doc.detectedType == .docx)
        let kinds = doc.blocks.map(\.kind)
        // Heading1 → documentTitle (first), Heading2 → sectionHeading; the
        // table emits one .table block plus one .tableRow per row.
        #expect(kinds == [.documentTitle, .paragraph, .sectionHeading, .listItem, .table, .tableRow, .tableRow])
        #expect(doc.blocks[0].rawText == "Contract Review")
        #expect(doc.blocks[3].rawText == "Net 30 days")
        #expect(doc.blocks[5].rawText == "Date | Amount")
        // The list item under Heading2 carries the live section path.
        #expect(doc.blocks[3].locator.sectionPath == ["Contract Review", "Payment Terms"])
        // Ordinals are dense and blocks carry native full confidence.
        #expect(doc.blocks.map(\.ordinal) == Array(0..<doc.blocks.count))
        #expect(doc.blocks.allSatisfy { $0.extractionMethod == .native && $0.extractionConfidence == 1.0 })
    }

    @Test("Header and footer parts are boilerplate block kinds, ordered around the body")
    func headerFooterBoilerplate() async throws {
        let body = """
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\
        <w:p><w:r><w:t>Body text.</w:t></w:r></w:p></w:body></w:document>
        """
        let header = #"<w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p><w:r><w:t>Case 12-345</w:t></w:r></w:p></w:hdr>"#
        let footer = #"<w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p><w:r><w:t>Page footer</w:t></w:r></w:p></w:ftr>"#
        let doc = try await parse(docx(body, extraParts: [("word/header1.xml", header), ("word/footer1.xml", footer)]))
        #expect(doc.blocks.map(\.kind) == [.pageHeader, .paragraph, .pageFooter])
        #expect(doc.blocks[0].rawText == "Case 12-345")
    }

    @Test("A ZIP with no word/document.xml is honestly corrupt, with the named warning")
    func missingDocumentPart() async throws {
        var z = ZIPArchiveWriter()
        z.addFile(path: "unrelated.txt", text: "not a docx")
        let doc = try await parse(z.build())
        #expect(doc.extractionStatus == .corrupt)
        #expect(doc.blocks.isEmpty)
        #expect(doc.warnings.contains { $0.code == "docx.no_document" })
    }

    @Test("Non-ZIP bytes are honestly corrupt, never a crash or empty success")
    func corruptPackage() async throws {
        let doc = try await parse(Data("this is not a zip package at all".utf8))
        #expect(doc.extractionStatus == .corrupt)
        #expect(doc.blocks.isEmpty)
        #expect(doc.warnings.contains { $0.code == "docx.unreadable" })
    }

    @Test("Part ordering walks header → body → footnotes → endnotes → footer")
    func partOrdering() {
        let parts = ["word/footer1.xml", "word/endnotes.xml", "word/document.xml",
                     "word/footnotes.xml", "word/header1.xml"]
        let sorted = parts.sorted { DocxStructuralParser.partOrder($0) < DocxStructuralParser.partOrder($1) }
        #expect(sorted == ["word/header1.xml", "word/document.xml", "word/footnotes.xml",
                           "word/endnotes.xml", "word/footer1.xml"])
    }
}
