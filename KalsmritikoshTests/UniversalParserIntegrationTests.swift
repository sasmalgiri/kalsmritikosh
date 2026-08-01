//
//  UniversalParserIntegrationTests.swift
//  KalsmritikoshTests
//
//  USF-M1 (§27/§28) — end-to-end routing through the ONE universal parser platform. Every source
//  type is owned by exactly one plugin; the executor runs it over the immutable snapshot and gates
//  the result identity. Covers native formats, structural-only text formats (html/json/xml/log),
//  multi-KnowledgeObject mbox, unknown-input honesty (no fabricated structure), deferred media (no
//  transcription), and the exact-byte hash gate. Synthetic sources only.
//

import Foundation
import Testing
import CryptoKit
@testable import Kalsmritikosh

@Suite("USF-M1 — universal parser integration", .serialized)
@MainActor
struct UniversalParserIntegrationTests {

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeRegistry() throws -> UniversalParserRegistry {
        try UniversalParserRegistryBuilder.standard(ocr: VisionOCR())
    }

    /// Write the bytes to a temp snapshot, build a request whose contentHash IS the SHA-256 of those
    /// exact bytes (so the executor's exact-byte gate passes), and execute through the registry.
    private func execute(_ type: SourceType, filename: String, bytes: Data,
                         registry: UniversalParserRegistry, overrideHash: String? = nil) async throws -> UniversalParserResult {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usfm1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(filename)
        try bytes.write(to: url)
        let request = UniversalParserRequest(
            originalURL: url, processingSnapshotURL: url, logicalSourceID: UUID(), sourceVersionID: UUID(),
            sourceType: type, contentHash: overrideHash ?? sha256(bytes), sizeBytes: Int64(bytes.count))
        return try await UniversalParserExecutor(registry: registry).execute(request)
    }

    // MARK: - Native formats

    @Test("A .txt source routes to format.txt with a complete text surface")
    func txtRoutesToFormatTxt() async throws {
        let r = try await execute(.txt, filename: "note.txt", bytes: Data("Synthetic note body with enough words.".utf8), registry: try makeRegistry())
        #expect(r.pluginID == "format.txt")
        #expect(!r.knowledgeObjects.isEmpty)
        #expect(r.surface(.text)?.coverage == .complete)
    }

    @Test("A .csv source produces a tables content surface")
    func csvProducesTablesSurface() async throws {
        let csv = "name,amount\nAlpha,10\nBravo,20\n"
        let r = try await execute(.csv, filename: "data.csv", bytes: Data(csv.utf8), registry: try makeRegistry())
        #expect(r.pluginID == "format.csv")
        #expect(r.parsedDocument != nil)
        #expect(r.surface(.tables)?.coverage != .notApplicable)
    }

    @Test("A .markdown source routes to a readable text surface")
    func markdownRoutesToText() async throws {
        let r = try await execute(.markdown, filename: "readme.md", bytes: Data("# Title\n\nSynthetic markdown paragraph.".utf8), registry: try makeRegistry())
        #expect(r.pluginID == "format.markdown")
        #expect(!r.knowledgeObjects.isEmpty)
    }

    // MARK: - Structural-only text formats (read via TextLoader, structure via structural parser)

    @Test("An .html source routes to format.html and produces structure")
    func htmlStructuralOnlyRoutes() async throws {
        let r = try await execute(.html, filename: "page.html", bytes: Data("<html><body><h1>Head</h1><p>Synthetic paragraph.</p></body></html>".utf8), registry: try makeRegistry())
        #expect(r.pluginID == "format.html")
        #expect(r.parsedDocument != nil)
    }

