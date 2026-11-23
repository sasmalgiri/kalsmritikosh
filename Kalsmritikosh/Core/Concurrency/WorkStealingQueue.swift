//
//  WorkStealingQueue.swift
//  Kalsmritikosh
//
//  Speed PERF-25/26 (owner 2026-11-23) — not tested yet. Work stealing over an index range for uneven items (files of
//  very different sizes, sources with a few pages or thousands, mailboxes with ten or ten thousand messages): the range
//  is cut into one segment per worker; a worker takes items from the front of its own segment, and when that is empty it
//  splits the LARGEST remaining segment in half and takes the back half. Nothing is claimed twice; every index is
//  claimed exactly once while workers keep asking. A lock-protected value (no actor hop per claim) so synchronous code
//  (`DispatchQueue.concurrentPerform`) and async workers can share it.
//

import Foundation
import os

public nonisolated final class WorkStealingQueue: Sendable {
    private struct Segment: Sendable {
        var lower: Int
        var upper: Int
        var count: Int { upper - lower }
    }

    private let segments: OSAllocatedUnfairLock<[Segment]>
    public let workers: Int

    /// `range` cut into `workers` near-equal segments (at least one worker).
    public init(_ range: Range<Int>, workers: Int) {
        let n = max(1, workers)
        self.workers = n
        let total = range.count
        var out: [Segment] = []
        out.reserveCapacity(n)
        var lower = range.lowerBound
        for w in 0..<n {
            let share = total / n + (w < total % n ? 1 : 0)
            out.append(Segment(lower: lower, upper: lower + share))
            lower += share
        }
        segments = OSAllocatedUnfairLock(initialState: out)
    }

    /// Up to `batch` indices for `worker` from its own segment; when that is empty, the back half of the largest remaining
    /// segment is stolen first (a single remaining item is taken whole). nil when every index has been claimed.
    public func claim(worker: Int, batch: Int = 1) -> Range<Int>? {
        let take = max(1, batch)
        return segments.withLock { segs in
            let me = ((worker % segs.count) + segs.count) % segs.count
            if segs[me].count == 0 {
                guard let victim = segs.indices.max(by: { segs[$0].count < segs[$1].count }), segs[victim].count > 0 else { return nil }
                let v = segs[victim]
                let mid = v.count >= 2 ? v.lower + v.count / 2 : v.lower
                segs[me] = Segment(lower: mid, upper: v.upper)
                segs[victim].upper = mid
            }
            let s = segs[me]
            let end = min(s.upper, s.lower + take)
            segs[me].lower = end
            return s.lower..<end
        }
    }

    /// Indices not yet claimed.
    public var remaining: Int { segments.withLock { $0.reduce(0) { $0 + $1.count } } }

    // MARK: - Runners

    /// Synchronous: `body(i)` for every i in 0..<count on `workers` threads with stealing. The first error stops the
    /// others from claiming more and is rethrown (work already running finishes).
    public static func perform(count: Int, workers: Int, _ body: (Int) throws -> Void) throws {
        guard count > 0 else { return }
        let n = max(1, min(workers, count))
        if n == 1 { for i in 0..<count { try body(i) }; return }
        let queue = WorkStealingQueue(0..<count, workers: n)
        let firstError = OSAllocatedUnfairLock<Error?>(initialState: nil)
        try withoutActuallyEscaping(body) { body in
            let box = UncheckedBox(body)
            DispatchQueue.concurrentPerform(iterations: n) { w in
                while firstError.withLock({ $0 == nil }), let r = queue.claim(worker: w) {
                    for i in r {
                        do { try box.value(i) } catch {
                            firstError.withLock { if $0 == nil { $0 = error } }
                            KalsmritikoshLog.app.error("WorkStealingQueue: an item failed; the others stop claiming: \(error.localizedDescription, privacy: .private)")
                            return
                        }
                    }
                }
            }
            if let e = firstError.withLock({ $0 }) { throw e }
        }
    }

    /// Async: `workers` tasks claim indices with stealing; `body(i)` runs for every index (until cancelled). Results in
    /// index order (nil for indices not run because the task was cancelled).
    public static func map<R: Sendable>(count: Int, workers: Int, batch: Int = 1,
                                        priority: (@Sendable (Int) -> Bool)? = nil,
                                        _ body: @escaping @Sendable (Int) async -> R) async -> [R?] {
        guard count > 0 else { return [] }
        let n = max(1, min(workers, count))
        let queue = WorkStealingQueue(0..<count, workers: n)
        // Speed PERF-36 torrent (owner 2026-11-23) — not tested yet: priority items at the front of every worker's segment.
        let order = priority.map { priorityOrder(count: count, workers: n, isPriority: $0) }
        var out = [R?](repeating: nil, count: count)
        await withTaskGroup(of: [(Int, R)].self) { group in
            for w in 0..<n {
                group.addTask {
                    var done: [(Int, R)] = []
                    while !Task.isCancelled, let r = queue.claim(worker: w, batch: batch) {
                        for pos in r { let i = order?[pos] ?? pos; done.append((i, await body(i))) }
                    }
                    return done
                }
            }
            for await part in group { for (i, r) in part { out[i] = r } }
        }
        return out
    }

    /// Speed PERF-29 (owner 2026-11-23) — not tested yet. Synchronous map with stealing: `body(i)` for every i in
    /// 0..<count on up to `workers` threads, results in index order. Each slot is written by exactly one worker.
    public static func mapSync<R>(count: Int, workers: Int, _ body: (Int) -> R) -> [R] {
        guard count > 0 else { return [] }
        let n = max(1, min(workers, count))
        if n == 1 { return (0..<count).map(body) }
        let slots = UnsafeMutableBufferPointer<R?>.allocate(capacity: count)
        slots.initialize(repeating: nil)
        defer { slots.deinitialize(); slots.deallocate() }
        let out = UncheckedBox(slots)
        let queue = WorkStealingQueue(0..<count, workers: n)
        withoutActuallyEscaping(body) { body in
            let box = UncheckedBox(body)
            DispatchQueue.concurrentPerform(iterations: n) { w in
                while let r = queue.claim(worker: w, batch: 1) {
                    for i in r { out.value[i] = box.value(i) }
                }
            }
        }
        return slots.compactMap { $0 }
    }

    /// Default width for CPU-bound per-document work: what memory allows for `perItemBytes`, at most cores − 1.
    public static func cpuWidth(perItemBytes: UInt64 = 8 << 20) -> Int {
        #if DEBUG
        if let forced = TestOverride.cpuWidth { return max(1, forced) }
        #endif
        return WorkerBudget.current().workers(perWorkerBytes: perItemBytes)
    }

    #if DEBUG
    /// Speed test phase (2026-11-23): a test's own CPU width for its task tree (1 = the serial pass), so a parallel
    /// result can be compared with the serial one. The app is unchanged.
    public enum TestOverride {
        @TaskLocal public static var cpuWidth: Int?
    }
    #endif

    /// Async, no results.
    public static func forEach(count: Int, workers: Int, batch: Int = 1, priority: (@Sendable (Int) -> Bool)? = nil,
                               _ body: @escaping @Sendable (Int) async -> Void) async {
        _ = await map(count: count, workers: workers, batch: batch, priority: priority) { await body($0) }
    }

    /// Speed PERF-36 torrent (owner 2026-11-23) — not tested yet. Position → index: the range is cut into the same segments
    /// as `init`, the priority indices dealt round-robin to the FRONT of the segments (so every worker starts on priority
    /// work), the rest after them in their usual order. A steal takes a segment's back half — non-priority work.
    public static func priorityOrder(count: Int, workers: Int, isPriority: (Int) -> Bool) -> [Int] {
        let n = max(1, workers)
        let sizes = (0..<n).map { count / n + ($0 < count % n ? 1 : 0) }
        let pri = (0..<count).filter(isPriority)
        guard !pri.isEmpty, pri.count < count else { return Array(0..<count) }
        var buckets = sizes.map { [Int]().reserving($0) }
        var w = 0
        for p in pri {
            while buckets[w].count >= sizes[w] { w = (w + 1) % n }
            buckets[w].append(p)
            w = (w + 1) % n
        }
        let isPri = Set(pri)
        var rest = (0..<count).lazy.filter { !isPri.contains($0) }.makeIterator()
        for k in 0..<n { while buckets[k].count < sizes[k], let x = rest.next() { buckets[k].append(x) } }
        return buckets.flatMap { $0 }
    }

    /// The width for file copies on this Mac now: what the memory budget allows for `bufferBytes` buffers, at most 8
    /// (a disk gains little past that) and at least 1.
    public static func copyWidth(bufferBytes: Int = StreamingFileCopy.bufferBytes) -> Int {
        max(1, min(8, WorkerBudget.current().workers(perWorkerBytes: UInt64(max(1, bufferBytes)) * 2)))
    }
}

private extension Array {
    func reserving(_ n: Int) -> [Element] { var a = self; a.reserveCapacity(n); return a }
}

/// A non-Sendable synchronous closure carried into `concurrentPerform` (which runs it only during the call).
private nonisolated struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
