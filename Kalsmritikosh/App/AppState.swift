//
//  AppState.swift
//  Kalsmritikosh
//
//  Single root container. Owns every long-lived service from Storage
//  through Brain. Wires capability resolution, incremental updates,
//  background compression, FolderWatcher → IngestCoordinator, and
//  embedding caching.
//

import Foundation
import Observation
import OSLog

@MainActor
@Observable
public final class AppState {
    public enum Phase: Sendable {
        case starting
        case ready
        case failed(String)
    }

    public private(set) var phase: Phase = .starting
    public let bookmarks: BookmarkStore

    // Storage
    public private(set) var database: Database?
    public private(set) var vectorStore: SQLiteVectorStore?
    public private(set) var files: FilesRepository?
    public private(set) var objects: KnowledgeObjectRepository?
    public private(set) var chunks: ChunksRepository?
    public private(set) var entities: EntitiesRepository?
    public private(set) var events: EventsRepository?
    public private(set) var summariesRepo: SummariesRepository?
    public private(set) var relationships: RelationshipsRepository?
    public private(set) var memoryRepo: MemoryRepository?
    public private(set) var conversations: ConversationsRepository?

    // Knowledge
    public private(set) var timelineEngine: TimelineEngine?
    public private(set) var summarizer: (any Summarizer)?
    public private(set) var compression: NightlyCompressionScheduler?
    public private(set) var graph: GraphStore?
    public private(set) var memoryDistiller: MemoryDistiller?
    public private(set) var retriever: HybridRetriever?
    public private(set) var weeklyBriefing: WeeklyBriefingGenerator?

    // Routing + Brain
    public private(set) var hardware: HardwareProfile?
    public private(set) var benchmark: PerformanceBenchmark?
    public private(set) var capabilities: CapabilityRegistry?
    public private(set) var expertRegistry: ExpertRegistry?
    public private(set) var router: DeterministicRouter?
    public private(set) var workerPool: WorkerPool?
    public private(set) var executor: ParallelExecutor?
    public private(set) var intentDetector: RuleIntentDetector?
    public private(set) var verifier: EvidenceVerifier?

    // Concurrency
    public private(set) var backgroundScheduler: BackgroundTaskScheduler?
    public private(set) var folderWatcher: FolderWatcher?
    public private(set) var incrementalUpdater: IncrementalUpdater?

    public private(set) var ingest: IngestCoordinator?
    public private(set) var brain: MasterBrain

    private var watcherTask: Task<Void, Never>?

    public init(bookmarks: BookmarkStore = .shared) {
        self.bookmarks = bookmarks
        self.brain = MasterBrain()
    }

