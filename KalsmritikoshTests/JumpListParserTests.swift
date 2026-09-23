//
//  JumpListParserTests.swift
//  KalsmritikoshTests
//
//  HOST-6b — Windows jump lists.
//
//  This unit composes two already-verified readers (MS-CFB and shell link), so
//  the tests here are about the COMPOSITION and about the two things the jump
//  list must not overclaim:
//
//   - `applicationIsNeverNamed` — the app is identified only by an AppID, and
//     translating it needs a community lookup table. Naming the wrong
//     application would attribute files to software that was never run.
//   - `destListIsNotDecoded` — the MRU order and access counts live at
//     community-derived, version-dependent offsets. A mis-read offset would
//     report a wrong access count as though it had been read.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Windows jump lists (HOST-6b)")
struct JumpListParserTests {

    private let parser = JumpListStructuralParser()

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.date(from: iso)!
    }

    private func parse(_ data: Data, as filename: String = "5f7b5f1e01b83767.automaticDestinations-ms")
    async throws -> ParsedDocument {
        try await parser.parse(data: data, filename: filename, type: .jumpList,
                               logicalSourceID: UUID(), sourceVersionID: UUID())
    }

    private func text(_ doc: ParsedDocument) -> String {
        doc.blocks.map(\.rawText).joined(separator: "\n")
    }
    private func stringAttribute(_ block: EvidenceBlock, _ key: String) -> String? {
        if case .string(let value) = block.attributes[key]?.value { return value }
        return nil
    }

    /// One shell link, as a jump-list stream would hold it.
    private func link(path: String, suffix: String, removable: Bool = false) -> Data {
        var writer = ShellLinkFixtureWriter()
        writer.localBasePath = path
        writer.commonPathSuffix = suffix
        writer.targetWritten = date("2026-03-11T17:02:10Z")
        writer.targetAccessed = date("2026-03-12T09:26:53Z")
        writer.targetSizeBytes = 248_512
        writer.volume = .init(driveType: removable ? 2 : 3,
                              serialNumber: 0xA4B2_11C7, label: removable ? "FIELDKIT" : "OS")
        writer.tracker = .init(machineID: "FORENSIC-WS7",
                               macAddress: [0x00, 0x1B, 0x44, 0x11, 0x3A, 0xB7])
        return writer.build()
    }

    /// An automatic jump list: an MS-CFB container of link streams plus DestList.
    private func automaticJumpList() -> Data {
        CFBFixtureWriter().build([
            .stream("1", link(path: #"C:\cases\"#, suffix: "statement.docx")),
            .stream("2", link(path: #"E:\exfil\"#, suffix: "clients.xlsx", removable: true)),
            // The MRU stream, deliberately left uninterpreted.
            .stream("DestList", Data(repeating: 0xAB, count: 256))
        ])
    }

    // MARK: - Composition

    @Test("Every target in an automatic jump list comes back fully parsed")
    func automaticListTargetsAreParsed() async throws {
        let doc = try await parse(automaticJumpList())
        let targets = doc.blocks.filter {
            stringAttribute($0, "evidenceOf") == "file-opened-with-application"
        }
        #expect(targets.count == 2)
        let paths = targets.compactMap { stringAttribute($0, "targetPath") }
        #expect(paths.contains(#"C:\cases\statement.docx"#))
        #expect(paths.contains(#"E:\exfil\clients.xlsx"#))
        // The volume facts HOST-6a recovers ride through unchanged, including
        // the one that matters most.
        #expect(text(doc).contains("REMOVABLE"))
        #expect(text(doc).contains("FIELDKIT"))
        #expect(text(doc).contains("A4B211C7"))
    }

    @Test("A custom-destinations list is a plain sequence of links, not a container")
    func customDestinationsAreScanned() async throws {
        // Not MS-CFB at all: links laid end to end behind a header.
        var data = Data(repeating: 0x00, count: 32)      // a header this parser skips over
        data += link(path: #"C:\cases\"#, suffix: "brief.pdf")
        data += link(path: #"C:\cases\"#, suffix: "exhibit-4.jpg")
        let doc = try await parse(data, as: "1b4dd67f29cb1962.customDestinations-ms")
        let targets = doc.blocks.filter {
            stringAttribute($0, "evidenceOf") == "file-opened-with-application"
        }
        #expect(targets.count == 2)
        #expect(text(doc).contains("brief.pdf"))
        #expect(text(doc).contains("exhibit-4.jpg"))
        #expect(text(doc).contains("custom destinations"))
    }

    @Test("Embedded links are located by their full 20-byte signature")
    func embeddedLinkScanIsSpecific() {
        let one = link(path: #"C:\a\"#, suffix: "b.txt")
        var stream = Data(repeating: 0x4C, count: 16)    // 0x4C bytes alone are not a link
        stream += one
        stream += Data([0x4C, 0x00, 0x00, 0x00])         // a header size with no class id
        let found = JumpListStructuralParser.embeddedShellLinks(in: stream)
        #expect(found.count == 1)
        #expect((try? ShellLinkReader(data: found[0]))?.targetPath == #"C:\a\b.txt"#)
    }

    // MARK: - THE two things not claimed

    @Test("The application is NEVER named — only its AppID is reported")
    func applicationIsNeverNamed() async throws {
        let doc = try await parse(automaticJumpList())
        #expect(JumpListStructuralParser.appID(
            fromFilename: "5f7b5f1e01b83767.automaticDestinations-ms") == "5f7b5f1e01b83767")
        let header = try #require(doc.blocks.first { $0.kind == .documentHeader })
        #expect(stringAttribute(header, "applicationID") == "5f7b5f1e01b83767")

        let disclosure = try #require(doc.blocks.first {
            stringAttribute($0, "limitation") == "appid-not-resolved-to-application"
        })
        #expect(disclosure.rawText.contains("NO application is named"))
        #expect(disclosure.rawText.contains("community-maintained lookup table"))

        // No product name is invented anywhere, however well known.
        let body = text(doc).lowercased()
        for product in ["word", "excel", "acrobat", "notepad", "explorer", "chrome"] {
            #expect(!body.contains(product), "the parser named an application: \(product)")
        }
    }

    @Test("The DestList stream is reported as present and NOT decoded")
    func destListIsNotDecoded() async throws {
        let doc = try await parse(automaticJumpList())
        #expect(doc.warnings.contains { $0.code == "jumplist.destlist_not_decoded" })
        let warning = try #require(doc.warnings.first { $0.code == "jumplist.destlist_not_decoded" })
        #expect(warning.message.contains("community-derived"))
        #expect(warning.message.contains("256-byte"))
        // And no access count or MRU position is asserted.
        let body = text(doc).lowercased()
        for phrase in ["access count", "opened 3 times", "most recently used position"] {
            #expect(!body.contains(phrase))
        }
        // The DestList stream is not mistaken for a target either.
        #expect(!doc.blocks.contains { stringAttribute($0, "stream") == "DestList" })
    }

    @Test("Target timestamps keep the HOST-6a disclaimer in every block")
    func timestampsKeepTheirDisclaimer() async throws {
        let doc = try await parse(automaticJumpList())
        let times = doc.blocks.filter { stringAttribute($0, "describes") == "target-file" }
        #expect(times.count == 4)      // two times × two targets
        for block in times {
            #expect(block.rawText.contains("TARGET FILE"))
            #expect(block.rawText.contains("NOT the time the file was opened"))
        }
    }

    @Test("The creating machine is reported per entry")
    func trackerIsReported() async throws {
        let doc = try await parse(automaticJumpList())
        let tracker = try #require(doc.blocks.first { stringAttribute($0, "machineID") != nil })
        #expect(stringAttribute(tracker, "machineID") == "FORENSIC-WS7")
        #expect(stringAttribute(tracker, "macAddress") == "00:1b:44:11:3a:b7")
    }

    // MARK: - Honest states

    @Test("A jump list with only a DestList and no links yields no invented targets")
    func destListOnlyIsEmpty() async throws {
        let data = CFBFixtureWriter().build([
            .stream("DestList", Data(repeating: 0xAB, count: 128))
        ])
        let doc = try await parse(data)
        #expect(doc.extractionStatus == .empty)
        #expect(doc.warnings.contains { $0.code == "jumplist.no_links" })
    }

    @Test("A stream that is not a shell link is counted, not reported as a target")
    func unreadableStreamsAreCounted() async throws {
        let data = CFBFixtureWriter().build([
            .stream("1", link(path: #"C:\cases\"#, suffix: "ok.docx")),
            .stream("2", Data(repeating: 0x5A, count: 200))
        ])
        let doc = try await parse(data)
        let targets = doc.blocks.filter {
            stringAttribute($0, "evidenceOf") == "file-opened-with-application"
        }
        #expect(targets.count == 1)
        #expect(doc.warnings.contains { $0.code == "jumplist.partial" })
    }

    @Test("Bytes that are neither a container nor a link sequence are refused")
    func junkIsRefused() async throws {
        let junk = Data((0..<2048).map { UInt8(($0 * 31 + 17) % 251) })
        let doc = try await parse(junk)
        #expect(doc.extractionStatus == .corrupt)
        #expect(doc.warnings.contains { $0.code == "jumplist.not_a_jumplist" })
    }

    @Test("An empty file is empty, not corrupt")
    func emptyIsEmpty() async throws {
        let doc = try await parse(Data())
        #expect(doc.extractionStatus == .empty)
        #expect(doc.blocks.isEmpty)
    }

    @Test("A filename that is not an AppID does not produce a fake one")
    func nonHexFilenameYieldsNoAppID() {
        #expect(JumpListStructuralParser.appID(fromFilename: "recent.automaticDestinations-ms") == nil)
        #expect(JumpListStructuralParser.appID(fromFilename: "5f7b.automaticDestinations-ms") == nil)
        #expect(JumpListStructuralParser.appID(fromFilename: "5f7b5f1e01b83767.customDestinations-ms")
                == "5f7b5f1e01b83767")
    }

    @Test("Parsing is deterministic")
    func deterministic() async throws {
        let data = automaticJumpList()
        #expect(text(try await parse(data)) == text(try await parse(data)))
    }

    // MARK: - Routing

    @Test("Both jump-list extensions are detected")
    func detection() {
        #expect(SourceType.detect(from: URL(fileURLWithPath:
            "/u/Recent/AutomaticDestinations/5f7b5f1e01b83767.automaticDestinations-ms")) == .jumpList)
        #expect(SourceType.detect(from: URL(fileURLWithPath:
            "/u/Recent/CustomDestinations/1b4dd67f29cb1962.customDestinations-ms")) == .jumpList)
        #expect(SourceType.jumpList.category == .hostArtifact)
    }

    @Test("A jump list is NOT swallowed by the generic MS-CFB document lane")
    func jumpListBeatsTheOLE2DocumentLane() {
        // An automatic jump list has the same container magic as a .doc. If the
        // extension did not win, it would parse as a Word document and yield
        // nothing.
        #expect(SourceType.sniffMagicBytes(automaticJumpList()) != .jumpList)
        #expect(SourceType.detect(from: URL(fileURLWithPath: "/x/abc123def4567890.automaticDestinations-ms"))
                == .jumpList)
    }

    @Test("The registry gives .jumpList a real immediate plugin")
    @MainActor
    func registryOwnsIt() throws {
        let registry = try UniversalParserRegistryBuilder.standard(ocr: VisionOCR())
        let plugin = try registry.resolve(.jumpList)
        #expect(plugin.pluginID == "format.jumpList")
        #expect(plugin.executionMode == .immediate)
        #expect(plugin.capabilities.producesStructure)
        #expect(!(plugin is PreservedOnlyPlugin))
    }
}
