//
//  StructuredTextParserTests.swift
//  KalsmritikoshTests
//
//  PAR-008 — HTML/JSON/XML/log structural adapters produce typed, located blocks
//  (not one flat blob), and route by extension.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Structured-text parsers (PAR-008)")
struct StructuredTextParserTests {

    private let parser = StructuredTextStructuralParser()

    private func parse(_ s: String, _ type: SourceType) async throws -> ParsedDocument {
        try await parser.parse(data: Data(s.utf8), filename: "f", type: type,
                               logicalSourceID: UUID(), sourceVersionID: UUID())
    }

    @Test("Extensions route to the four new types")
    func routing() {
        #expect(SourceType.detect(from: URL(fileURLWithPath: "a.html")) == .html)
        #expect(SourceType.detect(from: URL(fileURLWithPath: "a.json")) == .json)
        #expect(SourceType.detect(from: URL(fileURLWithPath: "a.xml")) == .xml)
        #expect(SourceType.detect(from: URL(fileURLWithPath: "a.log")) == .log)
        #expect(SourceType.html.category == .document)
    }

    @Test("JSON flattens to leaf blocks with key-path section")
    func json() async throws {
        let doc = try await parse(#"{"invoice": {"amount": 3800, "payee": "Rajesh"}}"#, .json)
        let texts = doc.blocks.map(\.rawText)
        #expect(texts.contains("invoice.amount: 3800"))
        #expect(texts.contains("invoice.payee: Rajesh"))
        // section path is the key path
        #expect(doc.blocks.first(where: { $0.rawText.contains("amount") })?.locator.sectionPath == ["invoice", "amount"])
    }

    @Test("JSON array indexes are captured")
    func jsonArray() async throws {
        let doc = try await parse(#"{"items": ["a", "b"]}"#, .json)
        #expect(doc.blocks.map(\.rawText).contains("items.[0]: a"))
        #expect(doc.blocks.map(\.rawText).contains("items.[1]: b"))
    }

    @Test("HTML drops script/style and keeps element text")
    func html() async throws {
        let doc = try await parse(
            "<html><head><style>.x{}</style></head><body><h1>Title</h1><script>evil()</script><p>Hello &amp; bye</p></body></html>", .html)
        let texts = doc.blocks.map(\.rawText)
        #expect(texts.contains("Title"))
        #expect(texts.contains("Hello & bye"))   // entity decoded
        #expect(!texts.contains { $0.contains("evil") })
        #expect(!texts.contains { $0.contains(".x{}") })
    }

    @Test("XML element text carries its tag path")
    func xml() async throws {
        let doc = try await parse("<root><item><name>Widget</name></item></root>", .xml)
        let name = try #require(doc.blocks.first(where: { $0.rawText == "Widget" }))
        #expect(name.locator.sectionPath == ["root", "item", "name"])
    }

    @Test("Log emits one record block per line")
    func log() async throws {
        let doc = try await parse("2024-01-01 INFO start\n2024-01-01 ERROR boom\n", .log)
        #expect(doc.blocks.count == 2)
        #expect(doc.blocks.allSatisfy { $0.kind == .logRecord })
        #expect(doc.blocks[1].rawText.contains("ERROR boom"))
    }
}
