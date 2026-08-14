//
//  ANNBenchmarkTests.swift
//  KalsmritikoshTests
//
//  P9.3 step 8 — the benchmark harness itself is proven at a CI-safe size so
//  the SC1 owner-hardware run only has to pass bigger sizes to the SAME
//  entry point (larger sizes via KALSMRITIKOSH_ANN_BENCH_SIZES on an
//  owner machine; marketing figures remain tested-figure-only).
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("P9.3 — ANN benchmark harness", .serialized)
struct ANNBenchmarkTests {

    @Test("A CI-safe run produces sane metrics and a well-formed report")
    func ciSafeRun() async throws {
        // Owner scale runs pass e.g. "100000,500000" via the env variable;
        // CI always covers the harness at a small size.
        let envSizes = ProcessInfo.processInfo.environment["KALSMRITIKOSH_ANN_BENCH_SIZES"]?
            .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let sizes = (envSizes?.isEmpty == false) ? envSizes! : [2_000]
        // KALSMRITIKOSH_ANN_BENCH_DIM lets the owner scale run measure at the
        // real embedding width (384 for BGE); CI stays fast at 64.
        let dim = ProcessInfo.processInfo.environment["KALSMRITIKOSH_ANN_BENCH_DIM"].flatMap { Int($0) } ?? 64

        let metrics = try await ANNBenchmark(queryCount: 20, insertCount: 20)
            .run(sizes: sizes, dimension: dim, seed: 0xBEEF)
        #expect(metrics.count == sizes.count)
        for m in metrics {
            #expect(m.size >= 2_000)
            #expect(m.cellCount >= 16, "cell count \(m.cellCount)")
            #expect(m.buildSeconds > 0)
            #expect(m.recallAt10 >= 0.90, "recall \(m.recallAt10) below harness floor")
            #expect(m.diskBytesAdded > 0)
            #expect(m.queryP95Ms >= m.queryP50Ms)
        }

        let report = ANNBenchmark.renderMarkdown(metrics)
        #expect(report.contains("| size |"))
        #expect(report.contains("recall@10"))
        print("ANN-BENCH:\n\(report)")
        // XCTest does not forward the test process's stdout to xcodebuild, so
        // the scale run also writes the table to KALSMRITIKOSH_ANN_BENCH_OUT
        // when set — a durable artifact for the owner-hardware SC1 evidence.
        if let out = ProcessInfo.processInfo.environment["KALSMRITIKOSH_ANN_BENCH_OUT"], !out.isEmpty {
            try? report.write(toFile: out, atomically: true, encoding: .utf8)
        }
    }
}
