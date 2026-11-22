//
//  PipelineStages.swift
//  Kalsmritikosh
//
//  Unified path PERF-19 (owner 2026-11-22, round 2) — not tested yet.
//
//  Every step of the import pipeline runs as its OWN bounded set of concurrent workers:
//
//    read (custody hash, routing) → parse → OCR (per page) → transcription → clean + chunk →
//    extraction → embedding (batched, Neural Engine) → write (one writer per shard ledger)
//
//  Each stage has a process-wide permit pool (`StagePermits`, an async semaphore whose size can change
//  while work runs). Its width comes from `WorkerBudget` — free memory, the kernel's memory-pressure
//  level, the thermal state — and the core count, and is re-computed (a) on every memory-pressure event
//  (`installPressureResponder`) and (b) whenever a permit is asked for and the last sizing is older than
//  two seconds (thermal changes, memory freed). Narrowing never interrupts work in flight; it only holds
//  back the next item. Stages hand work to each other through `BoundedChannel`, whose `send` suspends
//  when the buffer is full — back-pressure, so a fast reader can never run ahead of a slow OCR stage
//  and fill memory.
//
//  Rule: a holder of a stage's permit never asks for a permit of the SAME stage (no nesting), so a
//  width of 1 can never deadlock.
//

import Foundation
import os

/// One step of the import pipeline.
public nonisolated enum PipelineStage: String, Sendable, CaseIterable, Hashable {
    case read, parse, ocr, transcribe, chunk, extract, embed, write
}

/// An async semaphore with a capacity that can be changed while it is in use.
public actor StagePermits {
    public nonisolated let stage: PipelineStage
    private var capacity: Int
    private var inUse = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(stage: PipelineStage, capacity: Int) {
        self.stage = stage
        self.capacity = max(1, capacity)
    }

    public func currentCapacity() -> Int { capacity }
    public func running() -> Int { inUse }

    /// Wait for a permit (FIFO).
    public func acquire() async {
        if inUse < capacity, waiters.isEmpty {
            inUse += 1
            return
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in waiters.append(c) }
        // `release`/`resize` counted this permit for us before resuming.
    }

    public func release() {
        inUse = max(0, inUse - 1)
        wake()
    }

    /// Change the width. Widening wakes waiters at once; narrowing lets running work finish.
    public func resize(_ newCapacity: Int) {
        let n = max(1, newCapacity)
        guard n != capacity else { return }
        KalsmritikoshLog.ingestion.info("PipelineStages: \(self.stage.rawValue, privacy: .public) width \(self.capacity, privacy: .public) → \(n, privacy: .public)")
        capacity = n
        wake()
    }

    private func wake() {
        while inUse < capacity, !waiters.isEmpty {
            inUse += 1
            waiters.removeFirst().resume()
        }
    }
}

