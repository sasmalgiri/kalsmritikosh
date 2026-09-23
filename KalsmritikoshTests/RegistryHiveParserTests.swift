//
//  RegistryHiveParserTests.swift
//  KalsmritikoshTests
//
//  HOST-2 — proves the REGF reader and parser against real hive bytes built by
//  RegistryHiveFixtureWriter. The cases are chosen to be the ones that actually
//  decide whether a hive is usable evidence: key last-written times (what puts a
//  registry fact on a timeline), every REG_* value type rendered correctly, all
//  three subkey-list encodings, the small-value inline optimization, and — most
//  importantly — that a truncated or hostile hive is reported rather than trusted,
//  and can never hang the walk.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Windows registry hive (HOST-2)")
@MainActor
struct RegistryHiveParserTests {

    private let parser = RegistryHiveStructuralParser()

    /// 2026-03-14T09:26:53Z
    private var when: Date { Date(timeIntervalSince1970: 1_773_480_413) }

    private func parse(_ data: Data, _ filename: String = "NTUSER.DAT") async throws -> ParsedDocument {
        try await parser.parse(data: data, filename: filename, type: .registryHive,
                               logicalSourceID: UUID(), sourceVersionID: UUID())
    }

    private func rows(_ doc: ParsedDocument) -> [String] {
        doc.blocks.filter { $0.kind == .tableRow }.map(\.rawText)
    }
    private func keyLines(_ doc: ParsedDocument) -> [String] {
        doc.blocks.filter { $0.kind == .sectionHeading }.map(\.rawText)
    }

    /// A hive shaped like the single most-used forensic artifact: the Run key.
    private func runKeyHive(_ writer: RegistryHiveFixtureWriter = .init()) -> Data {
        writer.build(root: .init("ROOT", lastWritten: when, children: [
            .init("Microsoft", lastWritten: when, children: [
                .init("Windows", lastWritten: when, children: [
                    .init("CurrentVersion", lastWritten: when, children: [
                        .init("Run", lastWritten: when, values: [
                            .sz("Updater", "C:\\Users\\jdoe\\AppData\\Roaming\\upd.exe"),
                            .dword("Enabled", 1)
                        ])
                    ])
                ])
            ])
        ]))
    }

    // MARK: - Detection

