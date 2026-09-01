//
//  WorkerPoolOrderTests.swift
//  KalsmritikoshTests
//
//  UNIT E — the taxonomy's last site: WorkerPool collected TaskGroup
//  results in COMPLETION order, so thread scheduling reordered expert
//  findings per ask ("speed given authority") and a membership-sensitive
//  merge downstream flipped ±1 boundary source — the Q2/Q7 confidence
//  flicker that survived every other law. The red is DETERMINISTIC by
//  construction (owner binding #2): controlled completion latencies — the
//  LAST-submitted task finishes FIRST via a sleep gradient, so pre-fix
//  collection provably inverts submission order; post-fix, results return
//  index-slotted regardless of who finishes first. Execution stays
//  concurrent — only the collection is lawful.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Unit E — worker-pool results return in submission order, not completion order")
struct WorkerPoolOrderTests {

    @Test("A reversed completion gradient cannot reorder results")
    func submissionOrderSurvivesCompletionInversion() async {
        let pool = WorkerPool(maxConcurrentWorkers: 8)
        // Task i sleeps (7-i)×80ms: the LAST submitted finishes FIRST.
        let tasks: [@Sendable () async throws -> Int] = (0..<8).map { i in
            {
                try? await Task.sleep(nanoseconds: UInt64(7 - i) * 80_000_000)
                return i
            }
        }
        let results = await pool.run(tasks).compactMap { try? $0.get() }
        print("UNITE order: \(results) (submission order = 0...7)")
        #expect(results == Array(0..<8),
                "completion order leaked into results — speed has authority again")
    }
}
