//
//  EVTXParserTests.swift
//  KalsmritikoshTests
//
//  HOST-3 — Windows event logs, against real EVTX bytes from a fixture writer
//  built from the published fixed-offset layout.
//
//  The tests are split to match the unit's stated boundary, and the second half
//  matters as much as the first:
//    1. The CONTAINER is exact — record ids, written FILETIMEs, chunk striding,
//       the free-space limit, truncation and the dirty flag.
//    2. The LIMITATION IS DECLARED — BinXML templates are unresolved, and the
//       parser must say so in the evidence, report `.partial`, and never claim a
//       field name it did not recover. A thin result that looked complete would
//       lead a reader to a wrong conclusion, which is the failure this guards.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Windows event logs — EVTX (HOST-3)")
@MainActor
struct EVTXParserTests {

    private let parser = EVTXStructuralParser()

    /// 2026-03-14T09:26:53Z
    private var when: Date { Date(timeIntervalSince1970: 1_773_480_413) }

    private func parse(_ data: Data, _ filename: String = "Security.evtx") async throws -> ParsedDocument {
        try await parser.parse(data: data, filename: filename, type: .eventLog,
                               logicalSourceID: UUID(), sourceVersionID: UUID())
    }
    private func records(_ doc: ParsedDocument) -> [String] {
        doc.blocks.filter { $0.kind == .logRecord }.map(\.rawText)
    }
    private func attribute(_ block: EvidenceBlock, _ key: String) -> String? {
        if case .string(let v)? = block.attributes[key]?.value { return v }
        return nil
    }

    private var log: Data {
        EVTXFixtureWriter().build(records: [
            .init(id: 1001, written: when, strings: ["EVIDENCE-01", "riyaz", "Logon"]),
            .init(id: 1002, written: when.addingTimeInterval(60),
                  strings: ["EVIDENCE-01", "An account was successfully logged on"]),
            .init(id: 1003, written: nil, strings: ["ServiceInstalled"])
        ])
    }

    // MARK: - 1. The container is exact

    @Test("Every record's id and written time are recovered exactly")
    func recordIDsAndTimesAreExact() async throws {
        let doc = try await parse(log)
        #expect(records(doc).count == 3)
        let first = try #require(doc.blocks.first { $0.rawText.contains("Record 1001") })
        #expect(attribute(first, "timestamp") == "2026-03-14T09:26:53Z")
        #expect(first.rawText.contains("written 2026-03-14T09:26:53Z"))
    }

    @Test("A record with no written time says so rather than being dated 1601")
    func zeroFiletimeIsNotADate() async throws {
        // FILETIME 0 is a real state. Converting it would date evidence to 1601.
        let doc = try await parse(log)
        let undated = try #require(doc.blocks.first { $0.rawText.contains("Record 1003") })
        #expect(undated.rawText.contains("no written time recorded"))
        #expect(undated.attributes["timestamp"] == nil)
        #expect(!undated.rawText.contains("1601"))
    }

    @Test("The header states the record count, id range and time span")
    func headerSummarisesTheLog() async throws {
        let doc = try await parse(log)
        let header = try #require(doc.blocks.first { $0.kind == .documentHeader })
        #expect(header.rawText.contains("3 record(s)"))
        #expect(header.rawText.contains("ids 1001–1003"))
        #expect(header.rawText.contains("2026-03-14T09:26:53Z to 2026-03-14T09:27:53Z"))
    }

    @Test("Each record is citable at its exact byte offset")
    func recordsCiteTheirOffset() async throws {
        let doc = try await parse(log)
        let first = try #require(doc.blocks.first { $0.rawText.contains("Record 1001") })
        if case .int(let offset)? = first.attributes["fileOffset"]?.value {
            // First record sits at header (4096) + chunk records offset (512).
            #expect(offset == 4096 + 512)
        } else {
            Issue.record("record has no fileOffset")
        }
    }

    @Test("Records spanning multiple chunks are all found")
    func multipleChunksAreWalked() async throws {
        // Chunks are walked by their fixed 64 KB stride, so a log larger than one
        // chunk must not silently stop at the first.
        let many = (1...150).map {
            EVTXFixtureWriter.Record(id: UInt64(2000 + $0), written: when, strings: ["e\($0)"])
        }
        let doc = try await parse(EVTXFixtureWriter().build(records: many, recordsPerChunk: 64))
        #expect(records(doc).count == 150)
        #expect(records(doc).contains { $0.contains("Record 2150") })
    }

