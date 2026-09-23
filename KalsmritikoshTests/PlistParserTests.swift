//
//  PlistParserTests.swift
//  KalsmritikoshTests
//
//  HOST-1 — proves the plist lane on synthetic fixtures of every wire format.
//  The regression this guards is specific: `.plist` used to route to `.xml`, so a
//  BINARY plist (most of them, on macOS) produced nothing. Each test below writes
//  real bytes with Foundation and asserts the evidence a host artifact must yield:
//  typed key-path citations, ISO-8601 dates, nested-plist recovery, and an honest
//  status when the bytes are not a plist at all.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Plist parser (HOST-1)")
@MainActor
struct PlistParserTests {

    private let parser = PlistStructuralParser()

    private func parse(_ data: Data, _ filename: String = "Test.plist") async throws -> ParsedDocument {
        try await parser.parse(data: data, filename: filename, type: .plist,
                               logicalSourceID: UUID(), sourceVersionID: UUID())
    }

    private func encode(_ object: Any, _ format: PropertyListSerialization.PropertyListFormat) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: format, options: 0)
    }

    /// A realistic macOS host-identity artifact.
    private var systemVersion: [String: Any] {
        ["ProductName": "macOS", "ProductVersion": "26.0", "ProductBuildVersion": "25A354"]
    }

    // MARK: - Detection

    @Test("A .plist extension is its own type, no longer mis-routed to .xml")
    func extensionDetectsPlist() {
        #expect(SourceType.detect(from: URL(fileURLWithPath: "/x/SystemVersion.plist")) == .plist)
        #expect(SourceType.detect(from: URL(fileURLWithPath: "/x/data.xml")) == .xml)
    }

    @Test("bplist00 magic bytes identify an extensionless binary plist")
    func magicBytesDetectBinaryPlist() throws {
        let data = try encode(systemVersion, .binary)
        #expect(data.prefix(6) == Data("bplist".utf8))   // fixture really is binary
        // Host artifacts are routinely extensionless, so magic bytes must carry it.
        #expect(SourceType.sniffMagicBytes(data) == .plist)
    }

    // MARK: - All three wire formats

    @Test("Binary plist values are recovered and cited by key path")
    func binaryFormatParses() async throws {
        let doc = try await parse(try encode(systemVersion, .binary), "SystemVersion.plist")
        #expect(doc.extractionStatus == .complete)
        let rows = doc.blocks.filter { $0.kind == .tableRow }
        #expect(rows.count == 3)
        #expect(rows.contains { $0.rawText == "ProductVersion = 26.0" })
        // The citation must name the file and the key, or an answer can't point at it.
        let versionRow = try #require(rows.first { $0.rawText.hasPrefix("ProductVersion") })
        #expect(versionRow.locator.sectionPath == ["SystemVersion.plist", "ProductVersion"])
        // And the wire format is itself recorded as evidence.
        #expect(doc.blocks.contains { $0.kind == .documentHeader && $0.rawText.contains("binary") })
    }

    @Test("XML plist yields the same values as the binary encoding of the same object")
    func xmlMatchesBinary() async throws {
        let fromBinary = try await parse(try encode(systemVersion, .binary))
        let fromXML = try await parse(try encode(systemVersion, .xml))
        let values: (ParsedDocument) -> [String] = { d in
            d.blocks.filter { $0.kind == .tableRow }.map(\.rawText).sorted()
        }
        // Same facts regardless of how the file happened to be serialized.
        #expect(values(fromBinary) == values(fromXML))
        #expect(fromXML.blocks.contains { $0.kind == .documentHeader && $0.rawText.contains("XML") })
    }

    @Test("Legacy OpenStep/ASCII plist is read, not rejected")
    func openStepFormatParses() async throws {
        let text = "{ ComputerName = \"EVIDENCE-01\"; TimeZone = \"Asia/Kolkata\"; }"
        let doc = try await parse(Data(text.utf8), "preferences.plist")
        #expect(doc.extractionStatus == .complete)
        let rows = doc.blocks.filter { $0.kind == .tableRow }.map(\.rawText)
        #expect(rows.contains("ComputerName = EVIDENCE-01"))
        #expect(rows.contains("TimeZone = Asia/Kolkata"))
    }

    // MARK: - Forensically load-bearing value types

    @Test("Dates render ISO-8601 in UTC so the timeline can use them")
    func datesAreISO8601() async throws {
        // 2026-03-14T09:26:53Z
        let when = Date(timeIntervalSince1970: 1_773_480_413)
        let doc = try await parse(try encode(["InstallDate": when], .binary), "InstallHistory.plist")
        let row = try #require(doc.blocks.first { $0.kind == .tableRow })
        #expect(row.rawText == "InstallDate = 2026-03-14T09:26:53Z")
        if case .string(let t)? = row.attributes["valueType"]?.value { #expect(t == "date") }
        else { Issue.record("valueType attribute missing") }
    }

    @Test("Nested structure is walked and each leaf keeps its full key path")
    func nestedStructureKeepsPaths() async throws {
        let object: [String: Any] = [
            "KnownNetworks": [
                ["SSIDString": "CAFE-GUEST", "SecurityType": "WPA2"],
                ["SSIDString": "HOME-5G", "SecurityType": "WPA3"]
            ]
        ]
        let doc = try await parse(try encode(object, .binary), "com.apple.wifi.plist")
        let rows = doc.blocks.filter { $0.kind == .tableRow }.map(\.rawText)
        #expect(rows.contains("KnownNetworks.[0].SSIDString = CAFE-GUEST"))
        #expect(rows.contains("KnownNetworks.[1].SSIDString = HOME-5G"))
        // Array and dictionary containers announce themselves so the shape is citable.
        #expect(doc.blocks.contains { $0.kind == .table && $0.rawText.contains("array with 2 item(s)") })
    }

    @Test("A plist embedded in a data value is decoded, not dismissed as a blob")
    func embeddedPlistIsRecovered() async throws {
        let inner = try encode(["LastUser": "j.doe"], .binary)
        let doc = try await parse(try encode(["Payload": inner], .binary), "loginwindow.plist")
        let rows = doc.blocks.filter { $0.kind == .tableRow }.map(\.rawText)
        // Without recursion this would read "Payload = <data 42 bytes>" and the
        // username — the actual evidence — would be invisible to search.
        #expect(rows.contains { $0.contains("LastUser = j.doe") })
        #expect(!rows.contains { $0.hasPrefix("Payload = <data") })
    }

    @Test("A non-plist data value stays an honest blob description")
    func opaqueBlobIsDescribedNotInvented() async throws {
        let blob = Data((0..<64).map { _ in UInt8.random(in: 0...255) })
        let doc = try await parse(try encode(["Thumbnail": blob], .binary))
        let row = try #require(doc.blocks.first { $0.kind == .tableRow })
        #expect(row.rawText == "Thumbnail = <data 64 bytes>")
        if case .string(let t)? = row.attributes["valueType"]?.value { #expect(t == "data") }
        else { Issue.record("valueType attribute missing") }
    }

    @Test("Booleans and integers are not stringified into floats")
    func scalarsRenderExactly() async throws {
        let object: [String: Any] = ["Enabled": true, "Disabled": false, "Count": 42, "Ratio": 0.5]
        let doc = try await parse(try encode(object, .binary))
        let rows = doc.blocks.filter { $0.kind == .tableRow }.map(\.rawText)
        #expect(rows.contains("Enabled = true"))
        #expect(rows.contains("Disabled = false"))
        #expect(rows.contains("Count = 42"))         // not "42.0"
        #expect(rows.contains("Ratio = 0.5"))
    }

    // MARK: - Honesty under bad input

    @Test("Bytes that are not a plist are reported corrupt, never guessed at")
    func garbageIsCorruptNotFabricated() async throws {
        let doc = try await parse(Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33]))
        #expect(doc.extractionStatus == .corrupt)
        #expect(doc.blocks.filter { $0.kind == .tableRow }.isEmpty)
        #expect(doc.warnings.contains { $0.code == "plist.undecodable" && $0.severity == .error })
    }

    @Test("An empty file is empty, not corrupt")
    func emptyFileIsEmpty() async throws {
        let doc = try await parse(Data())
        #expect(doc.extractionStatus == .empty)
        #expect(doc.warnings.contains { $0.code == "plist.empty" })
    }

    @Test("Parsing is deterministic — same bytes, same block order")
    func parseIsDeterministic() async throws {
        // Dictionary key order is not stable in memory; citations must be anyway,
        // or re-ingesting an artifact silently renumbers every reference to it.
        let data = try encode(["zeta": 1, "alpha": 2, "mid": 3], .binary)
        let first = try await parse(data).blocks.map(\.rawText)
        let second = try await parse(data).blocks.map(\.rawText)
        #expect(first == second)
        #expect(first.filter { $0.contains(" = ") } == ["alpha = 2", "mid = 3", "zeta = 1"])
    }

    // MARK: - Loader + registry wiring

    @Test("PlistLoader produces searchable text for a BINARY plist (TextLoader cannot)")
    func loaderHandlesBinaryPlist() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plist-loader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("SystemVersion.plist")
        var artifact = systemVersion
        artifact["Count"] = 42          // a non-string value, which binary plists encode as bytes
        try encode(artifact, .binary).write(to: url)

        let ko = try await PlistLoader().ingest(fileAt: url, type: .plist)
        #expect(ko.content.contains("ProductVersion = 26.0"))
        #expect(ko.content.contains("Count = 42"))

        // The reason this loader exists, measured rather than assumed. On these same
        // bytes TextLoader does NOT throw — the file sits under its 200-scalar binary
        // guard — and returns the raw lossy decode:
        //   bplist00Ô…_ProductBuildVersion[ProductNameUCount^ProductVersionV25A354UmacOS\u{10}*T26.0
        // Key NAMES survive as ASCII runs, which is the trap: the text looks
        // plausible, so the adapter sees "the loader produced text" and skips the
        // structural parse on a searchCore request. But no key is joined to its
        // value, and the integer 42 is the byte \u{10}* rather than "42" — so the
        // indexed text can never answer "what version was this Mac running".
        let asText = try? await TextLoader().ingest(fileAt: url, type: .txt)
        let raw = try #require(asText?.content)     // nothing stops it
        #expect(!raw.contains("ProductVersion = 26.0"))   // no key→value association
        #expect(!raw.contains("42"))                      // non-string values unreadable
    }

    @Test("The universal registry gives .plist a real immediate structural plugin")
    func registryOwnsPlist() throws {
        let registry = try UniversalParserRegistryBuilder.standard(ocr: VisionOCR())
        let plugin = try registry.resolve(.plist)
        #expect(plugin.pluginID == "format.plist")
        #expect(plugin.executionMode == .immediate)
        #expect(plugin.capabilities.producesStructure)
        #expect(!(plugin is PreservedOnlyPlugin))
    }
}
