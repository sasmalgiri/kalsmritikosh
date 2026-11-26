//
//  SyntheticQuestionQueue.swift
//  Kalsmritikosh
//
//  Background queue that decouples synthetic-question generation from
//  the ingest path. Without this, IngestCoordinator.processKnowledgeObject
//  ran synth-q generation INSIDE the per-KO loop — 4 questions per
//  chunk × 42K chunks meant a re-ingest sat at 99% CPU for hours while
//  the activity banner kept spinning. Observed during 2026-06-25 real-
//  archive test: 47K of 167K questions produced after 1 hour, still
//  ~3 hours to go.
//
//  Design: queue-and-defer.
//   - IngestCoordinator persists KO + chunks + entities + events + bonds
//     immediately, then enqueues (objectID, chunks, documentContext)
//     onto this actor. The KO's ingest path returns within seconds.
//   - A long-running detached Task started at AppState boot drains the
//     queue. Each batch generates synth-q for its chunks and inserts.
//   - Idempotent: dropping a job mid-flight only loses that batch; the
//     next ingest of the same file resets via hash-skip; or the user
//     can trigger a "rebuild synthetic questions" action that re-enqueues.
//
//  Failure mode preservation: synth-q has always been a non-fatal
//  ADDITIONAL retrieval signal. If the queue can't keep up or a batch
//  fails, the rest of the ingest pipeline (entity search, FTS, bond
//  walk) still works.
//

import Foundation
import OSLog

public actor SyntheticQuestionQueue {

    public struct Job: Sendable {
        public let objectID: KnowledgeObject.ID
        public let chunks: [Chunk]
        public let documentContext: String
    }

    private let generator: any SyntheticQuestionGenerator
    private let repository: SyntheticQuestionsRepository

    private var pending: [Job] = []
    private var isProcessing = false
    private var processingTask: Task<Void, Never>?

    /// Total pending chunks across all queued jobs — useful for the
    /// status badge ("synth-q backlog: 18,243 chunks").
    public var pendingChunkCount: Int {
        pending.reduce(0) { $0 + $1.chunks.count }
    }

    public init(
        generator: any SyntheticQuestionGenerator,
        repository: SyntheticQuestionsRepository
    ) {
        self.generator = generator
        self.repository = repository
    }

    /// Add work. Triggers processing if the worker is idle.
    public func enqueue(_ job: Job) {
        pending.append(job)
        if !isProcessing {
            startProcessing()
        }
    }

    /// Cancel any in-flight worker task — used at app shutdown so the
    /// detached task doesn't outlive the DB handle.
    public func shutdown() {
        processingTask?.cancel()
        processingTask = nil
        isProcessing = false
    }

    private func startProcessing() {
        guard !isProcessing else { return }
        isProcessing = true
        processingTask = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        KalsmritikoshLog.ingestion.info("SynthQQueue: drain start, pending=\(self.pending.count, privacy: .public)")
        while !pending.isEmpty {
            if Task.isCancelled { break }
            let job = pending.removeFirst()
            await process(job)
        }
        isProcessing = false
        KalsmritikoshLog.ingestion.info("SynthQQueue: drain complete")
    }

    private func process(_ job: Job) async {
        // Speed PERF-22 (owner 2026-11-23) — not tested yet. The job's chunks in slices of 50; each slice runs concurrently
        // under one AIMD limiter (start 2, worker-budget cap, halved on overload) and is flushed when done — the per-slice
        // checkpoint (crash safety + observable progress, as the old every-200-rows flush).
        let generator = self.generator
        let context = job.documentContext
        var rows: [SyntheticQuestionsRepository.Row] = []
        for start in stride(from: 0, to: job.chunks.count, by: 50) {
            if Task.isCancelled { return }
            let slice = Array(job.chunks[start..<min(start + 50, job.chunks.count)])
            let results = await AdaptiveConcurrency.mapResults(slice) { chunk in
                await generator.generate(for: chunk, documentContext: context, topK: 4)
            }
            for (chunk, result) in zip(slice, results) {
                for q in (try? result.get()) ?? [] {
                    rows.append(SyntheticQuestionsRepository.Row(
                        chunkID: chunk.id,
                        objectID: job.objectID,
                        text: q.text,
                        confidence: q.confidence,
                        producedBy: generator.id
                    ))
                }
            }
            await flush(&rows)
        }
        await flush(&rows)
    }

    private func flush(_ rows: inout [SyntheticQuestionsRepository.Row]) async {
        guard !rows.isEmpty else { return }
        do {
            try await repository.insertBatch(rows)
        } catch {
            KalsmritikoshLog.ingestion.error("SynthQQueue: insertBatch failed: \(String(describing: error), privacy: .public)")
        }
        rows.removeAll(keepingCapacity: true)
    }
}