    @Test("A .json source routes to format.json and produces structure")
    func jsonStructuralOnlyRoutes() async throws {
        let r = try await execute(.json, filename: "data.json", bytes: Data(#"{"party":"Alpha","amount":10}"#.utf8), registry: try makeRegistry())
        #expect(r.pluginID == "format.json")
        #expect(r.parsedDocument != nil)
    }

    @Test("An .xml source routes to format.xml and produces structure")
    func xmlStructuralOnlyRoutes() async throws {
        let r = try await execute(.xml, filename: "doc.xml", bytes: Data("<root><item>Synthetic</item></root>".utf8), registry: try makeRegistry())
        #expect(r.pluginID == "format.xml")
        #expect(r.parsedDocument != nil)
    }

    @Test("A .log source routes to format.log and produces structure")
    func logStructuralOnlyRoutes() async throws {
        let log = "2025-03-03 12:00:00 INFO synthetic log line one\n2025-03-03 12:00:01 WARN synthetic log line two\n"
        let r = try await execute(.log, filename: "app.log", bytes: Data(log.utf8), registry: try makeRegistry())
        #expect(r.pluginID == "format.log")
        #expect(r.parsedDocument != nil)
    }

    // MARK: - Email

    @Test("An .eml source produces a structured email document")
    func emlProducesStructuredEmail() async throws {
        let eml = "From: alpha@example.com\r\nTo: bravo@example.com\r\nSubject: Synthetic\r\n\r\nBody text with enough words here.\r\n"
        let r = try await execute(.eml, filename: "msg.eml", bytes: Data(eml.utf8), registry: try makeRegistry())
        #expect(r.pluginID == "format.eml")
        #expect(r.parsedDocument != nil)
    }

    @Test("An .mbox source yields multiple KnowledgeObjects (one per message) via a single ingestMany")
    func mboxYieldsMultipleKnowledgeObjects() async throws {
        let mbox = """
        From alpha@example.com Mon Mar 03 12:00:00 2025
        From: alpha@example.com
        Subject: First synthetic message

        Body of the first synthetic message.

        From bravo@example.com Mon Mar 03 13:00:00 2025
        From: bravo@example.com
        Subject: Second synthetic message

        Body of the second synthetic message.

        """
        let r = try await execute(.mbox, filename: "archive.mbox", bytes: Data(mbox.utf8), registry: try makeRegistry())
        #expect(r.pluginID == "format.mbox")
        #expect(r.knowledgeObjects.count >= 2)   // §28 — multi-record loader runs once, returns many
    }

    // MARK: - Unknown input honesty

    @Test("Unknown binary input is preserved honestly — no fabricated structure or blocks")
    func unknownBinaryIsHonestNotFabricated() async throws {
        let binary = Data([0xFF, 0xD8, 0xFF, 0x00, 0x01, 0x02, 0x03, 0xFE, 0xFD])   // not valid UTF-8 text
        let r = try await execute(.unknown, filename: "blob.bin", bytes: binary, registry: try makeRegistry())
        #expect(r.pluginID == "system.generic-text-fallback")
        #expect(r.parsedDocument == nil)                                // never fabricates a structural doc
        #expect(r.surface(.structure)?.coverage == .notApplicable)      // no fake structure surface
    }

    @Test("Unknown but valid-text input is decoded into a readable text surface")
    func unknownValidTextIsReadable() async throws {
        let r = try await execute(.unknown, filename: "mystery", bytes: Data("Synthetic readable text of unknown type.".utf8), registry: try makeRegistry())
        #expect(r.pluginID == "system.generic-text-fallback")
        #expect(r.knowledgeObjects.contains { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    // MARK: - Deferred media

    @Test("Deferred media keeps custody and does NOT activate transcription")
    func deferredMediaKeepsCustodyNoTranscription() async throws {
        let registry = try makeRegistry()
        #expect(try registry.resolve(.mp3).executionMode == .deferred)
        let r = try await execute(.mp3, filename: "clip.mp3", bytes: Data([0x00, 0x01, 0x02, 0x03]), registry: registry)
        #expect(r.pluginID == "media.mp3")
        #expect(r.extractionStatus == .deferred)
        #expect(r.knowledgeObjects.isEmpty)     // no content produced — interpretation postponed
        #expect(r.parsedDocument == nil)
    }

    // MARK: - Identity + ownership gates

    @Test("A result whose content hash disagrees with the request is rejected (exact-byte gate)")
    func contentHashMismatchIsRejected() async throws {
        let registry = try makeRegistry()
        await #expect(throws: UniversalParserError.self) {
            _ = try await execute(.txt, filename: "x.txt", bytes: Data("payload".utf8),
                                  registry: registry, overrideHash: String(repeating: "a", count: 64))
        }
    }

    @Test("Every source type is owned by exactly one plugin, resolvable by type")
    func eachSourceTypeHasExactlyOneOwner() throws {
        let registry = try makeRegistry()
        for t in SourceType.allCases where t != .unknown {
            #expect(registry.owns(t))
        }
        #expect(registry.owns(.unknown))
        #expect(try registry.resolve(.pdf).pluginID == "format.pdf")
        #expect(try registry.resolve(.txt).pluginID == "format.txt")
    }
}
