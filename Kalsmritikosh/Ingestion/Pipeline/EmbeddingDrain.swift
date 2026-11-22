//
//  EmbeddingDrain.swift
//  Kalsmritikosh
//
//  F10 — one full, fair pass over every chunk still missing a vector. The old drain re-read the
//  newest 256 missing chunks each time and filtered known-unembeddable ones AFTER the LIMIT, so a
//  front page made entirely of chunks the embedder can't vectorize looked "drained" and every
//  older, perfectly embeddable chunk starved. The pass pages by rowid keyset instead: a page that
//  yields nothing moves the cursor past it, so every missing chunk is reached once per pass.
//

import Foundation
import os

enum EmbeddingDrain {

    struct PassResult: Equatable {
        var embedded = 0
        var newlyFailed: Set<Chunk.ID> = []
        var pages = 0
    }

    /// Walk every missing chunk once, newest first.
    ///  • `fetch(beforeRowID)` — one keyset page (`ChunksRepository.findChunksMissingVectorPage`);
    ///  • `skip` — chunks already known unembeddable this session (never re-sent);
    ///  • `betweenPages` — pause / priority-gate hook; returning false stops the pass early;
    ///  • `embed` — vectorize + store one batch, returning how many were stored and which chunks the
    ///    embedder could not vectorize.
    static func pass(
        isolation: isolated (any Actor)? = #isolation,
        fetch: (Int64?) async throws -> (chunks: [Chunk], lastRowID: Int64?),
        skip: Set<Chunk.ID>,
        betweenPages: () async -> Bool = { true },
        embed: ([Chunk]) async -> (stored: Int, unembeddable: [Chunk.ID])
    ) async -> PassResult {
        var result = PassResult()
        var cursor: Int64? = nil
        var known = skip
        while await betweenPages() {
            let page: (chunks: [Chunk], lastRowID: Int64?)
            do { page = try await fetch(cursor) } catch {
                KalsmritikoshLog.ingestion.error("Embedding drain page fetch failed: \(String(describing: error), privacy: .public)")
                break
            }
            guard let next = page.lastRowID else { break }  // no rows left → the pass is complete
            result.pages += 1
            cursor = next                                   // always move PAST this page
            let batch = page.chunks.filter { !known.contains($0.id) }
            guard !batch.isEmpty else { continue }          // an all-unembeddable page no longer blocks
            let outcome = await embed(batch)
            result.embedded += outcome.stored
            for id in outcome.unembeddable where known.insert(id).inserted { result.newlyFailed.insert(id) }
        }
        return result
    }

    /// Speed PERF-26 (owner 2026-11-23) — not tested yet. As `pass`, with several batches embedded at once: pages are
    /// still fetched in keyset order (one reader), and up to the embed stage's live width (`PipelineStages`, re-sized by
    /// memory pressure and heat) batches are embedded and stored concurrently. The page size adapts — it doubles (to
    /// 1,024) while a batch finishes in under a second and halves (to 64) when one takes over four — so a fast Neural
    /// Engine gets large batches and a slow fallback keeps short ones. The embed stage's permit is NOT taken here (the
    /// Core ML batch takes it itself; holding it twice could deadlock at width 1).
    static func concurrentPass(
        fetch: @escaping @Sendable (_ before: Int64?, _ limit: Int) async throws -> (chunks: [Chunk], lastRowID: Int64?),
        skip: Set<Chunk.ID>,
        betweenPages: @escaping @Sendable () async -> Bool = { true },
        embed: @escaping @Sendable ([Chunk]) async -> (stored: Int, unembeddable: [Chunk.ID])
    ) async -> PassResult {
        var result = PassResult()
        var cursor: Int64? = nil
        var known = skip
        var pageSize = 256
        await withTaskGroup(of: (stored: Int, unembeddable: [Chunk.ID], seconds: Double).self) { group in
            var running = 0
            func absorb(_ o: (stored: Int, unembeddable: [Chunk.ID], seconds: Double)) {
                running -= 1
                result.embedded += o.stored
                for id in o.unembeddable where known.insert(id).inserted { result.newlyFailed.insert(id) }
                if o.seconds < 1, pageSize < 1_024 { pageSize *= 2 } else if o.seconds > 4, pageSize > 64 { pageSize /= 2 }
            }
            while await betweenPages() {
                while running >= (await PipelineStages.currentWidth(.embed)), let done = await group.next() { absorb(done) }
                let page: (chunks: [Chunk], lastRowID: Int64?)
                do { page = try await fetch(cursor, pageSize) } catch {
                    KalsmritikoshLog.ingestion.error("Embedding drain page fetch failed: \(String(describing: error), privacy: .public)")
                    break
                }
                guard let next = page.lastRowID else { break }
                result.pages += 1
                cursor = next
                let batch = page.chunks.filter { !known.contains($0.id) }
                guard !batch.isEmpty else { continue }
                running += 1
                group.addTask {
                    let start = ContinuousClock.now
                    let o = await embed(batch)
                    let d = ContinuousClock.now - start
                    return (o.stored, o.unembeddable, Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
                }
            }
            while let done = await group.next() { absorb(done) }
        }
        return result
    }
}

/// Speed PERF-26 (owner 2026-11-23) — not tested yet. A wake-up for an idle background loop: `signal()` (new work, a
/// resume) ends a `wait` at once instead of the loop sleeping a fixed time. A signal sent while nobody waits is kept,
/// so the next `wait` returns immediately (no lost wake-up).
actor DrainWake {
    private var pending = false
    private var waiter: CheckedContinuation<Void, Never>?

    func signal() {
        if let w = waiter { waiter = nil; w.resume() } else { pending = true }
    }

    /// Wait for a signal or `timeout`, whichever is first (a fallback for work that arrives without a signal).
    func wait(timeout: Duration) async {
        if pending { pending = false; return }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.signal()
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                if let old = waiter { old.resume() }
                if Task.isCancelled { c.resume() } else { waiter = c }
            }
        } onCancel: {
            Task { await self.signal() }
        }
        pending = false
        timer.cancel()
    }
}