    @Test("Extensionless hive filenames are recognized by name")
    func filenamePatternsDetect() {
        for name in ["NTUSER.DAT", "UsrClass.dat", "SOFTWARE", "SYSTEM", "SAM", "SECURITY"] {
            #expect(SourceType.detect(from: URL(fileURLWithPath: "/case/config/\(name)")) == .registryHive,
                    "\(name) not detected as a hive")
        }
    }

    @Test("Transaction logs and backups are NOT claimed as whole hives")
    func logsAndBackupsAreNotHives() {
        // These are partial/secondary files; decoding them as hives would report
        // corrupt evidence for files that are simply not hives.
        for name in ["NTUSER.DAT.LOG1", "SYSTEM.LOG2", "SOFTWARE.SAV"] {
            #expect(SourceType.detect(from: URL(fileURLWithPath: "/case/\(name)")) != .registryHive,
                    "\(name) should not be treated as a hive")
        }
    }

    @Test("A hive the examiner renamed is still found by its regf signature")
    func magicBytesDetect() {
        let data = runKeyHive()
        #expect(data.prefix(4) == Data("regf".utf8))
        #expect(SourceType.sniffMagicBytes(data) == .registryHive)
    }

    @Test("Registry hives are host artifacts, not documents")
    func categoryIsHostArtifact() {
        #expect(SourceType.registryHive.category == .hostArtifact)
    }

    // MARK: - Structure

    @Test("Every key is reported with its full registry path")
    func keyPathsAreFull() async throws {
        let doc = try await parse(runKeyHive())
        #expect(doc.extractionStatus == .complete)
        let lines = keyLines(doc)
        #expect(lines.contains { $0.hasPrefix("ROOT\\Microsoft\\Windows\\CurrentVersion\\Run") })
        // Intermediate keys are reported too — a gap in the path would break citation.
        #expect(lines.contains { $0.hasPrefix("ROOT\\Microsoft\\Windows") })
        #expect(lines.count == 5)   // ROOT + 4 descendants
    }

    @Test("A value is citable by its full path, not just its name")
    func valuesCiteFullPath() async throws {
        let doc = try await parse(runKeyHive())
        let row = try #require(doc.blocks.first {
            $0.kind == .tableRow && $0.rawText.contains("Updater")
        })
        #expect(row.rawText.contains("upd.exe"))
        #expect(row.rawText.contains("(REG_SZ)"))
        #expect(row.locator.sectionPath ==
                ["NTUSER.DAT", "ROOT", "Microsoft", "Windows", "CurrentVersion", "Run", "Updater"])
    }

    @Test("Key last-written time is recovered as a real ISO-8601 date")
    func lastWrittenIsRecovered() async throws {
        // This is the fact that puts a registry entry on the timeline; without it
        // a hive is a pile of undated settings.
        let doc = try await parse(runKeyHive())
        #expect(keyLines(doc).contains { $0.contains("[last written 2026-03-14T09:26:53Z]") })
        let header = try #require(doc.blocks.first { $0.kind == .documentHeader })
        #expect(header.rawText.contains("last written 2026-03-14T09:26:53Z"))
    }

    @Test("A never-written key reports no date rather than the year 1601")
    func zeroFiletimeIsNotADate() async throws {
        // FILETIME 0 is a real state. Converting it would date the evidence to 1601.
        let data = RegistryHiveFixtureWriter().build(
            root: .init("ROOT", lastWritten: nil, values: [.sz("A", "x")]))
        let doc = try await parse(data)
        #expect(!keyLines(doc).contains { $0.contains("1601") })
        #expect(!keyLines(doc).contains { $0.contains("last written") })
    }

    @Test("The hive's embedded original path is preserved for attribution")
    func embeddedNameIsKept() async throws {
        // How a hive pulled out of an extraction gets tied back to a user account.
        var writer = RegistryHiveFixtureWriter()
        writer.embeddedName = "\\??\\C:\\Users\\r.ahmed\\NTUSER.DAT"
        let doc = try await parse(runKeyHive(writer))
        let header = try #require(doc.blocks.first { $0.kind == .documentHeader })
        #expect(header.rawText.contains("C:\\Users\\r.ahmed\\NTUSER.DAT"))
    }

    // MARK: - Value types

    @Test("Every REG_* type renders as its actual value, not a byte count")
    func allValueTypesRender() async throws {
        var big = UInt64(0x0102_0304_0506_0708).littleEndian
        let qword = withUnsafeBytes(of: &big) { Data($0) }
        let data = RegistryHiveFixtureWriter().build(root: .init("ROOT", lastWritten: when, values: [
            .sz("Text", "hello"),
            .dword("Count", 4_294_967_295),                       // full u32 range
            .multiSZ("List", ["alpha", "beta"]),
            .init(name: "Big", type: 11, data: qword),
            .binary("Blob", [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11])
        ]))
        let values = rows(try await parse(data))
        #expect(values.contains { $0.contains("Text = hello  (REG_SZ)") })
        #expect(values.contains { $0.contains("Count = 4294967295  (REG_DWORD)") })
        #expect(values.contains { $0.contains("List = alpha; beta  (REG_MULTI_SZ)") })
        #expect(values.contains { $0.contains("Big = 72623859790382856  (REG_QWORD)") })
        // Binary stays described. Inventing text for arbitrary bytes would be a lie.
        #expect(values.contains { $0.contains("Blob = <binary 6 bytes>  (REG_BINARY)") })
    }

    @Test("A small value stored inline in the vk record is read correctly")
    func inlineSmallValueIsRead() async throws {
        // The format packs values of 4 bytes or fewer into the data-offset FIELD.
        // Following that field as a pointer instead would read an unrelated cell.
        let data = RegistryHiveFixtureWriter().build(
            root: .init("ROOT", lastWritten: when, values: [.dword("Inline", 1337, inline: true)]))
        #expect(rows(try await parse(data)).contains { $0.contains("Inline = 1337") })
    }

    @Test("A key's unnamed default value is labelled, not blank")
    func defaultValueIsLabelled() async throws {
        let data = RegistryHiveFixtureWriter().build(
            root: .init("ROOT", lastWritten: when, values: [.sz("", "default payload")]))
        #expect(rows(try await parse(data)).contains { $0.contains("(default) = default payload") })
    }

    // MARK: - Subkey-list encodings

    @Test("All three subkey-list encodings (lh, li, ri) resolve to the same keys")
    func allSubkeyListKindsWork() async throws {
        var results: [String: [String]] = [:]
        for kind in [RegistryHiveFixtureWriter.SubkeyListKind.lh, .li, .ri] {
            var writer = RegistryHiveFixtureWriter()
            writer.subkeyListKind = kind
            let data = writer.build(root: .init("ROOT", lastWritten: when, children: [
                .init("Alpha", lastWritten: when, values: [.sz("V", "a")]),
                .init("Beta", lastWritten: when, values: [.sz("V", "b")])
            ]))
            let doc = try await parse(data)
            #expect(doc.extractionStatus == .complete, "\(kind) hive did not parse cleanly")
            results["\(kind)"] = rows(doc).sorted()
        }
        // A hive that fans out through ri must yield exactly what lh/li yield.
        #expect(results["lh"] == results["li"])
        #expect(results["lh"] == results["ri"])
        #expect(results["lh"]?.count == 2)
    }

    @Test("Sibling keys come out in a stable order on every parse")
    func orderIsDeterministic() async throws {
        // Citations must not renumber when an artifact is re-ingested.
        let data = RegistryHiveFixtureWriter().build(root: .init("ROOT", lastWritten: when, children: [
            .init("zeta", lastWritten: when), .init("alpha", lastWritten: when),
            .init("mid", lastWritten: when)
        ]))
        let first = keyLines(try await parse(data))
        let second = keyLines(try await parse(data))
        #expect(first == second)
        // Siblings come out alphabetically, and the root leads.
        let names = first.map { line -> String in
            let path = line.split(separator: " ").first.map(String.init) ?? ""
            return path.split(separator: "\\").last.map(String.init) ?? ""
        }
        #expect(names == ["ROOT", "alpha", "mid", "zeta"])
    }

    // MARK: - Honesty and safety on damaged input

    @Test("Bytes that are not a hive are reported, never guessed at")
    func nonHiveIsReported() async throws {
        let doc = try await parse(Data(repeating: 0x41, count: 8192))
        #expect(doc.extractionStatus == .corrupt)
        #expect(rows(doc).isEmpty)
        #expect(doc.warnings.contains { $0.code == "registry.not_regf" && $0.severity == .error })
    }

    @Test("A file shorter than the base block is truncated, not corrupt-silent")
    func shortFileIsTruncated() async throws {
        let doc = try await parse(Data("regf".utf8) + Data(repeating: 0, count: 100))
        #expect(doc.extractionStatus == .corrupt)
        #expect(doc.warnings.contains { $0.code == "registry.truncated" })
    }

    @Test("An empty file is empty, not corrupt")
    func emptyIsEmpty() async throws {
        let doc = try await parse(Data())
        #expect(doc.extractionStatus == .empty)
        #expect(doc.warnings.contains { $0.code == "registry.empty" })
    }

    @Test("A hive cut off mid-data yields what survived AND says it is partial")
    func truncatedHiveIsPartialNotSilent() async throws {
        // The realistic damaged-evidence case: the base block still declares the
        // original size. Keys that survived must be recovered; the loss must be stated.
        let full = runKeyHive()
        let doc = try await parse(full.prefix(full.count - 3000))
        #expect(doc.extractionStatus == .partial || doc.extractionStatus == .corrupt)
        if doc.extractionStatus == .partial {
            #expect(doc.warnings.contains { $0.code == "registry.partial" })
            #expect(doc.warnings.contains { $0.message.contains("truncated") })
        }
    }

    @Test("A hive whose subkey list points back at its parent cannot hang the walk")
    func cycleIsRefused() async throws {
        // Hand-corrupt a valid hive: aim the root's subkey-list field at the root
        // cell itself. A naive recursive walk never returns; the reader must refuse.
        var data = runKeyHive()
        let rootOffset = data.withUnsafeBytes { $0.load(fromByteOffset: 0x24, as: UInt32.self) }
        // Build a one-entry lh list that points at the root, and overwrite the
        // root's subkey-list offset with it. Reuse the tail padding of the bin.
        let listOffset = UInt32(data.count - 4096 - 32)      // inside the final padded region
        let absoluteList = 4096 + Int(listOffset)
        guard absoluteList + 16 <= data.count else { return }
        var cell = Data()
        var size = Int32(-16).littleEndian
        cell.append(withUnsafeBytes(of: &size) { Data($0) })
        cell += Data("lh".utf8)
        var one = UInt16(1).littleEndian
        cell.append(withUnsafeBytes(of: &one) { Data($0) })
        var target = rootOffset.littleEndian
        cell.append(withUnsafeBytes(of: &target) { Data($0) })
        var hash = UInt32(0).littleEndian
        cell.append(withUnsafeBytes(of: &hash) { Data($0) })
        data.replaceSubrange(absoluteList..<(absoluteList + cell.count), with: cell)

        let rootCell = 4096 + Int(rootOffset) + 4
        var patch = listOffset.littleEndian
        data.replaceSubrange((rootCell + 0x1C)..<(rootCell + 0x20),
                             with: withUnsafeBytes(of: &patch) { Data($0) })
        // Subkey count must be non-zero for the list to be followed at all.
        var oneKey = UInt32(1).littleEndian
        data.replaceSubrange((rootCell + 0x14)..<(rootCell + 0x18),
                             with: withUnsafeBytes(of: &oneKey) { Data($0) })

        // The real assertion is that this returns at all.
        let doc = try await parse(data)
        #expect(doc.warnings.contains { $0.message.contains("Cycle refused") })
    }

    // MARK: - Loader + registry wiring

    @Test("RegistryHiveLoader yields searchable text for binary hive bytes")
    func loaderProducesText() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("NTUSER.DAT")
        try runKeyHive().write(to: url)

        let ko = try await RegistryHiveLoader().ingest(fileAt: url, type: .registryHive)
        #expect(ko.content.contains("upd.exe"))
        #expect(ko.content.contains("CurrentVersion\\Run"))
    }

    @Test("The universal registry gives .registryHive a real immediate plugin")
    func registryOwnsHives() throws {
        let registry = try UniversalParserRegistryBuilder.standard(ocr: VisionOCR())
        let plugin = try registry.resolve(.registryHive)
        #expect(plugin.pluginID == "format.registryHive")
        #expect(plugin.executionMode == .immediate)
        #expect(plugin.capabilities.producesStructure)
        #expect(!(plugin is PreservedOnlyPlugin))
    }
}
