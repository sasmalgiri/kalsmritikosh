//
//  XMLTextFidelityTests.swift
//  KalsmritikoshTests
//
//  F32 — XML/HTML text is kept exactly: CDATA text survives, a '>' inside a comment or
//  CDATA never leaks markup into evidence, numeric entities decode, a declared non-UTF-8
//  encoding is honoured, external entities are never fetched, and malformed input is
//  reported as partial instead of complete.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("F32 — XML / HTML text fidelity")
struct XMLTextFidelityTests {

    private func parse(_ data: Data, _ type: SourceType) async throws -> ParsedDocument {
        try await StructuredTextStructuralParser().parse(
            data: data, filename: "f.\(type == .html ? "html" : "xml")", type: type,
            logicalSourceID: UUID(), sourceVersionID: UUID())
    }

    private func texts(_ doc: ParsedDocument) -> [String] { doc.blocks.map(\.rawText) }

    @Test("Plain text and CDATA text are both retained, with their element path")
    func cdataKept() async throws {
        let doc = try await parse(Data("<r><a>plain</a><b><![CDATA[x < y && z]]></b></r>".utf8), .xml)
        #expect(texts(doc) == ["plain", "x < y && z"])
        #expect(doc.blocks.last?.locator.sectionPath == ["r", "b"])
        #expect(doc.extractionStatus == .complete)
    }

    @Test("A '>' inside a comment or CDATA never leaks markup into the text")
    func noLeakFromAngleBrackets() async throws {
        for type in [SourceType.xml, .html] {
            let doc = try await parse(Data("<r><!-- a > b --><p>kept</p><q><![CDATA[1 > 0]]></q></r>".utf8), type)
            #expect(texts(doc) == ["kept", "1 > 0"], "\(type)")
        }
    }

    @Test("Named and numeric entities decode")
    func entitiesDecode() async throws {
        let doc = try await parse(Data("<r><a>caf&#233; &#x2014; &apos;q&apos; &amp; co</a></r>".utf8), .xml)
        #expect(texts(doc) == ["café — 'q' & co"])
    }

    @Test("A declared ISO-8859-1 encoding is honoured")
    func declaredEncoding() async throws {
        var bytes = Data("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><r><a>".utf8)
        bytes.append(contentsOf: [0x63, 0x61, 0x66, 0xE9])            // "caf" + é in Latin-1
        bytes.append(contentsOf: Data("</a></r>".utf8))
        let doc = try await parse(bytes, .xml)
        #expect(texts(doc) == ["café"])
    }

    @Test("An external entity is never fetched or expanded")
    func externalEntityNotFetched() async throws {
        let xml = """
        <?xml version="1.0"?><!DOCTYPE r [<!ENTITY ext SYSTEM "file:///etc/hosts">]><r><a>before &ext; after</a></r>
        """
        let doc = try await parse(Data(xml.utf8), .xml)
        #expect(!texts(doc).joined().contains("localhost"))
    }

    @Test("Malformed XML keeps what it can but is reported partial, never complete")
    func malformedIsPartial() async throws {
        let doc = try await parse(Data("<r><a>kept</a><b>unclosed".utf8), .xml)
        #expect(texts(doc).contains("kept"))
        #expect(doc.extractionStatus == .partial)
        #expect(!doc.warnings.isEmpty)
    }
}
