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
import NaturalLanguage

/// Tiny Sendable counter for the parallel `ingestAllRoots()` task group.
/// Kept at file scope so callers can pass it across actor boundaries.
public actor IngestCounter {
    public private(set) var value: Int = 0
    public init() {}
    public func increment() { value += 1 }
}

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

    /// Live count of in-flight ingest tasks. The UI banner reads this
    /// to show "Ingesting N file(s)…" so the user is never wondering
    /// whether work is happening.
    public private(set) var ingestActiveCount: Int = 0
    /// Most recent finished file's display name (for the banner subtext
    /// — "last: invoice-432.eml"). Cleared when the counter hits 0.
    public private(set) var ingestLastFile: String?

    // Idle maintenance (idle-driven summarization/distillation). The UI
    // shows a banner when a pass is running so the user knows the app is
    // working while their machine is idle — and that it stops the moment
    // they return.
    public private(set) var maintenanceActive: Bool = false
    /// Human-readable status line for the maintenance banner.
    public private(set) var maintenanceStatus: String?
    /// When the last maintenance transition happened (for "· 2m ago").
    public private(set) var maintenanceLastEventAt: Date?

    /// True while an "Ask first" prompt is waiting for the user's answer.
    public private(set) var maintenanceAskPending: Bool = false
    private var maintenanceAskContinuation: CheckedContinuation<Bool, Never>?

    /// Applied on the main actor whenever the idle scheduler transitions.
    /// Silent in Automatic mode — we still track `maintenanceActive` for
    /// internal logic but never surface a banner.
    func applyMaintenanceEvent(_ event: MaintenanceEvent) {
        let silent = FeatureFlags.shared.maintenanceMode == .automatic
        maintenanceLastEventAt = Date()
        switch event {
        case .started:
            maintenanceActive = true
            maintenanceStatus = silent ? nil : "Tidying your knowledge while your Mac is idle…"
        case .completed(let rows):
            maintenanceActive = false
            maintenanceStatus = silent ? nil : "Maintenance complete · \(rows) memories refreshed"
        case .paused:
            maintenanceActive = false
            maintenanceStatus = silent ? nil : "Maintenance paused — you're back"
        }
    }

    /// Policy gate consulted by the scheduler before each pass. Off →
    /// never; Automatic / Notify → always; Ask → surface a prompt and
    /// await the user's choice.
    func maintenanceGate() async -> Bool {
        switch FeatureFlags.shared.maintenanceMode {
        case .off:
            return false
        case .automatic, .notify:
            return true
        case .ask:
            guard !maintenanceAskPending else { return false }
            maintenanceAskPending = true
            maintenanceStatus = "Run maintenance now? Your Mac is idle."
            maintenanceLastEventAt = Date()
            let answer = await withCheckedContinuation { cont in
                maintenanceAskContinuation = cont
            }
            maintenanceAskPending = false
            maintenanceStatus = nil
            return answer
        }
    }

    /// Called by the UI when the user answers the "Ask first" prompt.
    public func respondToMaintenancePrompt(_ run: Bool) {
        maintenanceAskContinuation?.resume(returning: run)
        maintenanceAskContinuation = nil
        maintenanceAskPending = false
    }

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
    /// Ledger-AI v28 — closed-corpus answer contract stores. A corpus
    /// snapshot is taken per answer; the answer + its claims + evidence
    /// are persisted so "Why this answer?" can reconstruct the ledger
    /// state each answer was produced against.
    public private(set) var corpusSnapshots: CorpusSnapshotRepository?
    public private(set) var answerLedger: AnswerLedgerRepository?
    /// System 2 (Hot/Warm/Cold) — per-document importance + tier.
    public private(set) var enrichment: EnrichmentStatusRepository?
    /// System 3 — inferred missing-evidence gap nodes.
    public private(set) var gapNodes: GapNodeRepository?
    /// System 3 — persisted conflicts between simultaneously-supported claims.
    public private(set) var contradictions: ContradictionsRepository?
    /// T17 — append-only human-review ledger over reconstructed facts.
    public private(set) var factReviews: FactReviewsRepository?
    /// T18 — append-only chain-of-custody ledger over source files.
    public private(set) var custody: CustodyRepository?
    /// Count of open contradictions from the last proactive/maintenance scan.
    public private(set) var proactiveContradictionCount: Int = 0

    // MARK: - Header search hand-off
    /// A query typed into the always-visible header search box. SearchView
    /// picks it up on appear / change, runs it, then clears this. Lets the
    /// user search from anywhere without first navigating to Search.
    public var pendingSearchQuery: String?

    // MARK: - Self-check (auto, zero-touch)
    /// Result of the fast self-check (deterministic logic + all Convert
    /// formats + all 3 system modes/MoE). Auto-run once when Settings first
    /// appears and cached here, so the verdict shows with no clicks and does
    /// not re-run on every navigation. `nil` until the first run completes.
    public private(set) var selfCheckReport: ReleaseReadiness.Report?

    /// Runs the fast (no-LLM, seconds) self-check once and caches it.
    /// Idempotent: returns immediately if already run this session.
    public func runFastSelfCheckIfNeeded() async {
        guard selfCheckReport == nil else { return }
        let report = await ReleaseReadiness.run(self, mode: .fast)
        selfCheckReport = report
    }

    /// Caches a self-check report produced by a manual run (Settings) so the
    /// always-visible verdict chip reflects it.
    public func recordSelfCheck(_ report: ReleaseReadiness.Report) {
        selfCheckReport = report
    }

    // MARK: - System-mode chooser (first run + manual)
    /// Drives the system-mode chooser sheet (RootView presents it).
    public var showModeChooser: Bool = false
    /// Files the folder watcher has discovered this launch — shown on the
    /// active-mode badge so the user knows new material arrived.
    public private(set) var newFilesSinceLaunch: Int = 0
    /// Suspends first-run boot until the user picks a mode.
    private var modeSelectionContinuation: CheckedContinuation<Void, Never>?
    /// The one active system engine for this launch (built from SystemMode).
    /// Owns this system's background maintenance; see Knowledge/Ledger/SystemEngine.swift.
    public private(set) var systemEngine: (any SystemEngine)?
    /// Retains the context-prefix / document-card backfiller (Systems 1-3).
    public private(set) var contextPrefixBackfiller: ContextPrefixBackfiller?
    /// On-device idle name self-correction (mode-independent).
    public private(set) var entityReconciler: EntityReconciler?
    public private(set) var proactiveGapCount: Int = 0
    public private(set) var ledgerLastMaintainedAt: Date?
    /// G3.22 — exposed so smoke / eval rigs can assert against the
    /// typed-bond engine end-to-end.
    public private(set) var factBonds: FactBondsRepository?
    /// G2-SYNTHETIC-QUESTIONS — exposed so the Settings
    /// "Rebuild synthetic questions" button can re-run the generator
    /// over chunks that existed before this layer was wired.
    public private(set) var syntheticQuestions: SyntheticQuestionsRepository?
    /// Background queue that decouples synthetic-question generation
    /// from ingest. Owned by AppState so `shutdown()` can cancel its
    /// detached worker before the SQLite handle closes.
    public private(set) var syntheticQuestionQueue: SyntheticQuestionQueue?
    /// In-memory adjacency cache for the typed-bond graph. Warmed
    /// after the boot-time OntologyBackfill so BondWalker hits a
    /// hashmap instead of N SQL queries per hop. Optional — when nil
    /// (older boot paths, isolated test rigs), the SQL fallback runs.
    public private(set) var bondGraphCache: InMemoryBondGraph?
    /// In-memory cache for the Memory retrieval layer (first hop on
    /// every question).
    public private(set) var memoryCache: MemoryHashCache?
    /// In-memory per-entity sorted-by-date event index for Timeline
    /// range queries.
    public private(set) var entityTimeline: EntityTimeline?
    /// In-memory Trie + fuzzy index for entity hint resolution.
    public private(set) var entityTrie: EntityTrie?
    /// HNSW ANN index over the `vectors` table. Built at boot in
    /// parallel with the other caches. When built, SQLiteVectorStore
    /// .nearest takes the index path; brute-force is the fallback.
    public private(set) var hnswIndex: HNSWVectorIndex?

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
    /// G2-3 — model-choice advisor result computed at boot. Surfaced
    /// in SettingsView as a banner so the user is informed when their
    /// current model is a poor fit for the device. Nil while booting.
    public private(set) var modelChoiceAdvice: ModelChoiceRecommendation?
    /// G2-3 onboarding — present when the user needs to install
    /// Ollama and/or pull a model. Drives the "Setup" section in
    /// SettingsView. Nil when a reasoning model is already running.
    public private(set) var ollamaSetupSuggestion: OllamaSetupAdvisor.SetupSuggestion?
    /// G2-3 — persisted list of user-supplied .gguf files. SettingsView
    /// uses fileImporter to add new entries; AppState reloads on next
    /// boot. Public so the UI can read + write through the actor.
    public private(set) var ggufRegistry: GGUFRegistry?
    /// G2-3 — persisted list of user-supplied cloud endpoints (BYO
    /// API key + base URL + model name). API keys live in Keychain;
    /// metadata in JSON. PrivacyGate still gates whether these are
    /// callable.
    public private(set) var cloudEndpointRegistry: CloudEndpointRegistry?
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
    /// HISTORY Phase E.2 — exposed so the LibraryView can list the
    /// Phase B.2 communities + their LLM summaries. Nil until boot
    /// completes; UI guards on it.
    public private(set) var topicRetriever: TopicRetriever?
    /// Phase G.4 follow-on — exposed so HistoryView can let the user
    /// promote / demote / reject causal links the discoverer emitted.
    /// User assertions land as superseding rows with source=.user; the
    /// Hume guard stays intact since only an explicit user click can
    /// upgrade a heuristic link to CAUSED.
    public private(set) var eventLinks: EventLinksRepository?
    /// Phase H — LLM-driven investigation runner. Decomposes a complex
    /// question into sub-questions, runs each via the brain, and
    /// synthesizes a final answer. Nil while booting; the UI's
    /// "Investigate" affordance only fires when this is non-nil.
    public private(set) var investigationRunner: InvestigationRunner?
    /// Phase I.A — versioned audit log over `events` (SCD2 + PROV-O
    /// light). Future LLM-enrichment and user-correction paths write
    /// to this to keep an auditable history of every event change.
    public private(set) var eventVersions: EventVersionsRepository?
    /// Phase I.B — persisted Plan-and-Solve investigations. The
    /// Notebook tab reads from this; the InvestigationRunner saves
    /// here automatically on `.finished`.
    public private(set) var investigations: InvestigationsRepository?
    /// Phase J.5 — Vol 17 §A9 ProvenanceTracer. Single entry point
    /// for walking a citation back through the full ledger chain
    /// (file → KO → chunks → entities → events → causal links).
    /// Future "trace this claim" UI + the audit appendix in the
    /// report builder both call it.
    public private(set) var provenance: ProvenanceTracer?
    /// Phase J.7 — Vol 28 §Core Workspace. Persisted question
    /// bookmarks: the AskView's "save" button appends a row, the
    /// Saved Queries view lists + re-runs them.
    public private(set) var savedQueries: SavedQueriesRepository?
    /// Phase J.8 — Vol 17 §A8 ConfidencePropagator. Recomputes the
    /// confidence of every non-superseded causal link touching a
    /// corrected event. Future user-correction surfaces call this
    /// after writing a new event version so the link layer stays
    /// in sync with the updated event payload.
    public private(set) var confidencePropagator: ConfidencePropagator?
    /// Phase J.11 — Vol 17 §A6 EventMutator. Merge and split events
    /// with SCD2 audit through `event_versions` and atomic
    /// re-targeting of `event_entities` + `event_links`. Exposed so
    /// a future Timeline-edit affordance can call merge/split
    /// directly.
    public private(set) var eventMutator: EventMutator?
    /// Phase J.19 — Vol 17 §A3 assertion substrate. User-asserted
    /// claims + future LLM extractions land here as
    /// (subject, predicate, object, confidence, evidence) triples
    /// without disturbing the existing event/entity tables.
    public private(set) var assertions: AssertionsRepository?
    /// Phase J.13 — live observability. Per-stage ingest counters
    /// the pipeline bumps as files move through it; the Live tab
    /// reads these for the workflow strip.
    public private(set) var pipelineMetrics: PipelineMetrics?
    /// Phase J.13 — observable that polls the ledger + services
    /// every ~2s. The Live tab binds directly to its `current`
    /// sample and `throughput` window.
    public private(set) var liveMetrics: LiveMetrics?
    /// Phase J.13 — references to the four most user-visible
    /// background services so the Live tab can read each one's
    /// `currentStatus()`. Other services that don't yet expose a
    /// LastRunStatus are surfaced via the boolean health pill only.
    public private(set) var causalDiscovererService: CausalDiscoverer?
    public private(set) var cooccurrenceBuilderService: CooccurrenceGraphBuilder?
    public private(set) var communityDetectorService: AgglomerativeCommunityDetector?
    public private(set) var communitySummarizerService: CommunitySummarizer?

    private var watcherTask: Task<Void, Never>?

    // G2-SWIFT6 — the previous signature had `bookmarks: BookmarkStore
    // = .shared`. That default expression evaluates at the call site,
    // where Swift 6 strict concurrency saw "main-actor-isolated static
    // property cannot be referenced from a nonisolated context" even
    // though every real call site is @MainActor. Splitting into two
    // initialisers keeps the ergonomic default for the in-app case
    // while letting tests/eval explicitly pass an isolated store.
    public init(bookmarks: BookmarkStore) {
        self.bookmarks = bookmarks
        self.brain = MasterBrain()
    }

    public convenience init() {
        self.init(bookmarks: BookmarkStore.shared)
    }

    /// Boots AppState. Eval / Gate1Baseline / smoke harnesses pass
    /// `suppressAutoReingest: true` when they want a clean isolated DB
    /// without re-ingesting the user's persisted bookmarked roots —
    /// without this flag, any tempdir-DB-based test cascaded into a
    /// full archive replay (the v6/v7/v8 memory-drift attempts each
    /// timed out for exactly this reason).
    public func boot(
        databaseURL: URL? = nil,
        suppressAutoReingest: Bool = false
    ) async {
        do {
            // ── Storage ──────────────────────────────────────────────
            // `databaseURL` lets callers (Gate1Baseline) point AppState
            // at a throwaway temp-dir DB so the eval can't read from
            // (or write to) the user's real archive. nil = production
            // path under Application Support.
            let resolvedDBURL = databaseURL ?? DatabaseLocations.defaultDatabaseURL
            let db = try Database(url: resolvedDBURL)
            await db.loadSqliteVecIfAvailable()
            try await SchemaMigrations.migrate(db)
            AtlasLog.storage.info("Database open at \(db.url.path, privacy: .public)")

            // HNSW ANN index — built lazily after boot. Pass it to
            // SQLiteVectorStore so `nearest()` takes the index path
            // once it's built (brute force remains the fallback).
            let hnsw = HNSWVectorIndex()
            let vectors = SQLiteVectorStore(database: db, annIndex: hnsw)
            let files = FilesRepository(database: db)
            let objects = KnowledgeObjectRepository(database: db)
            let chunks = ChunksRepository(database: db)
            let entities = EntitiesRepository(database: db)
            let events = EventsRepository(database: db)
            let summariesRepo = SummariesRepository(database: db)
            let relationships = RelationshipsRepository(database: db)
            let memoryRepo = MemoryRepository(database: db)
            let conversationsRepo = ConversationsRepository(database: db)
            let corpusSnapshotsRepo = CorpusSnapshotRepository(database: db)
            let answerLedgerRepo = AnswerLedgerRepository(database: db)
            let enrichmentRepo = EnrichmentStatusRepository(database: db)
            let gapNodesRepo = GapNodeRepository(database: db)
            let contradictionsRepo = ContradictionsRepository(database: db)
            let factReviewsRepo = FactReviewsRepository(database: db)
            let custodyRepo = CustodyRepository(database: db)

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

            // G2-3 — register user-supplied .gguf files persisted
            // via SettingsView's file importer. Each entry becomes
            // its own LlamaCppProvider id so the advisor can rank it.
            let gguf = GGUFRegistry()
            let ggufEntries = await gguf.load()
            if !ggufEntries.isEmpty {
                AtlasLog.app.info("GGUF registry: \(ggufEntries.count, privacy: .public) user file(s)")
                for entry in ggufEntries {
                    let manifest = ModelManifest(
                        id: entry.id,
                        displayName: entry.displayName,
                        capabilities: [.textGeneration, .reasoning],
                        minRAMBytes: entry.estimatedRAMBytes,
                        diskBytes: entry.sizeBytes,
                        contextWindow: entry.contextWindow,
                        privacyLevel: .onDevice,
                        requiresDownload: false,
                        tier: entry.tier
                    )
                    // LlamaCppProvider is a stub today; once its
                    // runtime ships, the manifest already carries
                    // the file path the runtime needs.
                    _ = manifest
                }
            }

            // G2-3 — discover user-supplied MLX checkpoints in the
            // app's user-models directory (~/Library/Application
            // Support/Kalsmritikosh/MLXModels/<model-folder>/).
            // Each subdirectory with config.json registers as one
            // MLXProvider so the advisor can rank it among the user's
            // other choices.
            let mlxModels = MLXDiscovery.list()
            if !mlxModels.isEmpty {
                AtlasLog.app.info("MLX discovery: \(mlxModels.count, privacy: .public) user checkpoint(s)")
                for m in mlxModels {
                    let manifest = ModelManifest(
                        id: m.id,
                        displayName: m.displayName,
                        capabilities: [
                            .textGeneration, .reasoning, .summarization,
                            .extraction, .classification
                        ],
                        minRAMBytes: m.estimatedRAMBytes,
                        diskBytes: m.sizeBytes,
                        contextWindow: m.contextWindow,
                        privacyLevel: .onDevice,
                        requiresDownload: false,
                        tier: m.tier
                    )
                    await capabilities.register(MLXProvider(
                        id: m.id,
                        manifest: manifest,
                        downloader: ModelDownloader()
                    ))
                }
            }
            // Ollama is opt-in but on by default — when `ollama serve` is
            // running locally with the named models pulled, the registry
            // will rank it alongside Apple's model. When the server isn't
            // up, isAvailable() fails fast (1.5s probe) and the registry
            // skips it without affecting the user-visible latency.
            // G2-3 "any model the device can run" — discover every
            // model the user has pulled in their local Ollama daemon
            // and register one provider per model. The advisor then
            // ranks them by device-fit, surfaces the best, and warns
            // when the user has picked something that won't run well.
            // When the daemon isn't reachable OR no model is pulled,
            // we compute an OllamaSetupSuggestion so SettingsView can
            // walk the user through installing + downloading.
            let ollamaBase = URL(string: "http://localhost:11434")!
            let detectedOllama = await OllamaDiscovery.list(baseURL: ollamaBase)
            let ollamaReachable: Bool
            if !detectedOllama.isEmpty {
                ollamaReachable = true
            } else {
                ollamaReachable = await OllamaDiscovery.isReachable(baseURL: ollamaBase)
            }
            let setupSuggestion = OllamaSetupAdvisor.advise(
                ollamaReachable: ollamaReachable,
                installedReasoningModels: detectedOllama.map(\.name),
                totalRAMBytes: hardware.totalRAMBytes
            )
            if setupSuggestion.action != .nothingNeeded {
                AtlasLog.app.info("Ollama setup needed: \(setupSuggestion.summary, privacy: .public)")
            }
            if detectedOllama.isEmpty {
                await capabilities.register(OllamaProvider(
                    id: "provider.local.network",
                    baseURL: ollamaBase,
                    modelTag: "llama3:latest",
                    embeddingModelTag: "nomic-embed-text",
                    enabled: true,
                    displayName: "Local Ollama (llama3:latest)",
                    tier: .medium
                ))
            } else {
                AtlasLog.app.info("Ollama discovery: \(detectedOllama.count, privacy: .public) model(s) installed")
                for m in detectedOllama {
                    // Pull the actual context window from /api/show
                    // when available; fall back to a family default.
                    let ctx = await OllamaDiscovery.contextWindow(for: m.name, baseURL: ollamaBase)
                        ?? OllamaDiscovery.defaultContextWindow(forFamily: m.family)
                    let providerID = "provider.local.network.\(m.name)"
                    let displayName = "Ollama \(m.name)"
                    AtlasLog.app.info("Registering \(displayName, privacy: .public) — ram=\(m.estimatedRAMBytes, privacy: .public) tier=\(m.tier.rawValue, privacy: .public) ctx=\(ctx, privacy: .public)")
                    await capabilities.register(OllamaProvider(
                        id: providerID,
                        baseURL: ollamaBase,
                        modelTag: m.name,
                        embeddingModelTag: m.name.contains("embed") ? m.name : "nomic-embed-text",
                        enabled: true,
                        displayName: displayName,
                        tier: m.tier,
                        contextWindow: ctx,
                        minRAMBytes: m.estimatedRAMBytes
                    ))
                }
            }
            await capabilities.register(CloudProvider())

            // G2-3 — load user-supplied cloud endpoints. Each one
            // already carries a Keychain-resident API key from when
            // the user added it via Settings. Register one
            // CloudProvider per endpoint so the advisor can rank
            // them and the resolver can route to a specific one.
            let cloudRegistry = CloudEndpointRegistry()
            let cloudEntries = await cloudRegistry.load()
            if !cloudEntries.isEmpty {
                AtlasLog.app.info("Cloud BYO: \(cloudEntries.count, privacy: .public) endpoint(s)")
                for endpoint in cloudEntries {
                    guard let key = await cloudRegistry.apiKey(for: endpoint.id) else {
                        AtlasLog.app.warning("Cloud BYO: missing keychain entry for \(endpoint.id, privacy: .public); skipping")
                        continue
                    }
                    await capabilities.register(CloudProvider(endpoint: endpoint, apiKey: key))
                }
            }

            // G2-3 pre-warm — kick a tiny detached prompt at the
            // resolved reasoning provider so its model is paged in
            // (and, for Ollama, the daemon has already done its
            // first-token warmup) BEFORE the ingest pipeline asks
            // for per-chunk context_prefix generations. Without this
            // the first ~5 chunks each pay the cold-load tax and
            // time out on a per-chunk budget, leaving rows with NULL
            // prefix even though the provider would have answered
            // sub-second once warm. Detached so boot is not delayed.
            Task.detached(priority: .utility) { [capabilities] in
                let spec = CapabilitySpec.reasoning(
                    contextTokens: 256,
                    purpose: "appstate.boot.prewarm"
                )
                guard let provider = try? await capabilities.resolve(spec),
                      await provider.isAvailable() else { return }
                _ = try? await provider.generate(
                    prompt: "Reply with the single word: ready",
                    options: GenerationOptions(
                        maxTokens: 4,
                        temperature: 0.0,
                        systemPrompt: nil
                    )
                )
                AtlasLog.app.info("Reasoning provider pre-warmed: \(provider.id, privacy: .public)")
            }

            // ── Knowledge ────────────────────────────────────────────
            // Embedder goes through the CapabilityRegistry — when an
            // Ollama embedding model is reachable it wins; otherwise
            // we fall back to NLEmbedder. CachedEmbedder LRUs the result.
            let resolvedEmbedder = CapabilityResolvedEmbedder(capabilities: capabilities)
            let embedder: any Embedder = CachedEmbedder(
                wrapping: resolvedEmbedder,
                persistent: EmbeddingCacheRepository(database: db),
                modelID: "embedder-\(resolvedEmbedder.dimension)"
            )
            let timelineEngine = TimelineEngine(events: events)
            let summarizer = LLMSummarizer(
                objects: objects,
                summaries: summariesRepo,
                events: events,
                capabilities: capabilities
            )
            let graph = GraphStore(relationships: relationships)
            // G2-SYNTHETIC-QUESTIONS + G2-QA-PAIRS — repos shared between
            // ingest (writes) and retrieval (reads). One Database actor
            // → one source of truth for both surfaces.
            let syntheticQuestionsRepo = SyntheticQuestionsRepository(database: db)
            let qaPairsRepo = QAPairsRepository(database: db)
            // G3.10 — typed-bonds repo. Ingest writes per-KO bonds;
            // future schema-aware retrieval (Phase 4) and the
            // "Why this answer?" walk explainer (Phase 5) read them.
            let factBondsRepo = FactBondsRepository(database: db)
            // In-memory caches for the four hot paths. Created empty;
            // warmed asynchronously after OntologyBackfill finishes
            // (see Task.detached lower in this method). Each cache
            // exposes isWarm() so the consuming layer falls back to
            // SQL during the warm-up window.
            let bondCache = InMemoryBondGraph()
            let memoryHashCache = MemoryHashCache()
            let entityTimelineCache = EntityTimeline()
            let entityTrieCache = EntityTrie()
            let retriever = HybridRetriever(
                memory: memoryRepo,
                events: events,
                entities: entities,
                chunks: chunks,
                summaries: summariesRepo,
                graph: graph,
                vectors: vectors,
                embedder: embedder,
                syntheticQuestions: syntheticQuestionsRepo,
                qaPairs: qaPairsRepo,
                bondWalker: BondWalker(repository: factBondsRepo, cache: bondCache),
                walkExplainer: WalkExplainer(entities: entities, events: events, cache: bondCache),
                memoryCache: memoryHashCache,
                entityTrie: entityTrieCache,
                entityTimeline: entityTimelineCache
            )

            let expertRegistry = ExpertRegistry()
            await expertRegistry.register(EmailExpert())
            await expertRegistry.register(FinancialExpert())
            await expertRegistry.register(LegalExpert())
            await expertRegistry.register(ResearchExpert())
            await expertRegistry.register(OCRExpert())
            await expertRegistry.register(TimelineExpert())
            await expertRegistry.register(ProjectExpert())
            await expertRegistry.register(ReasoningExpert())   // generalist cross-source expert

            let router = DeterministicRouter(expertRegistry: expertRegistry)
            // G2-0 measurement (commit 0320a5a vs Gate 1 lock 4bcf4e5):
            // bumping this from 4 → 8 made lookup p50 +103% (concurrent
            // Ollama pressure with no breather between batches) and was
            // likely a contributor to a multihop recall regression
            // (0.67 → 0.54). Reverted to 4. Shared retrieval (the big
            // lever) is unchanged and keeps the temporal/multihop
            // ~15× wall-clock win. The retained 4+3 batching gives
            // Ollama small enqueue gaps that turned out to be load-
            // bearing for lookup latency.
            let workerPool = WorkerPool(maxConcurrentWorkers: 4)
            let executor = ParallelExecutor(pool: workerPool, experts: expertRegistry)
            let intentDetector = RuleIntentDetector()
            // G2-1 — Reranker shares the capability registry with the
            // experts. When a provider declares `.reranking` (today:
            // Ollama via prompted scoring) the verifier reorders
            // citation survivors by claim-relevance. When none is
            // available the Reranker returns identity scores and the
            // verifier falls back to pure scoreByObject — no regression.
            let reranker = Reranker(capabilities: capabilities)
            // G2-1.5 — per-session, in-memory question-meaning context.
            // MasterBrain records each turn; EvidenceVerifier reads the
            // snapshot at verify() time and hands it to the reranker so
            // follow-ups ("the same supplier", "by when?") resolve
            // against the prior turn instead of being re-interpreted
            // from scratch. Nothing here is persisted — privacy stays
            // on the ledger.
            let sessionProfile = SessionProfile()
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
                entityQualityGate: EntityQualityGate.bundled(),
                reranker: reranker,
                sessionProfile: sessionProfile
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
            // HISTORY Phase D.6 — narrative composer wired in. The
            // brain runs it for reconstructive intents and falls back
            // to the legacy expert pipeline for everything else. The
            // composer takes the chronological planner (B.2 topic
            // anchoring) and the capability registry; rule-based
            // fallback runs when no `.reasoning` provider clears the
            // privacy gate.
            let chronoPlanner = ChronologicalPlanner(database: db)
            // Phase G.3-G.5 — typed causal links between events. The
            // EventLinksRepository is shared by the discoverer (writes)
            // and the composers (reads).
            let eventLinksRepo = EventLinksRepository(database: db)
            let narrativeComposer: any NarrativeComposer = LLMNarrativeComposer(
                planner: chronoPlanner,
                capabilities: capabilities,
                links: eventLinksRepo
            )
            self.topicRetriever = TopicRetriever(database: db, entities: entities)
            // Phase G.4 — background discoverer that proposes typed
            // causal links between adjacent events. 4× per day; first
            // pass runs at boot so the History tab gets causal
            // chains immediately on a fresh ingest.
            let causalDiscoverer = CausalDiscoverer(
                database: db,
                events: events,
                entities: entities,
                objects: objects,
                links: eventLinksRepo
            )
            await causalDiscoverer.start()

            let brain = MasterBrain(
                intentDetector: intentDetector,
                router: router,
                retriever: retriever,
                executor: executor,
                capabilities: capabilities,
                verifier: verifier,
                weeklyBriefing: weeklyBriefing,
                sessionProfile: sessionProfile,
                memoryRepo: memoryRepo,
                narrativeComposer: narrativeComposer,
                eventsRepo: events,
                eventLinks: eventLinksRepo,
                onDemandDistiller: memoryDistiller
            )

            // ── Ingestion ────────────────────────────────────────────
            // G2-SYNTHETIC-QUESTIONS — same repo as the retriever's
            // (see above), so the ingest write path and the retrieval
            // read path share one Database actor. The heuristic
            // generator runs by default (free, deterministic, NLTagger
            // entity-name driven). To switch to LLM-backed generation,
            // pass CapabilitySyntheticQuestionGenerator(capabilities:)
            // as the generator argument below.
            // Background queue for synthetic-question generation — keeps
            // the ingest activity banner short and lets a 42K-chunk
            // archive complete in minutes instead of hours. The queue
            // drains in its own detached Task; the ingest path enqueues
            // and moves on.
            let synthQueue = SyntheticQuestionQueue(
                generator: HeuristicSyntheticQuestionGenerator(),
                repository: syntheticQuestionsRepo
            )

            // G2-3 — derive chunk size from the resolved reasoning
            // provider's manifest (contextWindow + minRAMBytes) AND
            // the user's actual device RAM. Adaptive to ANY model
            // and ANY device. Defaults if no provider resolves:
            // 8K tokens, 8 GB required (llama3 8B baseline).
            let resolvedManifest: (tokens: Int, requiredRAM: Int) = await {
                let spec = CapabilitySpec.reasoning(
                    contextTokens: 1_500,
                    purpose: "appstate.chunker.sizing"
                )
                guard let p = try? await capabilities.resolve(spec) else {
                    return (8_192, 8 * 1_073_741_824)
                }
                return (p.manifest.contextWindow, Int(p.manifest.minRAMBytes))
            }()
            let sizing = Chunker.diagnose(
                modelContextTokens: resolvedManifest.tokens,
                modelRequiredRAMBytes: resolvedManifest.requiredRAM,
                totalRAMBytes: Int(hardware.totalRAMBytes)
            )
            AtlasLog.app.info("Chunker target=\(sizing.target, privacy: .public) chars (modelTokens=\(resolvedManifest.tokens, privacy: .public), modelRAM=\(resolvedManifest.requiredRAM, privacy: .public) bytes, deviceRAM=\(hardware.totalRAMBytes, privacy: .public) bytes)")
            for w in sizing.warnings {
                AtlasLog.app.warning("Sizing warning: \(w, privacy: .public)")
            }
            let dynamicChunker = Chunker(targetCharacterCount: sizing.target)

            // G2-3 — compute the user-facing model-choice
            // recommendation. Surfaced in SettingsView as a banner.
            let resolvedReasoningManifest: ModelManifest? = await {
                let spec = CapabilitySpec.reasoning(
                    contextTokens: 1_500,
                    purpose: "appstate.advisor"
                )
                guard let p = try? await capabilities.resolve(spec) else { return nil }
                return p.manifest
            }()
            let allReasoningManifests: [ModelManifest] = await capabilities.allManifests()
            let advice = ModelChoiceAdvisor.advise(
                hardware: hardware,
                currentReasoning: resolvedReasoningManifest,
                availableReasoning: allReasoningManifests
            )
            AtlasLog.app.info("ModelChoiceAdvice severity=\(advice.severity.rawValue, privacy: .public): \(advice.summary, privacy: .public)")

            // Phase J.13 — created before IngestCoordinator so it can
            // be passed in; LiveMetrics polls it once it starts.
            let pipelineMetricsActor = PipelineMetrics()

            let ingest = IngestCoordinator(
                loaders: .standard(),
                chunker: dynamicChunker,
                entityExtractor: NLEntityExtractor(),
                entityLinker: EntityLinker(),
                entityQualityGate: EntityQualityGate.bundled(),
                eventExtractor: RuleEventExtractor(),
                narrativeSlotExtractor: RuleNarrativeSlotExtractor(),
                relationshipExtractor: Tier1RelationshipExtractor(),
                embedder: embedder,
                files: files,
                objects: objects,
                chunks: chunks,
                entities: entities,
                events: events,
                relationships: relationships,
                vectors: vectors,
                syntheticQuestions: syntheticQuestionsRepo,
                syntheticQuestionGenerator: HeuristicSyntheticQuestionGenerator(),
                synthQueue: synthQueue,
                qaPairs: qaPairsRepo,
                qaPairExtractor: EmailThreadQAPairExtractor(),
                bondConstructor: BondConstructor(repository: factBondsRepo, cache: bondCache),
                // G2-3 — LLM is the final path. No silent heuristic
                // substitution; the row's context_prefix stays NULL
                // when the LLM doesn't answer in budget. Timeout sized
                // for warm Ollama on a modest model (llama3 8B Q4 hits
                // sub-2s per chunk warm; bigger reasoning models can
                // take 6–15s per chunk, which we accept by default).
                //
                // PITFALL — bigger models:
                //   * a 14B Q4 model needs ~10GB RAM; on a 16GB Mac
                //     this evicts everything else and ingest slows by
                //     5–10x
                //   * cold-start can be 30+ seconds for a 14B; the
                //     boot pre-warm only helps if the user keeps the
                //     model loaded between sessions
                //   * inference is roughly linear in active params;
                //     14B is ~2x slower per token than 8B and 4x
                //     slower than a 3B distill
                // Settings UI surfaces these trade-offs at model
                // selection time so the user makes an informed call.
                // 2026-06-28 throughput fix — inline LLMContextPrefix
                // generation was the dominant ingest cost (8-24 s per
                // chunk × thousands of chunks = many hours of wait
                // time on a small archive). The
                // ContextPrefixBackfiller wired below already catches
                // missing prefixes in the background; setting this to
                // nil makes the ingest path fly through (chunk +
                // entity + event + slot work only) and lets the
                // backfiller fill prefixes opportunistically while
                // the user is already querying. Quality-or-nothing
                // still holds — chunks land with NULL prefix and get
                // re-enriched later, never with heuristic noise.
                contextPrefixGenerator: nil,
                pipelineMetrics: pipelineMetricsActor,
                custody: custodyRepo
            )

            // ── Concurrency + Live wiring ────────────────────────────
            let backgroundScheduler = BackgroundTaskScheduler()
            let compression = NightlyCompressionScheduler(
                summarizer: summarizer,
                memoryRepo: memoryRepo,
                idleThreshold: {
                    // Read live from Settings so changes apply without a
                    // relaunch. UserDefaults read is thread-safe.
                    let minutes = FeatureFlags.maintenanceIdleMinutesValue()
                    return TimeInterval(max(1, minutes) * 60)
                },
                gate: { [weak self] in
                    await self?.maintenanceGate() ?? false
                },
                onEvent: { event in
                    // Strong self is intentional: AppState is the app-lifetime
                    // root, so the scheduler→closure→AppState reference is not a
                    // leak, and a strong Sendable capture avoids the weak-optional
                    // read that Swift 6 flags inside a @Sendable closure.
                    Task { @MainActor in self.applyMaintenanceEvent(event) }
                }
            )
            await compression.start()

            // ── System engine (the three independent architectures) ──
            // Exactly one engine is built per launch from the active mode.
            // It owns this system's background maintenance; the ingest
            // plumbing below is generic and driven by `engine.ingestPolicy`.
            // Advanced FeatureFlags toggles are OR'd in as overrides. No
            // cross-mode gating lives in AppState any more — each engine is
            // self-contained (Knowledge/Ledger/*Engine.swift).
            let engine = SystemEngineFactory.make(FeatureFlags.systemModeValue())
            let basePolicy = engine.ingestPolicy

            // Ingest-time memory distillation: eager only if the engine's
            // policy wants it (Full LLM) or the advanced flag forces it.
            let distillOverride = await MainActor.run { FeatureFlags.shared.ingestTimeMemoryDistillation }
            let distillOnIngest = basePolicy.eagerMemoryDistillation || distillOverride
            let updater = IncrementalUpdater(
                stream: ingest.invalidations,
                distiller: memoryDistiller,
                distillationEnabled: distillOnIngest
            )
            await updater.start()
            if !distillOnIngest {
                AtlasLog.app.info("Ingest-time memory distillation OFF (ledger-first default — memory warmed on demand)")
            }

            // Hand the engine everything its maintenance needs, then
            // activate it. Only this engine's promoter runs — the others
            // are never even constructed.
            let engineContext = SystemEngineContext(
                enrichment: enrichmentRepo,
                objects: objects,
                entities: entities,
                events: events,
                distiller: memoryDistiller,
                scanForGaps: { [weak self] in
                    // System 3 idle maintenance re-derives BOTH the gap
                    // layer and the contradiction layer (both rule-based).
                    let gaps = await self?.scanForGaps() ?? 0
                    await self?.scanForContradictions()
                    return gaps
                },
                onGapScan: { count in
                    Task { @MainActor in
                        self.proactiveGapCount = count
                        self.ledgerLastMaintainedAt = Date()
                    }
                },
                bumpCitations: { [enrichmentRepo] ids in
                    for id in ids { await enrichmentRepo.bumpCitation(id) }
                }
            )
            await engine.activate(engineContext)
            AtlasLog.app.info("System engine active: \(engine.mode.rawValue, privacy: .public)")

            // On-device name self-correction — mode-independent, idle-gated.
            // Folds OCR/typo name variants into the corroborated spelling
            // (aliases + tier demotion; never deletes).
            let entityReconciler = EntityReconciler(
                reconcile: { [weak self] in await self?.reconcileEntityNames() ?? 0 }
            )
            await entityReconciler.start()

            // G2-3 — periodic backfill that re-runs the LLM context-
            // prefix generator on chunks whose row landed with NULL
            // because the LLM timed out during ingest. Per the
            // "quality or nothing" rule, we never substitute heuristic
            // noise into the embedding at ingest; this catches the
            // misses retroactively when the system is idle. Source
            // label is "<source>-backfill" so the operator can
            // distinguish ingest-time from backfilled rows in the
            // data.
            // Ledger-AI v28 — OFF by default. When enabled, the
            // backfiller now writes the prefix AND re-embeds the chunk's
            // vector (prefix + text), so the LLM work actually improves
            // retrieval. Still opt-in because it's LLM-heavy; the archive
            // stays fully FTS + entity + event searchable regardless.
            // System-mode preset: Full LLM turns the LLM context-prefix
            // sweep ON (deep); the other modes leave it off. Individual
            // flag is an advanced override.
            // Context-prefix work, driven by the engine's ingest policy:
            //   • Full LLM  → full sweep: an LLM prefix on EVERY chunk (+re-embed).
            //   • Hot/W/C + Ledger → one document-card call per file (first
            //     chunk only) — the Stage-2 "document card."
            // The advanced FeatureFlag forces the full sweep on regardless.
            let prefixOverride = await MainActor.run { FeatureFlags.shared.contextPrefixBackfillEnabled }
            let fullPrefixSweep = basePolicy.contextPrefixBackfill || prefixOverride
            let firstChunkCardOnly = basePolicy.firstChunkCard && !fullPrefixSweep
            var startedBackfiller: ContextPrefixBackfiller? = nil
            if fullPrefixSweep || firstChunkCardOnly {
                let contextPrefixBackfiller = ContextPrefixBackfiller(
                    chunks: chunks,
                    objects: objects,
                    generator: LLMContextPrefixGenerator(
                        capabilities: capabilities,
                        initialTimeoutMs: 8_000,
                        maxTimeoutMs: 32_000,
                        maxAttempts: 3
                    ),
                    embedder: embedder,
                    vectors: vectors,
                    firstChunkPerObjectOnly: firstChunkCardOnly
                )
                await contextPrefixBackfiller.start()
                startedBackfiller = contextPrefixBackfiller
                AtlasLog.app.info("ContextPrefixBackfiller started (mode: \(firstChunkCardOnly ? "document-card/file" : "full sweep", privacy: .public))")
            } else {
                AtlasLog.app.info("ContextPrefixBackfiller disabled")
            }

            // HISTORY Phase A.8 — periodic re-tier of pre-Phase-A
            // entity rows. Hourly cadence with 500-row batches;
            // demote-only (T2 → T3 when shape rules now flag the
            // value as noise). Never deletes; only updates the
            // quality_tier column.
            let qualityTierBackfiller = QualityTierBackfiller(database: db)
            await qualityTierBackfiller.start()

            // HISTORY Phase C follow-on — populate 5W+H slots for
            // events ingested before schema v21 landed. Without this
            // backfill, the reconstructive path retrieves events the
            // composer can barely describe (every old event's
            // narrative_slots_json is the default '{}'). 6-hour
            // cadence with 200-row batches; idempotent (only touches
            // events whose slot bundle is still empty).
            let narrativeSlotBackfiller = NarrativeSlotBackfiller(
                database: db,
                events: events,
                objects: objects,
                entities: entities,
                extractor: RuleNarrativeSlotExtractor()
            )
            await narrativeSlotBackfiller.start()

            // HISTORY Phase B.1 — entity co-occurrence graph
            // builder. Rebuilds 4× per day; community detection
            // (B.2) consumes the table. Skips T3 entities so the
            // topic graph doesn't get polluted by hostname-shape
            // noise.
            let cooccurrenceBuilder = CooccurrenceGraphBuilder(database: db)
            await cooccurrenceBuilder.start()

            // HISTORY Phase B.2 — community detection on the
            // co-occurrence graph. Runs every 12h; greedy
            // agglomerative algorithm with deterministic edge
            // ordering. Communities capped at 100 members so a
            // hub entity (gmail.com, common signatures) doesn't
            // collapse the whole graph into one mega-cluster.
            let communityDetector = AgglomerativeCommunityDetector(database: db)
            await communityDetector.start()

            // HISTORY Phase B.3 — per-community LLM
            // summarization. Runs 1× per day; produces a title +
            // 2-3 sentence summary per community detected in B.2.
            // Quality-or-nothing: leaves rows blank when the LLM
            // can't produce a clean response, never fabricates.
            let communitySummarizer = CommunitySummarizer(
                database: db,
                entities: entities,
                capabilities: capabilities
            )
            await communitySummarizer.start()

            // G3.8 — one-shot ontology backfill. Walks every entity /
            // event row whose `fact_type` is NULL (post-v11 migration)
            // and labels it via the rule-based classifier. Idempotent:
            // safe to re-run; only touches NULL rows. Runs in a detached
            // Task so it doesn't block boot; logs counts when done.
            Task.detached(priority: .utility) { [entities, events, objects, capabilities, factBondsRepo, bondCache, memoryHashCache, entityTimelineCache, entityTrieCache, memoryRepo, vectors, hnsw] in
                let llm = LLMSlotExtractor(capabilities: capabilities)
                let backfill = OntologyBackfill(
                    entities: entities,
                    events: events,
                    llmSlotExtractor: llm,
                    knowledgeObjects: objects,
                    cache: bondCache
                )
                _ = await backfill.run()
                // Warm the five in-memory caches in parallel after
                // backfill: fact_type / memory / timeline / trie /
                // HNSW vector index. Each flips isWarm()/isBuilt()
                // at completion so its consumer stops falling back
                // to SQL.
                async let bondWarm: Void = bondCache.warm(
                    bonds: factBondsRepo,
                    entities: entities,
                    events: events
                )
                async let memoryWarm: Void = memoryHashCache.warm(memory: memoryRepo)
                async let timelineWarm: Void = entityTimelineCache.warm(events: events)
                async let trieWarm: Void = entityTrieCache.warm(entities: entities)
                // G4.2 — load from disk when the persisted graph matches
                // the ledger; otherwise build fresh from SQL and re-persist.
                // Cold-start at 10M vectors: ~30-60s build → ~100ms load.
                // Cache file lives next to knowledge.sqlite so a DB wipe
                // also wipes the index.
                async let hnswWarm: HNSWVectorIndex.BuildStats = {
                    let cacheURL = resolvedDBURL
                        .deletingLastPathComponent()
                        .appendingPathComponent("hnsw-index.bin")
                    let liveCount = (try? await vectors.count()) ?? 0
                    if liveCount > 0,
                       await hnsw.load(from: cacheURL, expectedCount: liveCount) {
                        return await hnsw.stats()
                            ?? HNSWVectorIndex.BuildStats(vectorsLoaded: 0, maxLayer: 0, buildSeconds: 0)
                    }
                    let stats = await hnsw.build(from: vectors)
                    _ = await hnsw.persist(to: cacheURL)
                    return stats
                }()
                _ = await (bondWarm, memoryWarm, timelineWarm, trieWarm, hnswWarm)
                AtlasLog.app.info("All five in-memory caches warmed (bond + memory + timeline + trie + HNSW)")
            }

            let watcher = FolderWatcher()
            // Capture weak — when AppState is deallocated the consumer
            // task observes that ingest/watcher are gone and exits.
            // G4.4 + lane-based ingest. The prior shared
            // `maxInFlight=4` capped all formats at one semaphore;
            // a 4-PDF burst could stall image OCR even though Vision
            // ran on a totally different resource (Neural Engine).
            // Lanes give each hardware resource its own cap:
            //   cpu          ≈ cores - 1   (text/PDF/DOCX/EML/...)
            //   neuralEngine = 1           (Vision OCR, Apple Speech)
            //   gpuModel     = 1..2        (future Whisper/PaddleOCR)
            //   llm          = 1           (Ollama context-prefix)
            //   diskIO       = 2..4        (PST/NSF B-tree walks)
            //   network      = 4           (cloud OCR / reasoning)
            // Mixed-format corpora hit ~3× speedup; same-format
            // bursts unchanged (still bounded by their own lane).
            let laneScheduler = LaneScheduler(
                capacities: LaneScheduler.defaultCapacities(
                    processorCount: ProcessInfo.processInfo.activeProcessorCount,
                    availableRAMBytes: hardware.totalRAMBytes
                )
            )
            // Phase L — chat + browser loaders are flag-gated for
            // App Store compatibility. Default OFF; user opts in via
            // Settings. Plain-text chat exports default ON since
            // they don't touch any other app's data.
            let flags = FeatureFlags.shared
            let loaderRegistry = LoaderRegistry.standard(
                iMessageEnabled: flags.iMessageLoaderEnabled,
                browserHistoryEnabled: flags.browserHistoryLoaderEnabled,
                chatExportEnabled: flags.chatExportLoaderEnabled
            )
            // 2026-06-28 focus-suspension fix — the watcher consumer
            // previously ran as a plain `Task { ... }` spawned from
            // boot()'s MainActor context. That task inherited
            // MainActor isolation, which meant the `for await event`
            // loop and every `withIngestActivity` continuation got
            // queued through the AppKit main run loop. When the user
            // backgrounded the window, App Nap throttled the main run
            // loop and ingest visibly idled at 0% CPU for minutes at
            // a time. `Task.detached` runs on the cooperative thread
            // pool, immune to MainActor scheduling pressure.
            self.watcherTask = Task.detached(priority: .utility) { [weak self, weak ingest, weak watcher, laneScheduler, loaderRegistry] in
                guard let watcher else { return }
                for await event in watcher.events {
                    guard let ingest, let self else { return }
                    let discovered = event.urls.count
                    if discovered > 0 {
                        await MainActor.run { self.noteDiscoveredFiles(discovered) }
                    }
                    await withTaskGroup(of: Void.self) { group in
                        for url in event.urls {
                            group.addTask { [weak self, weak ingest] in
                                guard let self, let ingest else { return }
                                let type = SourceType.detect(from: url)
                                let lane = loaderRegistry.loader(for: type).primaryLane
                                await laneScheduler.withLane(lane) {
                                    await self.withIngestActivity(file: url.lastPathComponent) {
                                        do {
                                            _ = try await ingest.ingest(fileAt: url)
                                        } catch {
                                            AtlasLog.ingestion.error("Watcher-triggered ingest failed for \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                                        }
                                    }
                                }
                            }
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
            self.corpusSnapshots = corpusSnapshotsRepo
            self.answerLedger = answerLedgerRepo
            self.enrichment = enrichmentRepo
            self.gapNodes = gapNodesRepo
            self.contradictions = contradictionsRepo
            self.factReviews = factReviewsRepo
            self.custody = custodyRepo
            self.factBonds = factBondsRepo
            self.eventLinks = eventLinksRepo
            let investigationsRepo = InvestigationsRepository(database: db)
            self.investigations = investigationsRepo
            self.investigationRunner = InvestigationRunner(
                brain: brain,
                capabilities: capabilities,
                investigations: investigationsRepo
            )
            self.eventVersions = EventVersionsRepository(database: db)
            self.provenance = ProvenanceTracer(
                objects: objects,
                chunks: chunks,
                entities: entities,
                events: events,
                links: eventLinksRepo
            )
            self.savedQueries = SavedQueriesRepository(database: db)
            let confidencePropagatorActor = ConfidencePropagator(
                links: eventLinksRepo,
                events: events,
                database: db
            )
            self.confidencePropagator = confidencePropagatorActor
            let eventVersionsRepo = EventVersionsRepository(database: db)
            // Phase J.15 — Vol 25 ¶10. When any event version lands
            // (user correction, ontology backfill, future LLM
            // refiner), automatically recompute the confidence of
            // every causal link touching that event. The propagator
            // logs its own outcomes; this wiring just connects the
            // two actors.
            await eventVersionsRepo.setOnVersionRecorded { [weak confidencePropagatorActor] eventID in
                await confidencePropagatorActor?.propagate(forEvent: eventID)
            }
            self.eventMutator = EventMutator(
                database: db,
                events: events,
                versions: eventVersionsRepo
            )
            self.assertions = AssertionsRepository(database: db)
            // Phase J.13 — live observability. The pipeline-metrics
            // actor was created earlier (above the IngestCoordinator)
            // so the ingest path could be wired with it; here we just
            // stash a reference and start the polling task.
            self.pipelineMetrics = pipelineMetricsActor
            let live = LiveMetrics(appState: self, pipeline: pipelineMetricsActor)
            self.liveMetrics = live
            self.causalDiscovererService = causalDiscoverer
            self.cooccurrenceBuilderService = cooccurrenceBuilder
            self.communityDetectorService = communityDetector
            self.communitySummarizerService = communitySummarizer
            // Phase J.13 — polling is on-demand. LiveDashboardView
            // calls `live.start()` from `.onAppear` and `live.stop()`
            // from `.onDisappear`, so the 13 COUNT queries only fire
            // while the user is actually on the Live tab.
            self.syntheticQuestions = syntheticQuestionsRepo
            self.syntheticQuestionQueue = synthQueue
            // Exposed so smoke / DataHealthCheck can poke stats; warm
            // completion is async (chained off the OntologyBackfill
            // detached task below).
            self.bondGraphCache = bondCache
            self.memoryCache = memoryHashCache
            self.entityTimeline = entityTimelineCache
            self.entityTrie = entityTrieCache
            self.hnswIndex = hnsw
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
            self.modelChoiceAdvice = advice
            self.ollamaSetupSuggestion = setupSuggestion.action == .nothingNeeded
                ? nil : setupSuggestion
            self.ggufRegistry = gguf
            self.cloudEndpointRegistry = cloudRegistry
            self.expertRegistry = expertRegistry
            self.router = router
            self.workerPool = workerPool
            self.executor = executor
            self.intentDetector = intentDetector
            self.verifier = verifier
            self.backgroundScheduler = backgroundScheduler
            self.folderWatcher = watcher
            self.incrementalUpdater = updater
            self.systemEngine = engine
            self.contextPrefixBackfiller = startedBackfiller
            self.entityReconciler = entityReconciler
            self.brain = brain
            self.ingest = ingest
            self.phase = .ready
            AtlasLog.app.info("AppState booted successfully")

            // Post-boot auto-reingest: if a bookmark exists but the DB
            // has zero file rows under that root (recovered from a wiped
            // DB, fresh install on a backed-up machine, or schema migration
            // that dropped rows), kick off a one-shot ingest for that root
            // so the user doesn't have to re-pick the same folder. Runs
            // detached so boot completes immediately.
            //
            // Eval / Gate1Baseline / smoke harnesses skip this — they
            // run against an isolated tempdir DB and don't want the
            // user's persisted bookmarks pulled in (that cascade was
            // the v6/v7/v8 memory-drift timeout root cause).
            if !suppressAutoReingest {
                // Detached so the bulk re-ingest pass runs on the
                // cooperative pool, not on MainActor. Pairs with the
                // watcherTask fix above — both are long-running ingest
                // dispatchers that the focus-suspension bug stalled.
                Task.detached(priority: .utility) { [weak self] in
                    await self?.autoReingestEmptyRoots()
                }
            } else {
                AtlasLog.app.info("AppState: auto-reingest suppressed (eval / smoke boot)")
            }
        } catch {
            AtlasLog.app.error("AppState boot failed: \(String(describing: error), privacy: .public)")
            self.phase = .failed("\(error)")
        }
    }

    /// Bumps the in-flight counter for the duration of `body`. Caller
    /// passes a display name so the banner can show "last: <file>"
    /// after the work finishes.
    ///
    /// `nonisolated` so detached ingest dispatchers (watcherTask,
    /// autoReingest, boostIngestForQuestion) can wrap their per-file
    /// work without re-pinning the closure body to MainActor. The
    /// counter mutations explicitly hop to MainActor via
    /// `MainActor.run`; the actual ingest work in `body` runs on
    /// whichever executor its caller is on (usually the cooperative
    /// pool, or the IngestCoordinator actor's own queue).
    public nonisolated func withIngestActivity<T>(
        file displayName: String,
        body: () async throws -> T
    ) async rethrows -> T {
        await MainActor.run {
            self.ingestActiveCount += 1
        }
        defer {
            // The end-state mutation is scheduled on MainActor but
            // doesn't block the caller — once `body` returns the
            // counter eventually decrements and the banner clears.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.ingestActiveCount = max(0, self.ingestActiveCount - 1)
                self.ingestLastFile = displayName
                if self.ingestActiveCount == 0 {
                    // Clear "last file" after a brief delay so the user
                    // sees it for a beat once everything finishes.
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if self.ingestActiveCount == 0 {
                        self.ingestLastFile = nil
                    }
                }
            }
        }
        return try await body()
    }

    /// Maximum files boosted into ingestion per question. Prevents a
    /// vague question ("what's in my archive?") from drowning the queue.
    public static let maxBoostedFilesPerQuestion = 25

    /// Query-driven priority ingest. When the user asks a question
    /// — especially while bulk ingest is still running or hasn't
    /// started — pull the high-signal nouns out of the question and
    /// hand any filename-matching files in the watched roots straight
    /// to the IngestCoordinator. The actor's serialized queue runs them
    /// next, and T8's hash-idempotent path no-ops on files already
    /// ingested. Fire-and-forget — the brain's own answer call runs in
    /// parallel and gets refined on the user's next question.
    /// Ledger-AI v28 — take a fresh corpus snapshot and persist the
    /// answer (with its claims + citation evidence) against it. Called
    /// after every user-facing answer so the ledger records what the
    /// archive looked like when each answer was produced. Best-effort:
    /// failures are logged, never surfaced to the user.
    public func recordAnswer(question: String, answer: VerifiedAnswer) async {
        guard let snapshots = corpusSnapshots, let ledger = answerLedger else { return }
        let snapshot = await currentCorpusSnapshot()
        do {
            if let snapshot { try await snapshots.insert(snapshot) }
            try await ledger.persist(
                question: question,
                answer: answer,
                corpusSnapshotID: snapshot?.id
            )
        } catch {
            AtlasLog.app.error("recordAnswer failed: \(String(describing: error), privacy: .public)")
        }

        // Hand the shipped answer to the active system engine. System 2
        // (Hot/Warm/Cold) folds the citation signal into importance on its
        // next idle scoring pass; the other engines no-op. All mode-
        // specific behaviour now lives in the engine, not here.
        await systemEngine?.onAnswer(answer)
    }

    /// Build a point-in-time census of the archive from the live repos.
    /// FTS is populated synchronously at chunk insert, so parsed KOs are
    /// immediately searchable — indexedCount tracks parsedCount. Returns
    /// nil if the core repos aren't booted.
    public func currentCorpusSnapshot() async -> CorpusSnapshot? {
        guard let files, let objects else { return nil }
        let fileCount = (try? await files.count()) ?? 0
        let parsed = (try? await objects.count()) ?? 0
        let eventCount = (try? await events?.count() ?? 0) ?? 0
        // Ledgered = parsed KOs that have contributed structured facts.
        // Approximate as parsed when any events exist (the extractor ran);
        // 0 before the first extraction pass.
        let ledgered = eventCount > 0 ? parsed : 0
        return CorpusSnapshot(
            schemaVersion: SchemaMigrations.latestVersion,
            fileCount: fileCount,
            parsedCount: parsed,
            indexedCount: parsed,      // FTS is synchronous at insert
            ledgeredCount: ledgered,
            failedCount: 0
        )
    }

    // MARK: - System-mode selection

    /// Called from the app entry BEFORE `boot()`. On a fresh install this
    /// suspends until the user picks a mode, so the engine boots in the
    /// chosen mode with no relaunch. On later launches it returns at once.
    public func awaitModeSelectionIfNeeded() async {
        if FeatureFlags.shared.systemModeChosen { return }
        showModeChooser = true
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.modeSelectionContinuation = cont
        }
    }

    /// Persist the chosen mode and dismiss the chooser. On first run this
    /// unblocks `boot()`. After boot, the change is saved but the running
    /// engine keeps its mode until the next launch (the ingest stream has a
    /// single consumer, so mode is a boot-time decision) — the chooser
    /// surfaces that via `modeAppliesNextLaunch`.
    public func chooseMode(_ mode: SystemMode) {
        FeatureFlags.shared.systemMode = mode
        FeatureFlags.shared.systemModeChosen = true
        showModeChooser = false
        if let cont = modeSelectionContinuation {
            modeSelectionContinuation = nil
            cont.resume()
        }
    }

    /// True once the engine has already booted, so a mode change now only
    /// takes effect on the next launch.
    public var modeAppliesNextLaunch: Bool {
        if case .ready = phase { return true }
        return false
    }

    /// Folder watcher hook — record newly discovered files for the badge.
    public func noteDiscoveredFiles(_ count: Int) {
        guard count > 0 else { return }
        newFilesSinceLaunch += count
    }

    // MARK: - Entity name self-correction (on-device, non-destructive)

    /// Fold single-occurrence OCR/typo name variants into the corroborated
    /// spelling — e.g. a garbled signature-line "Thirshendus Sasmal" becomes
    /// an alias of "Shirshendu Sasmal" (seen cleanly several times). Rule-
    /// based, no LLM, no deletes: the variant is aliased + demoted in trust
    /// (T3 / low confidence), so lookups + answers resolve to the winner
    /// while the original row is preserved. Returns how many were folded.
    @discardableResult
    public func reconcileEntityNames() async -> Int {
        guard let entities else { return 0 }
        let people = (try? await entities.canonicalsWithMentionCounts(kind: .person, limit: 2_000)) ?? []
        guard people.count > 1 else { return 0 }
        // Most-corroborated names first — they become the winners.
        let ranked = people.sorted { $0.mentionCount > $1.mentionCount }
        var claimed = Set<UUID>()
        var folded = 0
        for i in 0..<ranked.count {
            let winner = ranked[i]
            if claimed.contains(winner.id) { continue }
            guard winner.mentionCount >= 2 else { break }   // list is sorted; rest are <2 too
            for j in (i + 1)..<ranked.count {
                let loser = ranked[j]
                if claimed.contains(loser.id) { continue }
                guard loser.mentionCount <= 1 else { continue }   // only lone slips fold in
                guard Self.plausibleOCRVariant(winner: winner.normalized, loser: loser.normalized) else { continue }
                do {
                    try await entities.markOCRVariant(
                        loserID: loser.id,
                        winnerID: winner.id,
                        loserNormalized: loser.normalized
                    )
                    claimed.insert(loser.id)
                    folded += 1
                    AtlasLog.knowledge.info("Reconcile: '\(loser.value, privacy: .public)' → variant of '\(winner.value, privacy: .public)'")
                } catch {
                    AtlasLog.knowledge.error("Reconcile failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
        return folded
    }

    /// Conservative same-person test: identical surname, both multi-token,
    /// high Jaro-Winkler. Tuned to catch "thirshendus sasmal" ≈
    /// "shirshendu sasmal" while never merging two genuinely different people.
    private static func plausibleOCRVariant(winner: String, loser: String) -> Bool {
        guard winner != loser else { return false }
        let w = winner.split(separator: " ")
        let l = loser.split(separator: " ")
        guard w.count >= 2, l.count >= 2 else { return false }
        guard let ws = w.last, let ls = l.last, ws == ls else { return false }  // same surname
        return NameSimilarity.jaroWinkler(winner, loser) >= 0.88
    }

    // MARK: - System 3: gap detection + investigation (rule-based)

    /// Scan the ledger for expected-but-missing evidence and persist
    /// GapNodes. Rule-based, no LLM. Runs all three GapDetector rules:
    ///   1. sequence holes in numbered IDs (invoice / payment),
    ///   2. dangling references ("invoice #42" with no such invoice ingested),
    ///   3. reply threads whose original message wasn't ingested.
    /// Returns the count found.
    @discardableResult
    public func scanForGaps() async -> Int {
        guard let entities, let gapNodes else { return 0 }
        await gapNodes.clear()
        let detector = GapDetector()
        var found: [GapNode] = []

        // Rule 1 — holes in numbered sequences. Also collect the known
        // invoice numbers to feed the dangling-reference rule below.
        let numbered: [(Entity.Kind, String)] = [
            (.invoiceNumber, "Invoice"),
            (.paymentID, "Payment")
        ]
        var knownInvoiceNumbers = Set<Int>()
        for (kind, hint) in numbered {
            let rows = (try? await entities.list(kind: kind, limit: 500)) ?? []
            let labels = rows.map(\.value)
            found += detector.detectSequenceGaps(labels: labels, kindHint: hint)
            if kind == .invoiceNumber {
                for label in labels { knownInvoiceNumbers.formUnion(Self.integers(in: label)) }
            }
        }

        // Rules 2 & 3 need document bodies + subjects. Load a bounded
        // sample so one huge archive can't make an idle scan expensive.
        if let objects {
            let sample = await loadObjectSample(objects: objects, limit: 300)

            // Rule 2 — dangling references to invoices not in the archive.
            let texts = sample.map { (objectID: $0.id, text: $0.content) }
            found += detector.detectDanglingReferences(
                texts: texts,
                knownNumbers: knownInvoiceNumbers,
                referenceKeyword: "invoice"
            )

            // Rule 3 — replies whose original (thread root) wasn't ingested.
            // A message is a "root" if its subject carries no reply prefix;
            // a reply hasParent iff some root shares its normalized subject.
            let rootSubjects = Set(
                sample.compactMap { row -> String? in
                    guard let s = row.subject, !s.isEmpty, !Self.isReplySubject(s) else { return nil }
                    let n = Self.normalizeSubject(s)
                    return n.isEmpty ? nil : n
                }
            )
            let replySubjects: [(objectID: UUID, subject: String, hasParent: Bool)] =
                sample.compactMap { row in
                    guard let s = row.subject, !s.isEmpty else { return nil }
                    let hasParent = rootSubjects.contains(Self.normalizeSubject(s))
                    return (objectID: row.id, subject: s, hasParent: hasParent)
                }
            found += detector.detectThreadParent(replySubjects: replySubjects)
        }

        await gapNodes.insertMany(found)
        AtlasLog.knowledge.info("Gap scan found \(found.count, privacy: .public) likely-missing items (sequence + dangling-ref + thread-parent)")
        return found.count
    }

    /// Scan the ledger for CONTRADICTIONS — conflicts the archive
    /// supports simultaneously (currently: the same event dated
    /// differently by two independent sources). Rule-based, no LLM.
    /// Persists the open set (replacing the prior scan) and returns the count.
    @discardableResult
    public func scanForContradictions() async -> Int {
        guard let events, let contradictions else { return 0 }
        let recent = (try? await events.recent(limit: 2_000)) ?? []
        let found = ContradictionDetector().detectEventDateConflicts(recent)
        await contradictions.clear()
        await contradictions.insertMany(found)
        let openCount = await contradictions.count()
        self.proactiveContradictionCount = openCount
        AtlasLog.knowledge.info("Contradiction scan found \(found.count, privacy: .public) conflicting-date pair(s)")
        return found.count
    }

    /// Load a bounded sample of objects with their body + email subject
    /// (from metadata) for the rule-based gap detectors. No LLM.
    private func loadObjectSample(
        objects: KnowledgeObjectRepository,
        limit: Int
    ) async -> [(id: UUID, content: String, subject: String?)] {
        let ids = (try? await objects.allIDs(offset: 0, pageSize: limit)) ?? []
        var out: [(id: UUID, content: String, subject: String?)] = []
        out.reserveCapacity(ids.count)
        for id in ids {
            guard let obj = (try? await objects.load(id: id)) ?? nil else { continue }
            var subject: String?
            if case .string(let s)? = obj.metadata["subject"]?.value { subject = s }
            out.append((id: obj.id, content: obj.content, subject: subject))
        }
        return out
    }

    /// True if a subject line is a reply / forward.
    private static func isReplySubject(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.hasPrefix("re:") || t.hasPrefix("re ")
            || t.hasPrefix("fwd:") || t.hasPrefix("fwd ")
            || t.hasPrefix("fw:") || t.hasPrefix("fw ")
    }

    /// Strip leading reply / forward prefixes and normalize for matching.
    private static func normalizeSubject(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var changed = true
        while changed {
            changed = false
            for p in ["re:", "fwd:", "fw:", "re ", "fwd ", "fw "] where t.hasPrefix(p) {
                t = String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        return t
    }

    /// Every run of digits in a string, parsed to Int (for known-number sets).
    private static func integers(in s: String) -> [Int] {
        var out: [Int] = []
        var current = ""
        for ch in s {
            if ch.isNumber { current.append(ch) }
            else if let n = Int(current) { out.append(n); current = "" }
            else { current = "" }
        }
        if let n = Int(current) { out.append(n) }
        return out
    }

    /// Fishbone (Ishikawa) cause-and-effect for one event — deterministic
    /// graph query over the causal-link ledger. No LLM.
    public func fishbone(forEventID id: Event.ID) async -> Fishbone? {
        guard let events, let eventLinks else { return nil }
        guard let effect = (try? await events.findByIDs([id]))?.first else { return nil }
        let incoming = (try? await eventLinks.incoming(to: id)) ?? []
        let sourceIDs = incoming.map(\.sourceEventID)
        let causeEvents = (try? await events.findByIDs(sourceIDs)) ?? []
        return FishboneAnalyzer().analyze(effect: effect, links: incoming, events: causeEvents)
    }

    /// 5-Whys root-cause chain for one event — walks the causal graph.
    public func fiveWhys(forEventID id: Event.ID, maxDepth: Int = 5) async -> FiveWhysResult? {
        guard let events, let eventLinks else { return nil }
        guard let effect = (try? await events.findByIDs([id]))?.first else { return nil }
        // Pull a generous slice of links + events to walk. For a modest
        // archive this is fine; a huge one would page this.
        let allEvents = (try? await events.recent(limit: 2_000)) ?? []
        let ids = allEvents.map(\.id)
        let links = (try? await eventLinks.links(in: ids)) ?? []
        return FiveWhysAnalyzer().analyze(effect: effect, links: links, events: allEvents, maxDepth: maxDepth)
    }

    public func boostIngestForQuestion(_ question: String) async {
        guard let ingest else { return }
        let nouns = Self.extractNouns(from: question)
        guard !nouns.isEmpty else { return }
        AtlasLog.ingestion.info("Boost ingest for nouns: \(nouns.joined(separator: ", "), privacy: .public)")
        var collected: [URL] = []
        for root in bookmarks.roots {
            if collected.count >= Self.maxBoostedFilesPerQuestion { break }
            guard let url = try? bookmarks.resolve(root) else { continue }
            defer { bookmarks.stopAccessing(url) }
            let matches = Self.scanFiles(at: url, matching: nouns,
                                         remaining: Self.maxBoostedFilesPerQuestion - collected.count)
            collected.append(contentsOf: matches)
        }
        guard !collected.isEmpty else {
            AtlasLog.ingestion.info("Boost: no filename matches found")
            return
        }
        AtlasLog.ingestion.info("Boost: queueing \(collected.count, privacy: .public) file(s) for priority ingest")
        for matchURL in collected {
            // Detached so the per-file ingest runs on the cooperative
            // pool and the boost path doesn't pile MainActor tasks
            // behind any in-flight SwiftUI work. The IngestCoordinator
            // is its own actor, so the actual work runs on its queue
            // regardless of how the caller is scheduled.
            Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                await self.withIngestActivity(file: matchURL.lastPathComponent) {
                    _ = try? await ingest.ingest(fileAt: matchURL)
                }
            }
        }
    }

    /// Pull noun-shaped tokens from the raw question via NLTagger
    /// (on-device, English-tuned). Filters common stopwords / weekday
    /// names so generic question vocabulary doesn't trigger boost.
    /// Exposed (internal, not private) so SmokeTest can verify the
    /// extraction is sane on representative questions.
    static func extractNouns(from question: String) -> [String] {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return [] }
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType])
        tagger.string = trimmed
        // English-only product — pin the language so NLTagger doesn't
        // emit "Unsupported language X detected." when a question
        // contains pasted non-English fragments.
        tagger.setLanguage(.english, range: trimmed.startIndex..<trimmed.endIndex)
        var nouns = Set<String>()
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        tagger.enumerateTags(
            in: trimmed.startIndex..<trimmed.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: options
        ) { tag, range in
            if tag == .noun || tag == .otherWord {
                let token = String(trimmed[range])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if token.count >= 3, !Self.questionStopwords.contains(token) {
                    nouns.insert(token)
                }
            }
            return true
        }
        // Also pick up proper names (people / orgs / places) as
        // first-class boost terms even if NLTagger classified them as
        // something other than `.noun`.
        tagger.enumerateTags(
            in: trimmed.startIndex..<trimmed.endIndex,
            unit: .word,
            scheme: .nameType,
            options: options
        ) { tag, range in
            if tag == .personalName || tag == .organizationName || tag == .placeName {
                let token = String(trimmed[range])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if token.count >= 3 { nouns.insert(token) }
            }
            return true
        }
        return Array(nouns)
    }

    /// Common question vocabulary that NLTagger sometimes tags as
    /// noun but should never trigger file boosting.
    private static let questionStopwords: Set<String> = [
        "what", "when", "where", "who", "why", "how", "which",
        "tell", "show", "list", "give", "find", "search",
        "thing", "things", "stuff", "item", "items",
        "anyone", "anything", "something", "nothing",
        "today", "yesterday", "tomorrow", "week", "month", "year",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december",
        "atlas", "archive", "files", "file", "document", "documents",
        "answer", "question", "questions", "data"
    ]

    /// Walk the file tree under `root` collecting up to `remaining` URLs
    /// whose lowercased lastPathComponent contains ANY of the nouns.
    /// Cheap O(N) filesystem walk — no content reads. Exposed
    /// (internal, not private) so SmokeTest can verify matching.
    static func scanFiles(at root: URL, matching nouns: [String], remaining: Int) -> [URL] {
        guard remaining > 0 else { return [] }
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        var out: [URL] = []
        while let next = enumerator?.nextObject() as? URL {
            if out.count >= remaining { break }
            let isRegular = (try? next.resourceValues(forKeys: [.isRegularFileKey])
                .isRegularFile) ?? false
            guard isRegular else { continue }
            let name = next.lastPathComponent.lowercased()
            if nouns.contains(where: { name.contains($0) }) {
                out.append(next)
            }
        }
        return out
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

    /// Re-ingest any bookmarked root whose file rows are absent from the
    /// DB. Called once at the end of boot(). Each root with > 0 existing
    /// file rows is left alone — FolderWatcher handles the incremental
    /// case. Idempotent at the ingestor level (content-hash dedup).
    ///
    /// The function itself stays on MainActor (BookmarkStore lives
    /// there), but the per-file enumeration + ingest loop is handed
    /// off to a nonisolated helper so it runs on the cooperative pool.
    /// Without this the per-file `await ingest.ingest()` continuations
    /// queued back through the AppKit main run loop and stalled under
    /// App Nap when the window lost focus.
    public func autoReingestEmptyRoots() async {
        guard let ingest, let files else { return }
        // Snapshot the URLs that need a fresh pass while we're still on
        // MainActor (bookmarks resolution requires it). Each URL keeps
        // its security-scoped access live until the detached worker
        // releases it below.
        var rootsToIngest: [(displayName: String, url: URL)] = []
        for root in bookmarks.roots {
            guard let url = try? bookmarks.resolve(root) else { continue }
            let existing = (try? await files.countUnderRoot(url)) ?? 0
            if existing > 0 {
                bookmarks.stopAccessing(url)
                continue
            }
            AtlasLog.app.info("Auto-reingest: root \(root.displayName, privacy: .public) has 0 files in DB — kicking off bulk ingest")
            rootsToIngest.append((root.displayName, url))
        }

        // Hand each root to the nonisolated enumerator so the
        // per-file loop runs without MainActor scheduling pressure.
        let bookmarksRef = bookmarks
        await withTaskGroup(of: Void.self) { group in
            for (_, url) in rootsToIngest {
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.enumerateAndIngest(url: url, ingest: ingest, label: "Auto-reingest")
                    await MainActor.run {
                        bookmarksRef.stopAccessing(url)
                    }
                }
            }
        }
        AtlasLog.app.info("Auto-reingest pass complete")
    }

    @discardableResult
    public func ingestAllRoots() async -> Int {
        guard let ingest else { return 0 }
        // Snapshot URLs on MainActor (BookmarkStore is MainActor-isolated).
        var urls: [URL] = []
        for root in bookmarks.roots {
            guard let url = try? bookmarks.resolve(root) else { continue }
            urls.append(url)
        }
        let bookmarksRef = bookmarks
        // Counter must be Sendable + actor-safe; a tiny actor is enough.
        let counter = IngestCounter()
        await withTaskGroup(of: Void.self) { group in
            for url in urls {
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.enumerateAndIngest(
                        url: url,
                        ingest: ingest,
                        label: "Bulk ingest",
                        counter: counter
                    )
                    await MainActor.run {
                        bookmarksRef.stopAccessing(url)
                    }
                }
            }
        }
        return await counter.value
    }

    /// Per-root walker. `nonisolated` so the loop runs on whatever
    /// executor the caller picks (autoReingest uses a TaskGroup child
    /// from MainActor, which inherits a nonisolated context). Without
    /// this opt-out, the `while let next = enumerator?.nextObject()`
    /// loop pinned to MainActor and stalled under App Nap.
    nonisolated func enumerateAndIngest(
        url: URL,
        ingest: IngestCoordinator,
        label: String,
        counter: IngestCounter? = nil
    ) async {
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        while let next = enumerator?.nextObject() as? URL {
            let isRegular = (try? next.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isRegular else { continue }
            await self.withIngestActivity(file: next.lastPathComponent) {
                do {
                    _ = try await ingest.ingest(fileAt: next)
                    if let counter { await counter.increment() }
                } catch {
                    AtlasLog.ingestion.error("\(label, privacy: .public) failed for \(next.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// Deterministically release every resource the boot() flow opened.
    /// The eval harness (Gate1Baseline) MUST call this before its
    /// `defer` removes the temp directory; otherwise the SQLite handle
    /// stays open against an unlinked file and macOS raises
    /// `vnode unlinked while in use` / `invalidated open fd: N` per
    /// open descriptor. Idempotent: safe to call more than once.
    public func shutdown() async {
        watcherTask?.cancel()
        watcherTask = nil
        // Cancel synth-q queue worker before closing the DB so it
        // doesn't try to insert into a closed handle.
        await syntheticQuestionQueue?.shutdown()
        await database?.close()
        phase = .starting
    }
}
