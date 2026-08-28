//
//  LiveMetrics.swift
//  Kalsmritikosh
//
//  Phase J.13 — live observability. Periodically polls the ledger
//  + background services and publishes a snapshot the Live tab
//  renders. @Observable so SwiftUI views update without explicit
//  bindings; @MainActor because the polling task touches AppState
//  properties that are MainActor-isolated.
//
//  Refresh cadence: 2 seconds by default. Cheap reads only — every
//  query is either a single COUNT or a cached actor snapshot, so a
//  poll completes in low milliseconds on archives we target.
//

import Foundation
import Observation
import OSLog

@MainActor
@Observable
public final class LiveMetrics {

    public struct Sample: Sendable, Hashable {
        public let capturedAt: Date
        public let fileCount: Int
        public let objectCount: Int
        public let chunkCount: Int
        public let vectorCount: Int
        public let entityCount: Int
        public let eventCount: Int
        public let causalLinkCount: Int
        public let hypotheticalLinkCount: Int
        public let memoryCount: Int
        public let summaryCount: Int
        public let investigationCount: Int
        public let savedQueryCount: Int
        public let ingestActiveCount: Int
        public let ingestLastFile: String?
        public let pipelineCounters: [PipelineMetrics.Stage: Int]
        public let dbBytes: Int64
        public let processMemoryBytes: UInt64
        // Ledger-first LLM budget (LLMCallCounters snapshot).
        public var llmCallsRun: Int = 0
        public var llmCallsSkipped: Int = 0
        public var llmTimeouts: Int = 0
        public var embedHitRate: Double = 0
        /// Fraction of would-be LLM work skipped by the reduction policy.
        public var llmSkipRate: Double {
            let total = llmCallsRun + llmCallsSkipped
            return total > 0 ? Double(llmCallsSkipped) / Double(total) : 0
        }
    }

    public struct ThroughputPoint: Sendable, Hashable, Identifiable {
        public let id: UUID = UUID()
        public let timestamp: Date
        public let perStage: [PipelineMetrics.Stage: Int]
    }

    public struct FormatCount: Sendable, Hashable, Identifiable {
        public let id: String   // sourceType raw value
        public let count: Int
        public init(id: String, count: Int) {
            self.id = id
            self.count = count
        }
    }

    /// Most recent sample. The dashboard binds to this directly.
    public private(set) var current: Sample = Sample(
        capturedAt: .distantPast,
        fileCount: 0, objectCount: 0, chunkCount: 0, vectorCount: 0,
        entityCount: 0, eventCount: 0, causalLinkCount: 0,
        hypotheticalLinkCount: 0, memoryCount: 0, summaryCount: 0,
        investigationCount: 0, savedQueryCount: 0,
        ingestActiveCount: 0, ingestLastFile: nil,
        pipelineCounters: [:],
        dbBytes: 0, processMemoryBytes: 0
    )

    /// Rolling window of per-stage throughput deltas — the dashboard
    /// renders this as a small sparkline. Bounded so the buffer
    /// doesn't grow unbounded over a long session.
    public private(set) var throughput: [ThroughputPoint] = []
    public static let throughputWindow: Int = 60

    /// Per-source-type file counts (eml / pdf / image / docx / …).
    /// Refreshed each poll alongside the snapshot.
    public private(set) var formatCounts: [FormatCount] = []

    /// Per-service last-run status (only the four most user-visible
    /// services today: causal discoverer + the three topic services).
    public private(set) var serviceStatuses: [LastRunStatus] = []

    private weak var appState: AppState?
    private let pipeline: PipelineMetrics
    private var pollTask: Task<Void, Never>?
    private let pollInterval: TimeInterval

    public init(
        appState: AppState,
        pipeline: PipelineMetrics,
        pollInterval: TimeInterval = 2.0
    ) {
        self.appState = appState
        self.pipeline = pipeline
        self.pollInterval = pollInterval
    }