    @Test("Bytes beyond a chunk's free-space offset are NOT read as records")
    func freeSpaceLimitIsHonoured() async throws {
        // Past that offset lies whatever the previous log left behind. Reading it
        // would present stale records as current ones — a fabricated finding.
        let doc = try await parse(log)
        #expect(records(doc).count == 3)
        #expect(!records(doc).contains { $0.contains("Record 0") })
    }

    @Test("UTF-16 strings in a record are recovered and deduplicated")
    func stringsAreHarvested() async throws {
        let doc = try await parse(log)
        let first = try #require(doc.blocks.first { $0.rawText.contains("Record 1001") })
        #expect(first.rawText.contains("EVIDENCE-01"))
        #expect(first.rawText.contains("riyaz"))
        // A repeated string within one record appears once.
        let dupes = EVTXReader.utf16Strings(
            in: Data("A\0B\0C\0".utf16Bytes + "A\0B\0C\0".utf16Bytes), from: 0, to: 12)
        #expect(dupes.count == Set(dupes).count)
    }

    @Test("Short runs and binary are not harvested as text")
    func binaryIsNotMistakenForText() {
        // Without a minimum run length, GUIDs and integers arrive as mojibake that
        // reads like text and pollutes every search.
        let noise = Data([0x01, 0x00, 0x02, 0x00, 0xFF, 0xFF, 0x03, 0x00])
        #expect(EVTXReader.utf16Strings(in: noise, from: 0, to: noise.count).isEmpty)
        // A real word IS harvested.
        let word = Data("Logon".utf16Bytes)
        #expect(EVTXReader.utf16Strings(in: word, from: 0, to: word.count) == ["Logon"])
    }

    // MARK: - 2. The limitation is declared

    @Test("The parser reports PARTIAL, never complete")
    func statusIsAlwaysPartial() async throws {
        // The container is exact but the content is uninterpreted. Reporting
        // complete would be the single most misleading thing this parser could do.
        let doc = try await parse(log)
        #expect(doc.extractionStatus == .partial)
        #expect(doc.warnings.contains { $0.code == "evtx.binxml_unresolved" })
    }