/// The process-wide stage pools and their live sizing.
public nonisolated enum PipelineStages {
    private static let gates: [PipelineStage: StagePermits] = {
        let budget = WorkerBudget.current()
        var out: [PipelineStage: StagePermits] = [:]
        for s in PipelineStage.allCases { out[s] = StagePermits(stage: s, capacity: width(for: s, budget: budget)) }
        return out
    }()

    /// The newest memory-pressure level reported to the stages.
    private static let pressure = OSAllocatedUnfairLock<MemoryPressureLevel>(initialState: .normal)
    /// When the widths were last computed (seconds since the reference date).
    private static let lastSized = OSAllocatedUnfairLock<Double>(initialState: 0)
    /// Whether the pressure responder is installed.
    private static let responderInstalled = OSAllocatedUnfairLock<Bool>(initialState: false)
    /// Re-size at most this often when nothing else asks for it.
    static let refreshInterval: TimeInterval = 2

    /// Memory one in-flight item of a stage is assumed to hold at its peak.
    static func perItemBytes(_ stage: PipelineStage) -> UInt64 {
        switch stage {
        case .read: return 16 * 1_048_576            // hashing streams in 1 MiB pieces
        case .parse: return 256 * 1_048_576
        case .ocr: return 192 * 1_048_576            // a 300-dpi page bitmap + Vision's working set
        case .transcribe: return 1_024 * 1_048_576   // speech models
        case .chunk: return 64 * 1_048_576
        case .extract: return 256 * 1_048_576       // language models of entity extraction
        case .embed: return 512 * 1_048_576          // one batch of 64 × 512-token inputs + outputs
        case .write: return 128 * 1_048_576          // one shard connection's page cache
        }
    }

    /// The width a stage may have under `budget`: memory share and cores, narrowed by pressure and heat.
    public static func width(for stage: PipelineStage, budget: WorkerBudget) -> Int {
        let cores = max(1, budget.activeCores - 1)
        let byMemory = Int(min(UInt64(64), budget.shareableBytes / max(1, perItemBytes(stage))))
        var n: Int
        switch stage {
        case .read: n = min(cores * 2, 16)           // I/O bound
        case .parse, .chunk, .extract: n = cores
        case .ocr: n = min(cores, 8)                 // Vision spreads over Neural Engine, GPU and CPU
        case .transcribe: n = max(1, cores / 4)
        case .embed: n = 2                           // batched on the Neural Engine: two batches overlap tokenising and inference
        case .write: n = cores                       // one writer per shard ledger
        }
        n = max(1, min(n, max(1, byMemory)))
        switch budget.pressure {
        case .critical: n = 1
        case .warning: n = max(1, n / 2)
        case .normal: break
        }
        switch budget.thermal {
        case .serious, .critical: n = 1
        case .fair: n = max(1, n - 1)
        default: break
        }
        return n
    }

    /// The pool of `stage`.
    public static func gate(_ stage: PipelineStage) -> StagePermits {
        // Every case is in the dictionary by construction.
        gates[stage] ?? StagePermits(stage: stage, capacity: 1)
    }

    /// The width `stage` has right now (re-sized first when the last sizing is stale).
    public static func currentWidth(_ stage: PipelineStage) async -> Int {
        await refreshIfStale()
        return await gate(stage).currentCapacity()
    }

    /// Re-compute every stage's width from the Mac as it is now.
    public static func refresh(pressure level: MemoryPressureLevel? = nil) async {
        if let level { pressure.withLock { $0 = level } }
        lastSized.withLock { $0 = Date().timeIntervalSinceReferenceDate }
        let budget = WorkerBudget.current(pressure: pressure.withLock { $0 })
        for s in PipelineStage.allCases { await gate(s).resize(width(for: s, budget: budget)) }
    }

    static func refreshIfStale() async {
        let now = Date().timeIntervalSinceReferenceDate
        let stale = lastSized.withLock { last -> Bool in
            guard now - last >= refreshInterval else { return false }
            last = now
            return true
        }
        if stale { await refresh() }
    }

    /// Follow the app's memory-pressure governor: every level change re-sizes the stages at once.
    /// Idempotent (the governor keeps its responders for the life of the app).
    public static func installPressureResponder(on governor: MemoryPressureGovernor?) async {
        guard let governor else { return }
        let first = responderInstalled.withLock { installed -> Bool in
            if installed { return false }
            installed = true
            return true
        }
        guard first else { return }
        await governor.addResponder { level in await PipelineStages.refresh(pressure: level) }
        await refresh(pressure: await governor.latestReportedLevel())
    }

    /// Run `body` holding one permit of `stage`. Never call it again for the same stage inside `body`.
    public static func withPermit<T>(_ stage: PipelineStage, _ body: () async throws -> T) async rethrows -> T {
        await refreshIfStale()
        let g = gate(stage)
        await g.acquire()
        do {
            let value = try await body()
            await g.release()
            return value
        } catch {
            await g.release()
            throw error
        }
    }
}

