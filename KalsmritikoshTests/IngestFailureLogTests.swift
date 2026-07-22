//
//  IngestFailureLogTests.swift
//  KalsmritikoshTests
//
//  ING-002 (collected-failures half) — the batch failure collector accumulates
//  per-file failures/timeouts, and the summary reports succeeded vs failed honestly.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Ingest failure collection (ING-002)")
struct IngestFailureLogTests {

    @Test("Collector accumulates failures across concurrent recorders")
    func collects() async {
        let log = IngestFailureLog()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    await log.record(IngestFailure(
                        fileName: "f\(i).pdf",
                        stage: i.isMultiple(of: 2) ? .failed : .timeout,
                        reason: "r\(i)"))
                }
            }
        }
        #expect(await log.count == 10)
        #expect(await log.all().count == 10)
    }

    @Test("Summary reports totals and separates timeouts")
    func summary() {
        let fails = [
            IngestFailure(fileName: "a.pdf", stage: .failed, reason: "parse error"),
            IngestFailure(fileName: "b.mbox", stage: .timeout, reason: "exceeded budget"),
        ]
        let s = IngestBatchSummary(succeeded: 8, failures: fails)
        #expect(s.total == 10)
        #expect(s.failedCount == 2)
        #expect(s.timedOut.map(\.fileName) == ["b.mbox"])
        #expect(s.headline.contains("8 of 10"))
    }

    @Test("All-success summary reads clean")
    func allSuccess() {
        let s = IngestBatchSummary(succeeded: 5, failures: [])
        #expect(s.total == 5)
        #expect(s.failedCount == 0)
        #expect(s.headline.contains("all succeeded"))
    }
}
