//
//  PrefetchParserTests.swift
//  KalsmritikoshTests
//
//  HOST-6d — Windows Prefetch.
//
//  Prefetch is the only artifact in this lane that evidences EXECUTION, so two
//  tests carry the weight:
//
//   - `compressedFileIsRefusedNotHalfRead` — a Windows 10+ body needs an
//     LZXPRESS Huffman decoder that cannot be verified here. The file is still
//     reported (its existence means the program ran) but its run times are
//     NOT invented.
//   - `pathHashIsNotPresentedAsAPath` — prefetch records a HASH of the run
//     path, not the path. Two entries with one name and two hashes are the
//     same program run from different places; claiming a location would be a
//     fabrication.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Windows Prefetch (HOST-6d)")
struct PrefetchParserTests {

    private let parser = PrefetchStructuralParser()

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.date(from: iso)!
    }

    private func parse(_ data: Data, as filename: String = "POWERSHELL.EXE-A1B2C3D4.pf")
    async throws -> ParsedDocument {
        try await parser.parse(data: data, filename: filename, type: .prefetch,
                               logicalSourceID: UUID(), sourceVersionID: UUID())
    }
    private func text(_ doc: ParsedDocument) -> String {
        doc.blocks.map(\.rawText).joined(separator: "\n")
    }
    private func stringAttribute(_ b: EvidenceBlock, _ k: String) -> String? {
        if case .string(let v) = b.attributes[k]?.value { return v }
        return nil
    }

    // MARK: - Fidelity across the uncompressed generations

    @Test("All three uncompressed versions decode name, hash, count and times")
    func everyUncompressedVersionDecodes() throws {
        for version in [PrefetchReader.Version.winXP, .winVista7, .win8] {
            var writer = PrefetchFixtureWriter()
            writer.version = version
            writer.runCount = 7
            writer.runTimes = [date("2026-03-12T09:26:53Z")]
            let reader = try PrefetchReader(data: writer.build())
            #expect(reader.version == version, "\(version) version tag")
            #expect(reader.executableName == "POWERSHELL.EXE", "\(version) name")
            #expect(reader.pathHash == 0x1A2B_3C4D, "\(version) path hash")
            #expect(reader.runCount == 7, "\(version) run count")
            #expect(reader.runTimes.first == date("2026-03-12T09:26:53Z"), "\(version) run time")
        }
    }

    @Test("A Windows 8 file yields an execution HISTORY, not one point")
    func winEightKeepsEightRuns() async throws {
        var writer = PrefetchFixtureWriter()
        writer.version = .win8
        writer.runCount = 3
        writer.runTimes = [date("2026-03-12T09:00:00Z"),
                           date("2026-03-11T08:00:00Z"),
                           date("2026-03-10T07:00:00Z")]
        let doc = try await parse(writer.build())
        let runs = doc.blocks.filter { stringAttribute($0, "runOrdinal") != nil
                                       || $0.attributes["runOrdinal"] != nil }
        #expect(runs.count == 3)
        #expect(text(doc).contains("Most recent run"))
        #expect(text(doc).contains("execution HISTORY"))
    }

    @Test("Unused run slots are padding, not runs dated to 1601")
    func unusedSlotsAreNotRuns() throws {
        // A v26 file with three runs zeroes the other five. Reading those as
        // FILETIME 0 would put five executions in the year 1601.
        var writer = PrefetchFixtureWriter()
        writer.version = .win8
        writer.runTimes = [date("2026-03-12T09:00:00Z"), date("2026-03-11T08:00:00Z")]
        let reader = try PrefetchReader(data: writer.build())
        #expect(reader.runTimes.count == 2)
        #expect(!reader.runTimes.contains { $0.timeIntervalSince1970 < 0 })
    }

    @Test("Execution is stated as execution — the word Amcache may not use")
    func executionIsStated() async throws {
        var writer = PrefetchFixtureWriter()
        writer.runCount = 12
        writer.runTimes = [date("2026-03-12T02:14:07Z")]
        let doc = try await parse(writer.build())
        let header = try #require(doc.blocks.first { $0.kind == .documentHeader })
        #expect(header.rawText.contains("was RUN"))
        #expect(header.rawText.contains("12 time(s)"))
        #expect(stringAttribute(header, "evidenceOf") == "program-execution")
    }

    // MARK: - THE two refusals

    @Test("A compressed Windows 10 file is refused, not half-read")
    func compressedFileIsRefusedNotHalfRead() async throws {
        let doc = try await parse(PrefetchFixtureWriter.compressed(uncompressedSize: 9_001))
        // Still evidence: the file existing means Windows saw a program run.
        #expect(doc.extractionStatus == .partial)
        #expect(text(doc).contains("COMPRESSED"))
        #expect(text(doc).contains("9001 bytes"))
        // But no run time or count is invented.
        #expect(!doc.blocks.contains { $0.attributes["runOrdinal"] != nil })
        #expect(doc.warnings.contains { $0.code == "prefetch.compressed" })
        let limitation = try #require(doc.blocks.first {
            stringAttribute($0, "limitation") == "lzxpress-huffman-not-decompressed"
        })
        #expect(limitation.rawText.contains("shared misunderstanding"))
    }

    @Test("The path HASH is never presented as a path")
    func pathHashIsNotPresentedAsAPath() async throws {
        // Two entries with the same name and different hashes are the same
        // program run from different locations. Naming a location would be a
        // fabrication, so the caveat is in the evidence.
        var writer = PrefetchFixtureWriter()
        writer.runTimes = [date("2026-03-12T09:00:00Z")]
        let doc = try await parse(writer.build())
        let caveat = try #require(doc.blocks.first { stringAttribute($0, "pathHash") != nil })
        #expect(stringAttribute(caveat, "pathHash") == "1A2B3C4D")
        #expect(caveat.rawText.contains("not the path itself"))
        #expect(caveat.rawText.contains("DIFFERENT locations"))
        // No invented drive or directory anywhere.
        let body = text(doc).lowercased()
        for invented in ["c:\\", "system32", "\\windows\\"] {
            #expect(!body.contains(invented), "the parser invented a path: \(invented)")
        }
    }

    // MARK: - Honest states

    @Test("An unsupported version is named, not decoded at guessed offsets")
    func unsupportedVersionIsNamed() async throws {
        var bytes = [UInt8](PrefetchFixtureWriter().build())
        bytes[0] = 99      // a version this reader has never checked
        let doc = try await parse(Data(bytes))
        #expect(doc.extractionStatus == .partial)
        #expect(doc.warnings.contains { $0.code == "prefetch.unsupported_version" })
        #expect(!doc.blocks.contains { $0.attributes["runOrdinal"] != nil })
    }

    @Test("Bytes that are not prefetch are reported, never guessed at")
    func junkIsRefused() async throws {
        let junk = Data((0..<512).map { UInt8(($0 * 31 + 17) % 251) })
        let doc = try await parse(junk)
        #expect(doc.extractionStatus == .corrupt)
        #expect(doc.warnings.contains { $0.code == "prefetch.not_prefetch" })
    }

    @Test("An empty file is empty, not corrupt")
    func emptyIsEmpty() async throws {
        let doc = try await parse(Data())
        #expect(doc.extractionStatus == .empty)
        #expect(doc.blocks.isEmpty)
    }

    @Test("Parsing is deterministic")
    func deterministic() async throws {
        var writer = PrefetchFixtureWriter()
        writer.runTimes = [date("2026-03-12T09:00:00Z")]
        let data = writer.build()
        #expect(text(try await parse(data)) == text(try await parse(data)))
    }

    // MARK: - Routing

    @Test("A .pf is detected by extension, and a renamed one by signature")
    func detection() {
        #expect(SourceType.detect(from: URL(fileURLWithPath:
            "/case/Windows/Prefetch/POWERSHELL.EXE-A1B2C3D4.pf")) == .prefetch)
        var writer = PrefetchFixtureWriter()
        writer.runTimes = [Date()]
        #expect(SourceType.sniffMagicBytes(writer.build()) == .prefetch)
        // The compressed container is recognised too.
        #expect(SourceType.sniffMagicBytes(PrefetchFixtureWriter.compressed()) == .prefetch)
        #expect(SourceType.prefetch.category == .hostArtifact)
    }

    @Test("The registry gives .prefetch a real immediate plugin")
    @MainActor
    func registryOwnsIt() throws {
        let registry = try UniversalParserRegistryBuilder.standard(ocr: VisionOCR())
        let plugin = try registry.resolve(.prefetch)
        #expect(plugin.pluginID == "format.prefetch")
        #expect(plugin.executionMode == .immediate)
        #expect(plugin.capabilities.producesStructure)
        #expect(!(plugin is PreservedOnlyPlugin))
    }
}