/// A bounded, back-pressured hand-off between two stages: `send` suspends while the buffer is full,
/// `receive` suspends while it is empty and returns nil once the channel is finished and drained.
public actor BoundedChannel<Element: Sendable> {
    public nonisolated let capacity: Int
    private var buffer: [Element] = []
    private var head = 0
    private var finished = false
    private var senders: [CheckedContinuation<Void, Never>] = []
    private var receivers: [CheckedContinuation<Element?, Never>] = []

    public init(capacity: Int) { self.capacity = max(1, capacity) }

    private var count: Int { buffer.count - head }

    /// Hand `element` on; waits while the buffer is full. Dropped (returns false) once finished.
    @discardableResult
    public func send(_ element: Element) async -> Bool {
        while !finished, receivers.isEmpty, count >= capacity {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in senders.append(c) }
        }
        guard !finished else { return false }
        if !receivers.isEmpty {
            receivers.removeFirst().resume(returning: element)
            return true
        }
        buffer.append(element)
        return true
    }

    /// The next element, or nil when finished and drained.
    public func receive() async -> Element? {
        if count > 0 {
            let e = buffer[head]
            head += 1
            if head > 64, head * 2 > buffer.count { buffer.removeFirst(head); head = 0 }
            if !senders.isEmpty { senders.removeFirst().resume() }
            return e
        }
        if finished { return nil }
        return await withCheckedContinuation { (c: CheckedContinuation<Element?, Never>) in receivers.append(c) }
    }

    /// No more elements: waiting receivers get nil, waiting senders return.
    public func finish() {
        guard !finished else { return }
        finished = true
        for r in receivers { r.resume(returning: nil) }
        receivers.removeAll()
        for s in senders { s.resume() }
        senders.removeAll()
    }
}

/// Small combinators over the stage pools.
public nonisolated enum StagedPipeline {
    /// Transform `inputs` with up to the stage's live width at a time (each item holding one permit of
    /// `stage`) and send each non-nil result into `channel` as it completes; the channel is finished at
    /// the end. `shouldContinue` is asked before each item is started.
    public static func feed<In: Sendable, Out: Sendable>(
        _ inputs: [In], stage: PipelineStage, into channel: BoundedChannel<Out>,
        shouldContinue: @escaping @Sendable () async -> Bool = { true },
        transform: @escaping @Sendable (In) async -> Out?
    ) async {
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for item in inputs {
                guard await shouldContinue() else { break }
                while running >= (await PipelineStages.currentWidth(stage)) {
                    if await group.next() != nil { running -= 1 } else { running = 0 }
                }
                group.addTask {
                    let out = await PipelineStages.withPermit(stage) { await transform(item) }
                    if let out { await channel.send(out) }
                }
                running += 1
            }
            for await _ in group {}
        }
        await channel.finish()
    }

    /// `transform` over `inputs` with up to the stage's live width at a time; results in input order.
    public static func map<In: Sendable, Out: Sendable>(
        _ inputs: [In], stage: PipelineStage, transform: @escaping @Sendable (Int, In) async -> Out
    ) async -> [Out] {
        guard inputs.count > 1 else {
            var single: [Out] = []
            for (i, x) in inputs.enumerated() { single.append(await PipelineStages.withPermit(stage) { await transform(i, x) }) }
            return single
        }
        var results = [Out?](repeating: nil, count: inputs.count)
        await withTaskGroup(of: (Int, Out).self) { group in
            var running = 0
            for (i, item) in inputs.enumerated() {
                while running >= (await PipelineStages.currentWidth(stage)) {
                    if let (j, v) = await group.next() { results[j] = v; running -= 1 } else { running = 0 }
                }
                group.addTask { (i, await PipelineStages.withPermit(stage) { await transform(i, item) }) }
                running += 1
            }
            for await (j, v) in group { results[j] = v }
        }
        return results.compactMap { $0 }
    }
}
