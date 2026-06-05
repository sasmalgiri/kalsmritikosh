//
//  CompressionScheduler.swift
//  Atlas chronica memora
//
//  Long-running background service that drives hierarchical summarization
//  and Memory distillation. Wakes via BackgroundTaskScheduler; reads
//  invalidations from IncrementalUpdater (which already debounces).
//

import Foundation
import OSLog

public actor NightlyCompressionScheduler: CompressionScheduler, BackgroundService {
    public let id = "atlas.compression.nightly"
    private let summarizer: Summarizer
    private let memoryRepo: MemoryRepository
    private let scheduler: BackgroundTaskScheduler
    private let interval: TimeInterval

    public init(
        summarizer: Summarizer,
        memoryRepo: MemoryRepository,
        scheduler: BackgroundTaskScheduler,
        interval: TimeInterval = 6 * 60 * 60   // every 6 hours
    ) {
        self.summarizer = summarizer
        self.memoryRepo = memoryRepo
        self.scheduler = scheduler
        self.interval = interval
    }

    public func start() async {
        let summarizer = self.summarizer
        let memoryRepo = self.memoryRepo
        let job = BackgroundTaskScheduler.Job(
            id: id,
            interval: interval
        ) {
            await NightlyCompressionScheduler.runOnce(
                summarizer: summarizer,
                memoryRepo: memoryRepo
            )
        }
        await scheduler.schedule(job)
    }

    public func stop() async {
        await scheduler.cancel(id)
    }

    public func runNightlyCompression() async throws {
        await Self.runOnce(summarizer: summarizer, memoryRepo: memoryRepo)
    }

    private static func runOnce(summarizer: Summarizer, memoryRepo: MemoryRepository) async {
        AtlasLog.knowledge.info("Nightly compression starting")
        let now = Date()
        let yearAgo = Calendar.current.date(byAdding: .year, value: -1, to: now) ?? now
        let range = Summary.Scope.Range(start: yearAgo, end: now)
        do {
            _ = try await summarizer.summarize(
                scope: .knowledgeBase,
                level: .knowledgeBase,
                length: .executive
            )
            _ = try await summarizer.summarize(
                scope: .timeline(range),
                level: .timeline,
                length: .medium
            )
        } catch {
            AtlasLog.knowledge.error("Nightly compression failed: \(String(describing: error), privacy: .public)")
        }
        let memoryRowCount = (try? await memoryRepo.count()) ?? -1
        AtlasLog.knowledge.info("Nightly compression complete (memory rows: \(memoryRowCount, privacy: .public))")
    }
}
