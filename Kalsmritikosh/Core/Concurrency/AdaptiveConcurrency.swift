//
//  AdaptiveConcurrency.swift
//  Kalsmritikosh
//
//  Speed PERF-22 (owner 2026-11-23) — not tested yet. Throughput-tuned concurrency for AI calls (the download
//  manager's AIMD): start at 2 requests at once; after each window of successes (one window = as many finished
//  requests as the current limit) add 1 while the throughput still rises; halve on an overload (HTTP 429 / 503 /
//  529 or a timeout) and wait what the provider's Retry-After asked before starting another; never above the cap
//  the caller takes from WorkerBudget. An overload seen by ANY sender (AIOverload, noted by the online retry) halves
//  every live limiter too, so independent loops back off together.
//
//  No model names, no network: this only paces work the callers hand it.
//

import Foundation
import os

/// An error that means "the provider is overloaded / limiting" (and, when it said so, how long to wait).
public protocol AIOverloadSignalling: Error {
    var overloadRetryAfter: Double? { get }
    var isOverload: Bool { get }
}

/// Speed PERF-22 (owner 2026-11-23) — not tested yet. The app-wide overload signal: every 429/503/529 (and the
/// wait asked for) bumps the epoch; each AdaptiveConcurrency halves when it sees a new epoch.
public nonisolated enum AIOverload {
    struct State { var epoch = 0; var notBefore: ContinuousClock.Instant? }
    private static let state = OSAllocatedUnfairLock(initialState: State())

    public static func note(retryAfter seconds: Double?) {
        state.withLock { s in
            s.epoch += 1
            if let seconds, seconds > 0 {
                let until = ContinuousClock.now + .milliseconds(Int(min(seconds, 120) * 1_000))
                if s.notBefore.map({ $0 < until }) ?? true { s.notBefore = until }
            }
        }
    }
    static var snapshot: State { state.withLock { $0 } }
}

