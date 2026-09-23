//
//  ShellLinkParserTests.swift
//  KalsmritikoshTests
//
//  HOST-6a — Windows shortcuts.
//
//  Two tests here protect an investigation from a confident wrong answer, and
//  the rest are fidelity:
//
//   - `timestampsAreLabelledAsTheTargets` — a shortcut's three FILETIMEs belong
//     to the TARGET FILE, not to the use of the shortcut. Quoted as "accessed at
//     09:26" they would assert an access this file never recorded.
//   - `macAddressOnlyFromAVersion1UUID` — the droid's node bytes are a real MAC
//     address only for a version-1 unicast UUID. Reporting a version-4 UUID's
//     random bytes would manufacture a hardware identifier that an
//     investigation could attribute to a person.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Windows shortcuts (HOST-6a)")
struct ShellLinkParserTests {

    private let parser = ShellLinkStructuralParser()

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.date(from: iso)!
    }

    private func parse(_ data: Data, as filename: String = "report.lnk")
    async throws -> ParsedDocument {
        try await parser.parse(data: data, filename: filename, type: .shellLink,
                               logicalSourceID: UUID(), sourceVersionID: UUID())
    }

    private func text(_ doc: ParsedDocument) -> String {
        doc.blocks.map(\.rawText).joined(separator: "\n")
    }
    private func stringAttribute(_ block: EvidenceBlock, _ key: String) -> String? {
        if case .string(let value) = block.attributes[key]?.value { return value }
        return nil
    }

    /// A shortcut to a document on a USB stick — the case this format exists for.
    private func usbShortcut() -> Data {
        var writer = ShellLinkFixtureWriter()
        writer.targetCreated = date("2026-03-10T08:15:00Z")
        writer.targetAccessed = date("2026-03-12T09:26:53Z")
        writer.targetWritten = date("2026-03-11T17:02:10Z")
        writer.targetSizeBytes = 248_512
        writer.localBasePath = #"E:\cases\2026-CR-114\"#
        writer.commonPathSuffix = "statement.docx"
        writer.volume = .init(driveType: 2, serialNumber: 0xA4B2_11C7, label: "FIELDKIT")
        writer.relativePath = #"..\..\cases\2026-CR-114\statement.docx"#
        writer.workingDirectory = #"E:\cases\2026-CR-114"#
        writer.tracker = .init(machineID: "FORENSIC-WS7",
                               macAddress: [0x00, 0x1B, 0x44, 0x11, 0x3A, 0xB7])
        return writer.build()
    }

    // MARK: - Fidelity

    @Test("Every field of a shortcut is decoded exactly")
    func fieldsAreExact() throws {
        let link = try ShellLinkReader(data: usbShortcut())
        #expect(link.localBasePath == #"E:\cases\2026-CR-114\"#)
        #expect(link.commonPathSuffix == "statement.docx")
        #expect(link.targetPath == #"E:\cases\2026-CR-114\statement.docx"#)
        #expect(link.targetSizeBytes == 248_512)
        #expect(link.targetCreated == date("2026-03-10T08:15:00Z"))
        #expect(link.targetAccessed == date("2026-03-12T09:26:53Z"))
        #expect(link.targetWritten == date("2026-03-11T17:02:10Z"))
        #expect(link.relativePath == #"..\..\cases\2026-CR-114\statement.docx"#)
        #expect(link.workingDirectory == #"E:\cases\2026-CR-114"#)
        #expect(!link.targetIsDirectory)
    }

    @Test("The volume's drive type, serial and label identify the DEVICE")
    func volumeIsDecoded() async throws {
        let volume = try #require(try ShellLinkReader(data: usbShortcut()).volume)
        #expect(volume.driveType == .removable)
        #expect(volume.serialNumber == 0xA4B2_11C7)
        #expect(volume.label == "FIELDKIT")

        // And it reaches the evidence in the words that matter: a removable
        // volume is the finding, not a detail.
        let body = text(try await parse(usbShortcut()))
        #expect(body.contains("REMOVABLE"))
        #expect(body.contains("A4B211C7"))
        #expect(body.contains("FIELDKIT"))
        #expect(body.contains("NOT on this machine's own disk"))
    }

    // MARK: - THE timestamp misreading

    @Test("The three timestamps are labelled as the TARGET's, never as an access")
    func timestampsAreLabelledAsTheTargets() async throws {
        let doc = try await parse(usbShortcut())
        let times = doc.blocks.filter { stringAttribute($0, "describes") == "target-file" }
        #expect(times.count == 3)
        for block in times {
            // Each one has to carry the disclaimer itself: a retrieved answer
            // quotes a BLOCK, not the whole document, so a caveat elsewhere in
            // the file would not travel with it.
            #expect(block.rawText.contains("TARGET FILE"))
            #expect(block.rawText.contains("NOT the time the shortcut was used"))
        }
        // And nothing anywhere claims the shortcut itself was used at a time.
        let body = text(doc).lowercased()
        #expect(!body.contains("shortcut was opened at"))
        #expect(!body.contains("shortcut was used at"))
    }

    @Test("A shortcut with no target timestamps says so rather than dating it 1601")
    func zeroTimestampsAreNotDates() async throws {
        var writer = ShellLinkFixtureWriter()
        writer.localBasePath = #"C:\temp\x.txt"#
        let doc = try await parse(writer.build())
        let link = try ShellLinkReader(data: writer.build())
        #expect(link.targetCreated == nil)
        #expect(link.targetAccessed == nil)
        #expect(link.targetWritten == nil)
        #expect(text(doc).contains("records no timestamps"))
        #expect(!text(doc).contains("1601"))
    }

    // MARK: - THE manufactured-identifier refusal

    @Test("A MAC address is reported ONLY from a version-1 unicast UUID")
    func macAddressOnlyFromAVersion1UUID() throws {
        // Version 1: the node field IS the creating machine's adapter address.
        var v1 = ShellLinkFixtureWriter()
        v1.localBasePath = #"C:\x"#
        v1.tracker = .init(machineID: "WS7", macAddress: [0x00, 0x1B, 0x44, 0x11, 0x3A, 0xB7])
        #expect(try ShellLinkReader(data: v1.build()).tracker?.macAddress == "00:1b:44:11:3a:b7")

        // Version 4: the same bytes are random. Reporting them as a MAC address
        // would invent a hardware identifier.
        var v4 = v1
        v4.tracker = .init(machineID: "WS7", macAddress: [0x00, 0x1B, 0x44, 0x11, 0x3A, 0xB7],
                           useVersion4: true)
        let fromV4 = try ShellLinkReader(data: v4.build()).tracker
        #expect(fromV4?.machineID == "WS7")       // the machine name is still real
        #expect(fromV4?.macAddress == nil)

        // Multicast bit set: the standard's own marker for "this node is not a
        // real address".
        var multicast = v1
        multicast.tracker = .init(machineID: "WS7",
                                  macAddress: [0x02, 0x1B, 0x44, 0x11, 0x3A, 0xB7],
                                  multicastNode: true)
        #expect(try ShellLinkReader(data: multicast.build()).tracker?.macAddress == nil)
    }

    @Test("The tracker names the machine that MADE the shortcut")
    func trackerNamesTheCreatingMachine() async throws {
        // Not the machine it was found on — a shortcut travels with a profile,
        // and conflating the two would place a person at the wrong computer.
        let doc = try await parse(usbShortcut())
        let tracker = try #require(doc.blocks.first { stringAttribute($0, "machineID") != nil })
        #expect(stringAttribute(tracker, "machineID") == "FORENSIC-WS7")
        #expect(tracker.rawText.contains("not necessarily the machine it was found on"))
    }

    // MARK: - Other shapes

    @Test("A network share shortcut records the share, not a volume")
    func networkShortcut() async throws {
        var writer = ShellLinkFixtureWriter()
        writer.networkPath = #"\\FILESERVER\cases"#
        writer.commonPathSuffix = #"2026\brief.pdf"#
        writer.targetWritten = date("2026-03-12T09:00:00Z")
        let link = try ShellLinkReader(data: writer.build())
        #expect(link.networkPath == #"\\FILESERVER\cases"#)
        #expect(link.targetPath == #"\\FILESERVER\cases\2026\brief.pdf"#)
        #expect(link.volume == nil)
        #expect(text(try await parse(writer.build())).contains("network share"))
    }

    @Test("Command-line arguments are recorded — they are how a program was invoked")
    func argumentsAreRecorded() async throws {
        var writer = ShellLinkFixtureWriter()
        writer.localBasePath = #"C:\Windows\System32\cmd.exe"#
        writer.arguments = #"/c powershell -enc SQBFAFgA"#
        let doc = try await parse(writer.build(), as: "run.lnk")
        #expect(text(doc).contains(#"/c powershell -enc SQBFAFgA"#))
        // And it is stated flatly, with no judgement attached.
        let body = text(doc).lowercased()
        for word in ["suspicious", "malicious", "obfuscated", "attack"] {
            #expect(!body.contains(word))
        }
    }

    @Test("ANSI string fields are read when the unicode flag is absent")
    func ansiStrings() throws {
        var writer = ShellLinkFixtureWriter()
        writer.unicodeStrings = false
        writer.localBasePath = #"C:\x.txt"#
        writer.relativePath = #"..\x.txt"#
        writer.name = "an old shortcut"
        let link = try ShellLinkReader(data: writer.build())
        #expect(link.name == "an old shortcut")
        #expect(link.relativePath == #"..\x.txt"#)
    }

    @Test("A shell-item id list is skipped by its declared size, and disclosed")
    func idListIsSkippedNotDecoded() async throws {
        // The fields AFTER the id list must still land: skipping by the wrong
        // amount would shift every later offset and silently mis-report paths.
        var writer = ShellLinkFixtureWriter()
        writer.targetIDListBytes = 137
        writer.localBasePath = #"C:\cases\brief.pdf"#
        writer.relativePath = #"..\brief.pdf"#
        writer.tracker = .init(machineID: "WS7", macAddress: nil)
        let link = try ShellLinkReader(data: writer.build())
        #expect(link.targetIDListSize == 137)
        #expect(link.localBasePath == #"C:\cases\brief.pdf"#)
        #expect(link.relativePath == #"..\brief.pdf"#)
        #expect(link.tracker?.machineID == "WS7")

        let doc = try await parse(writer.build())
        #expect(doc.warnings.contains { $0.code == "lnk.idlist_not_decoded" })
        #expect(doc.extractionStatus == .complete)
    }

    @Test("A folder target is reported as a folder")
    func folderTarget() throws {
        var writer = ShellLinkFixtureWriter()
        writer.targetIsDirectory = true
        writer.localBasePath = #"D:\exfil"#
        #expect(try ShellLinkReader(data: writer.build()).targetIsDirectory)
    }

    @Test("A shortcut whose target path was never recorded says that plainly")
    func noPathRecorded() async throws {
        var writer = ShellLinkFixtureWriter()
        writer.targetWritten = date("2026-03-12T09:00:00Z")
        let doc = try await parse(writer.build())
        #expect(text(doc).contains("target's path was not recorded"))
        // A time on its own is still substance, so this is not a failed parse.
        #expect(doc.extractionStatus == .complete)
    }

    // MARK: - Honest states

    @Test("Bytes that are not a shortcut are reported, never guessed at")
    func junkIsRefused() async throws {
        let junk = Data((0..<600).map { UInt8(($0 * 31 + 17) % 251) })
        let doc = try await parse(junk)
        #expect(doc.extractionStatus == .corrupt)
        #expect(doc.warnings.contains { $0.code == "lnk.not_lnk" })
    }

    @Test("A file with the right header size but the wrong class id is refused")
    func wrongCLSIDIsRefused() async throws {
        // 0x4C at offset 0 is not rare in binary data; the class id is what
        // actually identifies the format.
        var bytes = [UInt8](repeating: 0, count: 0x4C)
        bytes[0] = 0x4C
        bytes[4] = 0x02        // not the shell link CLSID
        let doc = try await parse(Data(bytes))
        #expect(doc.extractionStatus == .corrupt)
    }

    @Test("An empty file is empty, not corrupt")
    func emptyIsEmpty() async throws {
        let doc = try await parse(Data())
        #expect(doc.extractionStatus == .empty)
        #expect(doc.blocks.isEmpty)
    }

    @Test("A shortcut truncated mid-header is reported as truncated")
    func truncatedHeader() async throws {
        let full = usbShortcut()
        let doc = try await parse(full.prefix(40))
        #expect(doc.extractionStatus == .corrupt)
        #expect(doc.warnings.contains { $0.code == "lnk.truncated" })
    }

    @Test("A shortcut cut off after its header yields the header's facts")
    func truncatedAfterHeader() async throws {
        // Real extractions contain partial files. What survived is still
        // evidence, and the header alone carries the target's times and size.
        let doc = try await parse(usbShortcut().prefix(0x4C))
        #expect(doc.extractionStatus == .complete)
        #expect(text(doc).contains("2026-03-12T09:26:53Z"))
        #expect(text(doc).contains("target's path was not recorded"))
    }

    @Test("A declared id list that does not fit is refused, not read past")
    func overlongIDListIsRefused() async throws {
        var writer = ShellLinkFixtureWriter()
        writer.targetIDListBytes = 40
        writer.localBasePath = #"C:\x"#
        var bytes = [UInt8](writer.build())
        // Claim a list far larger than the file.
        bytes[0x4C] = 0xFF; bytes[0x4D] = 0x7F
        let doc = try await parse(Data(bytes))
        #expect(doc.warnings.contains { $0.message.contains("does not fit in the file") })
        // The header's facts survive; nothing beyond the bad length is invented.
        #expect(doc.extractionStatus != .corrupt)
    }

    @Test("Parsing is deterministic")
    func deterministic() async throws {
        let data = usbShortcut()
        #expect(text(try await parse(data)) == text(try await parse(data)))
    }

    // MARK: - Routing

    @Test("A .lnk is detected by extension and by signature when renamed")
    func detection() {
        #expect(SourceType.detect(from: URL(fileURLWithPath: "/u/Recent/report.lnk")) == .shellLink)
        #expect(SourceType.sniffMagicBytes(usbShortcut()) == .shellLink)
        #expect(SourceType.shellLink.category == .hostArtifact)
    }

    @Test("The registry gives .shellLink a real immediate plugin")
    @MainActor
    func registryOwnsIt() throws {
        let registry = try UniversalParserRegistryBuilder.standard(ocr: VisionOCR())
        let plugin = try registry.resolve(.shellLink)
        #expect(plugin.pluginID == "format.shellLink")
        #expect(plugin.executionMode == .immediate)
        #expect(plugin.capabilities.producesStructure)
        #expect(!(plugin is PreservedOnlyPlugin))
    }

    @Test("The loader's text carries the timestamp disclaimer too")
    @MainActor
    func loaderKeepsTheDisclaimer() async throws {
        // The searchable surface must not be able to say something the citable
        // blocks refuse to.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lnk-\(UUID().uuidString).lnk")
        try usbShortcut().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let object = try await ShellLinkLoader().ingest(fileAt: url, type: .shellLink)
        #expect(object.content.contains("NOT the time the shortcut was used"))
        #expect(object.content.contains("REMOVABLE"))
        #expect(object.confidence == .high)
    }
}