    public func boot() async {
        do {
            // ── Storage ──────────────────────────────────────────────
            let db = try Database(url: DatabaseLocations.defaultDatabaseURL)
            await db.loadSqliteVecIfAvailable()
            try await SchemaMigrations.migrate(db)
            AtlasLog.storage.info("Database open at \(db.url.path, privacy: .public)")

            let vectors = SQLiteVectorStore(database: db)
            let files = FilesRepository(database: db)
            let objects = KnowledgeObjectRepository(database: db)
            let chunks = ChunksRepository(database: db)
            let entities = EntitiesRepository(database: db)
            let events = EventsRepository(database: db)
            let summariesRepo = SummariesRepository(database: db)
            let relationships = RelationshipsRepository(database: db)
            let memoryRepo = MemoryRepository(database: db)
            let conversationsRepo = ConversationsRepository(database: db)

            // ── Routing (CapabilityRegistry) ─────────────────────────
            let hardware = HardwareProbe.probe()
            AtlasLog.routing.info("Hardware: \(hardware.chipName, privacy: .public), tier \(hardware.tier.rawValue, privacy: .public), \(hardware.totalRAMBytes) bytes RAM")
            let benchmark = PerformanceBenchmark(hardwareProfile: hardware)
            let capabilities = CapabilityRegistry(
                hardware: hardware,
                benchmark: benchmark
            )
            await capabilities.register(FoundationModelsProvider())
            await capabilities.register(
                MLXProvider(
                    id: "provider.local.mlx.reasoning",
                    manifest: ModelManifest(
                        id: "provider.local.mlx.reasoning",
                        displayName: "Local reasoning model",
                        capabilities: [
                            .textGeneration, .reasoning, .summarization,
                            .extraction, .longContext, .structuredOutput,
                            .expertLarge
                        ],
                        minRAMBytes: 12 * 1_073_741_824,
                        diskBytes: 5_500_000_000,
                        contextWindow: 32_768,
                        privacyLevel: .onDevice,
                        requiresDownload: true,
                        tier: .medium
                    ),
                    downloader: ModelDownloader()
                )
            )
            await capabilities.register(LlamaCppProvider())
            // Ollama is opt-in but on by default — when `ollama serve` is
            // running locally with the named models pulled, the registry
            // will rank it alongside Apple's model. When the server isn't
            // up, isAvailable() fails fast (1.5s probe) and the registry
            // skips it without affecting the user-visible latency.
            await capabilities.register(OllamaProvider(
                modelTag: "qwen2.5:14b",
                embeddingModelTag: "nomic-embed-text",
                enabled: true,
                displayName: "Local Ollama (qwen2.5:14b)",
                tier: .medium
            ))
            await capabilities.register(CloudProvider())

            // ── Knowledge ────────────────────────────────────────────
            // Embedder goes through the CapabilityRegistry — when an
            // Ollama embedding model is reachable it wins; otherwise
            // we fall back to NLEmbedder. CachedEmbedder LRUs the result.
            let embedder: any Embedder = CachedEmbedder(
                wrapping: CapabilityResolvedEmbedder(capabilities: capabilities)
            )
            let timelineEngine = TimelineEngine(events: events)
            let summarizer = LLMSummarizer(
                objects: objects,
                summaries: summariesRepo,
                events: events,
                capabilities: capabilities
            )
            let graph = GraphStore(relationships: relationships)
            let retriever = HybridRetriever(
                memory: memoryRepo,
                events: events,
                entities: entities,
                chunks: chunks,
                summaries: summariesRepo,
                graph: graph,
                vectors: vectors,
                embedder: embedder
            )

            let expertRegistry = ExpertRegistry()
            await expertRegistry.register(EmailExpert())
            await expertRegistry.register(FinancialExpert())
            await expertRegistry.register(LegalExpert())
            await expertRegistry.register(ResearchExpert())
            await expertRegistry.register(OCRExpert())
            await expertRegistry.register(TimelineExpert())
            await expertRegistry.register(ProjectExpert())

            let router = DeterministicRouter(expertRegistry: expertRegistry)
            let workerPool = WorkerPool(maxConcurrentWorkers: 4)
            let executor = ParallelExecutor(pool: workerPool, experts: expertRegistry)
            let intentDetector = RuleIntentDetector()
            // T11 close-out — give the verifier a real ingest-coverage
            // readout: fraction of registered files that have at least one
            // KnowledgeObject in the store. While ingest is incomplete the
            // engine multiplies final confidence by max(coverage, 0.5).
            let verifier = EvidenceVerifier(
                ingestCoverageProvider: { [weak files, weak objects] in
                    guard let files, let objects else { return 1.0 }
                    let fileCount = (try? await files.count()) ?? 0
                    guard fileCount > 0 else { return 1.0 }
                    let koCount = (try? await objects.count()) ?? 0
                    let raw = Double(koCount) / Double(fileCount)
                    return min(1.0, max(0.0, raw))
                },
                entityQualityGate: EntityQualityGate.bundled()
            )
            let memoryDistiller = MemoryDistiller(
                memory: memoryRepo,
                events: events,
                entities: entities,
                capabilities: capabilities,
                knowledgeObjects: objects
            )
            let weeklyBriefing = WeeklyBriefingGenerator(
                memory: memoryRepo,
                summarizer: summarizer,
                capabilities: capabilities
            )

            // ── Brain ────────────────────────────────────────────────
            let brain = MasterBrain(
                intentDetector: intentDetector,
                router: router,
                retriever: retriever,
                executor: executor,
                capabilities: capabilities,
                verifier: verifier,
                weeklyBriefing: weeklyBriefing
            )

            // ── Ingestion ────────────────────────────────────────────
            let ingest = IngestCoordinator(
                entityExtractor: NLEntityExtractor(),
                entityLinker: EntityLinker(),
                entityQualityGate: EntityQualityGate.bundled(),
                eventExtractor: RuleEventExtractor(),
                relationshipExtractor: Tier1RelationshipExtractor(),
                embedder: embedder,
                files: files,
                objects: objects,
                chunks: chunks,
                entities: entities,
                events: events,
                relationships: relationships,
                vectors: vectors
            )

            // ── Concurrency + Live wiring ────────────────────────────
            let backgroundScheduler = BackgroundTaskScheduler()
            let compression = NightlyCompressionScheduler(
                summarizer: summarizer,
                memoryRepo: memoryRepo,
                scheduler: backgroundScheduler
            )
            await compression.start()

            let updater = IncrementalUpdater(
                stream: ingest.invalidations,
                distiller: memoryDistiller
            )
            await updater.start()

            let watcher = FolderWatcher()
            // Capture weak — when AppState is deallocated the consumer
            // task observes that ingest/watcher are gone and exits.
            self.watcherTask = Task { [weak ingest, weak watcher] in
                guard let watcher else { return }
                for await event in await watcher.events {
                    guard let ingest else { return }
                    for url in event.urls {
                        do {
                            _ = try await ingest.ingest(fileAt: url)
                        } catch {
                            AtlasLog.ingestion.error("Watcher-triggered ingest failed for \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                        }
                    }
                }
            }
            // T8 — Root reachability sweep at boot. Unreachable roots have
            // their files flagged offline_root; reachable roots' files
            // get restored to .available.
            for root in bookmarks.roots {
                if let url = try? bookmarks.resolve(root) {
                    await watcher.watch(root: root, url: url)
                    if FileManager.default.fileExists(atPath: url.path) {
                        try? await files.markFilesUnderRoot(url, as: .available)
                    } else {
                        try? await files.markFilesUnderRoot(url, as: .offlineRoot)
                    }
                    bookmarks.stopAccessing(url)
                }
            }

            // Commit
            self.database = db
            self.vectorStore = vectors
            self.files = files
            self.objects = objects
            self.chunks = chunks
            self.entities = entities
            self.events = events
            self.summariesRepo = summariesRepo
            self.relationships = relationships
            self.memoryRepo = memoryRepo
            self.conversations = conversationsRepo
            self.timelineEngine = timelineEngine
            self.summarizer = summarizer
            self.compression = compression
            self.graph = graph
            self.memoryDistiller = memoryDistiller
            self.retriever = retriever
            self.weeklyBriefing = weeklyBriefing
            self.hardware = hardware
            self.benchmark = benchmark
            self.capabilities = capabilities
            self.expertRegistry = expertRegistry
            self.router = router
            self.workerPool = workerPool
            self.executor = executor
            self.intentDetector = intentDetector
            self.verifier = verifier
            self.backgroundScheduler = backgroundScheduler
            self.folderWatcher = watcher
            self.incrementalUpdater = updater
            self.brain = brain
            self.ingest = ingest
            self.phase = .ready
            AtlasLog.app.info("AppState booted successfully")
        } catch {
            AtlasLog.app.error("AppState boot failed: \(String(describing: error), privacy: .public)")
            self.phase = .failed("\(error)")
        }
    }

    /// T8 — Root removal with explicit knowledge-preservation choice.
    /// .stopWatching keeps every learned KO, chunk, entity, event, etc.
    /// .stopAndForget performs the explicit cascading delete of every
    /// file under that root (and via FK cascade, all dependent rows).
    public enum RootRemovalStrategy: Sendable {
        case stopWatching
        case stopAndForget
    }

    public func countFiles(underRoot root: BookmarkStore.Root) async -> Int {
        guard let files,
              let url = try? bookmarks.resolve(root) else { return 0 }
        defer { bookmarks.stopAccessing(url) }
        return (try? await files.countUnderRoot(url)) ?? 0
    }

    public func removeRoot(_ root: BookmarkStore.Root, strategy: RootRemovalStrategy) async {
        let url = try? bookmarks.resolve(root)
        defer { if let url { bookmarks.stopAccessing(url) } }
        switch strategy {
        case .stopWatching:
            // Knowledge survives; files become offline_root since we no
            // longer watch them.
            if let url, let files {
                try? await files.markFilesUnderRoot(url, as: .offlineRoot)
            }
        case .stopAndForget:
            if let url, let files {
                try? await files.deleteAllUnderRoot(url)
            }
        }
        bookmarks.remove(root)
        // FolderWatcher has no unwatch entry point in v1; the bookmark
        // removal alone prevents further re-ingest because resolution
        // fails the next time the watcher fires for that root.
    }

    @discardableResult
    public func ingestAllRoots() async -> Int {
        guard let ingest else { return 0 }
        var count = 0
        for root in bookmarks.roots {
            guard let url = try? bookmarks.resolve(root) else { continue }
            defer { bookmarks.stopAccessing(url) }
            let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            while let next = enumerator?.nextObject() as? URL {
                let isRegular = (try? next.resourceValues(forKeys: [.isRegularFileKey])
                    .isRegularFile) ?? false
                guard isRegular else { continue }
                do {
                    _ = try await ingest.ingest(fileAt: next)
                    count += 1
                } catch {
                    AtlasLog.ingestion.error("Bulk ingest failed for \(next.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
        return count
    }
}
