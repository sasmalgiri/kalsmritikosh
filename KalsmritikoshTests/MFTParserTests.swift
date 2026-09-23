//
//  MFTParserTests.swift
//  KalsmritikoshTests
//
//  HOST-5 — the NTFS master file table.
//
//  Four tests carry the weight:
//
//   - `fixupsAreApplied` — NTFS overwrites the last two bytes of every 512-byte
//     sector. A reader that ignores that reads plausible-looking WRONG dates for
//     any field crossing a sector boundary. Silent corruption is the worst kind.
//   - `deletedFilesAreReportedAsDeleted` — the reason this artifact matters is
//     that it outlives its files, and a deleted file presented like a live one
//     would put something on the timeline that was not there.
//   - `staleParentPathIsLabelled` — a reused directory record yields a path that
//     is what the record says, not where the file was.
//   - `timestampDisagreementIsReportedNotDiagnosed` — the two timestamp sets
//     differing is a fact; calling it timestomping is a conclusion.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("NTFS master file table (HOST-5)")
struct MFTParserTests {

    private let parser = MFTStructuralParser()

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.date(from: iso)!
    }

    private func parse(_ data: Data, as filename: String = "$MFT")
    async throws -> ParsedDocument {
        try await parser.parse(data: data, filename: filename, type: .masterFileTable,
                               logicalSourceID: UUID(), sourceVersionID: UUID())
    }

    private func text(_ doc: ParsedDocument) -> String {
        doc.blocks.map(\.rawText).joined(separator: "\n")
    }
    private func stringAttribute(_ block: EvidenceBlock, _ key: String) -> String? {
        if case .string(let value) = block.attributes[key]?.value { return value }
        return nil
    }
    private func boolAttribute(_ block: EvidenceBlock, _ key: String) -> Bool? {
        if case .bool(let value) = block.attributes[key]?.value { return value }
        return nil
    }

    /// Root directory (record 5) plus a folder and a file inside it.
    private func smallVolume() -> Data {
        let writer = MFTFixtureWriter()
        return writer.build(records: [
            .init(recordNumber: 5, name: ".", parentRecordNumber: 5, isDirectory: true,
                  standardTimes: .all(date("2026-01-01T00:00:00Z"))),
            .init(recordNumber: 40, name: "cases", parentRecordNumber: 5, isDirectory: true,
                  standardTimes: .all(date("2026-02-01T09:00:00Z"))),
            .init(recordNumber: 41, name: "statement.docx", parentRecordNumber: 40,
                  standardTimes: .init(created: date("2026-03-10T08:15:00Z"),
                                       modified: date("2026-03-11T17:02:10Z"),
                                       recordChanged: date("2026-03-11T17:02:10Z"),
                                       accessed: date("2026-03-12T09:26:53Z")),
                  realSize: 248_512, nonResidentSize: 248_512)
        ])
    }

    // MARK: - THE fixup trap

    @Test("Update-sequence fixups are applied before anything is parsed")
    func fixupsAreApplied() throws {
        // The fixture applies fixups exactly as NTFS does. If the reader did not
        // undo them, two bytes per sector would still hold the sequence number
        // and any field straddling offset 510 would decode to garbage.
        var reader = try MFTReader(data: smallVolume())
        let records = reader.records()
        let file = try #require(records.first { $0.primaryName == "statement.docx" })
        #expect(file.standardInformation?.modified == date("2026-03-11T17:02:10Z"))
        #expect(file.standardInformation?.accessed == date("2026-03-12T09:26:53Z"))
        #expect(file.dataSizeBytes == 248_512)

        // And prove the fixup path is really exercised: the raw bytes at the
        // sector boundary are NOT the restored ones.
        let raw = smallVolume()
        let recordStart = 2 * 1024      // the third record
        let boundary = recordStart + MFTReader.sectorSize - 2
        let placeholder = UInt16(raw[boundary]) | (UInt16(raw[boundary + 1]) << 8)
        #expect(placeholder == 1, "the fixture did not apply a fixup, so the test proves nothing")
    }

    @Test("A record whose fixup check fails is refused, not read with corrupt fields")
    func tornRecordIsRefused() async throws {
        let writer = MFTFixtureWriter()
        let data = writer.build(records: [
            .init(recordNumber: 5, name: ".", parentRecordNumber: 5, isDirectory: true),
            .init(recordNumber: 60, name: "torn.txt", standardTimes: .all(date("2026-03-12T09:00:00Z")),
                  corruptFixup: true)
        ])
        var reader = try MFTReader(data: data)
        let records = reader.records()
        // A mid-write capture would otherwise yield a plausible wrong date.
        #expect(!records.contains { $0.primaryName == "torn.txt" })
        #expect(reader.problems.contains { $0.contains("torn mix of two versions") })

        let doc = try await parse(data)
        #expect(doc.warnings.contains { $0.message.contains("torn mix of two versions") })
    }

    // MARK: - THE reason this artifact exists

    @Test("A deleted file keeps its name and times, and is reported as DELETED")
    func deletedFilesAreReportedAsDeleted() async throws {
        let writer = MFTFixtureWriter()
        let data = writer.build(records: [
            .init(recordNumber: 5, name: ".", parentRecordNumber: 5, isDirectory: true),
            .init(recordNumber: 70, name: "ledger-2025.xlsx", parentRecordNumber: 5,
                  inUse: false,
                  standardTimes: .init(created: date("2026-01-04T11:00:00Z"),
                                       modified: date("2026-03-01T15:30:00Z"),
                                       recordChanged: date("2026-03-01T15:30:00Z"),
                                       accessed: date("2026-03-11T08:00:00Z")),
                  realSize: 92_160, nonResidentSize: 92_160)
        ])
        let doc = try await parse(data)
        let record = try #require(doc.blocks.first {
            stringAttribute($0, "fileName") == "ledger-2025.xlsx"
        })
        #expect(boolAttribute(record, "isDeleted") == true)
        #expect(record.rawText.hasPrefix("DELETED"))
        // The evidence that survives the file:
        #expect(record.rawText.contains("2026-03-01T15:30:00Z"))
        #expect(record.rawText.contains("92160 bytes"))
        #expect(text(doc).contains("1 of them DELETED"))
        // And the document explains why a deleted record still holds all this.
        #expect(doc.blocks.contains {
            stringAttribute($0, "limitation") == "mft-record-semantics"
        })
    }

    @Test("A small file's entire content comes back from inside its record")
    func residentContentIsRecovered() async throws {
        // This is the strongest thing the MFT does: for a resident file the
        // content is in the record, so it survives deletion of the data itself.
        let writer = MFTFixtureWriter()
        let note = "Meet at the depot 03:00. Bring the drive. — R"
        let data = writer.build(records: [
            .init(recordNumber: 5, name: ".", parentRecordNumber: 5, isDirectory: true),
            .init(recordNumber: 80, name: "note.txt", parentRecordNumber: 5, inUse: false,
                  standardTimes: .all(date("2026-03-12T02:14:07Z")),
                  realSize: UInt64(note.utf8.count),
                  residentData: Data(note.utf8))
        ])
        let doc = try await parse(data)
        #expect(text(doc).contains(note))
        let content = try #require(doc.blocks.first { $0.rawText.contains("recovered in full") })
        #expect(content.rawText.contains("note.txt"))
    }

    @Test("Binary resident content is not rendered as fake recovered text")
    func binaryResidentContentIsNotMojibake() async throws {
        let writer = MFTFixtureWriter()
        let blob = Data((0..<64).map { UInt8(($0 * 7 + 3) % 251) })
        let data = writer.build(records: [
            .init(recordNumber: 5, name: ".", parentRecordNumber: 5, isDirectory: true),
            .init(recordNumber: 81, name: "thumb.db", parentRecordNumber: 5,
                  standardTimes: .all(date("2026-03-12T02:14:07Z")), residentData: blob)
        ])
        let doc = try await parse(data)
        // The file is still reported; only the unreadable bytes are not dressed
        // up as words that a search would match.
        #expect(text(doc).contains("thumb.db"))
        #expect(!doc.blocks.contains { $0.rawText.contains("recovered in full") })
    }

    // MARK: - Paths

    @Test("Full paths are rebuilt through parent references")
    func pathsAreRebuilt() async throws {
        let doc = try await parse(smallVolume())
        let file = try #require(doc.blocks.first {
            stringAttribute($0, "fileName") == "statement.docx"
        })
        #expect(stringAttribute(file, "fullPath") == #"\cases\statement.docx"#)
        #expect(stringAttribute(file, "pathCertainty") == "certain")
    }

    @Test("A path through a REUSED directory record is labelled stale")
    func staleParentPathIsLabelled() async throws {
        // The parent slot now holds a different directory (sequence 7, not the 1
        // the child remembers). The path is what the record says, not where the
        // file was — and a confident path here would be a wrong answer.
        let writer = MFTFixtureWriter()
        let data = writer.build(records: [
            .init(recordNumber: 5, name: ".", parentRecordNumber: 5, isDirectory: true),
            .init(recordNumber: 40, sequenceNumber: 7, name: "invoices",
                  parentRecordNumber: 5, isDirectory: true),
            .init(recordNumber: 41, name: "deleted-photo.jpg",
                  parentRecordNumber: 40, parentSequenceNumber: 1, inUse: false,
                  standardTimes: .all(date("2026-03-01T10:00:00Z")))
        ])
        let doc = try await parse(data)
        let file = try #require(doc.blocks.first {
            stringAttribute($0, "fileName") == "deleted-photo.jpg"
        })
        #expect(stringAttribute(file, "pathCertainty") == "parentReused")
        #expect(file.rawText.contains("reused by a different folder"))
    }

    @Test("A path whose parent is not in the extraction says the path is incomplete")
    func missingParentIsDisclosed() async throws {
        let writer = MFTFixtureWriter()
        let data = writer.build(records: [
            .init(recordNumber: 5, name: ".", parentRecordNumber: 5, isDirectory: true),
            .init(recordNumber: 90, name: "orphan.txt", parentRecordNumber: 4242,
                  standardTimes: .all(date("2026-03-12T09:00:00Z")))
        ])
        let doc = try await parse(data)
        let file = try #require(doc.blocks.first {
            stringAttribute($0, "fileName") == "orphan.txt"
        })
        #expect(stringAttribute(file, "pathCertainty") == "parentMissing")
        #expect(file.rawText.contains("not in this extraction"))
    }

    @Test("A parent chain that points at itself cannot hang the walk")
    func cycleIsRefused() throws {
        let writer = MFTFixtureWriter()
        let data = writer.build(records: [
            .init(recordNumber: 100, name: "a", parentRecordNumber: 101, isDirectory: true),
            .init(recordNumber: 101, name: "b", parentRecordNumber: 100, isDirectory: true)
        ])
        var reader = try MFTReader(data: data)
        let paths = MFTReader.paths(for: reader.records())
        #expect(paths[100] != nil)
        #expect(paths[101] != nil)
    }

    // MARK: - THE two timestamp sets

    @Test("Disagreeing timestamp sets are reported as a fact, not diagnosed")
    func timestampDisagreementIsReportedNotDiagnosed() async throws {
        let writer = MFTFixtureWriter()
        let data = writer.build(records: [
            .init(recordNumber: 5, name: ".", parentRecordNumber: 5, isDirectory: true),
            .init(recordNumber: 110, name: "backdated.exe", parentRecordNumber: 5,
                  standardTimes: .init(created: date("2019-01-01T00:00:00Z"),
                                       modified: date("2019-01-01T00:00:00Z"),
                                       recordChanged: date("2026-03-12T09:26:53Z"),
                                       accessed: date("2019-01-01T00:00:00Z")),
                  fileNameTimes: .all(date("2026-03-12T09:20:00Z")))
        ])
        let doc = try await parse(data)
        let discrepancy = try #require(doc.blocks.first {
            stringAttribute($0, "observation") == "timestamp-sets-disagree"
        })
        // Both values, and which field — "they differ" alone is not evidence.
        #expect(discrepancy.rawText.contains("2019-01-01T00:00:00Z"))
        #expect(discrepancy.rawText.contains("2026-03-12T09:20:00Z"))
        #expect(discrepancy.rawText.contains("$STANDARD_INFORMATION"))
        #expect(discrepancy.rawText.contains("$FILE_NAME"))
        // And no diagnosis anywhere in the document.
        let body = text(doc).lowercased()
        for word in ["timestomp", "tampered", "forged", "falsified", "anti-forensic"] {
            #expect(!body.contains(word), "the parser diagnosed a cause: \(word)")
        }
        #expect(discrepancy.rawText.contains("not as a conclusion"))
    }

    @Test("Matching timestamp sets produce no discrepancy block")
    func matchingTimestampsAreQuiet() async throws {
        // Most files match. A discrepancy block on every file would make the
        // signal worthless.
        let doc = try await parse(smallVolume())
        #expect(!doc.blocks.contains {
            stringAttribute($0, "observation") == "timestamp-sets-disagree"
        })
    }

    // MARK: - Record kinds and honest states

    @Test("A DOS 8.3 name is not reported as a second file")
    func dosNamesAreNotDuplicateFiles() throws {
        let writer = MFTFixtureWriter()
        let data = writer.build(records: [
            .init(recordNumber: 120, name: "PROGRA~1", namespace: 2, parentRecordNumber: 5,
                  isDirectory: true)
        ])
        var reader = try MFTReader(data: data)
        let record = try #require(reader.records().first)
        #expect(record.names.first?.isDOSOnly == true)
        // With only an 8.3 name it is still the record's name, but it is flagged
        // so a long-name sibling wins wherever both exist.
        #expect(record.primaryName == "PROGRA~1")
    }

    @Test("An extension record's names are not counted as another file")
    func extensionRecordsAreNotSeparateFiles() async throws {
        // A file with many attributes spills into extension records that name
        // the same file. Counting them would inflate every file count.
        let writer = MFTFixtureWriter()
        let data = writer.build(records: [
            .init(recordNumber: 5, name: ".", parentRecordNumber: 5, isDirectory: true),
            .init(recordNumber: 130, name: "big.vmdk", parentRecordNumber: 5,
                  standardTimes: .all(date("2026-03-12T09:00:00Z"))),
            .init(recordNumber: 131, name: "big.vmdk", parentRecordNumber: 5,
                  standardTimes: .all(date("2026-03-12T09:00:00Z")), baseRecordNumber: 130)
        ])
        let doc = try await parse(data)
        let named = doc.blocks.filter { stringAttribute($0, "fileName") == "big.vmdk" }
        #expect(named.count == 1)
        // Three record slots, two named files (the root directory and big.vmdk),
        // and the extension record counted as neither.
        #expect(text(doc).contains("2 named record(s)"))
        #expect(text(doc).contains("3 record slot(s) read"))
    }

    @Test("A BAAD record is reported with its fields marked untrustworthy")
    func baadRecordsAreFlagged() async throws {
        let writer = MFTFixtureWriter()
        let data = writer.build(records: [
            .init(recordNumber: 5, name: ".", parentRecordNumber: 5, isDirectory: true),
            .init(recordNumber: 140, name: "damaged.dat", parentRecordNumber: 5, isBAAD: true,
                  standardTimes: .all(date("2026-03-12T09:00:00Z")))
        ])
        let doc = try await parse(data)
        let record = try #require(doc.blocks.first {
            stringAttribute($0, "fileName") == "damaged.dat"
        })
        #expect(record.rawText.contains("NTFS marked this record BAD"))
    }

    @Test("Unused record slots are skipped silently, data-bearing ones are counted")
    func unusedSlotsAreNotNoise() async throws {
        // A real MFT is mostly empty slots; warning about each would bury the
        // findings.
        let writer = MFTFixtureWriter()
        var data = writer.build(records: [
            .init(recordNumber: 5, name: ".", parentRecordNumber: 5, isDirectory: true)
        ])
        data += writer.emptySlot()
        data += writer.emptySlot()
        let doc = try await parse(data)
        #expect(!doc.warnings.contains { $0.message.contains("held data but no FILE") })
        #expect(doc.extractionStatus == .complete)
    }

    @Test("A 4096-byte-record table is read using the size the file declares")
    func declaredRecordSizeIsHonoured() throws {
        // Large-sector volumes use 4096-byte records. Hard-coding 1024 would
        // mis-align every record after the first.
        var writer = MFTFixtureWriter()
        writer.recordSize = 4096
        let data = writer.build(records: [
            .init(recordNumber: 5, name: ".", parentRecordNumber: 5, isDirectory: true),
            .init(recordNumber: 150, name: "wide.txt", parentRecordNumber: 5,
                  standardTimes: .all(date("2026-03-12T09:00:00Z")))
        ])
        var reader = try MFTReader(data: data)
        #expect(reader.recordSize == 4096)
        #expect(reader.records().contains { $0.primaryName == "wide.txt" })
    }

    @Test("A zero timestamp is no date, not 1601")
    func zeroTimesAreNotDates() throws {
        let writer = MFTFixtureWriter()
        let data = writer.build(records: [
            .init(recordNumber: 160, name: "undated.txt", parentRecordNumber: 5)
        ])
        var reader = try MFTReader(data: data)
        let record = try #require(reader.records().first)
        #expect(record.standardInformation?.isEmpty == true)
    }

    @Test("Bytes that are not an MFT are reported, never guessed at")
    func junkIsRefused() async throws {
        let junk = Data((0..<4096).map { UInt8(($0 * 31 + 17) % 251) })
        let doc = try await parse(junk)
        #expect(doc.extractionStatus == .corrupt)
        #expect(doc.warnings.contains { $0.code == "mft.not_an_mft" })
    }

    @Test("An empty file is empty, not corrupt")
    func emptyIsEmpty() async throws {
        let doc = try await parse(Data())
        #expect(doc.extractionStatus == .empty)
        #expect(doc.blocks.isEmpty)
    }

    @Test("A trailing partial record is reported, and what survived is kept")
    func truncationIsReported() async throws {
        let data = smallVolume().prefix(2 * 1024 + 300)
        let doc = try await parse(Data(data))
        #expect(text(doc).contains("cases"))
        #expect(doc.warnings.contains { $0.message.contains("trailing partial record") })
    }

    @Test("Parsing is deterministic")
    func deterministic() async throws {
        let data = smallVolume()
        #expect(text(try await parse(data)) == text(try await parse(data)))
    }

    // MARK: - Routing

    @Test("An exported $MFT is detected by name and by the .mft extension")
    func detection() {
        #expect(SourceType.detect(from: URL(fileURLWithPath: "/case/C/$MFT")) == .masterFileTable)
        #expect(SourceType.detect(from: URL(fileURLWithPath: "/case/mft")) == .masterFileTable)
        #expect(SourceType.detect(from: URL(fileURLWithPath: "/case/volume.mft")) == .masterFileTable)
        #expect(SourceType.masterFileTable.category == .hostArtifact)
    }

    @Test("The structural probe finds a renamed MFT but refuses lookalikes")
    func structuralProbeIsStrict() {
        // "FILE" is a weak signature, so the probe also requires the header's
        // own offsets to be self-consistent — otherwise it would reclassify
        // unrelated files that merely start with those four letters.
        #expect(MFTReader.looksLikeAnMFT(smallVolume()))
        var pretender = Data("FILE".utf8)
        pretender += Data(repeating: 0x41, count: 2048)   // "FILE" then plain text
        #expect(!MFTReader.looksLikeAnMFT(pretender))
        #expect(!MFTReader.looksLikeAnMFT(Data("FILES AND FOLDERS README".utf8)))
    }

    @Test("The registry gives .masterFileTable a real immediate plugin")
    @MainActor
    func registryOwnsIt() throws {
        let registry = try UniversalParserRegistryBuilder.standard(ocr: VisionOCR())
        let plugin = try registry.resolve(.masterFileTable)
        #expect(plugin.pluginID == "format.masterFileTable")
        #expect(plugin.executionMode == .immediate)
        #expect(plugin.capabilities.producesStructure)
        #expect(!(plugin is PreservedOnlyPlugin))
    }

    @Test("The loader's text keeps the DELETED marker")
    @MainActor
    func loaderKeepsDeletedMarker() async throws {
        // A filename search must not return a hit that reads as though the file
        // were still on the disk.
        let writer = MFTFixtureWriter()
        let data = writer.build(records: [
            .init(recordNumber: 5, name: ".", parentRecordNumber: 5, isDirectory: true),
            .init(recordNumber: 170, name: "gone.docx", parentRecordNumber: 5, inUse: false,
                  standardTimes: .all(date("2026-03-01T10:00:00Z")))
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mft-\(UUID().uuidString).mft")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let object = try await MFTLoader().ingest(fileAt: url, type: .masterFileTable)
        #expect(object.content.contains("DELETED file gone.docx"))
        #expect(object.confidence == .high)
    }
}