public actor AdaptiveConcurrency {
    public enum Outcome: Sendable { case success, overloaded(retryAfter: Double?), failure }

    public private(set) var limit: Int
    public let cap: Int
    private let floor: Int
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var notBefore: ContinuousClock.Instant?
    private var seenEpoch: Int
    // The current window: successes since the last change and when it started; the last window's throughput.
    private var windowDone = 0
    private var windowStart = ContinuousClock.now
    private var lastThroughput: Double = 0

    /// `cap`: the most at once (take it from WorkerBudget); `start`: the first limit (2).
    public init(start: Int = 2, cap: Int, floor: Int = 1) {
        let c = max(1, cap)
        self.cap = c
        self.floor = max(1, min(floor, c))
        self.limit = max(self.floor, min(start, c))
        self.seenEpoch = AIOverload.snapshot.epoch
    }

    /// The cap for AI calls on this Mac now: what WorkerBudget allows (each request holds its prompt and reply,
    /// ~64 MB at most), never more than 8 at once.
    public static func aiCap(pressure: MemoryPressureLevel = .normal) -> Int {
        min(8, WorkerBudget.current(pressure: pressure).workers(perWorkerBytes: 64 * 1_048_576))
    }

    /// Wait for a slot (and for any Retry-After wait to pass).
    public func acquire() async {
        while true {
            absorbGlobalOverload()
            let wait = [notBefore, AIOverload.snapshot.notBefore].compactMap { $0 }.max()
            if let wait, wait > ContinuousClock.now {
                do { try await Task.sleep(until: wait, clock: .continuous) } catch {
                    KalsmritikoshLog.app.debug("AdaptiveConcurrency: wait cancelled; the slot is taken so the caller can stop")
                    inFlight += 1
                    return
                }
                continue
            }
            if inFlight < limit { inFlight += 1; return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    /// Give the slot back with how the request went.
    public func release(_ outcome: Outcome) {
        inFlight = max(0, inFlight - 1)
        switch outcome {
        case .success:
            windowDone += 1
            if windowDone >= limit {
                let d = ContinuousClock.now - windowStart
                let elapsed = max(0.001, Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
                let throughput = Double(windowDone) / elapsed
                // +1 only while throughput still rises (≥ 5 % over the last window; the first window always grows).
                if (lastThroughput == 0 || throughput >= lastThroughput * 1.05), limit < cap { limit += 1 }
                lastThroughput = throughput
                windowDone = 0
                windowStart = .now
            }
        case .overloaded(let retryAfter):
            backOff(retryAfter: retryAfter)
        case .failure:
            break
        }
        wakeAll()
    }

    /// Run `body` in a slot, classifying its outcome (overload errors halve the limit).
    public func run<R: Sendable>(_ body: @Sendable () async throws -> R) async throws -> R {
        await acquire()
        do {
            let r = try await body()
            release(.success)
            return r
        } catch {
            release(Self.classify(error))
            throw error
        }
    }

    public static func classify(_ error: Error) -> Outcome {
        if error is CancellationError { return .failure }
        if let s = error as? AIOverloadSignalling, s.isOverload { return .overloaded(retryAfter: s.overloadRetryAfter) }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorTimedOut { return .overloaded(retryAfter: nil) }
        return .failure
    }

    private func backOff(retryAfter: Double?) {
        limit = max(floor, limit / 2)
        windowDone = 0
        windowStart = .now
        lastThroughput = 0
        if let retryAfter, retryAfter > 0 {
            let until = ContinuousClock.now + .milliseconds(Int(min(retryAfter, 120) * 1_000))
            if notBefore.map({ $0 < until }) ?? true { notBefore = until }
        }
    }

    private func absorbGlobalOverload() {
        let epoch = AIOverload.snapshot.epoch
        guard epoch != seenEpoch else { return }
        seenEpoch = epoch
        backOff(retryAfter: nil)
    }

    private func wakeAll() {
        let w = waiters
        waiters.removeAll()
        for c in w { c.resume() }
    }

    // MARK: - Helpers for loops

    /// Run `body` over `items` with an AIMD limiter (start 2, `cap`), keeping the order; every item's own result
    /// (a failure does not stop the others). Stops launching new items once the task is cancelled.
    public static func mapResults<T: Sendable, R: Sendable>(_ items: [T], cap: Int = aiCap(), start: Int = 2,
                                                            _ body: @escaping @Sendable (T) async throws -> R) async -> [Result<R, Error>] {
        guard !items.isEmpty else { return [] }
        let limiter = AdaptiveConcurrency(start: start, cap: cap)
        var out = [Result<R, Error>?](repeating: nil, count: items.count)
        await withTaskGroup(of: (Int, Result<R, Error>).self) { group in
            for (i, item) in items.enumerated() {
                if Task.isCancelled { break }
                await limiter.acquire()
                group.addTask {
                    do {
                        let r = try await body(item)
                        await limiter.release(.success)
                        return (i, .success(r))
                    } catch {
                        await limiter.release(classify(error))
                        return (i, .failure(error))
                    }
                }
            }
            for await done in group { out[done.0] = done.1 }
        }
        return out.map { $0 ?? .failure(CancellationError()) }
    }

    /// As `mapResults`, but the first error (other than for items after it) is thrown and the rest cancelled.
    public static func map<T: Sendable, R: Sendable>(_ items: [T], cap: Int = aiCap(), start: Int = 2,
                                                     _ body: @escaping @Sendable (T) async throws -> R) async throws -> [R] {
        guard !items.isEmpty else { return [] }
        let limiter = AdaptiveConcurrency(start: start, cap: cap)
        var out = [R?](repeating: nil, count: items.count)
        try await withThrowingTaskGroup(of: (Int, R).self) { group in
            for (i, item) in items.enumerated() {
                try Task.checkCancellation()
                await limiter.acquire()
                group.addTask {
                    do {
                        let r = try await body(item)
                        await limiter.release(.success)
                        return (i, r)
                    } catch {
                        await limiter.release(classify(error))
                        throw error
                    }
                }
            }
            while let done = try await group.next() { out[done.0] = done.1 }
        }
        return out.compactMap { $0 }
    }

    /// As `mapResults`, and `onResult` is called IN ORDER (index 0, 1, …) as soon as each result and all before it
    /// are in — for work that streams its results (chapters shown as they are ready, in reading order).
    public static func forEachOrdered<T: Sendable, R: Sendable>(_ items: [T], cap: Int = aiCap(), start: Int = 2,
                                                                _ body: @escaping @Sendable (T) async -> R,
                                                                onResult: (Int, R) async -> Void) async {
        guard !items.isEmpty else { return }
        let limiter = AdaptiveConcurrency(start: start, cap: cap)
        var ready: [Int: R] = [:]
        var nextOut = 0
        await withTaskGroup(of: (Int, R).self) { group in
            var nextIn = 0
            func launch() async {
                guard nextIn < items.count, !Task.isCancelled else { return }
                let i = nextIn, item = items[i]
                nextIn += 1
                await limiter.acquire()
                group.addTask {
                    let r = await body(item)
                    await limiter.release(.success)
                    return (i, r)
                }
            }
            await launch()
            while nextIn < items.count, await limiter.hasRoom() { await launch() }
            while let (i, r) = await group.next() {
                ready[i] = r
                while let r = ready.removeValue(forKey: nextOut) { await onResult(nextOut, r); nextOut += 1 }
                await launch()
                while nextIn < items.count, await limiter.hasRoom() { await launch() }
            }
        }
    }

    /// Whether another request may start now without waiting.
    func hasRoom() -> Bool { inFlight < limit && (notBefore.map { $0 <= .now } ?? true) }
}