    @Test("The limitation is in the EVIDENCE, not only in a warning")
    func limitationIsAnEvidenceBlock() async throws {
        // A retrieved answer built from this log must be able to quote what the
        // log could not say; a warning alone never reaches the answer surface.
        let doc = try await parse(log)
        let note = try #require(doc.blocks.first {
            attribute($0, "limitation") == "binxml-templates-unresolved"
        })
        #expect(note.rawText.contains("EventID"))
        #expect(note.rawText.contains("cannot yet be filtered by event id"))
    }

    @Test("No record claims a field name the parser did not recover")
    func noFabricatedFieldNames() async throws {
        // The failure mode being guarded: emitting "EventID: 4624" from a string
        // harvest would be an invention, and an examiner could not tell.
        let doc = try await parse(log)
        for block in doc.blocks where block.kind == .logRecord {
            #expect(!block.rawText.contains("EventID"))
            #expect(!block.rawText.contains("Provider"))
            #expect(block.attributes["eventID"] == nil)
        }
    }

    @Test("The loader's text carries the limitation, and confidence is not high")
    func loaderSurfacesTheLimitation() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("evtx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Security.evtx")
        try log.write(to: url)

        let ko = try await EVTXLoader().ingest(fileAt: url, type: .eventLog)
        #expect(ko.content.contains("EVIDENCE-01"))
        #expect(ko.content.contains("BinXML template resolution is not implemented"))
        // Medium, never high: the record content is uninterpreted.
        #expect(ko.confidence == .medium)
    }

    // MARK: - Honesty on damaged input

    @Test("A truncated log yields what survived AND says it is short")
    func truncationIsReported() async throws {
        var writer = EVTXFixtureWriter()
        writer.overDeclareChunks = 3
        let doc = try await parse(writer.build(records: [
            .init(id: 1, written: when, strings: ["survived"])
        ]))
        #expect(records(doc).count == 1)
        #expect(doc.warnings.contains { $0.message.contains("truncated") })
    }

    @Test("A log copied while in use reports its dirty flag")
    func dirtyFlagIsReported() async throws {
        // The last chunk may be mid-write, so its final records can be incomplete.
        // An examiner needs to know that before relying on the tail.
        var writer = EVTXFixtureWriter()
        writer.dirty = true
        let doc = try await parse(writer.build(records: [
            .init(id: 1, written: when, strings: ["open when copied"])
        ]))
        #expect(doc.warnings.contains { $0.message.contains("dirty flag") })
        let header = try #require(doc.blocks.first { $0.kind == .documentHeader })
        if case .bool(let dirty)? = header.attributes["isDirty"]?.value { #expect(dirty) }
        else { Issue.record("isDirty not recorded") }
    }

    @Test("Bytes that are not an event log are reported, never guessed at")
    func nonEVTXIsReported() async throws {
        let doc = try await parse(Data(repeating: 0x41, count: 8192))
        #expect(doc.extractionStatus == .corrupt)
        #expect(records(doc).isEmpty)
        #expect(doc.warnings.contains { $0.code == "evtx.not_evtx" && $0.severity == .error })
    }

    @Test("A header with no records is empty and says why")
    func headerOnlyIsEmpty() async throws {
        let doc = try await parse(EVTXFixtureWriter().buildHeaderOnly())
        #expect(doc.extractionStatus == .empty)
        #expect(doc.warnings.contains { $0.message.contains("no readable record") })
    }

    @Test("An empty file is empty, not corrupt")
    func emptyIsEmpty() async throws {
        let doc = try await parse(Data())
        #expect(doc.extractionStatus == .empty)
        #expect(doc.warnings.contains { $0.code == "evtx.empty" })
    }

    @Test("A record with an impossible size stops that chunk instead of running away")
    func impossibleSizeIsRefused() async throws {
        // A corrupt size field must not be followed: an enormous value would read
        // past the chunk, and a tiny one would loop forever.
        var data = log
        // Corrupt the FIRST record's size to 0.
        let sizeOffset = 4096 + 512 + 4
        data.replaceSubrange(sizeOffset..<(sizeOffset + 4), with: Data([0, 0, 0, 0]))
        let doc = try await parse(data)      // must return at all
        #expect(doc.warnings.contains { $0.message.contains("impossible size") })
    }

    @Test("Parsing is deterministic")
    func deterministic() async throws {
        let first = try await parse(log).blocks.map(\.rawText)
        let second = try await parse(log).blocks.map(\.rawText)
        #expect(first == second)
    }

    // MARK: - Routing

    @Test("An .evtx file and a renamed one are both detected")
    func detection() {
        #expect(SourceType.detect(from: URL(fileURLWithPath: "/case/Security.evtx")) == .eventLog)
        // Renamed evidence is still found by its ElfFile signature.
        #expect(SourceType.sniffMagicBytes(log) == .eventLog)
        #expect(SourceType.eventLog.category == .hostArtifact)
    }

    @Test("The registry gives .eventLog a real immediate plugin")
    func registryOwnsIt() throws {
        let registry = try UniversalParserRegistryBuilder.standard(ocr: VisionOCR())
        let plugin = try registry.resolve(.eventLog)
        #expect(plugin.pluginID == "format.eventLog")
        #expect(plugin.executionMode == .immediate)
        #expect(plugin.capabilities.producesStructure)
        #expect(!(plugin is PreservedOnlyPlugin))
    }

    @Test("The published coverage matrix says PARTIAL, so marketing cannot say Supported")
    func coverageIsPartialInTheManifest() throws {
        // The generated matrix is what SUPPORTED_SOURCES.md and the advertising
        // rule read. It downgrades on OCR, and would otherwise have called EVTX
        // FULL purely because the plugin produces structure — which it does,
        // while leaving record content uninterpreted.
        let universal = try UniversalParserRegistryBuilder.standard(ocr: VisionOCR())
        let entry = try #require(
            ParserCapabilityManifest.generate(registry: universal)
                .first { $0.sourceType == SourceType.eventLog.rawValue })
        #expect(entry.coverage == .partial)
        #expect(entry.producesStructure)      // structure yes, interpretation no
        #expect(!entry.requiresOCR)           // partial for a DIFFERENT reason than images

        let structural = ParserCapabilityManifest.generate(
            registry: StructuralParserRegistry.standard(ocr: VisionOCR()))
        let legacy = try #require(
            structural.first { $0.sourceType == SourceType.eventLog.rawValue })
        #expect(legacy.coverage == .partial)
    }
}

private extension String {
    /// UTF-16LE bytes, NUL-terminated — the shape BinXML stores strings in.
    var utf16Bytes: [UInt8] {
        var out: [UInt8] = []
        for unit in Array(utf16) { out.append(UInt8(unit & 0xFF)); out.append(UInt8(unit >> 8)) }
        return out
    }
}
