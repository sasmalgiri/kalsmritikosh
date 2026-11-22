//
//  UnifiedPathForensicTests.swift
//  KalsmritikoshTests
//
//  Test phase T3 (2026-11-22) — the forensic readers of the unified-path program against freely licensed public
//  samples (Fixtures/Forensic: plaso test data, Apache-2.0; Fixtures/Archives/homebrew-container.rar: Homebrew test
//  fixture, BSD-2-Clause). SRC-12 readers, SRC-11 Shimcache on a real value, IN-24 RAR through the system libarchive,
//  IN-15 logistics tables on an OCR'd image table. No network; expected values are the ones the NOTICE records.
//

import Foundation
import CryptoKit
import Testing
@testable import Kalsmritikosh

@Suite("Unified path — forensic readers on public samples", .serialized)
struct UnifiedPathForensicTests {

    static var fixtures: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures", isDirectory: true) }
    static func forensic(_ name: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent("Forensic/\(name)")) }
    static func utc(_ s: String) -> Date { ISO8601DateFormatter().date(from: s) ?? .distantPast }
    static func near(_ a: Date?, _ b: Date) -> Bool { a.map { abs($0.timeIntervalSince(b)) < 1 } ?? false }

    /// A gzip member's payload (RFC 1952 header, raw DEFLATE body via the system's zlib decoder).
    static func gunzip(_ d: Data) throws -> Data {
        let b = [UInt8](d)
        guard b.count > 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { throw CocoaError(.fileReadCorruptFile) }
        let flags = b[3]
        var p = 10
        if flags & 0x04 != 0 { p += 2 + (Int(b[p]) | Int(b[p + 1]) << 8) }
        if flags & 0x08 != 0 { while p < b.count, b[p] != 0 { p += 1 }; p += 1 }
        if flags & 0x10 != 0 { while p < b.count, b[p] != 0 { p += 1 }; p += 1 }
        if flags & 0x02 != 0 { p += 2 }
        let body = Data(b[p..<(b.count - 8)])
        return try (body as NSData).decompressed(using: .zlib) as Data
    }

    // MARK: - SRC-12 Prefetch

    @Test("SRC-12: Windows 10/11 MAM-compressed Prefetch (one and two Xpress blocks) and XP/7 Prefetch read to the run times and counts plaso records; path hashes match the file names")
    func prefetch() throws {
        let cases: [(file: String, version: PrefetchReader.Version, compressed: Bool, count: UInt32, newest: String?)] = [
            ("AM_DELTA_PATCH_1.443.990.0.EX-7037CF86.pf", .win11, true, 1, "2026-02-04T13:43:44Z"),
            ("NOTEPAD.EXE-D8414F97.pf", .win10, true, 2, nil),
            ("ONEDRIVE.EXE-7E152375.pf", .win10, true, 2, nil),
            ("CMD.EXE-087B4001.pf", .winXP, false, 2, "2013-03-10T10:11:49Z"),
            ("PING.EXE-B29F6629.pf", .winVista7, false, 14, "2012-04-06T19:00:55Z")]
        for c in cases {
            let r = try PrefetchReader(data: try Self.forensic(c.file))
            #expect(r.version == c.version && r.wasCompressed == c.compressed, "\(c.file): \(r.version) compressed \(r.wasCompressed)")
            #expect(r.runCount == c.count, "\(c.file): run count \(r.runCount)")
            let hash = String(c.file.split(separator: "-").last?.prefix(8) ?? "")
            #expect(String(format: "%08X", r.pathHash) == hash, "\(c.file): path hash \(String(format: "%08X", r.pathHash))")
            let stem = String(c.file.split(separator: "-").first ?? "")
            #expect(r.executableName.uppercased().hasPrefix(String(stem.prefix(8))), "\(c.file): name \(r.executableName)")
            if let newest = c.newest {
                #expect(Self.near(r.runTimes.max(), Self.utc(newest)), "\(c.file): runs \(r.runTimes)")
            }
            if c.version == .win10 { #expect(r.runTimes.count == 2, "\(c.file): two runs, got \(r.runTimes)") }
        }
        // A MAM header whose body does not decompress is refused with its declared size, never read as garbage.
        var broken = [UInt8](try Self.forensic("NOTEPAD.EXE-D8414F97.pf"))
        for i in 12..<min(broken.count, 400) { broken[i] = 0xFF }
        #expect(throws: PrefetchReader.ReaderError.self) { _ = try PrefetchReader(data: Data(broken)) }
    }

    // MARK: - SRC-12 EVTX

    @Test("SRC-12: EVTX BinXML resolves every record of both plaso logs; event-ID filtering returns exactly the IDs asked for")
    func eventLogs() throws {
        var small = try EVTXReader(data: try Self.forensic("System2.evtx"))
        let s = small.records()
        #expect(s.count == 194 && s.allSatisfy { $0.event?.eventID != nil }, "System2: \(s.count) records, \(s.filter { $0.event?.eventID == nil }.count) unresolved")
        let ids = Dictionary(grouping: s.compactMap { $0.event?.eventID }, by: { $0 }).mapValues(\.count)
        #expect(ids[4624] == 47 && ids[4672] == 36 && ids[4735] == 34, "\(ids)")
        #expect(small.records(eventIDs: [4624]).count == 47)
        #expect(small.records(eventIDs: [4624, 4672]).allSatisfy { [4624, 4672].contains($0.event?.eventID ?? 0) })

        var big = try EVTXReader(data: try Self.forensic("System.evtx"))
        let b = big.records()
        #expect(b.count == 5_009 && b.allSatisfy { $0.event?.eventID != nil }, "System: \(b.count)")
        let bigIDs = Dictionary(grouping: b.compactMap { $0.event?.eventID }, by: { $0 }).mapValues(\.count)
        #expect(bigIDs[7036] == 3_434 && bigIDs[7040] == 1_018, "\(bigIDs.filter { $0.value > 500 })")
        let first = try #require(b.min { $0.recordID < $1.recordID })
        #expect(first.recordID == 1 && first.event?.eventID == 7036 && first.event?.provider == "Service Control Manager", "\(String(describing: first.event))")
        let values = first.event?.data.map(\.value) ?? []
        #expect(values.contains("Windows Event Log") && values.contains("stopped"), "\(values)")
    }

    // MARK: - SRC-12 journald

    @Test("SRC-12: a Linux systemd journal reads all 2,101 entries in order between the header's first and last times")
    func journal() throws {
        let data = try Self.gunzip(try Self.forensic("system.journal.gz"))
        #expect(JournaldReader.isJournal(data))
        var reader = try JournaldReader(data: data)
        let entries = reader.entries()
        #expect(entries.count == 2_101 && reader.declaredEntries == 2_101, "\(entries.count) of \(reader.declaredEntries); \(reader.problems)")
        #expect(Self.near(entries.first?.realtime, Self.utc("2017-01-27T09:40:55Z")) || entries.first?.realtime.map { $0 < Self.utc("2017-01-27T09:40:56Z") } == true,
                "first \(String(describing: entries.first?.realtime))")
        #expect(entries.last?.realtime.map { abs($0.timeIntervalSince(Self.utc("2017-02-06T16:24:42Z"))) < 1 } == true, "last \(String(describing: entries.last?.realtime))")
        #expect(zip(entries, entries.dropFirst()).allSatisfy { $0.seqnum < $1.seqnum }, "seqnum order")
        let text = try #require(JournaldReader.text(from: data))
        #expect(text.hasPrefix("Linux systemd journal: 2101 entries"), "\(text.prefix(120))")
    }

    // MARK: - SRC-12 jump lists

    @Test("SRC-12: DestList v1 and v3 give the entries in most-recent order with their stream names, host, access counts and newest time")
    func jumpLists() throws {
        func destList(_ file: String) throws -> JumpListDestList.Decoded {
            let ole = try OLE2Reader(data: try Self.forensic(file))
            let stream = try #require(ole.rootChildren().first { $0.name.lowercased() == "destlist" }, "\(file): no DestList stream")
            return try #require(JumpListDestList.decode(ole.readEntryData(stream)), "\(file): DestList not decoded")
        }
        let v1 = try destList("1b4dd67f29cb1962.automaticDestinations-ms")
        #expect(v1.version == 1 && v1.entries.map(\.streamName) == ["7", "5", "2", "1", "6", "4", "3"] && v1.stoppedEarly == nil,
                "v1: \(v1.entries.map(\.streamName)) \(String(describing: v1.stoppedEarly))")
        #expect(v1.entries.allSatisfy { $0.hostName == "student-pc1" })
        let newest1 = try #require(v1.entries.max { ($0.lastAccess ?? .distantPast) < ($1.lastAccess ?? .distantPast) })
        #expect(Self.near(newest1.lastAccess, Self.utc("2015-08-29T15:32:44Z")) && newest1.path == "C:\\Users\\bperry\\Downloads", "\(newest1)")
        let v3 = try destList("9d1f905ce5044aee.automaticDestinations-ms")
        #expect(v3.version == 3 && v3.entries.map(\.streamName) == ["2", "1"] && v3.entries.allSatisfy { $0.accessCount == 1 }, "v3: \(v3.entries)")
        #expect(Self.near(v3.entries.compactMap(\.lastAccess).max(), Self.utc("2016-01-17T13:08:08Z")))
    }

    // MARK: - SRC-11 / SRC-12 Shimcache (real value)

    @Test("SRC-11/SRC-12: the real Windows 7 AppCompatCache value from plaso's SYSTEM hive decodes to 330 entries with paths, times and insert flags")
    func shimcacheRealValue() throws {
        let value = try Self.forensic("SYSTEM.ControlSet001.AppCompatCache.bin")
        guard case .decoded(let entries, let stopped) = ShimcacheDecoder.decode(value) else {
            Issue.record("the real value did not decode"); return
        }
        #expect(entries.count == 330 && stopped == nil, "\(entries.count) entries; stopped \(String(describing: stopped))")
        #expect(entries.first?.path == "\\??\\C:\\Program Files\\McAfee\\VirusScan Enterprise\\mfeann.exe", "\(String(describing: entries.first?.path))")
        #expect(Self.near(entries.first?.fileLastModified, Self.utc("2011-01-12T12:08:00Z")), "\(String(describing: entries.first?.fileLastModified))")
        #expect(entries.filter { $0.insertFlagSet == true }.count == 238)
        #expect(entries.allSatisfy { $0.layout != "win10" }, "a Windows 7 layout, not the Windows 10 one")
        #expect(entries.map(\.ordinal) == Array(entries.map(\.ordinal)).sorted(), "kept in cache order")
        #expect(!ShimcacheDecoder.note(forLayout: entries[0].layout).isEmpty)
    }

    // MARK: - IN-24 RAR

    @Test("IN-24: a RAR4 archive (Homebrew test fixture, BSD-2-Clause) is listed and its member extracted byte-exact through the system libarchive")
    func rarThroughLibarchive() throws {
        let url = Self.fixtures.appendingPathComponent("Archives/homebrew-container.rar")
        let members = try SystemArchiveReader.listMembers(url: url, limit: 10)
        #expect(members.filter { !$0.isDirectory }.map(\.path) == ["container"], "\(members.map(\.path))")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("us-rar-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        let reader = try SystemArchiveReader(url: url)
        var extracted = 0
        while let m = try reader.next() {
            guard !m.isDirectory else { continue }
            _ = try reader.extractCurrent(to: out, maxBytes: 1_000_000)
            let sha = SHA256.hash(data: try Data(contentsOf: out)).map { String(format: "%02x", $0) }.joined()
            #expect(sha == "306c6ca7407560340797866e077e053627ad409277d1b9da58106fce4cf717cb")
            #expect(String(decoding: try Data(contentsOf: out), as: UTF8.self) == "#!/bin/sh\nexit 0\n")
            extracted += 1
        }
        #expect(extracted == 1)
    }

    // MARK: - IN-15 logistics tables from OCR

    struct TableOCR: OCREngine {
        nonisolated var engineID: String { "t3-table" }
        let grid: [[String]]
        func recognizePrinted(at url: URL) async -> [String] { [] }
        func recognizeHandwritten(at url: URL) async -> [String] { [] }
        func recognizeTable(at url: URL) async -> [[String]] { grid }
    }

    @Test("IN-15: an image whose OCR table is a Type-2 logistics form carries the labelled, merged-column-filled rows beside the raw rows; another table does not")
    func logisticsFromImageOCR() async throws {
        let grid = [["Uhrzeit", "Gleis", "Anzahl", "Waggons", "Station", "Abr.", "Halle", "Datum", "Uhrzeit DB", "Begründung"],
                    ["08:00", "3", "2", "12", "Delhi", "A", "H1", "2026-07-01", "09:00", "late"],
                    ["", "4", "1", "6", "Mumbai", "B", "H2", "", "", ""]]
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let doc = try await ImageStructuralParser(ocr: TableOCR(grid: grid)).parse(data: png, filename: "rota.png", type: .png,
                                                                                  logicalSourceID: UUID(), sourceVersionID: UUID())
        let table = try #require(doc.blocks.first { $0.kind == .table })
        guard case .string(let kind)? = table.attributes["logisticsKind"]?.value else { Issue.record("no logistics kind: \(table.attributes.keys)"); return }
        #expect(kind == "type2")
        guard case .array(let rows)? = table.attributes["logisticsRows"]?.value else { Issue.record("no logistics rows"); return }
        #expect(rows.count == 2, "header row dropped")
        if case .array(let second) = rows[1], case .string(let time)? = second.first {
            #expect(time == "08:00", "merged Uhrzeit forward-filled")
            if case .string(let station)? = second.dropFirst(4).first { #expect(station == "Mumbai") }
        } else {
            Issue.record("logistics row is not an array of strings: \(rows[1])")
        }
        #expect(doc.blocks.filter { $0.kind == .tableRow }.count == 3, "the raw OCR rows stay as the evidence")
        let other = try await ImageStructuralParser(ocr: TableOCR(grid: [["Name", "Qty"], ["Acme", "3"]])).parse(
            data: png, filename: "grid.png", type: .png, logicalSourceID: UUID(), sourceVersionID: UUID())
        #expect(other.blocks.first { $0.kind == .table }?.attributes["logisticsKind"] == nil)
    }
}