    /// Start the polling loop. Cancels and restarts the previous
    /// loop if `start()` is called twice. Idempotent when already
    /// running: a second `start()` with an active task is a no-op.
    ///
    /// LiveDashboardView calls this on `.onAppear` and `stop()` on
    /// `.onDisappear` so the 13 COUNT queries + Swift Charts redraw
    /// only fire while the user is actually looking at the Live tab.
    public func start() {
        if pollTask != nil { return }
        // Clear the rolling throughput buffer so the first poll after
        // a resume doesn't render a giant delta against pre-pause
        // counter values. Cumulative pipeline counters live on the
        // PipelineMetrics actor and are untouched.
        throughput = []
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                let ns = UInt64((self?.pollInterval ?? 2.0) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    public var isRunning: Bool { pollTask != nil }

    // MARK: - Polling

    private func poll() async {
        guard let app = appState else { return }
        async let fileCount: Int = {
            (try? await app.files?.count()) ?? 0
        }()
        async let objectCount: Int = {
            (try? await app.objects?.count()) ?? 0
        }()
        async let chunkCount: Int = await Self.tableCount(database: app.database, table: "chunks")
        // Embeddings live in chunk_embeddings (per-model store) — the legacy
        // `vectors` table was migrated into it and stays empty for all new
        // data, so counting it froze the "Chunks → Vectors" bar at 0%
        // (rc8 witness finding). DISTINCT chunk_id: one chunk may carry
        // embeddings from more than one model.
        async let vectorCount: Int = await Self.embeddedChunkCount(database: app.database)
        async let entityCount: Int = {
            (try? await app.entities?.canonicalCount()) ?? 0
        }()
        async let eventCount: Int = {
            (try? await app.events?.count()) ?? 0
        }()
        async let causalLinkCount: Int = {
            (try? await app.eventLinks?.count(includeSuperseded: false)) ?? 0
        }()
        async let hypotheticalLinkCount: Int = {
            (try? await app.eventLinks?.hypotheticalCount()) ?? 0
        }()
        async let memoryCount: Int = {
            (try? await app.memoryRepo?.count()) ?? 0
        }()
        async let summaryCount: Int = await Self.tableCount(database: app.database, table: "summaries")
        async let investigationCount: Int = {
            (try? await app.investigations?.count()) ?? 0
        }()
        async let savedQueryCount: Int = {
            (try? await app.savedQueries?.count()) ?? 0
        }()
        async let counters: [PipelineMetrics.Stage: Int] = pipeline.snapshot()

        let pipelineSnapshot = await counters
        let llm = await LLMCallCounters.shared.snapshot()
        var sample = await Sample(
            capturedAt: Date(),
            fileCount: fileCount,
            objectCount: objectCount,
            chunkCount: chunkCount,
            vectorCount: vectorCount,
            entityCount: entityCount,
            eventCount: eventCount,
            causalLinkCount: causalLinkCount,
            hypotheticalLinkCount: hypotheticalLinkCount,
            memoryCount: memoryCount,
            summaryCount: summaryCount,
            investigationCount: investigationCount,
            savedQueryCount: savedQueryCount,
            ingestActiveCount: app.ingestActiveCount,
            ingestLastFile: app.ingestLastFile,
            pipelineCounters: pipelineSnapshot,
            dbBytes: Self.databaseSizeBytes(from: app.database),
            processMemoryBytes: Self.processMemoryBytes()
        )
        sample.llmCallsRun = llm.callsRun
        sample.llmCallsSkipped = llm.callsSkipped
        sample.llmTimeouts = llm.timeouts
        sample.embedHitRate = llm.embedHitRate

        // Diff per-stage to compute the throughput point.
        let previous = self.current.pipelineCounters
        var deltas: [PipelineMetrics.Stage: Int] = [:]
        for stage in PipelineMetrics.Stage.allCases {
            let cur = sample.pipelineCounters[stage] ?? 0
            let pre = previous[stage] ?? 0
            deltas[stage] = max(0, cur - pre)
        }
        var newThroughput = throughput
        newThroughput.append(ThroughputPoint(timestamp: sample.capturedAt, perStage: deltas))
        if newThroughput.count > Self.throughputWindow {
            newThroughput.removeFirst(newThroughput.count - Self.throughputWindow)
        }
        self.current = sample
        self.throughput = newThroughput

        // Per-format file census + per-service last-run statuses.
        // These are independent of the snapshot — failures here
        // don't disturb the main metric refresh.
        if let files = app.files {
            let counts = (try? await files.countsBySourceType()) ?? []
            self.formatCounts = counts.map { FormatCount(id: $0.sourceType, count: $0.count) }
        }
        var statuses: [LastRunStatus] = []
        if let svc = app.causalDiscovererService {
            statuses.append(await svc.currentStatus())
        }
        if let svc = app.cooccurrenceBuilderService {
            statuses.append(await svc.currentStatus())
        }
        if let svc = app.communityDetectorService {
            statuses.append(await svc.currentStatus())
        }
        if let svc = app.communitySummarizerService {
            statuses.append(await svc.currentStatus())
        }
        self.serviceStatuses = statuses
    }

    /// Generic table-count helper for tables whose repository
    /// doesn't expose a `count()` (chunks, summaries today). Keeps
    /// the poll loop a sequence of cheap COUNT queries.
    private static func tableCount(database: Database?, table: String) async -> Int {
        guard let database else { return 0 }
        guard let rows = try? await database.query(
            "SELECT COUNT(*) FROM \(table);",
            []
        ) else { return 0 }
        return Int(rows.first?.int(0) ?? 0)
    }

    /// Chunks with at least one embedding — the same authority the health
    /// check and inventory use (DataHealthCheck, KnowledgeInventory).
    /// Internal (not private) so the regression test can pin the source table.
    static func embeddedChunkCount(database: Database?) async -> Int {
        guard let database else { return 0 }
        guard let rows = try? await database.query(
            "SELECT COUNT(DISTINCT chunk_id) FROM chunk_embeddings;",
            []
        ) else { return 0 }
        return Int(rows.first?.int(0) ?? 0)
    }

    // MARK: - Resource probes

    private static func databaseSizeBytes(from db: Database?) -> Int64 {
        guard let url = db?.url,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return 0 }
        return size
    }

    private static func processMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return 0 }
        return info.resident_size
    }
}
