//
//  IngestWorkerPool.swift
//  Kalsmritikosh
//
//  Unified-path program (owner, 2026-11-22), PERF-14 — runs the batches of a large folder import on as
//  many workers as the Mac can carry NOW. The count comes from `WorkerBudget` (free + inactive memory,
//  half kept back for the system and the app, a per-worker share, the memory-pressure level from the
//  app's MemoryPressureGovernor when there is one, and the thermal state), stays between 1 and the
//  active cores − 1, and is asked again before every new batch starts — so a run that began on a cool,
//  idle Mac narrows when memory tightens or the Mac heats up, and widens again when it recovers.
//  Batches already running are never interrupted; the pool only holds back the next one.
//
//  Not tested yet (owner 2026-11-22: implement now, test later).
//

import Foundation
import os

public nonisolated struct IngestWorkerPool: Sendable {
    /// Memory one import worker is assumed to hold at its peak (parsers, text recognition, the
    /// language models of entity extraction, its own shard connection). Deliberately generous.
    public static let defaultPerWorkerBytes: UInt64 = 768 * 1_048_576

    public let perWorkerBytes: UInt64
    /// The current memory-pressure level (the app's governor), or nil when it has none.
    public let pressure: @Sendable () async -> MemoryPressureLevel?

    public init(perWorkerBytes: UInt64 = IngestWorkerPool.defaultPerWorkerBytes,
                pressure: @escaping @Sendable () async -> MemoryPressureLevel?) {
        self.perWorkerBytes = perWorkerBytes
        self.pressure = pressure
    }

    /// The Mac's budget now.
    public func budget() async -> WorkerBudget {
        WorkerBudget.current(pressure: await pressure() ?? .normal)
    }

    /// How many workers may run now.
    public func workerCount() async -> Int {
        await budget().workers(perWorkerBytes: perWorkerBytes)
    }

    /// Run `work` once per batch, at most `workerCount()` at a time, re-checking the count before each
    /// new batch. `shouldContinue` is asked before starting a batch (a Stop ends the run cleanly — the
    /// batches already started finish). Returns the indices of the batches that were started.
    @discardableResult
    public func run<Batch: Sendable>(
        _ batches: [Batch],
        shouldContinue: @escaping @Sendable () async -> Bool = { true },
        work: @escaping @Sendable (Int, Batch) async -> Void
    ) async -> [Int] {
        guard !batches.isEmpty else { return [] }
        var started: [Int] = []
        await withTaskGroup(of: Int.self) { group in
            var running = 0
            var next = 0
            while next < batches.count {
                guard await shouldContinue() else {
                    KalsmritikoshLog.ingestion.info("IngestWorkerPool: stopped before batch \(next + 1, privacy: .public) of \(batches.count, privacy: .public)")
                    break
                }
                let allowed = await workerCount()
                if running < allowed {
                    let index = next
                    let batch = batches[index]
                    group.addTask { await work(index, batch); return index }
                    started.append(index)
                    running += 1
                    next += 1
                    KalsmritikoshLog.ingestion.info("IngestWorkerPool: batch \(index + 1, privacy: .public)/\(batches.count, privacy: .public) started (\(running, privacy: .public) running, \(allowed, privacy: .public) allowed now)")
                } else if await group.next() != nil {
                    running -= 1
                } else {
                    running = 0
                }
            }
            for await _ in group {}
        }
        return started
    }
}
