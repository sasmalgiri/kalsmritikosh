//
//  ScaleRunTests.swift
//  KalsmritikoshTests
//
//  W0-1 — the scale-run summary's verdicts, and a simulated scale run: a large
//  synthetic mailbox streamed through the real mbox loader while the process
//  footprint is sampled the same way ScaleRunRecorder samples it. The summary is
//  attached to the test result as `scale-run.txt` (xcresulttool export attachments).
//

import Foundation
import SQLite3
import Testing
@testable import Kalsmritikosh

@Suite("W0-1 scale run")
struct ScaleRunTests {

    private func series(_ mib: (Int) -> Double, count: Int = 120) -> [ScaleSample] {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        return (0..<count).map { i in
            ScaleSample(at: t0.addingTimeInterval(Double(i) * 10),
                        footprint: UInt64(mib(i) * ScaleRunSummary.mib), documents: i * 50)
        }
    }

    @Test func flatRunIsReportedFlat() {
        let s = series { 400 + Double($0 % 3) }            // jitter, no growth
        let text = ScaleRunSummary.text(s, hardware: "test")
        #expect(text.contains("— flat"))
        #expect(text.contains("5950 documents read"))
        #expect(text.contains("every 10 s on average"))
    }

    @Test func fallingRunIsNotCalledGrowth() {
        let s = series { 500 - Double($0) }                // memory released over the run
        #expect(ScaleRunSummary.text(s, hardware: "test").contains("— flat"))
    }

    @Test func leakingRunIsReportedNotFlat() {
        let s = series { 300 + Double($0) * 2 }            // +2 MiB every 10 s = +720 MiB/hour
        let slope = try? #require(ScaleRunSummary.lateSlopeMiBPerHour(s))
        #expect(abs((slope ?? 0) - 720) < 1)
        #expect(ScaleRunSummary.text(s, hardware: "test").contains("NOT flat"))
    }

    @Test func shortRunsGetNoTrendVerdict() {
        let s = series({ 300 + Double($0) * 2 }, count: 30)   // 5 minutes
        let text = ScaleRunSummary.text(s, hardware: "test")
        #expect(text.contains("not judged"))
        #expect(!text.contains("NOT flat") && !text.contains("— flat"))
    }

    @Test func tooFewSamplesSaySo() {
        #expect(ScaleRunSummary.text(series({ _ in 1 }, count: 1), hardware: "x").hasPrefix("Not enough samples"))
    }

    /// ~100 MB, 50,000 messages, streamed in bounded batches; nothing is retained between batches.
    @Test(.timeLimit(.minutes(10)))
    func simulatedLargeMailboxStaysBounded() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("archive.mbox")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        let messages = 50_000
        let filler = String(repeating: "Quarterly figures, minutes and follow-up actions for the project review. ", count: 24)
        var chunk = ""
        for i in 0..<messages {
            chunk += "From sender\(i % 977)@example.com Mon Jan  1 00:00:00 2024\n"
            chunk += "From: Sender \(i % 977) <sender\(i % 977)@example.com>\nTo: team@example.com\n"
            chunk += "Subject: Review \(i)\nDate: Mon, 1 Jan 2024 10:\(String(format: "%02d", i % 60)):00 +0000\n\n"
            chunk += "Message \(i). \(filler)\n\n"
            if i % 1000 == 999 { try handle.write(contentsOf: Data(chunk.utf8)); chunk = "" }
        }
        try handle.write(contentsOf: Data(chunk.utf8))
        try handle.close()
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0

        let loader = EmailLoader()
        try #require(loader.streamsRecords(type: .mbox))
        var samples = [ScaleSample(at: Date(), footprint: ProcessFootprint.bytes(), documents: 0)]
        var read = 0, batchesSeen = 0
        try await loader.streamRecords(fileAt: url, type: .mbox,
                                       budget: StreamBatchBudget(maxObjects: 250, maxContentBytes: 8 << 20)) { batch in
            read += batch.count
            batchesSeen += 1
            if batchesSeen % 4 == 0 {
                samples.append(ScaleSample(at: Date(), footprint: ProcessFootprint.bytes(), documents: read))
            }
        }
        samples.append(ScaleSample(at: Date(), footprint: ProcessFootprint.bytes(), documents: read))

        let hardware = await MainActor.run { ScaleRunRecorder.hardware() }
        let summary = ScaleRunSummary.text(samples, hardware: hardware)
        Attachment.record("file=\(size) bytes, messages=\(messages)\n\(summary)\n", named: "scale-run.txt")

        #expect(read == messages)
        let baseline = Double(samples[0].footprint) / ScaleRunSummary.mib
        let peak = Double(samples.map(\.footprint).max() ?? 0) / ScaleRunSummary.mib
        // Bounded: growth stays well under the size of the file itself.
        #expect(peak - baseline < Double(size) / ScaleRunSummary.mib, "peak \(peak) MiB vs baseline \(baseline) MiB for a \(size)-byte file")
    }

    /// ~100 MB SQLite database, 300,000 text rows, through the same streaming contract.
    @Test(.timeLimit(.minutes(10)))
    func simulatedLargeSQLiteStaysBounded() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("records.sqlite")
        var h: OpaquePointer?
        try #require(sqlite3_open_v2(url.path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        let rows = 300_000
        let sql = """
            CREATE TABLE notes(id INTEGER PRIMARY KEY, author TEXT, body TEXT);
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(rows))
            INSERT INTO notes SELECT i, 'author ' || (i % 977),
              'Note ' || i || ': ' || printf('%.300c', 'x') FROM n;
            """
        try #require(sqlite3_exec(h, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(h)
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0

        var samples = [ScaleSample(at: Date(), footprint: ProcessFootprint.bytes(), documents: 0)]
        var read = 0, batchesSeen = 0
        try await SQLiteLoader().streamRecords(fileAt: url, type: .sqlite,
                                               budget: StreamBatchBudget(maxObjects: 50, maxContentBytes: 8 << 20)) { batch in
            read += batch.count
            batchesSeen += 1
            if batchesSeen % 4 == 0 {
                samples.append(ScaleSample(at: Date(), footprint: ProcessFootprint.bytes(), documents: read))
            }
        }
        samples.append(ScaleSample(at: Date(), footprint: ProcessFootprint.bytes(), documents: read))
        let hardware = await MainActor.run { ScaleRunRecorder.hardware() }
        Attachment.record("file=\(size) bytes, rows=\(rows)\n\(ScaleRunSummary.text(samples, hardware: hardware))\n",
                          named: "scale-run-sqlite.txt")

        #expect(read > 0)
        let baseline = Double(samples[0].footprint) / ScaleRunSummary.mib
        let peak = Double(samples.map(\.footprint).max() ?? 0) / ScaleRunSummary.mib
        #expect(peak - baseline < Double(size) / ScaleRunSummary.mib, "peak \(peak) MiB vs baseline \(baseline) MiB for a \(size)-byte file")
    }
}
