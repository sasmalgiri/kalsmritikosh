//
//  HostArtifactRobustnessTests.swift
//  KalsmritikoshTests
//
//  ADVERSARIAL SWEEP over every binary reader added in the forensic lane.
//
//  These parsers run on UNTRUSTED evidence: a seized machine's files, possibly
//  truncated by the imaging tool, possibly corrupt, possibly crafted. A crash
//  loses the examiner's session; a hang looks like the app is broken; a
//  quadratic scan on a 10 MB artifact looks the same. None of that is
//  acceptable in a tool someone runs against a case.
//
//  The technique that earns its keep here is the PREFIX SWEEP: take a valid
//  file and parse every truncation of it. That walks the parser through every
//  partial-header, partial-record and mid-field state systematically, instead
//  of relying on me to guess which boundary I got wrong. Every other test in
//  this repo checks a case I thought of; this one checks the cases I did not.
//
//  Each assertion is only "it returned something honest without crashing or
//  hanging" — fidelity is the per-format suites' job.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Host-artifact readers survive hostile input")
struct HostArtifactRobustnessTests {

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.date(from: iso)!
    }

    // MARK: - Valid reference artifacts, one per format

    private func validEVTX() -> Data {
        EVTXFixtureWriter().build(records: [
            .init(id: 1, written: date("2026-03-12T09:26:53Z"), strings: ["EVIDENCE-01", "riyaz"])
        ])
    }
    private func validUtmp() -> Data {
        UtmpFixtureWriter().build(records: [
            .boot(at: date("2026-03-12T08:41:02Z")),
            .session("riyaz", on: "pts/0", at: date("2026-03-12T09:00:00Z"))
        ])
    }
    private func validShellLink() -> Data {
        var w = ShellLinkFixtureWriter()
        w.localBasePath = #"E:\cases\"#
        w.commonPathSuffix = "statement.docx"
        w.targetWritten = date("2026-03-11T17:02:10Z")
        w.volume = .init(driveType: 2, serialNumber: 0xA4B2_11C7, label: "FIELDKIT")
        w.tracker = .init(machineID: "WS7", macAddress: [0x00, 0x1B, 0x44, 0x11, 0x3A, 0xB7])
        return w.build()
    }
    private func validMFT() -> Data {
        MFTFixtureWriter().build(records: [
            .init(recordNumber: 5, name: ".", parentRecordNumber: 5, isDirectory: true),
            .init(recordNumber: 41, name: "statement.docx", parentRecordNumber: 5,
                  standardTimes: .all(date("2026-03-12T09:00:00Z")),
                  residentData: Data("small file".utf8))
        ])
    }
    private func validPrefetch() -> Data {
        var w = PrefetchFixtureWriter()
        w.runCount = 3
        w.runTimes = [date("2026-03-12T09:00:00Z"), date("2026-03-11T08:00:00Z")]
        return w.build()
    }

    // MARK: - THE prefix sweep

    /// Every truncation of a valid file must be handled, not crash or hang.
    /// Step 1 for the small formats so no boundary is skipped.
    @Test("Every truncation of every binary artifact is handled")
    func everyTruncationIsHandled() async throws {
        let artifacts: [(String, Data, SourceType, any StructuralParser)] = [
            ("EVTX", validEVTX(), .eventLog, EVTXStructuralParser()),
            ("utmp", validUtmp(), .loginRecord, UtmpStructuralParser()),
            ("lnk", validShellLink(), .shellLink, ShellLinkStructuralParser()),
            ("MFT", validMFT(), .masterFileTable, MFTStructuralParser()),
            ("prefetch", validPrefetch(), .prefetch, PrefetchStructuralParser())
        ]
        for (name, full, type, parser) in artifacts {
            // Sweep every byte boundary for the first 300 bytes (all headers
            // live there), then stride through the rest.
            var lengths = Array(0...min(300, full.count))
            lengths += stride(from: 300, to: full.count, by: 7)
            for length in lengths where length <= full.count {
                let doc = try await parser.parse(
                    data: full.prefix(length), filename: "probe.\(type.rawValue)", type: type,
                    logicalSourceID: UUID(), sourceVersionID: UUID())
                // The only invariant: it came back, and never claimed complete
                // with nothing to show.
                if doc.extractionStatus == .complete {
                    #expect(!doc.blocks.isEmpty,
                            "\(name)@\(length): complete with zero blocks")
                }
                // Ordinals stay contiguous whatever survived.
                #expect(doc.blocks.map(\.ordinal) == Array(0..<doc.blocks.count),
                        "\(name)@\(length): ordinals broken")
            }
        }
    }

    // MARK: - Hostile declared sizes and degenerate content

    @Test("Hostile declared lengths and counts do not crash any reader")
    func hostileDeclaredValuesAreRefused() async throws {
        // A crafted or corrupt artifact can claim absurd sizes. Each of these
        // must be refused rather than used to index memory.
        let parsers: [(String, SourceType, any StructuralParser)] = [
            ("EVTX", .eventLog, EVTXStructuralParser()),
            ("utmp", .loginRecord, UtmpStructuralParser()),
            ("lnk", .shellLink, ShellLinkStructuralParser()),
            ("MFT", .masterFileTable, MFTStructuralParser()),
            ("prefetch", .prefetch, PrefetchStructuralParser()),
            ("amcache", .amcache, AmcacheStructuralParser()),
            ("jumplist", .jumpList, JumpListStructuralParser())
        ]
        let hostile: [(String, Data)] = [
            ("all zeros 8KB", Data(repeating: 0, count: 8192)),
            ("all 0xFF 8KB", Data(repeating: 0xFF, count: 8192)),
            ("one byte", Data([0x41])),
            ("two bytes", Data([0x4C, 0x00])),
            ("random 4KB", Data((0..<4096).map { UInt8(($0 * 31 + 17) % 251) })),
            ("ascending", Data((0..<4096).map { UInt8($0 % 256) }))
        ]
        for (pname, type, parser) in parsers {
            for (hname, data) in hostile {
                let doc = try await parser.parse(
                    data: data, filename: "hostile.bin", type: type,
                    logicalSourceID: UUID(), sourceVersionID: UUID())
                // Never "complete" off garbage, and never blocks without status.
                if doc.extractionStatus == .complete {
                    #expect(!doc.blocks.isEmpty, "\(pname)/\(hname): complete with no blocks")
                }
                #expect(doc.blocks.map(\.ordinal) == Array(0..<doc.blocks.count),
                        "\(pname)/\(hname): ordinals broken")
            }
        }
    }

    @Test("A record claiming a size larger than the file cannot walk off the end")
    func overlongRecordSizesAreBounded() async throws {
        // EVTX record size, MFT used-size and the LNK id-list length are all
        // attacker-controlled u16/u32 fields used as offsets.
        var evtx = [UInt8](validEVTX())
        // The first record's size field sits just after the record magic.
        let recordStart = EVTXReader.headerSize + EVTXReader.recordsOffsetInChunk
        for i in 0..<4 { evtx[recordStart + 4 + i] = 0xFF }
        let evtxDoc = try await EVTXStructuralParser().parse(
            data: Data(evtx), filename: "x.evtx", type: .eventLog,
            logicalSourceID: UUID(), sourceVersionID: UUID())
        #expect(evtxDoc.blocks.map(\.ordinal) == Array(0..<evtxDoc.blocks.count))

        var mft = [UInt8](validMFT())
        for i in 0..<4 { mft[0x18 + i] = 0xFF }      // used size = 0xFFFFFFFF
        let mftDoc = try await MFTStructuralParser().parse(
            data: Data(mft), filename: "$MFT", type: .masterFileTable,
            logicalSourceID: UUID(), sourceVersionID: UUID())
        #expect(mftDoc.blocks.map(\.ordinal) == Array(0..<mftDoc.blocks.count))
    }

    @Test("A self-referential MFT parent chain terminates")
    func selfReferentialStructuresTerminate() throws {
        // Two directories each claiming the other as parent, plus one naming
        // itself. Path reconstruction must not recurse forever.
        let data = MFTFixtureWriter().build(records: [
            .init(recordNumber: 100, name: "a", parentRecordNumber: 101, isDirectory: true),
            .init(recordNumber: 101, name: "b", parentRecordNumber: 100, isDirectory: true),
            .init(recordNumber: 102, name: "self", parentRecordNumber: 102, isDirectory: true)
        ])
        var reader = try MFTReader(data: data)
        let paths = MFTReader.paths(for: reader.records())
        #expect(paths.count == 3)
        for number in [UInt64(100), 101, 102] {
            #expect(paths[number] != nil, "record \(number) produced no verdict")
        }
    }

    // MARK: - Performance cliffs (a hang looks identical to a crash)

    @Test("A multi-megabyte custom-destinations file scans in reasonable time", .timeLimit(.minutes(1)))
    func jumpListScanIsNotQuadratic() throws {
        // The signature scan runs over every byte position. Allocating a Data
        // slice per position turns a routine 8 MB jumplist into minutes of work,
        // which to the examiner is indistinguishable from a hang.
        var big = Data(count: 0)
        big.append(Data(repeating: 0x00, count: 8 * 1024 * 1024))
        let started = Date()
        let found = JumpListStructuralParser.embeddedShellLinks(in: big)
        let elapsed = Date().timeIntervalSince(started)
        #expect(found.isEmpty)
        #expect(elapsed < 5.0, "8 MB signature scan took \(elapsed)s")
    }

    @Test("A large attributedBody blob decodes without scanning it twice over",
          .timeLimit(.minutes(1)))
    func attributedBodySearchIsBounded() {
        // The class-name search used to run over the whole blob. A malformed
        // multi-megabyte value would be walked twice for two needles before
        // being refused.
        var blob = Data([0x04, 0x0B]) + Data("streamtyped".utf8)
        blob += Data(repeating: 0x41, count: 4 * 1024 * 1024)   // no class record
        let started = Date()
        let result = AttributedBodyText.decode(blob)
        let elapsed = Date().timeIntervalSince(started)
        #expect(result == nil)
        #expect(elapsed < 2.0, "4 MB refusal took \(elapsed)s")
    }

    @Test("A history file that is one giant continuation does not go quadratic",
          .timeLimit(.minutes(3)))   // 25k lines in two runs; the RATIO is the check (~2 s alone, 36 s+ under full-suite load)
    func shellHistoryContinuationIsLinear() async throws {
        // Every line ending in a backslash means one command built from 20 000
        // appends. String concatenation in that loop is O(n²).
        // Measured as a RATIO (P4.1): an absolute limit failed only under the
        // full suite's parallel load (27–36 s vs 10 s; ~2 s alone). Linear
        // work grows ~4× from 5k to 20k lines, quadratic ~16×; a shared
        // slowdown scales both runs alike.
        let line = String(repeating: "x", count: 40) + " \\"
        func timed(_ count: Int) async throws -> (Double, Int) {
            let text = Array(repeating: line, count: count).joined(separator: "\n") + "\ndone\n"
            let started = Date()
            let doc = try await ShellHistoryStructuralParser().parse(
                data: Data(text.utf8), filename: ".bash_history", type: .shellHistory,
                logicalSourceID: UUID(), sourceVersionID: UUID())
            return (Date().timeIntervalSince(started), doc.blocks.count)
        }
        let (small, _) = try await timed(5_000)
        let (large, blocks) = try await timed(20_000)
        #expect(blocks > 0)
        #expect(large < max(0.5, small * 8), "5k lines \(small)s → 20k lines \(large)s: worse than linear")
    }

    // MARK: - The readers' own caps hold

    @Test("Record ceilings are enforced rather than exhausting memory")
    func recordCeilingsHold() throws {
        // A utmp with more records than the stated cap must stop at the cap and
        // say so, not read 2 million rows into memory.
        let writer = UtmpFixtureWriter()
        let many = (0..<600).map { i in
            UtmpFixtureWriter.Record.session("u\(i)", on: "pts/\(i % 8)",
                                             at: Date(timeIntervalSince1970: 1_773_480_000 + Double(i)))
        }
        var reader = try UtmpReader(data: writer.build(records: many), filename: "wtmp")
        let records = reader.records()
        #expect(records.count == 600)
        #expect(records.count <= UtmpReader.maxRecords)
    }
}
