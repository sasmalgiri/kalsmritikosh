//
//  Endgame.swift
//  Kalsmritikosh
//
//  Speed PERF-37 torrent (owner 2026-11-23) — not tested yet. "Endgame mode": at the end of a run of local work, when
//  every item has started and fewer are running than the workers allowed, an idle worker starts a DUPLICATE of the
//  longest-running unfinished item (once per item, only after it has run `minimumSeconds`). The first attempt to finish
//  wins; the other is cancelled and its result is discarded. A slow page range (a stuck recogniser, a page under memory
//  pressure, a core that went to sleep) no longer holds the whole document up.
//
//  Rules:
//    • ON-MAC WORK ONLY (OCR pages, parsing ranges, pure computations). Never for AI or network calls — a duplicate there
//      would be a second paid request. Callers pass `local: true`; anything else runs without duplicates.
//    • `work` must not commit anything itself (pure), or commit only idempotently (an upsert of the same value under the
//      same key, as the content cache does): only the winner's RESULT is returned to the caller, who commits it once.
//

import Foundation
import os

public nonisolated enum Endgame {
    /// An item must have run this long before a duplicate is started (short items are never duplicated).
    public static let minimumSeconds: Double = 2

    private enum Event<Out: Sendable>: Sendable {
        case done(index: Int, attempt: Int, value: Out)
        case cancelled(index: Int, attempt: Int)
        case tick
    }

    /// `work(i, input)` for every input with up to `width()` attempts running at once; results in input order (nil only
    /// when the caller's task was cancelled before the item finished).
    public static func map<In: Sendable, Out: Sendable>(
        _ inputs: [In], local: Bool, width: @escaping @Sendable () async -> Int,
        minimumSeconds: Double = Endgame.minimumSeconds,
        work: @escaping @Sendable (Int, In) async -> Out
    ) async -> [Out?] {
        guard !inputs.isEmpty else { return [] }
        let (stream, continuation) = AsyncStream<Event<Out>>.makeStream()
        var results = [Out?](repeating: nil, count: inputs.count)
        var finished = 0
        var next = 0
        // index → (attempt → task), and when the first attempt started.
        var running: [Int: [Int: Task<Void, Never>]] = [:]
        var startedAt: [Int: ContinuousClock.Instant] = [:]
        var duplicated = Set<Int>()
        var attemptCounter = 0
        let clock = ContinuousClock()

        func launch(_ i: Int) {
            attemptCounter += 1
            let attempt = attemptCounter
            let input = inputs[i]
            let task = Task {
                let value = await work(i, input)
                continuation.yield(Task.isCancelled ? .cancelled(index: i, attempt: attempt) : .done(index: i, attempt: attempt, value: value))
            }
            running[i, default: [:]][attempt] = task
            if startedAt[i] == nil { startedAt[i] = clock.now }
        }
        func attempts() -> Int { running.values.reduce(0) { $0 + $1.count } }

        // A tick so a long item is noticed even when nothing finishes.
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                continuation.yield(.tick)
            }
        }
        await withTaskCancellationHandler {
            var limit = max(1, await width())
            while next < inputs.count, attempts() < limit { launch(next); next += 1 }
            for await event in stream {
                switch event {
                case .done(let i, let attempt, let value):
                    running[i]?[attempt] = nil
                    if results[i] == nil {
                        results[i] = value
                        finished += 1
                        // The other attempt loses: cancelled, its result (if it still comes) discarded.
                        if let others = running[i], !others.isEmpty {
                            for t in others.values { t.cancel() }
                            KalsmritikoshLog.ingestion.info("Endgame: item \(i, privacy: .public) won by attempt \(attempt, privacy: .public); the duplicate was cancelled")
                        }
                        running[i] = nil
                    }
                case .cancelled(let i, let attempt):
                    running[i]?[attempt] = nil
                    if running[i]?.isEmpty == true { running[i] = nil }
                    // A lone attempt cancelled without a winner (the caller's own cancel): nothing to retry.
                case .tick:
                    break
                }
                if finished == inputs.count || Task.isCancelled { break }
                limit = max(1, await width())
                while next < inputs.count, attempts() < limit { launch(next); next += 1 }
                // Endgame: everything has started; idle slots duplicate the longest-running items (once each).
                if local, next >= inputs.count {
                    let now = clock.now
                    let candidates = running.keys
                        .filter { results[$0] == nil && !duplicated.contains($0) && running[$0]?.count == 1 }
                        .compactMap { i -> (Int, Double)? in
                            guard let s = startedAt[i] else { return nil }
                            let d = now - s
                            let secs = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
                            return secs >= minimumSeconds ? (i, secs) : nil
                        }
                        .sorted { $0.1 > $1.1 }
                    for (i, secs) in candidates where attempts() < limit {
                        duplicated.insert(i)
                        KalsmritikoshLog.ingestion.info("Endgame: item \(i, privacy: .public) running \(Int(secs), privacy: .public) s; a duplicate starts on an idle worker")
                        launch(i)
                    }
                }
                if running.isEmpty, next >= inputs.count { break }   // every attempt ended (cancelled) without all results
            }
        } onCancel: {
            ticker.cancel()
            continuation.finish()   // the loop ends; the attempts still running are cancelled below
        }
        ticker.cancel()
        continuation.finish()
        for attempts in running.values { for t in attempts.values { t.cancel() } }
        return results
    }
}
