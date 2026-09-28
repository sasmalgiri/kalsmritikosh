//
//  AmcacheParserTests.swift
//  KalsmritikoshTests
//
//  HOST-6c — Amcache.
//
//  The load-bearing test is `presenceIsNotExecution`. Amcache is routinely read
//  as a list of "programs that ran", and it is not one: Windows populates the
//  inventory from a scheduled filesystem walk. An answer that turned an entry
//  into "they executed this" would be a confident wrong conclusion, so the
//  distinction has to be in the evidence and not only in a comment.
//
//  The second is `sha1OnlyFromARealDigest`: a hash that is reported can be
//  matched against a hash set, so a value that is not a 40-character digest must
//  never be labelled SHA-1.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Windows Amcache (HOST-6c)")
struct AmcacheParserTests {

    private let parser = AmcacheStructuralParser()
    private typealias Key = RegistryHiveFixtureWriter.Key
    private typealias Val = RegistryHiveFixtureWriter.Val

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.date(from: iso)!
    }

    /// A hive shaped like a real Amcache: Root → InventoryApplicationFile →
    /// one key per executable, and InventoryApplication → one per program.
    private func amcacheHive() -> Data {
        let sevenZip = Key(
            "7z.exe|8f4e2c1a", lastWritten: date("2026-03-12T09:26:53Z"),
            values: [
                .sz("LowerCaseLongPath", #"c:\program files\7-zip\7z.exe"#),
                .sz("Name", "7z.exe"),
                .sz("Publisher", "Igor Pavlov"),
                .sz("ProductName", "7-Zip"),
                .sz("Version", "23.01"),
                .sz("FileId", "0000da39a3ee5e6b4b0d3255bfef95601890afd80709"),
                .dword("Size", 583_048),
                .sz("LinkDate", "06/20/2023 18:04:11"),
                .sz("ProgramId", "0006f1c2b3a4"),
                .sz("BinaryType", "pe64_amd64"),
                .dword("IsOsComponent", 0)
            ])
        let tool = Key(
            "nc.exe|11aa22bb", lastWritten: date("2026-03-12T02:14:07Z"),
            values: [
                .sz("LowerCaseLongPath", #"e:\tools\nc.exe"#),
                .sz("Name", "nc.exe"),
                .sz("FileId", "0000b7e23ec29af22b0b4e41da31e868d57226121c84"),
                .dword("Size", 38_616)
            ])
        let program = Key(
            "0006f1c2b3a4", lastWritten: date("2026-02-01T10:00:00Z"),
            values: [
                .sz("Name", "7-Zip 23.01 (x64)"),
                .sz("Publisher", "Igor Pavlov"),
                .sz("Version", "23.01"),
                .sz("InstallDate", "02/01/2026 10:00:00"),
                .sz("RootDirPath", #"c:\program files\7-zip"#),
                .sz("Source", "Msi")
            ])

        let writer = RegistryHiveFixtureWriter()
        return writer.build(root: Key("Root", children: [
            Key("InventoryApplicationFile", children: [sevenZip, tool]),
            Key("InventoryApplication", children: [program])
        ]))
    }

    private func parse(_ data: Data, as filename: String = "Amcache.hve")
    async throws -> ParsedDocument {
        try await parser.parse(data: data, filename: filename, type: .amcache,
                               logicalSourceID: UUID(), sourceVersionID: UUID())
    }

    private func text(_ doc: ParsedDocument) -> String {
        doc.blocks.map(\.rawText).joined(separator: "\n")
    }
    private func stringAttribute(_ block: EvidenceBlock, _ key: String) -> String? {
        if case .string(let value) = block.attributes[key]?.value { return value }
        return nil
    }

    // MARK: - THE misconception

    @Test("An Amcache entry is evidence of PRESENCE, never of execution")
    func presenceIsNotExecution() async throws {
        let doc = try await parse(amcacheHive())

        let disclosure = try #require(doc.blocks.first {
            stringAttribute($0, "limitation") == "presence-not-execution"
        })
        #expect(disclosure.rawText.contains("NOT evidence that the program was EXECUTED"))
        #expect(disclosure.rawText.contains("scheduled task"))

        // Every entry block carries the claim it IS making, because a retrieved
        // answer quotes a block and the document-level caveat would not travel
        // with it.
        let entries = doc.blocks.filter { stringAttribute($0, "evidenceOf") == "file-presence" }
        #expect(entries.count == 2)
        for entry in entries {
            #expect(entry.rawText.hasPrefix("Executable present:"))
        }

        // And no RECORD says a program ran. The sweep is over the record
        // blocks, not the whole document: the disclosure paragraph uses the word
        // "EXECUTED" precisely in order to deny it.
        for entry in entries {
            let line = entry.rawText.lowercased()
            for phrase in ["was executed", "was run at", "program ran", "execution of"] {
                #expect(!line.contains(phrase), "a record implied execution: \(phrase)")
            }
        }
    }

    // MARK: - THE hash

    @Test("A SHA-1 is reported only when the value really is a 40-character digest")
    func sha1OnlyFromARealDigest() {
        // The real format: four zeros, then the digest.
        #expect(AmcacheReader.sha1(fromFileID: "0000da39a3ee5e6b4b0d3255bfef95601890afd80709")
                == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        // A bare digest is accepted too — some builds write it without the prefix.
        #expect(AmcacheReader.sha1(fromFileID: "DA39A3EE5E6B4B0D3255BFEF95601890AFD80709")
                == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        // Everything else is some other identifier. Labelling it SHA-1 would let
        // an answer assert a hash that a hash-set lookup then contradicts.
        #expect(AmcacheReader.sha1(fromFileID: "0000") == nil)
        #expect(AmcacheReader.sha1(fromFileID: "not-a-hash") == nil)
        #expect(AmcacheReader.sha1(fromFileID: "0000zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz") == nil)
        #expect(AmcacheReader.sha1(fromFileID: nil) == nil)
        // An all-zero digest is a placeholder, not the hash of anything.
        #expect(AmcacheReader.sha1(fromFileID: "0000" + String(repeating: "0", count: 40)) == nil)
    }

    @Test("The executable's identifying facts are all recovered")
    func entryFieldsAreRecovered() async throws {
        let doc = try await parse(amcacheHive())
        let entry = try #require(doc.blocks.first {
            stringAttribute($0, "executableName") == "7z.exe"
        })
        #expect(stringAttribute(entry, "executablePath") == #"c:\program files\7-zip\7z.exe"#)
        #expect(stringAttribute(entry, "sha1") == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        #expect(stringAttribute(entry, "publisher") == "Igor Pavlov")
        #expect(entry.rawText.contains("7-Zip"))
        #expect(entry.rawText.contains("23.01"))
        #expect(entry.rawText.contains("583048 bytes"))
        #expect(entry.rawText.contains("06/20/2023 18:04:11"))
        #expect(entry.rawText.contains("pe64_amd64"))
    }

    @Test("The key's last-written time is labelled as the RECORD's, not the file's")
    func keyTimeIsTheRecordsTime() async throws {
        let doc = try await parse(amcacheHive())
        let entry = try #require(doc.blocks.first {
            stringAttribute($0, "executableName") == "nc.exe"
        })
        #expect(entry.rawText.contains("Inventory record last written 2026-03-12T02:14:07Z"))
        let disclosure = try #require(doc.blocks.first {
            stringAttribute($0, "limitation") == "presence-not-execution"
        })
        #expect(disclosure.rawText.contains("property of the RECORD, not of the file"))
    }

    @Test("Installed applications are a separate kind of fact from files on disk")
    func programsAreDistinctFromFiles() async throws {
        let doc = try await parse(amcacheHive())
        let program = try #require(doc.blocks.first {
            stringAttribute($0, "evidenceOf") == "application-installed"
        })
        #expect(stringAttribute(program, "applicationName") == "7-Zip 23.01 (x64)")
        #expect(program.rawText.contains("installed 02/01/2026 10:00:00"))
        #expect(program.rawText.contains(#"c:\program files\7-zip"#))
        // A program entry is not an executable-presence entry.
        #expect(stringAttribute(program, "sha1") == nil)
    }

    @Test("An executable on a removable path is recorded with that path, plainly")
    func toolOnRemovablePathIsRecorded() async throws {
        // `e:\tools\nc.exe` is the shape that matters in a case, and it is
        // reported as a path — with no judgement attached to the program.
        let doc = try await parse(amcacheHive())
        #expect(text(doc).contains(#"e:\tools\nc.exe"#))
        let body = text(doc).lowercased()
        for word in ["suspicious", "malicious", "hacking", "attack tool"] {
            #expect(!body.contains(word))
        }
    }

    // MARK: - Honest states

    @Test("The legacy numbered schema is counted, NOT mapped")
    func legacySchemaIsNotGuessedAt() async throws {
        // Windows 8 Amcache names its values `0`, `15`, `101` … The meanings are
        // community-derived, so labelling one "SHA-1" would dress a guess as a
        // fact.
        let writer = RegistryHiveFixtureWriter()
        let hive = writer.build(root: Key("Root", children: [
            Key("File", children: [
                Key("{c1b2a3d4-0000-0000-0000-000000000000}", children: [
                    Key("1000abcd", lastWritten: date("2026-03-12T09:00:00Z"), values: [
                        .sz("15", #"c:\windows\system32\cmd.exe"#),
                        .sz("101", "da39a3ee5e6b4b0d3255bfef95601890afd80709")
                    ])
                ])
            ])
        ]))
        let doc = try await parse(hive)
        #expect(doc.warnings.contains { $0.message.contains("legacy Windows 8 numbered") })
        #expect(doc.warnings.contains { $0.message.contains("guess in the shape of a fact") })
        // Nothing from those keys is asserted as an executable or a hash.
        #expect(!doc.blocks.contains { stringAttribute($0, "sha1") != nil })
        #expect(!doc.blocks.contains { stringAttribute($0, "evidenceOf") == "file-presence" })
        #expect(text(doc).contains("1 legacy-schema entr"))
    }

    @Test("An entry that identifies no file is not reported")
    func emptyEntriesAreDropped() async throws {
        // An inventory key with no path, name or hash names nothing, and a block
        // saying "(unnamed) was present" is noise that dilutes real evidence.
        let writer = RegistryHiveFixtureWriter()
        let hive = writer.build(root: Key("Root", children: [
            Key("InventoryApplicationFile", children: [
                Key("ghost|0000", values: [.dword("Size", 0)]),
                Key("real|0001", values: [.sz("Name", "real.exe")])
            ])
        ]))
        let doc = try await parse(hive)
        let entries = doc.blocks.filter { stringAttribute($0, "evidenceOf") == "file-presence" }
        #expect(entries.count == 1)
        #expect(stringAttribute(entries[0], "executableName") == "real.exe")
        #expect(doc.warnings.contains { $0.message.contains("identify no file") })
    }

    @Test("A registry hive that is NOT Amcache says so instead of reporting nothing")
    func nonAmcacheHiveIsReported() async throws {
        let writer = RegistryHiveFixtureWriter()
        let hive = writer.build(root: Key("Root", children: [
            Key("Software", children: [Key("Microsoft", values: [.sz("Version", "10.0")])])
        ]))
        let doc = try await parse(hive)
        #expect(doc.extractionStatus == .empty)
        #expect(doc.warnings.contains { $0.code == "amcache.no_inventory" })
    }

    @Test("Bytes that are not a hive are reported, never guessed at")
    func junkIsRefused() async throws {
        // Big enough to clear the header-size check, so it is the SIGNATURE that
        // rejects it — the case a renamed file of the wrong format hits.
        let junk = Data((0..<8192).map { UInt8(($0 * 31 + 17) % 251) })
        let doc = try await parse(junk)
        #expect(doc.extractionStatus == .corrupt)
        #expect(doc.warnings.contains { $0.code == "amcache.not_a_hive" })
    }

    @Test("A file too short to be a hive is reported as short, not as the wrong format")
    func shortFileIsReportedAsShort() async throws {
        // A hive's header alone is 4096 bytes. "Truncated" and "not a hive" are
        // different findings about an extraction, and conflating them would send
        // someone looking for the wrong problem.
        let doc = try await parse(Data((0..<900).map { UInt8(($0 * 31 + 17) % 251) }))
        #expect(doc.extractionStatus == .corrupt)
        #expect(doc.warnings.contains { $0.code == "amcache.unreadable" })
        #expect(!doc.warnings.contains { $0.code == "amcache.not_a_hive" })
    }

    @Test("An empty file is empty, not corrupt")
    func emptyIsEmpty() async throws {
        let doc = try await parse(Data())
        #expect(doc.extractionStatus == .empty)
        #expect(doc.blocks.isEmpty)
    }

    @Test("Parsing is deterministic")
    func deterministic() async throws {
        let data = amcacheHive()
        #expect(text(try await parse(data)) == text(try await parse(data)))
    }

    // MARK: - Routing

    @Test("Amcache.hve routes to the Amcache parser, not the generic hive parser")
    func detectionBeatsTheGenericHive() {
        // It IS a hive, and reading it as one would dump the keys without the
        // schema that makes them mean anything.
        #expect(SourceType.detect(
            from: URL(fileURLWithPath: "/case/Windows/appcompat/Programs/Amcache.hve")) == .amcache)
        #expect(SourceType.detect(from: URL(fileURLWithPath: "/case/SOFTWARE")) == .registryHive)
        #expect(SourceType.amcache.category == .hostArtifact)
    }

    @Test("The registry gives .amcache a real immediate plugin")
    @MainActor
    func registryOwnsIt() throws {
        let registry = try UniversalParserRegistryBuilder.standard(ocr: VisionOCR())
        let plugin = try registry.resolve(.amcache)
        #expect(plugin.pluginID == "format.amcache")
        #expect(plugin.executionMode == .immediate)
        #expect(plugin.capabilities.producesStructure)
        #expect(!(plugin is PreservedOnlyPlugin))
    }
}
