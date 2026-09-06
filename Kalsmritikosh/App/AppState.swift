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

/// Cooperative pause/stop shared between the (nonisolated) bulk-ingest loop and
/// the coordinator's embedding drain. Callers hit `checkpoint()` at safe points:
/// it returns `false` when a Stop was requested (caller should break) and blocks
/// while Paused. No forced cancellation — work already in flight (one file's
/// atomic commit) always finishes, so the ledger is never left half-written.
public actor IngestControl {
    private var paused = false
    private var stopped = false
    public init() {}

    public func pause()  { paused = true }
    public func resume() { paused = false }
    public func stop()   { stopped = true; paused = false }
    /// Call when a fresh bulk pass begins so a prior Stop doesn't leak in.
    public func reset()  { paused = false; stopped = false }
    public var isStopped: Bool { stopped }
    public var isPaused: Bool { paused }

    /// Safe point: `false` → stop (break the loop); otherwise waits out any pause
    /// and returns `true` to continue.
    public func checkpoint() async -> Bool {
        if stopped { return false }
        while paused && !stopped {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return !stopped
    }
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
    /// The file being ingested RIGHT NOW — so a slow/stuck file is visible
    /// (e.g. a large mailbox that takes minutes). Cleared when idle.
    public private(set) var ingestCurrentFile: String?

    /// User-facing ingest run state driving the Pause / Resume / Stop controls
    /// in the live panel. `.paused` idles the pipeline BETWEEN files (never
    /// mid-record, so the per-document atomic commit stays intact); `.stopping`
    /// ends the current bulk pass at the next safe checkpoint.
    public enum IngestRunState: String, Sendable { case idle, running, paused, stopping }
    public private(set) var ingestRunState: IngestRunState = .idle

    /// ING-002 — the last bulk ingest's collected outcome (how many succeeded and which
    /// files could not be processed). nil until a batch has run. Surfaced so the UI can
    /// report failures instead of only a success count.
    public private(set) var lastIngestSummary: IngestBatchSummary?

    /// Cooperative pause/stop flag shared with the nonisolated bulk-ingest loop
    /// AND the coordinator's background embedding drain. Both consult it at safe
    /// checkpoints (between files / between embed batches).
    public let ingestControl = IngestControl()

    /// Set at boot when the only available local reasoning model does NOT fit
    /// this Mac comfortably (≤70% RAM) — e.g. a 26 GB model on a 16 GB device.
    /// The UI surfaces a consent prompt recommending a device-suitable model to
    /// pull via Ollama. nil = a fitting model is present (nothing to suggest).
    /// The heavy model keeps working until the user agrees to install the lighter one.
    public private(set) var pendingModelSuggestion: OllamaSetupAdvisor.ModelSuggestion?
    /// 0…1 while a recommended model is downloading; nil when idle.
    public private(set) var modelInstallProgress: Double?

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

    /// True when the user resumed keyboard/mouse activity while an idle
    /// background scan (gap + contradiction maintenance) was mid-pass —
    /// drives the sidebar "keep scanning or stop?" card (owner decision
    /// 2026-08-15: the idle start is fine, but resuming should ask).
    public private(set) var scanContinuePromptPending: Bool = false
    /// The in-flight idle maintenance pass; the card's Stop cancels it at
    /// the next rule boundary (the prior derived layer is preserved).
    private var idleMaintenanceScan: Task<Int, Never>?

    /// True while a memory-distillation pass is running (on-demand button or
    /// the idle background pass). Guards against overlapping runs and lets the
    /// UI disable the "Distill memory now" button while it's working.
    public private(set) var isDistillingMemory: Bool = false

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

    /// Called by the UI when the user answers the "background work running —
    /// continue or stop?" card. Stop cancels the in-flight maintenance pass
    /// at its next rule boundary (prior derived layers stay intact) AND
    /// pauses the ingest/enrichment pipeline (resumable from the Live panel —
    /// nothing in flight is left half-written). Continue suppresses re-asking
    /// until the current busy episode fully ends.
    public func respondToScanContinuePrompt(continueScanning: Bool) {
        if continueScanning {
            resumePromptSuppressed = true
        } else {
            idleMaintenanceScan?.cancel()
            if ingestRunState == .running || ingestActiveCount > 0 { pauseIngest() }
        }
        scanContinuePromptPending = false
    }

    /// Once the user chose Continue for this busy episode, don't re-ask on
    /// every later idle/return cycle — cleared when all work goes quiet.
    private var resumePromptSuppressed = false
    private var idleResumeWatcher: Task<Void, Never>?

    /// Any long-running background work in flight: bulk ingest, per-file
    /// enrichment activity, or the idle maintenance scan.
    private var backgroundWorkInFlight: Bool {
        ingestRunState == .running || ingestActiveCount > 0 || idleMaintenanceScan != nil
    }

    /// Owner decision 2026-08-15 (generalized): whenever the user RETURNS
    /// from ≥90s of inactivity while background work is running, raise the
    /// continue-or-stop card. This watcher covers the minutes-long work
    /// (ingest + enrichment) that the per-scan watcher was too narrow for.
    private func startIdleResumeWatcher() {
        idleResumeWatcher?.cancel()
        idleResumeWatcher = Task { [weak self] in
            var wasIdle = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                let idle = SystemActivity.isIdle(threshold: 90)
                let busy = self.backgroundWorkInFlight
                if !busy {
                    // Episode over — clear suppression and any stale card.
                    self.resumePromptSuppressed = false
                    if self.scanContinuePromptPending { self.scanContinuePromptPending = false }
                } else if wasIdle && !idle && !self.resumePromptSuppressed {
                    self.scanContinuePromptPending = true
                }
                wasIdle = idle
            }
        }
    }

    /// Shared memory-distillation core used by BOTH the on-demand "Distill
    /// memory now" button and the idle background pass. The ledger-first engine
    /// does no distillation at ingest (minimum-LLM promise), so this is the one
    /// place `memory_objects` gets built for the top subjects in the ledger.
    /// Safe to call repeatedly — a run already in progress is a no-op. Surfaces
    /// progress on the maintenance banner so the user sees it working. Returns
    /// the number of subjects distilled.
    @discardableResult
    public func distillMemory(maxPerKind: Int = 200) async -> Int {
        guard let distiller = memoryDistiller, !isDistillingMemory else { return 0 }
        isDistillingMemory = true
        let activity = beginProcess("Distilling memory")
        defer { finishProcess(activity) }
        let bannerWasActive = maintenanceActive
        maintenanceActive = true
        maintenanceStatus = "Distilling memory…"
        maintenanceLastEventAt = Date()

        let produced = await distiller.distillTopSubjects(maxPerKind: maxPerKind)

        isDistillingMemory = false
        maintenanceActive = bannerWasActive
        maintenanceStatus = "Memory distilled · \(produced.count) subject(s) refreshed"
        maintenanceLastEventAt = Date()
        KalsmritikoshLog.app.info("Memory distillation complete: \(produced.count, privacy: .public) subject(s)")
        return produced.count
    }

    // Storage
    public private(set) var database: Database?
    public private(set) var vectorStore: SQLiteVectorStore?
    public private(set) var files: FilesRepository?
    public private(set) var objects: KnowledgeObjectRepository?
    public private(set) var chunks: ChunksRepository?
    public private(set) var genericFacts: GenericFactRepository?
    /// OPS-003D — screen-level scope filter; resolves KO/chunk sensitivity for view layers.
    public private(set) var sensitiveScopes: SensitiveScopeRepository?
    /// OPS-003D.1 — fail-closed screen gate for all view layers, wired once here.
    public private(set) var screenAuthorizer: ScreenScopeAuthorizer?
    /// OPS-003D.1.2 — single production path for all SensitiveScope mutations.
    /// Callers must use this service; the architecture guard enforces the contract.
    public private(set) var mutationService: SensitiveScopeMutationService?
    /// OPS-003D.1.1 — bumped whenever a sensitive-scope assignment is created or revoked.
    /// SourceViewer, EvidenceViewer, and EventDetailSheet include this in their .task(id:)
    /// identity so open views revalidate immediately when policy changes.
    public private(set) var sensitiveScopeRevision: Int = 0

    /// Called automatically by the policyChanges observer wired in setup(). Bumps
    /// sensitiveScopeRevision so that AuthorizationTaskID-keyed tasks re-fire.
    public func notifyScopePolicyChanged() {
        sensitiveScopeRevision += 1
    }

    /// Exposed for the retrieval self-eval (recall@k on the user's own data).
    public private(set) var embedder: (any Embedder)?
    public private(set) var entities: EntitiesRepository?
    public private(set) var events: EventsRepository?
    public private(set) var summariesRepo: SummariesRepository?
    public private(set) var relationships: RelationshipsRepository?
    public private(set) var memoryRepo: MemoryRepository?
    /// Universal History program — canonical subject-scoped reconstruction engine
    /// and its versioned artifact store (both over the one ledger).
    public private(set) var historyEngine: HistoryReconstructionEngine?
    public private(set) var historyArtifacts: HistoryArtifactRepository?
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
    public private(set) var monitorSnapshots: MonitorSnapshotRepository?

    // MARK: - Unified activity tracker
    /// Every long-running task the user should see — title, start time, progress,
    /// ETA. The live panel + dashboard render this. Determinate tasks set a total.
    public private(set) var activeProcesses: [ProcessActivity] = []

    /// True total files to process during a bulk (re)ingest, pre-counted by
    /// walking the bookmarked roots BEFORE ingesting — so the progress bar's
    /// denominator is the WHOLE corpus, not just the files discovered so far
    /// (which made it read ~100% while only ~12% done). 0 = no bulk pass active.
    public private(set) var ingestPlannedFileTotal: Int = 0

    /// Set/clear the pre-counted bulk-ingest total (MainActor mutator).
    public func setIngestPlannedTotal(_ n: Int) { ingestPlannedFileTotal = max(0, n) }

    // MARK: - Ingest run control (Pause / Resume / Stop)

    /// Pause the whole pipeline — the bulk-ingest loop idles between files and
    /// the background embedding drain idles between batches. Nothing in flight
    /// is interrupted, so no record is left half-written.
    public func pauseIngest() {
        ingestRunState = .paused
        Task { await ingestControl.pause(); await ingest?.setDrainPaused(true) }
    }

    /// Resume after a pause.
    public func resumeIngest() {
        ingestRunState = .running
        Task { await ingestControl.resume(); await ingest?.setDrainPaused(false) }
    }

    /// Stop the current bulk pass at the next safe checkpoint and halt the
    /// embedding drain. Already-ingested files stay; a later ingest resumes the
    /// remaining ones (content-hash dedup skips what's done).
    public func stopIngest() {
        ingestRunState = .stopping
        Task {
            await ingestControl.stop()
            await ingest?.setDrainPaused(false)
            await ingest?.stopEmbeddingDrain()
        }
    }

    /// True while any background task the user could want to halt is in flight:
    /// the bulk (re)ingest pass (running / paused / stopping), the embedding
    /// drain that rides it, or the idle maintenance scan. Drives the always-
    /// visible "Stop all" control and the mode-switch confirmation — the button
    /// only appears while there is actually something to stop.
    public var hasStoppableBackgroundWork: Bool {
        ingestRunState == .running
            || ingestRunState == .paused
            || ingestRunState == .stopping
            || idleMaintenanceScan != nil
    }

    /// STOP ALL — one action that halts every stoppable background task at its
    /// next safe checkpoint: the bulk ingest pass, its background embedding
    /// drain, and the idle maintenance scan. Nothing in flight is force-killed
    /// (a document's atomic commit always finishes, so the ledger is never left
    /// half-written); already-finished work stays and a later run resumes the
    /// remainder via content-hash dedup. Idempotent — safe to call when idle.
    public func stopAllBackgroundWork() {
        // Only drive the ingest stop when a bulk pass owns the run state, so its
        // `defer { ingestRunState = .idle }` resets us. Calling it while idle
        // would strand the UI at "Stopping…" with nothing to reset it.
        if ingestRunState == .running || ingestRunState == .paused {
            stopIngest()
        }
        idleMaintenanceScan?.cancel()
        idleMaintenanceScan = nil
        scanContinuePromptPending = false
    }

    // MARK: - Add files (user-initiated ingest)

    /// Ingest user-picked files (from an "Add files" button) into the private
    /// archive with the full pipeline, tracked on the live panel so the user sees
    /// progress. Picker URLs are sandbox security-scoped, so access is started per
    /// file for the read. Folders are handled by the Sources watcher, not here.
    public func ingestFiles(_ urls: [URL]) async {
        guard let ingest, !urls.isEmpty else { return }
        let activity = beginProcess("Adding \(urls.count) file(s)…", total: urls.count)
        defer { finishProcess(activity); ingestCurrentFile = nil }
        var done = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            ingestCurrentFile = url.lastPathComponent
            do {
                _ = try await ingest.ingest(fileAt: url, intent: .fullAvailable)
                ingestLastFile = url.lastPathComponent
            } catch {
                KalsmritikoshLog.app.error("Add-files ingest failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            done += 1
            updateProcess(activity, done: done)
        }
    }

    // MARK: - Device-suitable model install (consent-gated)

    /// User declined the suggested lighter model — hide the prompt for this session.
    public func dismissModelSuggestion() { pendingModelSuggestion = nil }

    /// Pull the recommended device-suitable model via Ollama (only after the user
    /// consents in the UI), streaming progress, then register it as a provider so
    /// the resolver can prefer it over the heavy one. No download happens without
    /// this explicit call.
    public func installRecommendedModel() async {
        // Ollama is an internal/DEBUG-only provider path (GOV-001): the release
        // build must never download via or register a network-backed provider,
        // so this action compiles to a no-op outside DEBUG.
        #if DEBUG
        guard let sug = pendingModelSuggestion, let capabilities else { return }
        let base = URL(string: "http://localhost:11434")!
        let proc = beginProcess("Downloading \(sug.displayName)…")
        modelInstallProgress = 0
        let installer = OllamaInstaller(baseURL: base)
        var ok = false
        let stream = await installer.pull(modelTag: sug.modelTag)
        for await result in stream {
            switch result {
            case .success(let p):
                modelInstallProgress = p.fractionComplete
                if p.totalBytes > 0 { updateProcess(proc, done: Int(p.completedBytes), total: Int(p.totalBytes)) }
                if p.isComplete { ok = true }
            case .failure(let e):
                KalsmritikoshLog.app.error("Model pull failed: \(String(describing: e), privacy: .public)")
            }
        }
        finishProcess(proc)
        modelInstallProgress = nil
        if ok {
            await capabilities.register(OllamaProvider(
                id: "provider.local.network.\(sug.modelTag)",
                baseURL: base,
                modelTag: sug.modelTag,
                embeddingModelTag: "nomic-embed-text",
                enabled: true,
                displayName: "Ollama \(sug.modelTag)",
                tier: .medium
            ))
            KalsmritikoshLog.app.info("Installed + registered device-suitable model \(sug.modelTag, privacy: .public)")
            pendingModelSuggestion = nil
        }
        #endif
    }

    /// Count regular, non-hidden files under `urls` — a fast pre-pass (no file
    /// reads) so ingest progress has an honest denominator. Nonisolated: pure FS.
    /// Extensions ingestion skips (audio/video, deferred format) — excluded from
    /// the progress denominator so the honest bar still reaches 100%.
    private nonisolated static let mediaExtensions: Set<String> = [
        "mp3", "wav", "m4a", "aac", "aiff", "caf", "flac", "3gp", "3gpp",
        "mp4", "mov", "avi", "mkv", "m4v", "wmv", "flv", "webm"
    ]

    /// Pre-count the units of ingest work under `urls`: each non-media file is 1
    /// unit, but a mailbox (.mbox) is counted as its MESSAGE COUNT — because one
    /// 91 MB Sent.mbox expands into hundreds of messages, and treating it as "1
    /// file" made the bar sit at ~95% for the entire (long) mbox pass. Message
    /// count is a fast mmap'd scan of the "\nFrom " separators.
    nonisolated func countRegularFiles(in urls: [URL]) -> Int {
        let mboxSep: [UInt8] = [0x0A, 0x46, 0x72, 0x6F, 0x6D, 0x20]   // "\nFrom "
        var n = 0
        for url in urls {
            let e = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            while let next = e?.nextObject() as? URL {
                guard (try? next.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let ext = next.pathExtension.lowercased()
                if Self.mediaExtensions.contains(ext) { continue }
                if ext == "mbox" || ext == "mbx" {
                    if let data = try? Data(contentsOf: next, options: .mappedIfSafe) {
                        n += max(1, Self.countPattern(mboxSep, in: data) + 1)  // +1: first message has no leading \n
                    } else { n += 1 }
                } else {
                    n += 1
                }
            }
        }
        return n
    }

    /// Count non-overlapping occurrences of a short byte pattern in `data`
    /// (mmap-friendly linear scan). Used to size a mailbox by its message count.
    private nonisolated static func countPattern(_ pattern: [UInt8], in data: Data) -> Int {
        guard !pattern.isEmpty, data.count >= pattern.count else { return 0 }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            let bytes = raw.bindMemory(to: UInt8.self)
            var count = 0, i = 0
            let n = bytes.count, m = pattern.count
            while i <= n - m {
                if bytes[i] == pattern[0] {
                    var k = 1
                    while k < m && bytes[i + k] == pattern[k] { k += 1 }
                    if k == m { count += 1; i += m; continue }
                }
                i += 1
            }
            return count
        }
    }

    /// Register a task. Returns its id for update/finish.
    @discardableResult
    public func beginProcess(_ title: String, total: Int? = nil) -> UUID {
        let a = ProcessActivity(title: title, unitsTotal: total)
        activeProcesses.append(a)
        return a.id
    }

    public func updateProcess(_ id: UUID, done: Int, total: Int? = nil) {
        guard let i = activeProcesses.firstIndex(where: { $0.id == id }) else { return }
        activeProcesses[i].unitsDone = done
        if let total { activeProcesses[i].unitsTotal = total }
    }

    public func finishProcess(_ id: UUID) {
        activeProcesses.removeAll { $0.id == id }
    }
    /// System 3 — persisted conflicts between simultaneously-supported claims.
    public private(set) var contradictions: ContradictionsRepository?
    /// T17 — append-only human-review ledger over reconstructed facts.
    public private(set) var factReviews: FactReviewsRepository?
    /// T18 — append-only chain-of-custody ledger over source files.
    public private(set) var custody: CustodyRepository?
    /// AUD-CHAIN — tamper-evident hash chain sealing the custody + review
    /// ledgers; drives the Audit view's "Verify integrity" action.
    public private(set) var auditChain: AuditChainService?
    /// §16 — append-only derived-objects ledger (query-time extractions).
    public private(set) var derivedObjects: DerivedObjectsRepository?
    /// A2 — canonical structural evidence store (typed blocks + versions).
    public private(set) var evidenceStore: EvidenceStore?
    /// PERF.2 — durable deferred-enrichment job ledger.
    public private(set) var enrichmentJobs: EnrichmentJobRepository?
    /// TBJ-FINAL — durable time-bounded Job planning envelope over the existing task / deadline /
    /// workflow authorities. Live from boot; consumed by the persona shell's "My Work" surface in a
    /// later stage. It is NOT a second task or deadline system — see JobRepository.
    public private(set) var jobs: JobRepository?
    /// LAB-001 — the ONE canonical Workbench / DataLab dataset authority (supersedes the EvidenceDataset
    /// prototype). Live from boot over the shared ledger; consumed by the DataLab surfaces (LAB-004+).
    public private(set) var workbenchDatasets: WorkbenchDatasetRepository?
    /// LAB-002 — the safe transformation engine's authoritative writer/reader over the same dataset
    /// ledger. Computes with the pure WorkbenchTransformEngine (no `eval`) and persists reproducible,
    /// audited derived values. Live from boot; consumed by the DataLab surfaces (LAB-004+).
    public private(set) var workbenchTransforms: WorkbenchTransformRepository?
    /// LAB-003 — the scenario overlay authority (non-destructive what-if branches with undo/redo and
    /// reviewed promotion) over the same dataset ledger. Live from boot; consumed by the DataLab
    /// surfaces (LAB-004+). Never mutates canonical evidence.
    public private(set) var workbenchScenarios: WorkbenchScenarioRepository?
    /// LAB-005 — the deterministic evidence-quality analyzer over the dataset/scenario ledger (missing
    /// values, stale/inaccessible sources, unsupported transformations, unreviewed scenario values, …).
    /// Pure read-only analysis; never mutates canonical evidence. Live from boot once the dataset +
    /// scenario authorities are constructed.
    public private(set) var workbenchDataQuality: WorkbenchDataQualityAnalyzer?
    /// SHELL-001 — the shared macOS shell's durable navigation-session autosave/resume (browser-style
    /// Back/Forward location history, distinct from workflow Prev/Next). Live from boot; restores the
    /// exact location on relaunch. Pure shell state — touches no canonical evidence.
    public private(set) var shellSession: ShellSessionRepository?
    /// WORK-CENTER — the SAP-style guided workflow runner's numbered-document ledger (schema v105):
    /// WF- run documents plus the IMP/RPT/PRD/… documents each confirmed step posts, with transactional
    /// TYPE-YEAR-#### number ranges. Documents REFERENCE work done in the shared surfaces (soft refs);
    /// they fork no canonical evidence. Live from boot.
    public private(set) var workCenter: WorkCenterRepository?
    /// SHELL-003 — the ONE background-work gate: every optional/deferred worker asks this instead of
    /// checking idle independently. Composes the shared QueryPriorityGate + SystemActivity + the user's
    /// background preference into a single P0–P6 decision, so background maintenance never competes with
    /// foreground user work.
    public private(set) var backgroundWorkGate: BackgroundWorkGate?
    /// INV-01-A — the Investigator persona's durable case-intake & scope authority (schema v96). Records
    /// a case's purpose, scope framing, time window, the in-scope source set (the HARD evidence boundary),
    /// scope confirmation and any bound CONFIRMED deadline — surviving relaunch with append-only audit. A
    /// LENS over the one engine: it references canonical workspaces / sources / deadlines by id and forks
    /// no canonical evidence, task, deadline or SensitiveScope authority. Live from boot.
    public private(set) var investigationCases: InvestigationCaseRepository?
    /// INV-01-C1 — the Investigator "Ask" entry point. Orchestration only: it resolves the active case's
    /// authorized source scope and runs the SHARED MasterBrain over a SourceScopedRetriever so no
    /// unauthorized source can enter the evidence packet or citations. No persona engine. Live from boot.
    public private(set) var investigationAnswers: InvestigationAnswerService?
    /// INV-02 — the Investigator "Subject dossier" entry point: nominate a canonical entity as a case
    /// subject (only with in-scope evidence), record the human identity confirmation, and assemble a
    /// dossier that cites exact evidence within the case scope. A lens over the shared entity engine.
    public private(set) var investigationSubjectDossier: InvestigationSubjectDossierService?
    /// INV-03 — the Investigator "Identity resolution" entry point: propose/confirm/reject/reverse merges
    /// of canonical identities behind a human gate, over the SHARED reversible EntitiesRepository merge,
    /// recording every decision. No auto-merge. Live from boot.
    public private(set) var investigationIdentityResolution: InvestigationIdentityResolutionService?
    /// INV-04..07 — the Investigator analytical spine: Brainstorm board (leads → hypotheses), 5W1H
    /// worksheet (each cell cites evidence or is marked unknown), Evidence collection plan (requests for
    /// missing evidence), and the Hypothesis matrix (for/against evidence, human-confirmed, never auto-won).
    /// Case-scoped over canonical evidence. Live from boot.
    public private(set) var investigationAnalysis: InvestigationAnalysisService?
    /// INV-08 — the case Source Reliability desk: a schedule of reliability ratings over the case's
    /// authorized source versions, reusing the shared SourceReliabilityAssessmentRepository; a rating is a
    /// judgement, never a fact. Live from boot.
    public private(set) var investigationReliability: InvestigationReliabilityService?
    /// INV-12 — the case Contradiction & Gap desk: in-scope contradictions (both sides preserved) and gaps
    /// (absence is not proof) over the shared detectors, with case-scoped human dispositions. Live from boot.
    public private(set) var investigationContradictionGap: InvestigationContradictionGapService?
    /// INV-18 — the case Evidence vault & custody manifest: per-authorized-source-version content hash +
    /// the shared append-only custody chain; recording a custody entry is a case-scoped human decision.
    /// Reuses the shared CustodyRepository + EvidenceStore. Live from boot.
    public private(set) var investigationCustody: InvestigationCustodyService?
    /// INV-20 — the case Closure authority: a case is closed only by a recorded human decision, unresolved
    /// items are retained (honest closure), and reopening preserves the prior closure. Live from boot.
    public private(set) var investigationClosure: InvestigationClosureService?
    /// INV-19 — the case Findings & export authority: findings are a case-scoped work product over the
    /// SHARED assembly/run/receipt engines, restricted to `case-authorized ∩ SensitiveScope`, and become the
    /// case's findings only by an explicit recorded human approval. Live from boot.
    public private(set) var investigationFindings: InvestigationFindingsService?
    /// INV-01-C3 — the case DataLab authority: prepares authorized-only datasets over the shared Workbench,
    /// restricted to `case-authorized ∩ SensitiveScope`. Live from boot (also the DataLab persona job's target).
    public private(set) var investigationDataLab: InvestigationDataLabService?
    /// #143 — the case-scoped professional-method services, live from boot over the SHARED ProfessionalMethod
    /// engine (ProfessionalMethodRegistry + MethodRunRepository + canonical evidence gate). These make the
    /// Investigator method / causal / linkage / CAPA persona jobs route into the real engine (no serviceUnavailable).
    public private(set) var investigationMethods: InvestigationMethodService?
    public private(set) var investigationCausal: InvestigationCausalService?
    public private(set) var investigationLinkage: InvestigationLinkageService?
    public private(set) var investigationCAPA: InvestigationCAPAService?
    /// #146 — the persona-neutral Handoff / Review read-service. Aggregates a matter's findings-approval,
    /// closure, and custody state from the shared authorities above so the Handoff & Review UI can review a
    /// matter and record the human-only approve / close / reopen decisions. Reads only; forks no engine.
    public private(set) var workProductHandoff: WorkProductHandoffService?
    /// Conformance roadmap 1.0.x-A (v107) — recorded per-rule assessments with
    /// their frozen Sutra snapshots and signed seals, one append-only row per run.
    public private(set) var conformanceAssessments: ConformanceAssessmentRepository?
    /// Conformance roadmap 1.1 (v108) — signed offline protocol packs and the
    /// governed review records behind the assurance board.
    public private(set) var protocolRegistry: ProtocolRegistryRepository?
    /// Fifth audit (v111) — append-only governance ledger (approval, withdrawal,
    /// assessment recording, bundle export) sealed by the audit chain.
    public private(set) var governanceEvents: GovernanceEventsRepository?
    /// PHASE C (v112) — the atomic approval composer: approval decision +
    /// sealed assessment + governance event in ONE savepoint.
    public private(set) var approvalTransactions: ApprovalTransactionRepository?
    /// PHASE B (v113) — machine observation of SOP phase completion from the
    /// case's own ledgers.
    public private(set) var phaseObservation: PhaseObservationService?
    /// #142 — the ONE production PersonaJobCatalog (built once at boot) and the ONE live consumer that
    /// discovers a persona, enumerates its real jobs, and routes a selected job into the real implementation.
    public private(set) var personaJobCatalog: PersonaJobCatalog?
    public private(set) var personaJobs: PersonaJobService?
    /// PERF.2 — consumer of the ledger above. Live but INERT until per-kind
    /// handlers are registered (a kind with no handler is never drained), so it
    /// is a strict no-op today; this is the integration point the future
    /// embedding/typedFacts/… engines register into.
    public private(set) var enrichmentDrainer: EnrichmentDrainer?
    /// Count of open contradictions from the last proactive/maintenance scan.
    public private(set) var proactiveContradictionCount: Int = 0

    // MARK: - Header search hand-off
    /// A query typed into the always-visible header search box. SearchView
    /// picks it up on appear / change, runs it, then clears this. Lets the
    /// user search from anywhere without first navigating to Search.
    public var pendingSearchQuery: String?
    /// Set by Home persona cards ("try asking"); AskView seeds its input from
    /// this on appear, then clears it. Lets a persona example open Ask ready
    /// to run.
    public var pendingAskQuestion: String?
    /// Set by a persona job's guided runner to hand off into the Work Center:
    /// the generated workflow's defID (e.g. "job.inv-01"). RootView navigates to
    /// the Work Center when this is set; WorkCenterView starts/opens that run and
    /// clears it. Lets a lazy user turn any job into its step-by-step workflow.
    public var pendingWorkCenterDefID: String?

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
    /// Idle background memory distillation (gated by the maintenance choice).
    public private(set) var backgroundMemoryDistiller: BackgroundMemoryDistiller?
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
    /// A2 §7.7 — durable per-file ingest outcomes (Sources failure surface).
    public private(set) var ingestAttempts: IngestAttemptsRepository?
    /// PI.3 (ING-001/004) — durable RUN-level ingest state: each bulk pass and
    /// every file's transition, so an interrupted run resumes from its remaining
    /// files instead of restarting from scratch.
    public private(set) var ingestRuns: IngestRunRepository?
    /// A2 §7.6 — parent→child source provenance (email→attachment, …).
    public private(set) var sourceRelations: SourceRelationsRepository?
    /// Persona features Epic 1 (F1) — bounded workspaces (filtered views over
    /// the one ledger) + their source/entity membership.
    public private(set) var workspaces: WorkspaceRepository?
    /// PA-PROD B3 — the shared, single-flight projection actor. Boot runs a resumable full
    /// backfill; the ingest hook fires incremental per-source projections on this SAME instance
    /// (so a full pass and an incremental refresh never scan concurrently).
    public private(set) var claimProjection: ClaimProjectionBackfill?
    /// The detached, cancellable boot-backfill task. Held so a re-boot cancels the prior pass
    /// (the backfill is single-flight + resumable, so cancellation loses nothing).
    private var claimProjectionBackfillTask: Task<Void, Never>?
    /// PA-UI-001 — the service the Workspaces UI uses to add/remove ingested sources to a
    /// workspace (candidate listing, membership writes, projection + reconciliation).
    public private(set) var workspaceSourceCoordinator: WorkspaceSourceCoordinator?
    /// Persona features Epic 1 (F2) — shared review model: tags, the
    /// append-only review-decision ledger, and saved views.
    public private(set) var review: ReviewRepository?
    /// Persona features (F9) — research screening log + PRISMA-compatible counts.
    public private(set) var screening: ScreeningRepository?
    /// Persona features (F8) — timecoded transcript segments (on-demand).
    public private(set) var transcripts: TranscriptRepository?
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
            KalsmritikoshLog.storage.info("Database open at \(db.url.path, privacy: .private)")

            // HNSW ANN index — built lazily after boot. Pass it to
            // SQLiteVectorStore so `nearest()` takes the index path
            // once it's built (brute force remains the fallback).
            let hnsw = HNSWVectorIndex()
            // P6.2 — label the vector index by the ACTIVE embedder so the
            // model-aware chunk_embeddings store is honest (the bundled Core ML
            // BGE model, when present, is the real embedder — its 384-dim vectors
            // must not masquerade as 'apple.nl.v1'). isAvailable() is a cheap
            // file+tokenizer check. Reconciliation of any already-stored vectors
            // written under the placeholder label happens just below, after
            // migrate().
            let activeEmbeddingModelID = await CoreMLEmbedderProvider().isAvailable()
                ? "bge-small.v1" : "apple.nl.v1"
            // P9.3 (GOV-005) — the strategy coordinator owns BOTH ANN
            // accelerators (in-memory HNSW + disk-backed IVF) and the
            // persisted decision; the store consumes only the coordinator,
            // so every retrieval caller is unchanged.
            let annRepo = ANNIndexRepository(database: db)
            let annDimension = activeEmbeddingModelID == "bge-small.v1" ? 384 : NLEmbedder().dimension
            let annCoordinator = ANNIndexCoordinator(
                hnsw: hnsw,
                ivf: IVFDiskVectorIndex(repository: annRepo, modelID: activeEmbeddingModelID,
                                        dimension: annDimension),
                repository: annRepo,
                modelID: activeEmbeddingModelID,
                dimension: annDimension)
            let vectors = SQLiteVectorStore(database: db, ann: annCoordinator, modelID: activeEmbeddingModelID)
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
            // AEE-M2 §27 — an app restart mid-answer must not leave a v89 answer silently
            // abandoned: mark any non-terminal progressive answer incomplete(interrupted),
            // preserving its last durable revision. Legacy pre-v89 answers are untouched.
            Task { try? await answerLedgerRepo.recoverInterruptedAnswers(reason: "interrupted") }
            let enrichmentRepo = EnrichmentStatusRepository(database: db)
            let gapNodesRepo = GapNodeRepository(database: db)
            let monitorSnapshotsRepo = MonitorSnapshotRepository(database: db)
            let contradictionsRepo = ContradictionsRepository(database: db)
            let factReviewsRepo = FactReviewsRepository(database: db)
            let custodyRepo = CustodyRepository(database: db)
            let sensitiveScopesRepo = SensitiveScopeRepository(database: db)
            let derivedObjectsRepo = DerivedObjectsRepository(database: db)
            // A2 — structural evidence store + parser registry (canonical typed
            // blocks, populated additively during ingest).
            let evidenceStoreRepo = EvidenceStore(database: db)
            // A5.1 — assertion ledger, constructed here so the ingest path can
            // derive directly-observed assertions from structural blocks.
            let assertionsRepo = AssertionsRepository(database: db)
            // SEM — durable domain-pack facts (derived projections carrying block
            // lineage), populated additively during ingest from structural blocks.
            let genericFactsRepo = GenericFactRepository(database: db)
            // EV-005 — managed-evidence vault, rooted next to the DB in the app container.
            // Passed to ingest; only copies bytes when managedEvidenceMode is on (default off).
            let evidenceVault = EvidenceVault(
                root: resolvedDBURL.deletingLastPathComponent().appendingPathComponent("EvidenceVault", isDirectory: true))
            // A2 §7.3 — durable per-file ingest outcome recorder.
            let ingestAttemptsRepo = IngestAttemptsRepository(database: db)
            // PERF.2 — durable deferred-enrichment job ledger. Boot recovery below
            // re-queues any job left `running` by a crash (idempotent stages).
            let enrichmentJobsRepo = EnrichmentJobRepository(database: db)
            // A2 §7.6 — parent→child source provenance recorder.
            let sourceRelationsRepo = SourceRelationsRepository(database: db)

            // ── Routing (CapabilityRegistry) ─────────────────────────
            let hardware = HardwareProbe.probe()
            KalsmritikoshLog.routing.info("Hardware: \(hardware.chipName, privacy: .public), tier \(hardware.tier.rawValue, privacy: .public), \(hardware.totalRAMBytes) bytes RAM")
            let benchmark = PerformanceBenchmark(hardwareProfile: hardware)
            let capabilities = CapabilityRegistry(
                hardware: hardware,
                benchmark: benchmark
            )
            // P1.3 — release/internal provider split. The v1 CONSUMER release
            // registers only on-device providers (Apple FoundationModels + the
            // bundled llama.cpp reasoning + local embedding/reranker). Cloud,
            // Ollama, MLX and user-BYO providers are INTERNAL-only: their code
            // stays compiled (so this file builds identically), but they are not
            // registered in release, so PrivacyGate/ReleaseReadiness can prove no
            // cloud/off-device path can resolve. DEBUG builds keep everything.
            #if DEBUG
            let internalProvidersEnabled = true
            #else
            let internalProvidersEnabled = false
            #endif

            await capabilities.register(FoundationModelsProvider())
            // P6.2 — bundled on-device sentence embedder. Resolves over the
            // Apple NLEmbedding fallback ONLY when its Core ML model is bundled
            // (Resources/BGESmallEmbedder/); otherwise isAvailable() is false and
            // embedding behaviour is unchanged. See docs/EMBEDDER_SWAP.md.
            let coreMLEmbedder = CoreMLEmbedderProvider()
            await capabilities.register(coreMLEmbedder)
            if internalProvidersEnabled {
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
            } // internalProvidersEnabled (MLX reasoning)
            // SIXTEENTH REVIEW — LlamaCpp is an INTENTIONAL NON-SHIPPING
            // PROVIDER STUB (SHIP_DECISIONS §4): registered in internal
            // builds only, so a Release capability resolution can never
            // surface an unavailable local-model path.
            if internalProvidersEnabled {
                await capabilities.register(LlamaCppProvider())
            }

            // G2-3 — register user-supplied .gguf files persisted
            // via SettingsView's file importer. Each entry becomes
            // its own LlamaCppProvider id so the advisor can rank it.
            let gguf = GGUFRegistry()
            let ggufEntries = await gguf.load()
            if !ggufEntries.isEmpty {
                KalsmritikoshLog.app.info("GGUF registry: \(ggufEntries.count, privacy: .public) user file(s)")
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
                KalsmritikoshLog.app.info("MLX discovery: \(mlxModels.count, privacy: .public) user checkpoint(s)")
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
                    if internalProvidersEnabled {
                        await capabilities.register(MLXProvider(
                            id: m.id,
                            manifest: manifest,
                            downloader: ModelDownloader()
                        ))
                    }
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
            // The ENTIRE Ollama path (including the localhost:11434 reachability
            // probe and the model suggestion) is internal-only: a release build
            // must make zero network connections, so it never probes the daemon
            // and never surfaces a setup suggestion.
            var internalOllamaSetupSuggestion: OllamaSetupAdvisor.SetupSuggestion? = nil
            if internalProvidersEnabled {
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
                KalsmritikoshLog.app.info("Ollama setup needed: \(setupSuggestion.summary, privacy: .public)")
                internalOllamaSetupSuggestion = setupSuggestion
            }
            // Device-fit gate. Even when a reasoning model IS installed, if NONE
            // of them fits this Mac comfortably (≤70% RAM) — e.g. only a 26 GB
            // model on a 16 GB device — don't silently keep using the heavy one.
            // Surface a consent prompt recommending a device-suitable model; the
            // user keeps using what's there until they agree to pull the lighter one.
            if ollamaReachable {
                let ramBudget = Int64(Double(hardware.totalRAMBytes) * 0.7)
                let hasFittingModel = detectedOllama.contains {
                    $0.estimatedRAMBytes > 0 && $0.estimatedRAMBytes <= ramBudget
                }
                // Model-pull suggestions are a developer convenience: the release
                // app is fully private by default — it never proposes a download
                // (all shipped AI, including BGE search models, is in the bundle).
                #if DEBUG
                if !hasFittingModel {
                    let sug = OllamaSetupAdvisor.recommendModel(totalRAMBytes: hardware.totalRAMBytes)
                    self.pendingModelSuggestion = sug
                    KalsmritikoshLog.app.info("No comfortably-fitting reasoning model on \(hardware.totalRAMBytes / 1_073_741_824, privacy: .public)GB device — suggesting \(sug.modelTag, privacy: .public)")
                }
                #endif
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
                KalsmritikoshLog.app.info("Ollama discovery: \(detectedOllama.count, privacy: .public) model(s) installed")
                for m in detectedOllama {
                    // Pull the actual context window from /api/show
                    // when available; fall back to a family default.
                    let ctx = await OllamaDiscovery.contextWindow(for: m.name, baseURL: ollamaBase)
                        ?? OllamaDiscovery.defaultContextWindow(forFamily: m.family)
                    let providerID = "provider.local.network.\(m.name)"
                    let displayName = "Ollama \(m.name)"
                    KalsmritikoshLog.app.info("Registering \(displayName, privacy: .public) — ram=\(m.estimatedRAMBytes, privacy: .public) tier=\(m.tier.rawValue, privacy: .public) ctx=\(ctx, privacy: .public)")
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
            } // internalProvidersEnabled (Ollama probe + discovery + registration)
            if internalProvidersEnabled {
                await capabilities.register(CloudProvider())
            }

            // G2-3 — load user-supplied cloud endpoints. Each one
            // already carries a Keychain-resident API key from when
            // the user added it via Settings. Register one
            // CloudProvider per endpoint so the advisor can rank
            // them and the resolver can route to a specific one.
            let cloudRegistry = CloudEndpointRegistry()
            let cloudEntries = await cloudRegistry.load()
            if internalProvidersEnabled, !cloudEntries.isEmpty {
                KalsmritikoshLog.app.info("Cloud BYO: \(cloudEntries.count, privacy: .public) endpoint(s)")
                for endpoint in cloudEntries {
                    guard let key = await cloudRegistry.apiKey(for: endpoint.id) else {
                        KalsmritikoshLog.app.warning("Cloud BYO: missing keychain entry for \(endpoint.id, privacy: .public); skipping")
                        continue
                    }
                    await capabilities.register(CloudProvider(endpoint: endpoint, apiKey: key))
                }
            }

            // Minimum-LLM (spec §15): the boot-time reasoning pre-warm
            // generation is REMOVED. It existed to page the model in before
            // ingest-time context_prefix generations — which the pinned
            // .ledgerEventDriven engine no longer runs. Under minimum-LLM the
            // app must make ZERO generative calls at startup; the first
            // generation happens only when the user asks a question. We still
            // resolve the provider (metadata only, no generation) so the
            // capability registry is warm.
            Task.detached(priority: .utility) { [capabilities] in
                let spec = CapabilitySpec.reasoning(contextTokens: 256, purpose: "appstate.boot.resolve")
                _ = try? await capabilities.resolve(spec)
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
            // PERF — pre-warm the embedder in the background at boot. The first
            // embed of a session pays a large ONE-TIME model-load cost (Apple's
            // NLEmbedding word-embedding asset load measured ~1–3 min cold on
            // some machines; warm calls are ~1–5 ms). Kicking a throwaway embed
            // here, off the main actor at utility QoS, means that cold-start
            // overlaps with launch/idle instead of blocking the first user query
            // or making the background vector drain look stuck.
            Task(priority: .utility) { _ = await embedder.embed("kalsmritikosh embedder warm-up") }
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
            // A4 — synthetic questions are OUT of the v1 consumer-release
            // ingest + retrieval path (no generative-adjacent projection during
            // normal ingest). Retained for INTERNAL/DEBUG builds only. This one
            // lever nils the repo everywhere it's wired (ingest generation,
            // retrieval FTS union), so release performs zero synthetic-question
            // work and the row count never grows on normal ingest.
            #if DEBUG
            let releaseSyntheticQuestions: SyntheticQuestionsRepository? = syntheticQuestionsRepo
            #else
            let releaseSyntheticQuestions: SyntheticQuestionsRepository? = nil
            #endif
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
            // A4 — retrieval does not query synthetic-question projections in release.
            let retriever = HybridRetriever(
                memory: memoryRepo,
                events: events,
                entities: entities,
                chunks: chunks,
                summaries: summariesRepo,
                graph: graph,
                vectors: vectors,
                embedder: embedder,
                syntheticQuestions: releaseSyntheticQuestions,
                qaPairs: qaPairsRepo,
                bondWalker: BondWalker(repository: factBondsRepo, cache: bondCache),
                walkExplainer: WalkExplainer(entities: entities, events: events, cache: bondCache),
                memoryCache: memoryHashCache,
                entityTrie: entityTrieCache,
                entityTimeline: entityTimelineCache,
                objects: objects,   // T18 §21 — enables the privilege post-filter
                genericFacts: genericFactsRepo   // SEM — facts ride the surfaced evidence
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
                sessionProfile: sessionProfile,
                // P1 citation integrity (release gate F3) — citations must
                // resolve through the approved retrieval layers AND still
                // exist in the ledger. On probe error the resolver fails
                // OPEN to the union verdict (the ID already came from this
                // request's scope-filtered retrieval); failing closed here
                // would nuke every answer on a transient DB hiccup.
                citationResolver: CitationResolver(
                    ledgerObjectProbe: { [weak objects] ids in
                        guard let objects else { return ids }
                        return (try? await objects.existingIDs(ids)) ?? ids
                    },
                    ledgerEventProbe: { [weak events] ids in
                        guard let events else { return ids }
                        let found = (try? await events.findByIDs(Array(ids))) ?? []
                        return Set(found.map(\.id))
                    }
                ),
                // P3-U0 — the anchor register feed: subject resolution reads
                // the live identifier anchors (small; 6 on the owner's
                // archive) so "the patent" resolves deterministically.
                anchorsProvider: { [weak entities] in
                    guard let entities else { return [] }
                    return (try? await entities.allAnchors()) ?? []
                },
                // P5 residual — the shape-aware event fetch: existence/count/
                // timeline questions ask the event table directly by their
                // own vocabulary when retrieval carried no matching events.
                eventsByTitleTokens: { [weak events] tokens in
                    guard let events else { return [] }
                    return (try? await events.findByTitleTokens(tokens)) ?? []
                },
                // A1.2 — the abstention receipt's archive-wide scope.
                archiveTotals: { [weak db] in
                    guard let db else { return (0, 0) }
                    let docs = Int((try? await db.query("SELECT COUNT(*) FROM knowledge_objects;", []).first?.int(0)) ?? 0)
                    let passages = Int((try? await db.query("SELECT COUNT(*) FROM chunks WHERE review_status IS NULL;", []).first?.int(0)) ?? 0)
                    return (docs, passages)
                }
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

            // ING-006 — shared query-priority gate: the answer path holds it, the
            // background embedding drain yields to it (interactive pre-empts background).
            let priorityGate = QueryPriorityGate()
            // SHELL-003 — the one background-work gate, composing the shared priority gate + idle signal.
            self.backgroundWorkGate = BackgroundWorkGate(queryGate: priorityGate)
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
                onDemandDistiller: memoryDistiller,
                derivedObjects: derivedObjectsRepo,
                answerLedger: answerLedgerRepo,
                evidenceStore: evidenceStoreRepo,
                objects: objects,
                priorityGate: priorityGate,
                // MMI-FINAL — deterministic identity fast path over typed fields, SensitiveScope-gated.
                typedFields: TypedFieldRepository(database: db),
                sensitiveScope: sensitiveScopesRepo
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
            // A4 — nil in release (releaseSyntheticQuestions is nil), so the
            // ingest path never enqueues or generates synthetic questions.
            let synthQueue: SyntheticQuestionQueue? = releaseSyntheticQuestions.map {
                SyntheticQuestionQueue(
                    generator: HeuristicSyntheticQuestionGenerator(),
                    repository: $0
                )
            }

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
            KalsmritikoshLog.app.info("Chunker target=\(sizing.target, privacy: .public) chars (modelTokens=\(resolvedManifest.tokens, privacy: .public), modelRAM=\(resolvedManifest.requiredRAM, privacy: .public) bytes, deviceRAM=\(hardware.totalRAMBytes, privacy: .public) bytes)")
            for w in sizing.warnings {
                KalsmritikoshLog.app.warning("Sizing warning: \(w, privacy: .public)")
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
                availableReasoning: allReasoningManifests,
                foundationModelsHint: FoundationModelsProvider.unavailabilityHint()
            )
            KalsmritikoshLog.app.info("ModelChoiceAdvice severity=\(advice.severity.rawValue, privacy: .public): \(advice.summary, privacy: .public)")

            // Phase J.13 — created before IngestCoordinator so it can
            // be passed in; LiveMetrics polls it once it starts.
            let pipelineMetricsActor = PipelineMetrics()

            // PA-PROD B3 — the shared Claim-projection substrate, built ONCE here so the boot
            // backfill and the ingest hook drive the SAME single-flight actor. Deterministic +
            // LLM-free: it only projects existing ledger rows into canonical Claims and
            // reconciles derived workspace membership; nothing here talks to a model.
            let workspacesRepo = WorkspaceRepository(database: db)
            let claimsRepo = ClaimRepository(database: db)
            let temporalClaimsRepo = TemporalClaimRepository(database: db)
            let claimProducer = ClaimProducer(
                genericFacts: genericFactsRepo, assertions: assertionsRepo,
                temporalClaims: temporalClaimsRepo, events: events,
                claims: claimsRepo, evidence: evidenceStoreRepo)
            let membershipDeriver = WorkspaceMembershipDeriver(database: db, workspaces: workspacesRepo)
            let claimProjectionBackfill = ClaimProjectionBackfill(
                producer: claimProducer,
                progress: ClaimProjectionProgressRepository(database: db),
                membership: membershipDeriver,
                genericFacts: genericFactsRepo, temporalClaims: temporalClaimsRepo,
                assertions: assertionsRepo, events: events)
            // Clean cancellation across re-boots: stop any prior projection actor's in-flight scan
            // (and its internal task) BEFORE replacing it, so a stale pass can't keep writing under
            // the old system. cancel() awaits wind-down and never marks unfinished work complete.
            claimProjectionBackfillTask?.cancel()
            if let previousProjection = self.claimProjection { await previousProjection.cancel() }
            self.claimProjection = claimProjectionBackfill
            // PA-UI-001 — the workspace source-management service, over the same repos.
            self.workspaceSourceCoordinator = WorkspaceSourceCoordinator(
                files: files, objects: objects, workspaces: workspacesRepo,
                membership: membershipDeriver, projection: claimProjectionBackfill)

            // USF-M1 — the ONE production routing authority. Feature-gated parsers stay gated.
            let universalParserRegistry = try UniversalParserRegistryBuilder.standard(
                ocr: VisionOCR(),
                iMessageEnabled: FeatureFlags.shared.iMessageLoaderEnabled,
                browserHistoryEnabled: FeatureFlags.shared.browserHistoryLoaderEnabled,
                chatExportEnabled: FeatureFlags.shared.chatExportLoaderEnabled)
            let ingest = IngestCoordinator(
                universalRegistry: universalParserRegistry,
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
                syntheticQuestions: releaseSyntheticQuestions,
                syntheticQuestionGenerator: releaseSyntheticQuestions == nil ? nil : HeuristicSyntheticQuestionGenerator(),
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
                custody: custodyRepo,
                evidenceStore: evidenceStoreRepo,
                assertions: assertionsRepo,
                ingestAttempts: ingestAttemptsRepo,
                sourceRelations: sourceRelationsRepo,
                genericFacts: genericFactsRepo,
                evidenceVault: evidenceVault,   // EV-005 — copies only when managed mode on
                priorityGate: priorityGate,     // ING-006 — drain yields to interactive queries
                claimProjection: claimProjectionBackfill,  // PA-PROD B3 — incremental projection hook
                // USF-002 — the pipeline advances each source version's independent readiness dimensions.
                readiness: SourceReadinessRepository(database: db),
                // MMI-FINAL — deterministic typed identity/document fields from the persisted blocks.
                typedFields: TypedFieldRepository(database: db),
                // USF-M2 — safe container expansion records a durable coverage manifest per archive.
                containerInspection: ContainerInspectionRepository(database: db),
                // USF-001 — every accessible file receives canonical custody before any parser runs.
                intakeCoordinator: UniversalSourceIntakeCoordinator(
                    repository: CanonicalSourceIntakeRepository(database: db, vault: evidenceVault))
            )

            // USF-M3 / USF-FINAL — wire progressive on-demand upgrade + completion + reprocessing, and
            // recover any upgrade jobs stranded (running with an expired lease) by a prior crash/quit.
            let sourceUpgradeJobs = SourceUpgradeJobRepository(database: db)
            await ingest.configureUpgrades(database: db, jobs: sourceUpgradeJobs, priorityGate: priorityGate)
            _ = try? await sourceUpgradeJobs.recoverExpiredLeases(at: Date())

            // AEE-M1 — now that the upgrade subsystem is live, give the brain its adaptive
            // evidence bridge so a mission that needs evidence-ready DECISIVE sources can
            // raise ONLY those exact versions at query time (never the whole archive).
            await brain.attachAEEUpgradeBridge(IngestCoordinatorEvidenceUpgradeBridge(ingest: ingest))

            // PERF.1 — resume the resumable background embedding drain as soon
            // as the coordinator exists (embedder + vectors are set at init),
            // NOT at the end of boot. On a populated DB the tail of boot does
            // heavy work (HNSW rebuild, inventory); deferring the drain to then
            // left prior-session pending embeddings stranded until a new ingest.
            // Starting here guarantees they finish on any launch.
            //
            // P6.2 — honest model-aware label reconciliation. The bundled Core ML
            // BGE embedder (384-dim) has been the active embedder, but earlier
            // builds wrote its vectors under the default 'apple.nl.v1' label. When
            // BGE is active, relabel those 384-dim rows to their true model id so
            // a future embedder swap can COEXIST per the model-aware design
            // (never delete — the vectors are correct, only mislabeled). Genuine
            // 300-dim NLEmbedding rows are left as 'apple.nl.v1'. Idempotent.
            if activeEmbeddingModelID == "bge-small.v1" {
                let mislabeled = (try? await db.query(
                    "SELECT COUNT(*) FROM chunk_embeddings WHERE model_id = 'apple.nl.v1' AND dim = 384;", []
                ))?.first?.int(0) ?? 0
                if mislabeled > 0 {
                    try? await db.exec(
                        "UPDATE chunk_embeddings SET model_id = 'bge-small.v1' WHERE model_id = 'apple.nl.v1' AND dim = 384;", []
                    )
                    let cacheURL = resolvedDBURL
                        .deletingLastPathComponent()
                        .appendingPathComponent("hnsw-index.bin")
                    try? FileManager.default.removeItem(at: cacheURL)
                    KalsmritikoshLog.app.info("Embedder labels: relabeled \(mislabeled, privacy: .public) BGE vector(s) apple.nl.v1 → bge-small.v1; HNSW cache dropped for rebuild")
                }
            }
            await ingest.startBackgroundEmbeddingDrain()

            // ── Concurrency + Live wiring ────────────────────────────
            let backgroundScheduler = BackgroundTaskScheduler()
            // P9.3 (GOV-005) — index-strategy maintenance runs OFF the query
            // path: decide (selector + hysteresis) → background rebuild →
            // flip the persisted strategy; also fires IVF retrains and the
            // steady-state posting reconcile.
            await backgroundScheduler.schedule(BackgroundTaskScheduler.Job(
                id: "ann.strategy.maintenance", interval: 300,
                body: { [annCoordinator] in await annCoordinator.maintain() }))
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

            // Ingest-time memory distillation is governed solely by the
            // engine's policy. Single minimum-LLM engine → always OFF; memory
            // is warmed on demand. (The old user override that could force
            // ingest-time LLM back on was removed — it defeated the
            // minimum-LLM guarantee.)
            let distillOnIngest = basePolicy.eagerMemoryDistillation
            let updater = IncrementalUpdater(
                stream: ingest.invalidations,
                distiller: memoryDistiller,
                distillationEnabled: distillOnIngest
            )
            await updater.start()
            if !distillOnIngest {
                KalsmritikoshLog.app.info("Ingest-time memory distillation OFF (ledger-first default — memory warmed on demand)")
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
                    guard let self else { return 0 }
                    // System 3 idle maintenance re-derives BOTH the gap layer
                    // and the contradiction layer (both rule-based). The pass
                    // is cancellable: if the user resumes activity while it
                    // runs, a sidebar card asks continue-or-stop (owner
                    // decision 2026-08-15); Stop cancels at the next rule
                    // boundary and the prior derived layers stay intact.
                    let scan = Task { () -> Int in
                        let gaps = await self.scanForGaps()
                        if !Task.isCancelled { await self.scanForContradictions() }
                        return gaps
                    }
                    await MainActor.run { self.idleMaintenanceScan = scan }
                    let watcher = Task {
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            if Task.isCancelled { return }
                            if !SystemActivity.isIdle(threshold: 3) {
                                await MainActor.run {
                                    if self.idleMaintenanceScan != nil {
                                        self.scanContinuePromptPending = true
                                    }
                                }
                                return
                            }
                        }
                    }
                    let gaps = await scan.value
                    watcher.cancel()
                    await MainActor.run {
                        self.idleMaintenanceScan = nil
                        self.scanContinuePromptPending = false
                    }
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
            KalsmritikoshLog.app.info("System engine active: \(engine.mode.rawValue, privacy: .public)")

            // On-device name self-correction — mode-independent, idle-gated.
            // Folds OCR/typo name variants into the corroborated spelling
            // (aliases + tier demotion; never deletes).
            let entityReconciler = EntityReconciler(
                reconcile: { [weak self] in await self?.reconcileEntityNames() ?? 0 }
            )
            await entityReconciler.start()

            // Background memory distillation — the idle half of the distill
            // pair (the on-demand button in Settings is the manual half). Gated
            // behind the maintenance choice: distillation can spend an LLM call,
            // so it only runs when the user has opted into background
            // maintenance (Ask / Notify / Automatic). With maintenance Off it is
            // a no-op, preserving the minimum-LLM default — memory is then only
            // warmed on demand (button or at query time).
            let backgroundDistiller = BackgroundMemoryDistiller(
                distill: { [weak self] in
                    guard let self else { return 0 }
                    guard await self.maintenanceGate() else { return 0 }
                    return await self.distillMemory()
                }
            )
            await backgroundDistiller.start()

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
            // Context-prefix work is governed solely by the engine's ingest
            // policy. Single minimum-LLM engine → both are false, so the
            // backfiller never starts and ingest stays zero-LLM. (The old
            // user override that could force the LLM sweep on was removed.)
            let fullPrefixSweep = basePolicy.contextPrefixBackfill
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
                KalsmritikoshLog.app.info("ContextPrefixBackfiller started (mode: \(firstChunkCardOnly ? "document-card/file" : "full sweep", privacy: .public))")
            } else {
                KalsmritikoshLog.app.info("ContextPrefixBackfiller disabled")
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
            // P6.5 — do NOT run the daily unbounded community summarizer by
            // default: it is silent background LLM maintenance, which the v1
            // release profile forbids (silentLLMBackgroundMaintenanceEnabled =
            // false). Community summaries should be generated lazily when the
            // user opens a topic. Kept wired for internal builds only.
            if ReleaseCapabilityProfile.v1.silentLLMBackgroundMaintenanceEnabled {
                await communitySummarizer.start()
            }

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
                    // P9.3 — warm the persisted ANN strategy first (metadata +
                    // IVF centroid cache; milliseconds). The HNSW build below
                    // stays the in-memory strategy's boot job.
                    await annCoordinator.warm()
                    let cacheURL = resolvedDBURL
                        .deletingLastPathComponent()
                        .appendingPathComponent("hnsw-index.bin")
                    let liveCount = (try? await vectors.count()) ?? 0
                    // P9.3 — adaptive scale gate: only hold the in-memory HNSW when
                    // the corpus fits the device's RAM budget. Above the cap, skip
                    // the build; SQLiteVectorStore's memory-bounded path serves
                    // queries (correct, slower) instead of OOMing on a huge corpus.
                    let cap = HNSWVectorIndex.recommendedMaxInMemoryVectors
                    if liveCount > cap {
                        KalsmritikoshLog.app.info("HNSW skipped: \(liveCount, privacy: .public) vectors exceed the in-memory cap (\(cap, privacy: .public)); using the memory-bounded disk path.")
                        return HNSWVectorIndex.BuildStats(vectorsLoaded: 0, maxLayer: 0, buildSeconds: 0)
                    }
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
                KalsmritikoshLog.app.info("All five in-memory caches warmed (bond + memory + timeline + trie + HNSW)")
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
                                            KalsmritikoshLog.ingestion.error("Watcher-triggered ingest failed for \(url.lastPathComponent, privacy: .private): \(String(describing: error), privacy: .public)")
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
            self.enrichmentJobs = enrichmentJobsRepo
            // TBJ-FINAL — the time-bounded Job planning envelope, live from boot over the shared ledger.
            self.jobs = JobRepository(database: db)
            // LAB-001 — the canonical Workbench dataset authority, live from boot over the shared ledger.
            self.workbenchDatasets = WorkbenchDatasetRepository(database: db)
            // LAB-002 — the safe transformation engine's writer, live from boot over the shared ledger.
            self.workbenchTransforms = WorkbenchTransformRepository(database: db)
            // LAB-003 — the scenario overlay authority, live from boot over the shared ledger.
            self.workbenchScenarios = WorkbenchScenarioRepository(database: db)
            // LAB-005 — the read-only data-quality analyzer, composing the dataset + scenario authorities.
            if let wbDatasets = self.workbenchDatasets, let wbScenarios = self.workbenchScenarios {
                self.workbenchDataQuality = WorkbenchDataQualityAnalyzer(datasets: wbDatasets, scenarios: wbScenarios)
            }
            // SHELL-001 — the shell navigation-session autosave/resume, live from boot over the shared ledger.
            self.shellSession = ShellSessionRepository(database: db)
            // WORK-CENTER — the guided-workflow numbered-document ledger, live from boot over the shared ledger.
            self.workCenter = WorkCenterRepository(database: db)
            // Owner decision 2026-08-15 — the return-from-idle consent card
            // covers ALL long-running background work, not only the
            // seconds-long maintenance scan.
            startIdleResumeWatcher()
            // INV-01-A — the Investigator case-intake & scope authority, live from boot over the shared ledger.
            let investigationCasesRepo = InvestigationCaseRepository(database: db)
            self.investigationCases = investigationCasesRepo
            // INV-01-C1 — the Investigator Ask entry point: composes the active case's authorized scope
            // over the SHARED retriever + SHARED MasterBrain (no persona engine). The brain is built per
            // request via this factory so the case-scoped retriever governs every retrieval pass while the
            // same shared collaborators are reused; building the actor only stores references.
            // Phase B-2 — the generic case-phase artifact ledger (v115): ask
            // answers and dataLab datasets become machine-observable.
            let casePhaseArtifactsRepo = CasePhaseArtifactRepository(database: db)
            self.investigationAnswers = InvestigationAnswerService(
                cases: investigationCasesRepo,
                resolver: CaseRetrievalScopeResolver(evidence: evidenceStoreRepo),
                baseRetriever: retriever,
                evidence: evidenceStoreRepo,
                makeBrain: { scoped in
                    MasterBrain(
                        intentDetector: intentDetector, router: router, retriever: scoped, executor: executor,
                        capabilities: capabilities, verifier: verifier, weeklyBriefing: weeklyBriefing,
                        sessionProfile: sessionProfile, memoryRepo: memoryRepo, narrativeComposer: narrativeComposer,
                        eventsRepo: events, eventLinks: eventLinksRepo, onDemandDistiller: memoryDistiller,
                        derivedObjects: derivedObjectsRepo, answerLedger: answerLedgerRepo, evidenceStore: evidenceStoreRepo,
                        objects: objects, priorityGate: priorityGate, typedFields: TypedFieldRepository(database: db),
                        sensitiveScope: sensitiveScopesRepo)
                },
                artifacts: casePhaseArtifactsRepo)
            // INV-02 / INV-03 — Subject dossier + Identity resolution, live from boot. Both are persona
            // LENSES over the SHARED canonical entity engine (EntitiesRepository merge/unmerge) bounded to
            // the active case's authorized scope via the ONE CaseRetrievalScopeResolver + CaseScopedEntityResolver.
            let investigationSubjectsRepo = InvestigationSubjectRepository(database: db)
            let caseScopedEntities = CaseScopedEntityResolver(entities: entities, evidence: evidenceStoreRepo)
            self.investigationSubjectDossier = InvestigationSubjectDossierService(
                cases: investigationCasesRepo,
                resolver: CaseRetrievalScopeResolver(evidence: evidenceStoreRepo),
                subjects: investigationSubjectsRepo, entities: entities, scopedEntities: caseScopedEntities)
            self.investigationIdentityResolution = InvestigationIdentityResolutionService(
                cases: investigationCasesRepo,
                resolver: CaseRetrievalScopeResolver(evidence: evidenceStoreRepo),
                scopedEntities: caseScopedEntities, entities: entities,
                decisions: InvestigationIdentityDecisionRepository(database: db))
            // INV-04..07 — the analytical spine (Brainstorm / 5W1H / Evidence collection plan / Hypothesis
            // matrix), live from boot. Case-scoped reasoning over canonical evidence: every citation is
            // checked against the case's authorized scope; a hypothesis is confirmed only when its counted
            // evidence profile supports it; unknowns are never fabricated. Forks no Claim/gap/contradiction
            // authority.
            self.investigationAnalysis = InvestigationAnalysisService(
                cases: investigationCasesRepo,
                resolver: CaseRetrievalScopeResolver(evidence: evidenceStoreRepo),
                evidence: evidenceStoreRepo,
                analysis: InvestigationAnalysisRepository(database: db))
            // INV-08 + INV-12 — the case review desks (Source reliability + Contradiction & gap), live from
            // boot. Both REUSE the shared canonical authorities (SourceReliabilityAssessmentRepository /
            // ContradictionsRepository / GapNodeRepository) bounded to the case scope, and record the case's
            // human disposition in the thin InvestigationDeskReviewRepository — forking none of them and
            // mutating no shared item's global status.
            let investigationDeskReviews = InvestigationDeskReviewRepository(database: db)
            self.investigationReliability = InvestigationReliabilityService(
                cases: investigationCasesRepo,
                resolver: CaseRetrievalScopeResolver(evidence: evidenceStoreRepo),
                reliability: SourceReliabilityAssessmentRepository(database: db), reviews: investigationDeskReviews)
            self.investigationContradictionGap = InvestigationContradictionGapService(
                cases: investigationCasesRepo,
                resolver: CaseRetrievalScopeResolver(evidence: evidenceStoreRepo),
                evidence: evidenceStoreRepo, contradictions: contradictionsRepo, gaps: gapNodesRepo,
                reviews: investigationDeskReviews)
            // INV-18 — the case Evidence vault & custody manifest, live from boot. REUSES the shared
            // append-only CustodyRepository + the EvidenceStore per-version content hashes, bounded to the
            // case's authorized source versions. Custody is never broken silently: every entry is a new
            // append-only row in the shared ledger. Forks no custody authority.
            self.investigationCustody = InvestigationCustodyService(
                cases: investigationCasesRepo,
                resolver: CaseRetrievalScopeResolver(evidence: evidenceStoreRepo),
                evidence: evidenceStoreRepo, custody: custodyRepo, database: db)
            // INV-20 — the case Closure authority, live from boot. A case is CLOSED only by a recorded human
            // decision (never auto-closed); the accepted unresolved items are retained (honest closure); a
            // reopen is a new decision that preserves the prior closure. The closure + case status transition
            // are atomic in the durable log.
            self.investigationClosure = InvestigationClosureService(
                cases: investigationCasesRepo,
                resolver: CaseRetrievalScopeResolver(evidence: evidenceStoreRepo),
                closures: InvestigationClosureRepository(database: db))
            // INV-19 — the case Findings & export authority, live from boot. Findings are a case-scoped work
            // product over the SHARED WorkProductAssemblyService (the ONE composition/receipt/run engine),
            // restricted to `case-authorized ∩ SensitiveScope` via the ONE CaseRetrievalScopeResolver; they
            // become the case's findings only by an explicit recorded human approval (never inferred).
            self.investigationFindings = InvestigationFindingsService(
                cases: investigationCasesRepo,
                resolver: CaseRetrievalScopeResolver(evidence: evidenceStoreRepo),
                workspaces: workspacesRepo,
                assembly: try WorkProductAssemblyService(
                    database: db, events: events, contradictions: contradictionsRepo, gaps: gapNodesRepo,
                    workspaces: workspacesRepo),
                runs: WorkProductRunRepository(database: db),
                approvals: InvestigationFindingsApprovalRepository(database: db))
            // INV-01-C3 — the case DataLab authority, live from boot (also the DataLab persona job's target).
            let investigationDataLabService = InvestigationDataLabService(
                cases: investigationCasesRepo,
                resolver: CaseRetrievalScopeResolver(evidence: evidenceStoreRepo),
                datasets: WorkbenchDatasetRepository(database: db),
                scopes: SensitiveScopeRepository(database: db), artifacts: casePhaseArtifactsRepo)
            self.investigationDataLab = investigationDataLabService
            // #143 — boot the SHARED ProfessionalMethod engine ONCE (registry + run store + canonical evidence
            // gate) and wire the case-scoped method services so the Investigator method / causal / linkage /
            // CAPA persona jobs route into the REAL engine. Every persona resolves this SAME method runtime.
            let sharedMethodCatalog = try ProfessionalMethodCatalog.standard()
            let sharedMethodRuns = MethodRunRepository(database: db)
            let sharedMethodGate = CanonicalWorkflowEvidenceReferenceGate(database: db, scopeRepository: sensitiveScopesRepo)
            let investigationMethodsService = InvestigationMethodService(
                cases: investigationCasesRepo,
                resolver: CaseRetrievalScopeResolver(evidence: evidenceStoreRepo),
                evidence: evidenceStoreRepo,
                methodRuns: sharedMethodRuns, registry: sharedMethodCatalog.methods, gate: sharedMethodGate)
            self.investigationMethods = investigationMethodsService
            let investigationCausalService = InvestigationCausalService(
                cases: investigationCasesRepo, registry: sharedMethodCatalog.methods, methods: investigationMethodsService)
            self.investigationCausal = investigationCausalService
            let investigationLinkageService = InvestigationLinkageService(
                cases: investigationCasesRepo, registry: sharedMethodCatalog.methods, methods: investigationMethodsService)
            self.investigationLinkage = investigationLinkageService
            let investigationCAPAService = InvestigationCAPAService(
                cases: investigationCasesRepo, registry: sharedMethodCatalog.methods, methods: investigationMethodsService)
            self.investigationCAPA = investigationCAPAService
            // #146 — the persona-neutral Handoff / Review read-service, live from boot. It composes the SHARED
            // case authorities (findings approval + closure + custody + case header) into one snapshot so the
            // Handoff & Review UI can review a matter and record the human-only approve / close / reopen
            // decisions. Reads only; forks no authority.
            if let handoffFindings = self.investigationFindings,
               let handoffClosure = self.investigationClosure,
               let handoffCustody = self.investigationCustody {
                self.workProductHandoff = WorkProductHandoffService(
                    cases: investigationCasesRepo, findings: handoffFindings,
                    closure: handoffClosure, custody: handoffCustody)
            }
            // Conformance roadmap 1.0.x-A — run-bound assessment persistence (v107).
            self.conformanceAssessments = ConformanceAssessmentRepository(database: db)
            // Conformance roadmap 1.1 — offline protocol packs + governed reviews (v108).
            self.protocolRegistry = ProtocolRegistryRepository(database: db)
            // Fifth audit — governance ledger (v111), sealed into the audit chain below.
            let governanceRepo = GovernanceEventsRepository(database: db)
            self.governanceEvents = governanceRepo
            // Phase C — atomic approval composer (v112).
            self.approvalTransactions = ApprovalTransactionRepository(database: db)
            // Phase B — machine observation of SOP phases from the case's own
            // ledgers (v113 case↔method-run linkage + the desk services).
            self.phaseObservation = PhaseObservationService(
                analysis: self.investigationAnalysis,
                reliability: self.investigationReliability,
                contradictionGap: self.investigationContradictionGap,
                dossier: self.investigationSubjectDossier,
                identity: self.investigationIdentityResolution,
                methodRuns: sharedMethodRuns,
                artifacts: casePhaseArtifactsRepo)
            // #142 — the ONE production PersonaJobCatalog + the ONE live consumer. The catalog makes the
            // Investigator persona DISCOVERABLE; PersonaJobService ENUMERATES its real jobs and ROUTES a
            // selected job into the real implementation (the case-scoped services wired above). This is the
            // single production composition + consumer — before it, the catalog was exercised only in tests.
            let composedCatalog = try PersonaJobCatalogComposer.composeProduction()
            self.personaJobCatalog = composedCatalog
            self.personaJobs = PersonaJobService(
                catalog: composedCatalog,
                cases: investigationCasesRepo,
                answers: self.investigationAnswers,
                subjectDossier: self.investigationSubjectDossier,
                identityResolution: self.investigationIdentityResolution,
                analysis: self.investigationAnalysis,
                reliability: self.investigationReliability,
                contradictionGap: self.investigationContradictionGap,
                custody: self.investigationCustody,
                closure: self.investigationClosure,
                findings: self.investigationFindings,
                dataLab: investigationDataLabService,
                methods: investigationMethodsService,
                causal: investigationCausalService,
                linkage: investigationLinkageService,
                capa: investigationCAPAService)
            // PERF.2 — the drainer yields to interactive queries via the same
            // priority gate the brain/ingest use (ING-006). No handlers are
            // registered yet, so drainAll() below is a no-op until the per-kind
            // engines plug in.
            self.enrichmentDrainer = EnrichmentDrainer(jobs: enrichmentJobsRepo, priorityGate: priorityGate)
            self.vectorStore = vectors
            self.files = files
            self.objects = objects
            self.chunks = chunks
            self.genericFacts = genericFactsRepo
            self.embedder = embedder
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
            self.monitorSnapshots = monitorSnapshotsRepo
            self.contradictions = contradictionsRepo
            self.factReviews = factReviewsRepo
            self.custody = custodyRepo
            // AUD-CHAIN — seal the three append-only ledgers into a verifiable
            // hash chain. Secret in the Keychain (falls back to a per-run
            // secret if unavailable — still detects corruption). The provider
            // reads ALL ledgers' ordered canonical events at seal/verify time:
            // custody + fact reviews + governance acts (fifth audit — the chain
            // covers approval/assessment/export history, not just evidence).
            if let auditSecret = AuditChainSecret.loadOrGenerate() {
                // EIGHTH AUDIT — the provider THROWS on any ledger-read
                // failure instead of substituting []. A partial event set
                // would let a truncated chain verify as intact; a thrown
                // error makes seal/verify fail, which strict approval
                // treats as a refusal.
                let auditChainService = AuditChainService(
                    database: db, secret: auditSecret,
                    eventProvider: { [weak custodyRepo, weak factReviewsRepo, weak governanceRepo] in
                        var out = try await custodyRepo?.auditChainEvents() ?? []
                        out += try await factReviewsRepo?.auditChainEvents() ?? []
                        out += try await governanceRepo?.auditChainEvents() ?? []
                        return out
                    })
                self.auditChain = auditChainService
                // Seal off the query path, then keep it current on a slow cadence.
                await backgroundScheduler.schedule(BackgroundTaskScheduler.Job(
                    id: "audit.chain.seal", interval: 600,
                    body: { [weak auditChainService] in _ = try? await auditChainService?.seal() }))
            } else {
                // Strict approval REFUSES without a chain (fail-closed), so a
                // missing Keychain secret must be loud, not a silent nil.
                KalsmritikoshLog.app.fault("audit-chain secret unavailable — no chain wired; strict-mode approvals will refuse until this is resolved")
            }
            self.sensitiveScopes = sensitiveScopesRepo
            self.screenAuthorizer = ScreenScopeAuthorizer(repository: sensitiveScopesRepo)
            let svc = SensitiveScopeMutationService(repository: sensitiveScopesRepo)
            self.mutationService = svc
            // Observe policy mutations and bump sensitiveScopeRevision on the MainActor
            // so SourceViewer / EvidenceViewer / EventDetailSheet .task(id:) re-fire.
            Task { @MainActor [weak self] in
                for await _ in svc.policyChanges {
                    self?.notifyScopePolicyChanged()
                }
            }
            self.derivedObjects = derivedObjectsRepo
            self.evidenceStore = evidenceStoreRepo
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
            self.workspaces = workspacesRepo
            self.review = ReviewRepository(database: db)
            self.screening = ScreeningRepository(database: db)
            self.transcripts = TranscriptRepository(database: db)
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
            self.assertions = assertionsRepo
            self.ingestAttempts = ingestAttemptsRepo
            self.ingestRuns = IngestRunRepository(database: db)
            // Universal History program (Phase 10 wiring) — the canonical
            // reconstruction engine + its versioned artifact store, over the SAME
            // ledger. Deterministic; no LLM required.
            self.historyEngine = HistoryReconstructionEngine(
                entities: entities, events: events, assertions: assertionsRepo,
                genericFacts: genericFactsRepo, relationships: relationships,
                blockResolver: evidenceStoreRepo,
                // P4-U2 — the H-law source context: email episodes + document
                // classes read from the ledger for the story's own evidence.
                storyContext: { [weak objects] ids in
                    (try? await objects?.storySourceContext(for: ids)) ?? .empty
                })
            self.historyArtifacts = HistoryArtifactRepository(database: db)
            self.sourceRelations = sourceRelationsRepo
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
            self.ollamaSetupSuggestion = internalOllamaSetupSuggestion
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
            self.backgroundMemoryDistiller = backgroundDistiller
            self.brain = brain
            self.ingest = ingest
            // UNIT C-ii — the receipt's ledger-state stamp reads SQLite's
            // data_version (a mutation counter, nearly free) at ask start.
            // P4-U4 rung 3 — the story door: story-shaped questions go to the
            // reconstruction engine + renderer + durable artifact persistence.
            await brain.setStoryComposer { [weak self] question in
                await self?.composeStoryAnswer(question: question)
            }
            // A3 — the tool-grounded middle floor.
            await brain.setToolGroundedFallback { [weak self] question in
                await self?.composeToolGroundedAnswer(question: question)
            }
            await brain.setLedgerStateProvider { [weak database] in
                // C-ii: begin the ask's read snapshot; the returned stamp is
                // data_version read ON the snapshot connection at ask start.
                await database?.beginAskSnapshot()
            }
            await brain.setAskSnapshotEnd { [weak database] in
                await database?.endAskSnapshot()
            }
            self.phase = .ready
            KalsmritikoshLog.app.info("AppState booted successfully")

            // W-4b — THE DRAIN RUNS IN THE APP: when any derived row is
            // behind its producer era (a fix shipped since it was written),
            // the ledger drain re-derives it in the background — facts
            // re-extracted, anchors re-minted, orphans swept, milestones
            // rebuilt. This is the "no re-ingest" promise made real for the
            // LIVE app, not only the harness. Idempotent; era-stamped rows
            // skip; suppressed during isolated eval boots.
            if !suppressAutoReingest {
                let drainDB = db
                let drainObjects = objects
                let drainEntities = entities
                let drainEvents = events
                let drainFacts = genericFactsRepo
                let drainEvidence = evidenceStoreRepo
                Task.detached(priority: .utility) {
                    do {
                        let stale = try await drainDB.query("""
                        SELECT (SELECT COUNT(*) FROM generic_facts WHERE COALESCE(producer_version,0) != \(DerivedProducerVersions.facts))
                             + (SELECT COUNT(*) FROM events WHERE COALESCE(producer_version,0) != \(DerivedProducerVersions.events))
                             + (SELECT COUNT(*) FROM entities WHERE COALESCE(producer_version,0) != \(DerivedProducerVersions.entities));
                        """, []).first?.int(0) ?? 0
                        if stale > 0 {
                            KalsmritikoshLog.app.info("Ledger drain: \(stale) derived row(s) behind their era — refreshing in the background")
                            let coordinator = LedgerDrainCoordinator(
                                database: drainDB, objects: drainObjects, entities: drainEntities,
                                events: drainEvents, facts: drainFacts, evidence: drainEvidence)
                            _ = try await coordinator.drain()
                        }
                    } catch {
                        KalsmritikoshLog.app.error("Ledger drain failed (will retry next launch): \(error)")
                    }
                    // SPEC A1.4 (the reachability lesson, applied) — the rest
                    // of the derived-data producers run in the SAME boot pass,
                    // each idempotent and self-skipping when current:
                    // chunk reindex → term salience → topic tree (the Big
                    // Picture's input) → the advisory twins (budgeted).
                    do {
                        _ = try await ChunkReindexCoordinator(database: drainDB).run()
                        _ = try await TermSalienceComputer(database: drainDB).run()
                        _ = try await TopicTreeBuilder(database: drainDB).run()
                        // A6 idempotence (parity finding #2): a per-boot twin
                        // BUDGET means every boot writes until the frontier
                        // drains (~50 docs/200 entities a launch). Loop each
                        // twin to frontier-empty in THIS one pass — later
                        // boots write nothing and the world stands still.
                        while try await EntityPlausibilityTwin(database: drainDB)
                            .runOnce(gate: EntityQualityGate.bundled()).scanned > 0 {}
                        while try await EventRecordTwin(database: drainDB)
                            .runOnce().documentsExamined > 0 {}
                        KalsmritikoshLog.app.info("Boot maintenance pass complete (reindex, terms, tree, twins)")
                    } catch {
                        KalsmritikoshLog.app.error("Boot maintenance pass failed (will retry next launch): \(error)")
                    }
                }
            }

            // One-time catch-up: apply the legal/patent milestone extractor to
            // documents ingested BEFORE it existed. New documents already get
            // milestones inline at ingest, so this runs once (flag-guarded) and
            // never blocks boot. Idempotent (backfill clears+regenerates), and
            // suppressed during isolated eval boots to keep them deterministic.
            if !suppressAutoReingest,
               !UserDefaults.standard.bool(forKey: "kalsmritikosh.milestones.backfilled.v1") {
                Task { [weak self] in
                    _ = await self?.backfillLegalMilestones()
                    UserDefaults.standard.set(true, forKey: "kalsmritikosh.milestones.backfilled.v1")
                }
            }

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
                // PA-PROD B3 — resumable full Claim-projection backfill. Boot is already
                // `.ready`; this runs detached at utility priority and never flips readiness.
                // Single-flight + durable keyset cursor → an interrupted pass resumes where it
                // left off, and the ingest hook drives the SAME actor, so a live incremental
                // projection never scans concurrently with this pass. run() logs its own
                // failures and never throws. Cancelled + restarted cleanly on a re-boot.
                claimProjectionBackfillTask?.cancel()
                claimProjectionBackfillTask = Task.detached(priority: .utility) { [weak self] in
                    guard let backfill = await self?.claimProjection else { return }
                    await backfill.run(at: Date())
                }
                // Detached so the bulk re-ingest pass runs on the
                // cooperative pool, not on MainActor. Pairs with the
                // watcherTask fix above — both are long-running ingest
                // dispatchers that the focus-suspension bug stalled.
                Task.detached(priority: .utility) { [weak self] in
                    await self?.autoReingestEmptyRoots()
                }
                // v54 resume — re-ingest any file whose last attempt is still
                // `.started` (a crash/quit interrupted it). Detached + best-
                // effort; idempotent via content-hash + the per-document atomic
                // commit (no partial KO can survive a crash).
                if let ingest = self.ingest {
                    Task.detached(priority: .utility) { [weak self] in
                        let n = await ingest.resumeIncompleteIngests()
                        if n > 0 {
                            KalsmritikoshLog.app.info("AppState: resumed \(n, privacy: .public) interrupted ingest(s)")
                            _ = self
                        }
                        // PERF.2 — re-queue any deferred-enrichment job stranded `running`
                        // by a crash so a fresh drainer picks it up (idempotent stages).
                        if let requeued = try? await self?.enrichmentJobs?.requeueStuckRunning(),
                           requeued > 0 {
                            KalsmritikoshLog.app.info("AppState: re-queued \(requeued, privacy: .public) stuck enrichment job(s)")
                        }
                        // PI.3 — resume any bulk run left mid-flight (its remaining
                        // files only). After the per-file resume so mid-commit files
                        // are already handled; idempotent, so any overlap is a no-op.
                        await self?.resumeInterruptedRuns()
                        // PERF.2 — drain any pending deferred-enrichment jobs (crash-
                        // requeued above). A strict no-op until per-kind handlers are
                        // registered; wired here so the consumer is live infrastructure.
                        _ = await self?.enrichmentDrainer?.drainAll()
                    }
                }
            } else {
                KalsmritikoshLog.app.info("AppState: auto-reingest suppressed (eval / smoke boot)")
            }
        } catch {
            KalsmritikoshLog.app.error("AppState boot failed: \(String(describing: error), privacy: .public)")
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
            // Surface the file being worked on RIGHT NOW so a slow/stuck file is
            // visible to the user (e.g. a 91 MB mailbox that legitimately takes
            // minutes). Set before body(); cleared when the last file finishes.
            self.ingestCurrentFile = displayName
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
                    self.ingestCurrentFile = nil
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
            KalsmritikoshLog.app.error("recordAnswer failed: \(String(describing: error), privacy: .public)")
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
        // V3 3b — GATE-THEN-FOLD at the reconcile chokepoint: a canonical that
        // fails the quality gate never folds (neither as a winner nor a variant),
        // so "Nil Nil" can't become anyone's name. gateRejected counts the live
        // 4,343's junk blocked each idle pass — climbing pre-drain is the gate
        // WORKING (owner expectation, beside "staleness lights to 716"), a free
        // preview of the inventory V5 retires. No delete: folds are refused only.
        let gate = EntityQualityGate.bundled()
        func gatePasses(_ value: String) -> Bool {
            gate.shouldKeep(Entity(kind: .person, value: value, sourceObjectID: UUID()))
        }
        var gateRejected = 0
        for i in 0..<ranked.count {
            let winner = ranked[i]
            if claimed.contains(winner.id) { continue }
            guard winner.mentionCount >= 2 else { break }   // list is sorted; rest are <2 too
            guard gatePasses(winner.value) else { gateRejected += 1; continue }
            for j in (i + 1)..<ranked.count {
                let loser = ranked[j]
                if claimed.contains(loser.id) { continue }
                guard loser.mentionCount <= 1 else { continue }   // only lone slips fold in
                guard gatePasses(loser.value) else { gateRejected += 1; continue }
                guard Self.plausibleOCRVariant(winner: winner.normalized, loser: loser.normalized) else { continue }
                do {
                    try await entities.markOCRVariant(
                        loserID: loser.id,
                        winnerID: winner.id,
                        loserNormalized: loser.normalized
                    )
                    claimed.insert(loser.id)
                    folded += 1
                    KalsmritikoshLog.knowledge.info("Reconcile: '\(loser.value, privacy: .private)' → variant of '\(winner.value, privacy: .private)'")
                } catch {
                    KalsmritikoshLog.knowledge.error("Reconcile failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
        if gateRejected > 0 {
            KalsmritikoshLog.knowledge.info("Reconcile gate refused \(gateRejected, privacy: .public) junk canonical(s) from folding (pre-drain live noise — gate working)")
        }
        return folded
    }

    /// Conservative same-person test: identical surname, both multi-token,
    /// high Jaro-Winkler. Tuned to catch "thirshendus sasmal" ≈
    /// "shirshendu sasmal" while never merging two genuinely different people.
    nonisolated static func plausibleOCRVariant(winner: String, loser: String) -> Bool {
        guard winner != loser else { return false }
        let w = winner.split(separator: " ")
        let l = loser.split(separator: " ")
        guard w.count >= 2, l.count >= 2 else { return false }
        let ws = String(w.last!), ls = String(l.last!)
        let jw = NameSimilarity.jaroWinkler(winner, loser)
        if ws == ls {
            // Same surname → given-name OCR variant ("thirshendus"/"shirshendu"
            // sasmal). Full-name similarity qualifies.
            return jw >= 0.88
        }
        // V3 3d (F2) — surnames DIFFER: fold ONLY when the given name matches
        // EXACTLY and the surname delta is FULLY EXPLAINED by ≤1 OCR letter-group
        // substitution (mechanism). Jaro-Winkler rides ONLY as a veto FLOOR here,
        // never the qualifying test — so "Sasmal"/"Sasrnal" folds (rn↔m) while
        // "Nair"/"Singh" and "Sharma"/"Verma" never do.
        let wGiven = w.dropLast().joined(separator: " ")
        let lGiven = l.dropLast().joined(separator: " ")
        guard wGiven == lGiven else { return false }
        guard NameOCRConfusion.surnameExplainable(ws, ls) else { return false }
        return jw >= 0.85
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
        let activity = beginProcess("Scanning for evidence gaps")
        defer { finishProcess(activity) }
        // The prior layer is REPLACED only at the very end (clear + insert
        // together): a pass cancelled mid-way (the user's continue-or-stop
        // card) leaves the previous complete derivation intact rather than
        // an empty or partial gap layer.
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

        if Task.isCancelled { return found.count }   // stopped by the user — prior layer stands

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

            // Rule 10 (A5.7) — masked / redacted values present in the text.
            found += detector.detectRedactedValues(texts: texts)

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

            // Rule 4 (A5.7) — messages that reference an attachment that
            // wasn't ingested with them.
            let emailRows = sample
                .filter(\.isEmail)
                .map { (objectID: $0.id, body: $0.content, hasAttachment: $0.hasAttachment) }
            found += detector.detectMissingAttachments(emails: emailRows)

            // Rule 8 (A5.7) — messages that request a reply with none in the
            // archive. A root message has a reply iff some Re:-prefixed message
            // shares its normalized subject.
            let repliedSubjects = Set(
                sample.compactMap { row -> String? in
                    guard let s = row.subject, !s.isEmpty, Self.isReplySubject(s) else { return nil }
                    let n = Self.normalizeSubject(s)
                    return n.isEmpty ? nil : n
                }
            )
            let awaiting: [(objectID: UUID, subject: String, body: String, hasReply: Bool)] =
                sample.compactMap { row in
                    guard row.isEmail, let s = row.subject, !s.isEmpty, !Self.isReplySubject(s) else { return nil }
                    let hasReply = repliedSubjects.contains(Self.normalizeSubject(s))
                    return (objectID: row.id, subject: s, body: row.content, hasReply: hasReply)
                }
            found += detector.detectExpectedResponses(messages: awaiting)

            // Rule 9 (A5.7) — documents present only as a draft (no final).
            let documents = sample
                .filter { !$0.isEmail }
                .map { (objectID: $0.id, filename: $0.filename) }
            found += detector.detectMissingFinalVersion(documents: documents)
        }

        if Task.isCancelled { return found.count }   // stopped by the user — prior layer stands

        // Rule 5 (A5.7) — unreadable regions from the structural layer: sources
        // whose parse was partial / corrupt / encrypted / unsupported / failed.
        if let evidenceStore {
            let issues = (try? await evidenceStore.documentsWithExtractionIssues(limit: 200)) ?? []
            found += detector.detectUnreadableRegions(
                regions: issues.map { (filename: $0.filename, status: $0.status, warningCount: $0.warningCount) }
            )
        }

        // Rule 6 (A5.7) — invoices issued with no matching payment (same amount).
        if let events {
            let recent = (try? await events.recent(limit: 2_000)) ?? []
            let issued = recent.filter { $0.kind == .invoiceIssued }.compactMap { e -> (amount: Double, currency: String, objectID: UUID)? in
                guard let m = ContradictionDetector.amount(of: e) else { return nil }
                return (m.value, m.currency, e.sourceObjectID)
            }
            let paid = recent.filter { $0.kind == .invoicePaid }.compactMap { e -> (amount: Double, currency: String)? in
                guard let m = ContradictionDetector.amount(of: e) else { return nil }
                return (m.value, m.currency)
            }
            found += detector.detectMissingPaymentProof(issued: issued, paid: paid)

            // Rule 10 (A5.7) — cadence breaks: a skipped period in a regular
            // series (recurring event titles arriving weekly/monthly).
            let series = recent.map {
                (seriesKey: GapDetector.normalizeSeriesKey($0.title), date: $0.date, objectID: $0.sourceObjectID)
            }
            found += detector.detectCadenceBreaks(items: series)
        }

        // Rule 7 (A5.7) — custody breaks: files whose bytes changed since first ingest.
        if let custody {
            let mismatches = (try? await custody.recentMismatches(limit: 200)) ?? []
            found += detector.detectCustodyBreaks(
                mismatches: mismatches.map { (detail: $0.detail, fileID: $0.fileID) }
            )
        }

        if Task.isCancelled { return found.count }   // stopped by the user — prior layer stands
        // Atomic-enough replace: clear + insert back-to-back at the end.
        await gapNodes.clear()
        await gapNodes.insertMany(found)
        KalsmritikoshLog.knowledge.info("Gap scan found \(found.count, privacy: .public) likely-missing items (sequence + dangling-ref + thread-parent + missing-attachment + unreadable-region + payment-proof + custody-break + expected-response + final-version + cadence-break)")
        return found.count
    }

    /// Scan the ledger for CONTRADICTIONS — conflicts the archive
    /// supports simultaneously (currently: the same event dated
    /// differently by two independent sources). Rule-based, no LLM.
    /// Persists the open set (replacing the prior scan) and returns the count.
    @discardableResult
    public func scanForContradictions() async -> Int {
        guard let events, let contradictions else { return 0 }
        let activity = beginProcess("Scanning for contradictions")
        defer { finishProcess(activity) }
        let recent = (try? await events.recent(limit: 2_000)) ?? []
        let detector = ContradictionDetector()
        // A5.6 — date + amount detectors over the same event set.
        var found = detector.detectEventDateConflicts(recent)
            + detector.detectEventAmountConflicts(recent)
            + detector.detectEventLocationConflicts(recent)
            + detector.detectEventSignatureConflicts(recent)
        // A5.6 — causal conflicts over the causal-link graph, when wired.
        if let eventLinks {
            let links = (try? await eventLinks.links(in: recent.map(\.id))) ?? []
            if !links.isEmpty {
                let titles = Dictionary(recent.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
                found += detector.detectCausalConflicts(links, title: titles)
            }
        }
        // A5.6 — testimony / statement conflicts over attributed statements.
        if let assertions {
            let asserts = (try? await assertions.recent(limit: 4_000)) ?? []
            if !asserts.isEmpty {
                found += detector.detectStatementConflicts(asserts)
            }
        }
        if Task.isCancelled { return found.count }   // stopped by the user — prior layer stands
        await contradictions.clear()
        await contradictions.insertMany(found)
        let openCount = await contradictions.count()
        self.proactiveContradictionCount = openCount
        KalsmritikoshLog.knowledge.info("Contradiction scan found \(found.count, privacy: .public) conflict(s) (date + amount + location + signature + causal + statement)")
        return found.count
    }

    /// Data-grounded "questions from your archive" (NotebookLM-style suggestions,
    /// done the evidence-ledger way). Derived from what's ACTUALLY in the ledger —
    /// top people/organizations/projects, recent events, open contradictions, and
    /// missing-evidence gaps — persona-weighted. Deterministic; no LLM, so it
    /// works even without a reasoning model. Empty until there's data to ground it.
    public func suggestedQuestions(for persona: String, limit: Int = 8) async -> [SuggestedQuestion] {
        var inputs = SuggestedQuestionBuilder.Inputs()
        if let entities {
            inputs.people = ((try? await entities.canonicalsWithMentionCounts(kind: .person, limit: 5)) ?? []).map(\.value)
            inputs.organizations = ((try? await entities.canonicalsWithMentionCounts(kind: .organization, limit: 4)) ?? []).map(\.value)
            inputs.projects = ((try? await entities.canonicalsWithMentionCounts(kind: .project, limit: 4)) ?? []).map(\.value)
        }
        if let events {
            inputs.events = ((try? await events.recent(limit: 6)) ?? []).map(\.title)
        }
        if let contradictions {
            inputs.contradictions = (await contradictions.open(limit: 5)).map(\.description)
        }
        if let gapNodes {
            inputs.gaps = (await gapNodes.all(includeDismissed: false, limit: 5)).map(\.description)
        }
        guard !inputs.isEmpty else { return [] }
        return SuggestedQuestionBuilder().build(persona: persona, inputs: inputs, limit: limit)
    }

    /// Cross-document matrix: for a query, the best-matching verbatim passage from
    /// EACH source document, with citation metadata. Deterministic (FTS + in-memory
    /// grouping), no LLM — the "what does every document say about X?" review a
    /// lawyer/journalist needs, with nothing summarized-away.
    public func crossDocumentMatrix(query: String, maxSources: Int = 40) async -> [CrossDocMatrixRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, let chunks, let objects else { return [] }
        let hits = (try? await chunks.searchFTS(trimmed, limit: 400)) ?? []
        let best = CrossDocumentMatrix.pickBestPerSource(hits, maxSources: maxSources)
        var rows: [CrossDocMatrixRow] = []
        for chunk in best {
            let ko = try? await objects.load(id: chunk.objectID)
            let url = ko?.sourceFile
            let filename = url?.lastPathComponent ?? "Source \(chunk.objectID.uuidString.prefix(8))"
            rows.append(CrossDocMatrixRow(
                objectID: chunk.objectID,
                filename: filename,
                url: url,
                date: ko?.createdAt,
                passage: CrossDocumentMatrix.snippet(chunk.text, query: trimmed),
                ordinal: chunk.ordinal,
                pageNumber: chunk.pageNumber
            ))
        }
        return rows
    }

    /// "How are these two connected?" — the shortest chain of relationships
    /// linking two entities, each hop with its citation. Bounded breadth-first
    /// expansion over the evidence-backed relationship graph (reusing
    /// RelationshipsRepository.neighbors), then a deterministic shortest path.
    /// Returns nil when no connection is found within `maxHops`.
    public func connectionPath(
        from source: Entity.ID, to target: Entity.ID, maxHops: Int = 5
    ) async -> ResolvedConnection? {
        guard source != target, let relationships, let entities, let objects else { return nil }

        // 1. Bounded BFS expansion from the source, collecting undirected edges.
        var adjacency: [Entity.ID: [ConnectionEdge]] = [:]
        var visited: Set<Entity.ID> = [source]
        var frontier: [Entity.ID] = [source]
        let nodeBudget = 800
        var hops = 0
        while !frontier.isEmpty, hops < maxHops, visited.count < nodeBudget {
            var next: [Entity.ID] = []
            for node in frontier {
                let rels = (try? await relationships.neighbors(of: node, limit: 80)) ?? []
                for r in rels {
                    let nb = r.fromEntityID == node ? r.toEntityID : r.fromEntityID
                    guard nb != node else { continue }
                    let label = r.kind.rawValue.replacingOccurrences(of: "_", with: " ")
                    adjacency[node, default: []].append(
                        ConnectionEdge(neighbor: nb, label: label, evidenceObjectID: r.sourceObjectID)
                    )
                    if !visited.contains(nb) { visited.insert(nb); next.append(nb) }
                }
            }
            if visited.contains(target) { break }
            frontier = next
            hops += 1
        }

        // 2. Deterministic shortest path over the collected graph.
        guard let path = ConnectionFinder.shortestPath(from: source, to: target, adjacency: adjacency),
              !path.hops.isEmpty else { return nil }

        // 3. Resolve names + evidence citations.
        let nameByID = Dictionary(
            uniqueKeysWithValues: ((try? await entities.findByIDs(path.nodes)) ?? [])
                .map { ($0.id, ($0.value, $0.kind.rawValue)) }
        )
        let evidenceIDs = Set(path.hops.compactMap(\.evidenceObjectID))
        let filenames = (try? await objects.sourceFilenames(for: evidenceIDs)) ?? [:]
        var urls: [KnowledgeObject.ID: URL] = [:]
        for id in evidenceIDs { if let u = try? await objects.fetchSourceURL(id: id) { urls[id] = u } }

        func name(_ id: Entity.ID) -> String { nameByID[id]?.0 ?? "an entity" }
        let nodes = path.nodes.map { ConnectionNode(id: $0, name: name($0), kind: nameByID[$0]?.1 ?? "") }
        let resolvedHops = path.hops.enumerated().map { (i, h) in
            ResolvedConnectionHop(
                id: i, label: h.label, fromName: name(h.from), toName: name(h.to),
                evidenceFilename: h.evidenceObjectID.flatMap { filenames[$0] },
                evidenceURL: h.evidenceObjectID.flatMap { urls[$0] }
            )
        }
        return ResolvedConnection(nodes: nodes, hops: resolvedHops)
    }

    /// "The whole story of X, in one cited file." Assembles a chronological,
    /// source-cited dossier for a subject (a patent number, person, project…)
    /// from the ledger: overview passages, parties, dated timeline, key clauses,
    /// roadblocks (contradictions), and gaps. Deterministic; every line cites a
    /// source. Returns nil when nothing matches. Renders markdown for export.
    public func subjectDossier(term rawTerm: String) async -> String? {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2 else { return nil }
        let lower = term.lowercased()
        var input = SubjectDossierInput(subject: term)
        var filenames: Set<String> = []

        // 1. Matching passages → overview + clause-flavored terms.
        let hits = (try? await chunks?.searchFTS(term, limit: 40)) ?? []
        let koIDs = Array(Set(hits.map(\.objectID)))
        let names = (try? await objects?.sourceFilenames(for: Set(koIDs))) ?? [:]
        func fn(_ id: KnowledgeObject.ID) -> String { names[id] ?? "source \(id.uuidString.prefix(8))" }
        let clauseTerms = ["clause", "grant", "claim", "right", "licen", "provision", "royalt", "assign", "term"]
        for c in hits {
            let f = fn(c.objectID); filenames.insert(f)
            let p = SubjectDossierInput.Passage(text: c.text, filename: f)
            let lc = c.text.lowercased()
            if clauseTerms.contains(where: { lc.contains($0) }), input.clauses.count < 8 {
                input.clauses.append(p)
            } else if input.overview.count < 6 {
                input.overview.append(p)
            }
        }

        // 2. Parties — entities appearing in the matched source documents.
        if let entities, !koIDs.isEmpty {
            let ents = (try? await entities.findInObjects(koIDs, limit: 40)) ?? []
            input.parties = ents.map(\.0)
                .filter { [.person, .organization, .vendor, .client].contains($0.kind) }
                .prefix(15).map(\.value)
        }
        if input.parties.isEmpty, let entities {
            input.parties = ((try? await entities.search(value: term, limit: 10)) ?? []).map(\.value)
        }

        // 3. Timeline — events whose title/summary mentions the term or that come
        //    from a matched source document.
        if let events {
            let koSet = Set(koIDs)
            let recent = (try? await events.recent(limit: 2_000)) ?? []
            let matched = recent.filter { ev in
                ev.title.lowercased().contains(lower)
                || (ev.summary?.lowercased().contains(lower) ?? false)
                || koSet.contains(ev.sourceObjectID)
            }
            let efns = (try? await events.sourceFilenames(forEventIDs: matched.map(\.id))) ?? [:]
            for ev in matched.prefix(60) {
                let f = efns[ev.id] ?? fn(ev.sourceObjectID); filenames.insert(f)
                input.timeline.append(.init(
                    date: ev.date, datePhrase: ev.datePrecision.renderPhrase(date: ev.date),
                    title: ev.title, summary: ev.summary, filename: f
                ))
            }
        }

        // 4. Roadblocks + gaps mentioning the term.
        if let contradictions {
            input.contradictions = (await contradictions.all())
                .filter { $0.description.lowercased().contains(lower) || $0.claimA.lowercased().contains(lower) || $0.claimB.lowercased().contains(lower) }
                .prefix(20).map { "\($0.description) — \($0.claimA) / \($0.claimB)" }
        }
        if let gapNodes {
            input.gaps = (await gapNodes.all(includeDismissed: false))
                .filter { $0.description.lowercased().contains(lower) || $0.reason.lowercased().contains(lower) }
                .prefix(20).map(\.description)
        }
        input.sourceFiles = Array(filenames)

        guard !input.isEmpty else { return nil }
        return SubjectDossier.markdown(input)
    }

    /// Backfill legal/patent MILESTONE events over already-ingested documents
    /// (new ingests get them automatically via the coordinator). Runs the
    /// deterministic PatentLegalEventExtractor across every object's content and
    /// inserts the dated milestone events — the "story spine" for legal matters.
    /// Returns the number of milestone events created.
    @discardableResult
    /// Phase 2 recovery — re-ingest legacy .doc/.xls files that failed before the
    /// real OLE2 parsers landed. Returns a human-readable summary line. Reports
    /// progress via the activity tracker.
    public func recoverLegacyDocuments() async -> String {
        guard let ingest else { return "Ingest not ready." }
        let activity = beginProcess("Recovering legacy .doc / .xls")
        defer { finishProcess(activity) }
        let r = await ingest.reingestFailedLegacy()
        if r.attempted == 0 && r.missing == 0 {
            return "No previously-failed .doc/.xls files found."
        }
        var msg = "✓ Recovered \(r.recovered) of \(r.attempted) legacy file(s)."
        if r.missing > 0 {
            msg += " \(r.missing) were extracted email/zip attachments no longer on disk — re-ingest their source folder (or the mailbox) to recover them through the new parsers."
        }
        return msg
    }

    public func backfillLegalMilestones() async -> Int {
        guard let objects, let events else { return 0 }
        // Idempotent: clear prior milestone events first so re-runs (and the
        // auto-run at boot) never duplicate. Milestones are derived data.
        try? await events.deleteMilestoneEvents()

        // V3 3d (I-5) — scan for OCR-near-duplicate split-suspects, persist the
        // reversible proposed merges, and get the suspect id set: a split-suspect
        // anchor NEVER threads a milestone chain (its identity is under review).
        let suspectAnchors = await reviewAnchorSplitSuspects()

        // Gather all object ids up front (cheap — just UUIDs) so the activity
        // has a real total → % + ETA.
        var allObjectIDs: [KnowledgeObject.ID] = []
        var offset = 0
        let pageSize = 500
        while true {
            let ids = (try? await objects.allIDs(offset: offset, pageSize: pageSize)) ?? []
            if ids.isEmpty { break }
            allObjectIDs.append(contentsOf: ids)
            offset += ids.count
            if ids.count < pageSize { break }
        }

        let activity = beginProcess("Rebuilding legal milestones", total: allObjectIDs.count)
        defer { finishProcess(activity) }
        var created = 0
        for (i, id) in allObjectIDs.enumerated() {
            if let content = try? await objects.fetchContent(id: id), !content.isEmpty {
                // V3 3c — thread milestones onto the identifier ANCHOR so the
                // patent's filed→hearing→objection→grant chain lands on ONE
                // subject id, not just the NER participants.
                let anchorIDs = await identifierAnchorIDs(inContent: content, sourceObjectID: id)
                    .filter { !suspectAnchors.contains($0) }   // I-5: split-suspects never thread
                let milestones = PatentLegalEventExtractor.extract(
                    text: content, sourceObjectID: id, entityIDs: anchorIDs)
                if !milestones.isEmpty {
                    try? await events.insertBatch(milestones)
                    created += milestones.count
                }
            }
            if i % 20 == 0 { updateProcess(activity, done: i + 1) }
        }
        updateProcess(activity, done: allObjectIDs.count)
        KalsmritikoshLog.knowledge.info("Legal-milestone backfill created \(created, privacy: .public) event(s)")
        return created
    }

    /// V3 3c — the identifier ANCHORS a document references, resolve-or-created
    /// (idempotent) so milestone events thread onto the canonical patent /
    /// application subject. Deterministic; reuses the single DomainFactExtractor
    /// for identifier detection so backfill and ingest agree on what an anchor is.
    /// Empty when the entities repo is absent — the caller then threads no anchors.
    private func identifierAnchorIDs(inContent content: String, sourceObjectID: UUID) async -> [UUID] {
        guard let entities else { return [] }
        let facts = DomainFactExtractor().extract(fromText: content, subjectLabel: "", blockID: UUID())
        var seen = Set<String>()
        var ids: [UUID] = []
        for f in facts where FactSchemaRegistry.expectedShape(of: f.field) == .identifier {
            guard !f.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let key = IdentifierAnchor.identityKey(field: f.field, value: f.value)
            guard seen.insert(key).inserted else { continue }
            if let anchorID = try? await entities.resolveOrCreateAnchor(
                field: f.field, value: f.value, sourceObjectID: sourceObjectID) {
                ids.append(anchorID)
            }
        }
        return ids
    }

    /// V3 3d (I-5) — scan the anchor set for OCR-near-duplicate SPLIT-SUSPECTS,
    /// persist a REVERSIBLE proposed-merge review event for each new one, and
    /// return the set of split-suspect anchor ids (the suspect `from` sides) so
    /// callers can exclude them (a split-suspect never threads a milestone chain).
    ///
    /// The proposal is a FactReview(action: .merge, reviewer: "system") — reusing
    /// the existing reversible review vocabulary, NOT a parallel status. Recording
    /// it is only a SUGGESTION: it never calls the entity merge, so the two anchors
    /// stay distinct until a human accepts. Idempotent (an existing proposal for a
    /// pair is not re-recorded), so the boot/backfill re-run never duplicates.
    @discardableResult
    public func reviewAnchorSplitSuspects() async -> Set<UUID> {
        guard let entities else { return [] }
        let anchors = (try? await entities.allAnchors()) ?? []
        let proposals = IdentifierAnchorReview.proposedMerges(among: anchors)
        if let factReviews {
            for p in proposals {
                let existing = (try? await factReviews.history(forSubject: p.fromAnchorID)) ?? []
                let already = existing.contains { $0.action == .merge && $0.newValue == p.toAnchorID.uuidString }
                if already { continue }
                let review = FactReview(
                    subjectKind: .entity, subjectID: p.fromAnchorID, action: .merge,
                    priorValue: p.fromValue, newValue: p.toAnchorID.uuidString,
                    reviewer: "system", reason: p.evidence)
                _ = try? await factReviews.record(review)
            }
            if !proposals.isEmpty {
                KalsmritikoshLog.knowledge.info("I-5: \(proposals.count, privacy: .public) anchor split-suspect merge(s) proposed for review")
            }
        }
        return Set(proposals.map(\.fromAnchorID))
    }

    /// Retrieval self-eval: recall@k measured by querying the vector index with
    /// text drawn from stored chunks and checking whether each chunk comes back.
    /// Label-free quality signal on the user's own data (not the human-labelled
    /// answer benchmark). Returns nil when the vector layer isn't wired.
    public func runRetrievalSelfEval(sampleSize: Int = 200) async -> RetrievalSelfEvalReport? {
        guard let chunks, let embedder, let vectorStore else { return nil }
        let activity = beginProcess("Retrieval self-check", total: sampleSize)
        defer { finishProcess(activity) }
        let report = await RetrievalSelfEval.run(
            chunks: chunks, embedder: embedder, vectors: vectorStore, sampleSize: sampleSize,
            progress: { [weak self] done, total in
                Task { @MainActor in self?.updateProcess(activity, done: done, total: total) }
            }
        )
        KalsmritikoshLog.app.info("Retrieval self-eval: \(report.summary, privacy: .public)")
        return report
    }

    /// Proactive change-monitoring: what contradictions/gaps are NEW or RESOLVED
    /// since the last acknowledged snapshot. Reads the currently-stored ledger
    /// sets (run the scans first for freshest results); deterministic, no LLM.
    public func changeDigest() async -> ChangeReport {
        let contradictions = (await self.contradictions?.all()) ?? []
        let gaps = (await self.gapNodes?.all(includeDismissed: false)) ?? []
        let cSig = Dictionary(contradictions.map { (ChangeDigest.signature($0), $0) }, uniquingKeysWith: { a, _ in a })
        let gSig = Dictionary(gaps.map { (ChangeDigest.signature($0), $0) }, uniquingKeysWith: { a, _ in a })
        let current = Set(cSig.keys).union(gSig.keys)

        let baseline = await monitorSnapshots?.latest()
        let previous = Set(baseline?.signatures ?? [])
        let (added, removed) = ChangeDigest.diff(previous: previous, current: current)

        let newContras = added.compactMap { cSig[$0] }
            .sorted { $0.severity.rawValue > $1.severity.rawValue }
        let newGaps = added.compactMap { gSig[$0] }
        let resolvedContra = removed.filter { $0.hasPrefix("contradiction|") }.count
        let resolvedGap = removed.filter { $0.hasPrefix("gap|") }.count

        return ChangeReport(
            previousDate: baseline?.createdAt,
            newContradictions: newContras,
            resolvedContradictionCount: resolvedContra,
            newGaps: newGaps,
            resolvedGapCount: resolvedGap,
            currentSignatures: Array(current),
            currentContradictionCount: contradictions.count,
            currentGapCount: gaps.count
        )
    }

    /// Mark the current state as reviewed: save it as the new baseline so the
    /// next digest diffs against it. Prunes old snapshots.
    public func acknowledgeChanges(_ report: ChangeReport) async {
        guard let monitorSnapshots else { return }
        await monitorSnapshots.save(MonitorSnapshot(
            createdAt: Date(),
            signatures: report.currentSignatures,
            contradictionCount: report.currentContradictionCount,
            gapCount: report.currentGapCount
        ))
        await monitorSnapshots.prune()
    }

    /// "Where do these two both appear?" — the documents that mention BOTH
    /// entities, plus each entity's footprint (mentions, distinct docs).
    /// Deterministic set intersection over the mention ledger; no model.
    public func compareEntities(a: Entity.ID, b: Entity.ID) async -> EntityComparison? {
        guard a != b, let entities else { return nil }
        let names = Dictionary(
            uniqueKeysWithValues: ((try? await entities.findByIDs([a, b])) ?? []).map { ($0.id, $0.value) }
        )
        let aMentions = (try? await entities.mentions(forEntityID: a, limit: 1000)) ?? []
        let bMentions = (try? await entities.mentions(forEntityID: b, limit: 1000)) ?? []

        func docMap(_ rows: [EntityMentionRow]) -> EntityOverlap.DocMap {
            var m: EntityOverlap.DocMap = [:]
            for r in rows where m[r.objectID] == nil {
                m[r.objectID] = (r.sourceFile.lastPathComponent, r.createdAt, r.sourceFile)
            }
            return m
        }
        let aDocs = docMap(aMentions), bDocs = docMap(bMentions)
        return EntityComparison(
            a: EntityFootprint(name: names[a] ?? "First", mentionCount: aMentions.count, documentCount: aDocs.count),
            b: EntityFootprint(name: names[b] ?? "Second", mentionCount: bMentions.count, documentCount: bDocs.count),
            shared: EntityOverlap.shared(aDocs, bDocs)
        )
    }

    /// Load a bounded sample of objects with their body + email subject
    /// (from metadata) for the rule-based gap detectors. No LLM.
    private func loadObjectSample(
        objects: KnowledgeObjectRepository,
        limit: Int
    ) async -> [(id: UUID, content: String, subject: String?, isEmail: Bool, hasAttachment: Bool, filename: String)] {
        let ids = (try? await objects.allIDs(offset: 0, pageSize: limit)) ?? []
        var out: [(id: UUID, content: String, subject: String?, isEmail: Bool, hasAttachment: Bool, filename: String)] = []
        out.reserveCapacity(ids.count)
        for id in ids {
            guard let obj = (try? await objects.load(id: id)) ?? nil else { continue }
            var subject: String?
            if case .string(let s)? = obj.metadata["subject"]?.value { subject = s }
            // A5.7 — attachment presence: EmailLoader stores ingested attachment
            // URLs as a JSON array under this key; a non-"[]" value means ≥1.
            var hasAttachment = false
            if case .string(let json)? = obj.metadata[EmailLoader.attachmentURLsMetaKey]?.value {
                let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
                hasAttachment = !trimmed.isEmpty && trimmed != "[]"
            }
            out.append((id: obj.id, content: obj.content, subject: subject,
                        isEmail: obj.sourceType.category == .email, hasAttachment: hasAttachment,
                        filename: obj.sourceFile.lastPathComponent))
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
        KalsmritikoshLog.ingestion.info("Boost ingest for nouns: \(nouns.joined(separator: ", "), privacy: .public)")
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
            KalsmritikoshLog.ingestion.info("Boost: no filename matches found")
            return
        }
        KalsmritikoshLog.ingestion.info("Boost: queueing \(collected.count, privacy: .public) file(s) for priority ingest")
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
        "kalsmritikosh", "archive", "files", "file", "document", "documents",
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

    /// True while a full erase is in flight (drives the Settings button state).
    public private(set) var deletingAllData = false

    /// User-initiated FULL ERASE of all ingested + derived data — the global
    /// "Delete all my data" the app was missing. Removes every watched folder
    /// and empties every ledger table; the on-disk vector-index cache and the
    /// managed-evidence vault copies are dropped too. Your ORIGINAL files on
    /// disk (outside the app container) are NOT touched. This is a deliberate
    /// user action — the preserve-everything directive guards against SILENT
    /// loss, not an explicit erase. Returns the number of tables cleared.
    @discardableResult
    public func deleteAllData() async -> Int {
        guard let db = database, !deletingAllData else { return 0 }
        deletingAllData = true
        defer { deletingAllData = false }

        // 1. Forget every watched root so nothing re-ingests. (Copy the list —
        //    removeRoot mutates bookmarks.roots.)
        for root in Array(bookmarks.roots) {
            await removeRoot(root, strategy: .stopAndForget)
        }
        // 2. Empty every user table. Skip sqlite internals and FTS shadow
        //    tables (those are maintained by triggers on their base tables, so
        //    deleting the base rows cleans the index). FK off during the wipe so
        //    parent/child delete order doesn't matter.
        let rows = (try? await db.query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '%_fts%';",
            [])) ?? []
        let tables = rows.compactMap { $0.string(0) }
        try? await db.exec("PRAGMA foreign_keys=OFF;", [])
        for t in tables { try? await db.exec("DELETE FROM \"\(t)\";", []) }
        try? await db.exec("PRAGMA foreign_keys=ON;", [])
        // 3. Drop the vector-index cache so it rebuilds empty.
        let cache = db.url.deletingLastPathComponent().appendingPathComponent("hnsw-index.bin")
        try? FileManager.default.removeItem(at: cache)
        // 4. Remove the managed-evidence vault (EV-005) — the content-addressed byte
        //    copies made while managed mode was on. Without this, "Delete all my data"
        //    left original bytes behind in the container. Same root as boot wiring
        //    (<db dir>/EvidenceVault); blobs are chmod 444, but unlinking depends on
        //    the parent directory, so removing the tree succeeds. Recreated on demand.
        let vaultRoot = db.url.deletingLastPathComponent().appendingPathComponent("EvidenceVault", isDirectory: true)
        try? FileManager.default.removeItem(at: vaultRoot)
        // 5. Return the freed pages to the filesystem. Without VACUUM the
        //    emptied knowledge.sqlite keeps its full pre-erase size on disk
        //    (owner witness: 121 MB with every table at 0 rows), which reads
        //    as "my data wasn't deleted" — a promise breach for an erase.
        try? await db.exec("VACUUM;", [])
        newFilesSinceLaunch = 0
        KalsmritikoshLog.app.info("Deleted all ingested data (\(tables.count, privacy: .public) tables cleared) — user-initiated full erase")
        return tables.count
    }

    /// One-click "start fresh": erase every ingested row IN PLACE (works even
    /// while the DB is open — no file-handle games) and then force a full
    /// re-ingest of all bookmarked roots through the current pipeline. This is
    /// the reliable wipe: a file-level delete of knowledge.sqlite is defeated by
    /// the app's open handle, and the boot auto-reingest only fires when a root
    /// has ZERO files — so once any rows survive, it silently skips. Returns a
    /// human-readable summary. Progress shows on the live panel + activity tracker.
    @discardableResult
    public func wipeAndReingestEverything() async -> String {
        let wipe = beginProcess("Erasing all ingested data")
        let cleared = await deleteAllData()
        finishProcess(wipe)
        // Let boot-time one-shots (milestone spine) re-run over the fresh corpus.
        UserDefaults.standard.removeObject(forKey: "kalsmritikosh.milestones.backfilled.v1")
        let n = await ingestAllRoots()
        let mile = beginProcess("Building timeline milestones…")
        _ = await backfillLegalMilestones()
        finishProcess(mile)
        return "✓ Erased \(cleared) tables, re-ingested \(n) file(s) with the evidence-first pipeline. Vectors deepen in the background."
    }

    /// A cheap progress snapshot for the live-activity panel's bars: how many
    /// files are parsed and how many chunks are embedded, each with its total.
    /// One query, four COUNTs — safe to poll every couple of seconds.
    public struct IngestProgress: Sendable, Equatable {
        public var filesDone = 0, filesTotal = 0
        public var embedDone = 0, embedTotal = 0
        public var parsing: Bool { filesTotal > 0 && filesDone < filesTotal }
        public var embedding: Bool { embedTotal > 0 && embedDone < embedTotal }
        public var idle: Bool { !parsing && !embedding }
    }

    public func ingestProgress() async -> IngestProgress {
        guard let db = database else { return IngestProgress() }
        let rows = (try? await db.query("""
        SELECT (SELECT COUNT(*) FROM knowledge_objects),
               (SELECT COUNT(*) FROM files),
               (SELECT COUNT(*) FROM chunks WHERE admit_embedding = 1),
               (SELECT COUNT(DISTINCT chunk_id) FROM chunk_embeddings);
        """, [])) ?? []
        guard let r = rows.first else { return IngestProgress() }
        // Numerator = knowledge objects, which grows per ingested UNIT (one per
        // email message + one per file/attachment) — so the bar advances smoothly
        // through a big mailbox instead of jumping only when the whole mbox ends.
        let koDone = Int(r.int(0) ?? 0)
        let dbFileCount = Int(r.int(1) ?? 0)
        // Denominator = the pre-counted units (files + mailbox messages). Outside
        // a bulk pass, fall back to whatever's larger so the bar reads 100% idle.
        let planned = max(ingestPlannedFileTotal, dbFileCount)
        let filesTotal = max(planned, koDone)   // cap at 100% (attachments add extra KOs)
        return IngestProgress(
            filesDone: koDone, filesTotal: filesTotal,
            embedDone: Int(r.int(3) ?? 0), embedTotal: Int(r.int(2) ?? 0)
        )
    }

    /// USF-002 — the DURABLE, multi-dimensional readiness of every source version: how many are
    /// searchable, evidence-ready, analytically ready, preserved-only, deferred, or need attention.
    /// This consumes the authoritative readiness ledger (not the live `IngestProgress` counters,
    /// which describe activity, not durable readiness). Never a single overall percentage.
    public func sourceReadinessSummary() async -> SourceReadinessSummary {
        guard let db = database else { return SourceReadinessSummary(snapshots: []) }
        let repo = SourceReadinessRepository(database: db)
        let ids = ((try? await db.query("SELECT source_version_id FROM source_readiness_aggregates;", [])) ?? [])
            .compactMap { $0.uuid(0) }
        var snapshots: [SourceReadinessSnapshot] = []
        for id in ids { if let s = try? await repo.snapshot(sourceVersionID: id) { snapshots.append(s) } }
        return SourceReadinessSummary(snapshots: snapshots)
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
    // MARK: - Universal History program (Phase 10 wiring)

    /// Resolve a free-text subject to a canonical entity (or ambiguity/notFound) so
    /// the Dossier never sends a bare name to a global search (trust rule 3).
    public func resolveHistorySubject(_ text: String) async -> HistoryResolution? {
        guard let entities else { return nil }
        return try? await HistorySubjectResolver(entities: entities).resolve(freeText: text)
    }

    /// Stream a reconstruction for a canonical subject via the engine.
    public func reconstructHistory(subject: HistorySubject) -> AsyncStream<HistoryUpdate> {
        guard let engine = historyEngine else { return AsyncStream { $0.finish() } }
        return engine.reconstruct(subject: subject, request: HistoryRequest())
    }

    /// Persist a verified reconstruction as a versioned artifact (best-effort).
    @discardableResult
    public func persistHistory(_ result: HistoryReconstructionResult, narrative: HistoryNarrative?) async -> UUID? {
        guard let repo = historyArtifacts else { return nil }
        return try? await repo.save(result, narrative: narrative, at: Date())
    }

    /// P4-U1 — the SECOND door: persist a story built straight from a question.
    /// Lands as `unreviewed` (the Dossier's door keeps `verified`), stamped with
    /// the ledger state it was built on, and dedup'd by (anchor, request-shape,
    /// ledger stamp): the same story asked again on an unchanged ledger returns
    /// the existing artifact instead of a new row. Only a COMPLETED
    /// reconstruction reaches this door — a cancelled stream never yields a
    /// result, so it persists nothing.
    @discardableResult
    public func persistStoryFromAsk(_ result: HistoryReconstructionResult,
                                    narrative: HistoryNarrative?,
                                    anchorKey: String) async -> UUID? {
        guard let repo = historyArtifacts else { return nil }
        guard let stamp = try? await repo.currentLedgerStamp() else { return nil }
        if let existing = try? await repo.existingCurrent(
            anchorKey: anchorKey, requestShape: "story", ledgerStamp: stamp) {
            // A4 — the cached-history receipt: the same subject on an
            // unchanged ledger reuses the persisted structure.
            KalsmritikoshLog.app.info("history: cached (artifact \(existing.uuidString.prefix(8), privacy: .public) reused — same subject, same ledger)")
            return existing
        }
        let saved = try? await repo.save(result, narrative: narrative, at: Date(),
                                         reviewState: "unreviewed", anchorKey: anchorKey,
                                         requestShape: "story", ledgerStamp: stamp)
        // P4-U2 — the placement twin re-checks the outline against the H-laws
        // AFTER persistence. Checker, never writer: its only output is
        // advisory review rows; the artifact is untouched either way.
        if let saved, let db = database {
            let findings = PlacementTwin.check(outline: result.outline)
            await PlacementTwin.record(findings: findings, artifactID: saved, database: db)
        }
        return saved
    }

    /// P4-U4 rung 3 — the STORY ANSWER, end to end: subject resolved via
    /// identifier anchors (never guessed), reconstructed by the engine,
    /// chaptered under the H-laws, rendered with gists and span citations,
    /// PERSISTED through the unreviewed door (dedup'd + stamped), gaps listed
    /// by kind. Ambiguity lists the candidates; no anchor refuses with the
    /// honest message; an engine failure returns nil so the normal pipeline
    /// carries (never a dead end).
    public func composeStoryAnswer(question: String) async -> VerifiedAnswer? {
        guard let entities, let engine = historyEngine else { return nil }
        let anchors = (try? await entities.allAnchors()) ?? []
        guard let resolution = try? await HistorySubjectResolver(entities: entities)
            .resolveStory(question: question, anchors: anchors) else { return nil }

        switch resolution {
        case .notResolvable(let message):
            return VerifiedAnswer(body: "", citations: [], confidence: .zero,
                                  refused: true, refusalReason: message)
        case .ambiguous(let message):
            return VerifiedAnswer(body: message, citations: [], confidence: Confidence(0.5),
                                  source: .historical)
        case .resolved(let subject, let anchorKey):
            var result: HistoryReconstructionResult?
            for await update in engine.reconstruct(subject: subject.subject, request: HistoryRequest()) {
                if case .verified(let r) = update { result = r }
            }
            guard let result else { return nil }
            let narrative = HistoryNarrativeRenderer().render(outline: result.outline)
            let artifactID = await persistStoryFromAsk(result, narrative: narrative, anchorKey: anchorKey)

            var body = narrative.summary
            for chapter in narrative.chapters {
                body += "\n\n## \(chapter.title)\n"
                if let gist = chapter.gist { body += gist + "\n" }
                body += chapter.prose
            }
            // Gaps by kind, plain-language, deterministic order.
            let gaps = result.outline.gaps
            if !gaps.isEmpty {
                let byKind = Dictionary(grouping: gaps, by: \.kind)
                    .map { (Self.plainGapKind($0.key), $0.value.count) }
                    .sorted { $0.0 < $1.0 }
                body += "\n\nOpen questions: " + byKind.map { "\($0.0) (\($0.1))" }.joined(separator: " · ")
            }
            var cached = false
            if let artifactID, let stampNow = try? await historyArtifacts?.currentLedgerStamp() {
                let hit = try? await historyArtifacts?.existingCurrent(
                    anchorKey: anchorKey, requestShape: "story", ledgerStamp: stampNow)
                cached = (hit == artifactID)
            }
            body += "\n\nThis story was saved to your archive"
                + (artifactID != nil ? " and awaits your review." : ".")
            if cached { body += " (History: reused — built earlier on this same ledger.)" }

            // Citations: the items' distinct source documents, deterministic order.
            var seen = Set<KnowledgeObject.ID>()
            let citations = result.outline.items
                .flatMap(\.evidence).map(\.objectID)
                .filter { seen.insert($0).inserted }
                .sorted { $0.uuidString < $1.uuidString }
                .prefix(10)
                .map { VerifiedAnswer.Citation(objectID: $0, snippet: "Story evidence") }
            return VerifiedAnswer(body: body, answerText: body, citations: Array(citations),
                                  confidence: Confidence(0.75), source: .historical)
        }
    }

    /// "missingEndDate" → "missing end date" (RC-8 plain language, no jargon).
    nonisolated static func plainGapKind(_ kind: HistoryGapKind) -> String {
        kind.rawValue.map { $0.isUppercase ? " \($0.lowercased())" : String($0) }.joined()
    }

    /// A3 — the Ask-the-Ledger fallback: derive the plan deterministically,
    /// gather small id-bearing tool results (the loop law: history + field
    /// lookup + one span fetch), compose via the on-device AI, SWEEP every
    /// sentence against the result it cites. nil at any failure — the
    /// ladder falls through, never a dead end. The receipt carries the
    /// plan, the tools, the model + build stamps, and — when the subject's
    /// anchor lives in a topic node — "scoped to ‹node›" (A2.2).
    public func composeToolGroundedAnswer(question: String) async -> VerifiedAnswer? {
        guard let entities, let events, let genericFacts = self.genericFacts,
              let chunks, let caps = capabilities, let db = database else { return nil }
        let anchors = (try? await entities.allAnchors()) ?? []
        let plan = QuestionPlan.derive(question: question, anchors: anchors)
        guard plan.shape != QuestionShape.outOfScope.rawValue else { return nil }

        let tools = LedgerTools(
            events: { [weak events] tokens in (try? await events?.findByTitleTokens(tokens)) ?? [] },
            facts: { [weak genericFacts] field in (try? await genericFacts?.facts(field: field)) ?? [] },
            chunksForQuestion: { [weak chunks] q in
                let hits = (try? await chunks?.searchFTS(SlotFieldResolver.expandAliases(q), limit: 15)) ?? []
                return hits.map { RetrievedChunk(chunk: $0, score: 1.0, viaLayer: .metadata) }
            })
        // The loop law: history → field lookup → ONE span fetch.
        var results = await tools.historyOf(question: question)
        if let field = plan.field { results += await tools.lookupField(field) }
        results += await tools.fetchSpans(question: question,
                                          shape: QuestionShape(rawValue: plan.shape) ?? .unresolved)
        guard let grounded = await ToolGroundedComposer.compose(
            question: question, plan: plan, results: results, capabilities: caps) else { return nil }

        var receipt = grounded.receiptLines
        // A2.2 — the scoping receipt: the anchor's topic node, when one holds it.
        if let anchorCanon = plan.subjectMention,
           let anchor = anchors.first(where: { SubjectResolver.canon($0) == anchorCanon }),
           let node = (try? await db.query("""
           SELECT cs.title FROM entity_communities ec
           JOIN community_summaries cs ON cs.community_id = ec.community_id AND cs.level = 1
           WHERE ec.entity_id = ? AND ec.level = 1 LIMIT 1;
           """, [.uuid(anchor.id)]).first?.string(0)) {
            receipt.append("Scoped to: \(node)")
        }
        let body = grounded.sentences.map(\.text).joined(separator: " ")
            + "\n\n(" + receipt.joined(separator: " · ") + ")"
        let citations = grounded.citedObjectIDs.prefix(8).map {
            VerifiedAnswer.Citation(objectID: $0, snippet: "Ledger result")
        }
        KalsmritikoshLog.brain.info("ledger.compose: shipped \(grounded.sentences.count) swept sentence(s)")
        return VerifiedAnswer(body: body,
                              answerText: grounded.sentences.map(\.text).joined(separator: " "),
                              citations: Array(citations), confidence: Confidence(0.6))
    }

    /// P4-U2 (B-4) — budgeted, advisory LEADS for a story's open gaps: each
    /// gap's expected-evidence targets run as archive searches; candidate
    /// documents surface for review. A lead never closes a gap and never
    /// touches the outline; a gap with no hits stays honestly open.
    public func storyGapLeads(for gaps: [HistoryGap]) async -> [GapLead] {
        guard let chunks else { return [] }
        let result = await GapLeadFinder().findLeads(for: gaps) { [weak chunks] query in
            let hits = (try? await chunks?.searchFTS(query, limit: 10)) ?? []
            return hits.map(\.objectID)
        }
        if result.gapsDeferred > 0 {
            KalsmritikoshLog.app.info("story gap leads: \(result.gapsTried) gap(s) tried, \(result.gapsDeferred) deferred to the next pass")
        }
        return result.leads
    }

    /// PI.3 — resume runs left mid-flight by a crash/quit/power-loss. Re-drives
    /// ONLY each interrupted run's not-done files (content-hash idempotent, so a
    /// file that actually finished is a cheap no-op), then finalizes the run.
    /// Complements the per-file `.started` resume (`resumeIncompleteIngests`):
    /// that catches files interrupted mid-commit; this catches files a bulk pass
    /// planned but never reached. Best-effort; the caller gates it out of
    /// eval/smoke boots. The bulk of the work runs during `await ingest.ingest`,
    /// which releases MainActor, so the UI is not blocked.
    public func resumeInterruptedRuns() async {
        guard let runs = ingestRuns, let ingest else { return }
        let resumable = (try? await runs.resumableRuns()) ?? []
        guard !resumable.isEmpty else { return }
        // Hold security scope for every root so the pending file URLs open.
        var scoped: [URL] = []
        for root in bookmarks.roots {
            if let url = try? bookmarks.resolve(root) { scoped.append(url) }
        }
        defer { for url in scoped { bookmarks.stopAccessing(url) } }
        for run in resumable {
            let pending = (try? await runs.pendingFiles(run: run.id)) ?? []
            guard !pending.isEmpty else {
                try? await runs.finish(run: run.id, status: .completed, atMillis: Self.nowMillis())
                continue
            }
            KalsmritikoshLog.app.info("PI.3: resuming run \(run.id.uuidString, privacy: .public) — \(pending.count, privacy: .public) file(s) remaining")
            for path in pending {
                guard await ingestControl.checkpoint() else { break }   // honor a fresh Stop/Pause
                let fileURL = URL(fileURLWithPath: path)
                do {
                    _ = try await ingest.ingest(fileAt: fileURL)
                    try? await runs.setFileState(run: run.id, path: path, state: .done, atMillis: Self.nowMillis())
                } catch {
                    try? await runs.setFileState(run: run.id, path: path, state: .failed,
                                                 error: String(describing: error).prefix(200).description, atMillis: Self.nowMillis())
                }
            }
            try? await runs.finish(run: run.id, status: .completed, atMillis: Self.nowMillis())
        }
    }

    /// App Nap when the window lost focus.
    public func autoReingestEmptyRoots() async {
        guard let ingest, let files else { return }
        // Fresh pass — clear any prior Stop/Pause and mark running for the
        // live Pause/Resume/Stop controls.
        await ingestControl.reset()
        await ingest.setDrainPaused(false)
        ingestRunState = .running
        defer { ingestRunState = .idle }
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
            KalsmritikoshLog.app.info("Auto-reingest: root \(root.displayName, privacy: .public) has 0 files in DB — kicking off bulk ingest")
            rootsToIngest.append((root.displayName, url))
        }

        // Pre-count the whole corpus so the progress bar's denominator is honest
        // (fixes the "100% while only 12% done" bar). Cleared when the pass ends.
        // Count OFF the MainActor — reading + byte-scanning a 91 MB mailbox to size
        // the bar must NOT run on the main thread (it froze the live panel at the
        // very start of a re-ingest, so the status looked dead). Detached + utility.
        let scanURLs = rootsToIngest.map(\.url)
        let scanProc = beginProcess("Scanning your files…")
        let plannedTotal = await Task.detached(priority: .utility) { [weak self] in
            self?.countRegularFiles(in: scanURLs) ?? 0
        }.value
        setIngestPlannedTotal(plannedTotal)
        finishProcess(scanProc)

        // Hold an activity assertion for the whole pass so macOS App Nap doesn't
        // suspend the background ingest when the window loses focus — the real
        // cause of the multi-minute stalls (a full bulk re-ingest froze at ~12%
        // for 73 minutes when unfocused). .userInitiated keeps the app at full
        // scheduling priority + blocks sudden termination until the pass ends.
        let napGuard = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .automaticTerminationDisabled],
            reason: "Ingesting documents"
        )
        defer { ProcessInfo.processInfo.endActivity(napGuard) }

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
        setIngestPlannedTotal(0)
        KalsmritikoshLog.app.info("Auto-reingest pass complete")
    }

    @discardableResult
    public func ingestAllRoots() async -> Int {
        guard let ingest else { return 0 }
        // Fresh pass — clear any prior Stop/Pause and mark running for the
        // live Pause/Resume/Stop controls.
        await ingestControl.reset()
        await ingest.setDrainPaused(false)
        ingestRunState = .running
        defer { ingestRunState = .idle }
        // Snapshot URLs on MainActor (BookmarkStore is MainActor-isolated).
        var urls: [URL] = []
        for root in bookmarks.roots {
            guard let url = try? bookmarks.resolve(root) else { continue }
            urls.append(url)
        }
        let bookmarksRef = bookmarks
        // Honest progress denominator across the whole corpus. Count OFF the
        // MainActor — scanning a 91 MB mailbox on the main thread froze the live
        // panel at the start of a wipe+re-ingest, so the status showed nothing.
        let scanURLs = urls
        let scanProc = beginProcess("Scanning your files…")
        let plannedTotal = await Task.detached(priority: .utility) { [weak self] in
            self?.countRegularFiles(in: scanURLs) ?? 0
        }.value
        setIngestPlannedTotal(plannedTotal)
        finishProcess(scanProc)
        // Keep macOS App Nap from suspending the ingest when unfocused.
        let napGuard = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .automaticTerminationDisabled],
            reason: "Ingesting documents"
        )
        defer { ProcessInfo.processInfo.endActivity(napGuard) }
        // Counter must be Sendable + actor-safe; a tiny actor is enough.
        let counter = IngestCounter()
        // ING-002 — collect per-file failures/timeouts across the parallel group so
        // the run reports which files didn't make it, not just how many did.
        let failures = IngestFailureLog()
        // PI.3 — open a durable run so an interrupted bulk pass (crash/quit) is
        // recoverable from its remaining files. Best-effort: a nil runID just
        // means no run row (ingest proceeds unchanged).
        let runsRepo = self.ingestRuns
        let runID = try? await runsRepo?.startRun(totalFiles: plannedTotal, atMillis: Self.nowMillis())
        await withTaskGroup(of: Void.self) { group in
            for url in urls {
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.enumerateAndIngest(
                        url: url,
                        ingest: ingest,
                        label: "Bulk ingest",
                        counter: counter,
                        failures: failures,
                        run: runID,
                        runs: runsRepo
                    )
                    await MainActor.run {
                        bookmarksRef.stopAccessing(url)
                    }
                }
            }
        }
        // Finalize the run: a user Stop leaves it resumable (paused); a clean
        // sweep completes it. A crash leaves it `running` → recovered at boot.
        if let runID {
            let stopped = await ingestControl.isStopped
            try? await runsRepo?.finish(run: runID, status: stopped ? .paused : .completed, atMillis: Self.nowMillis())
        }
        setIngestPlannedTotal(0)
        let succeeded = await counter.value
        let summary = IngestBatchSummary(succeeded: succeeded, failures: await failures.all())
        lastIngestSummary = summary
        if !summary.failures.isEmpty {
            KalsmritikoshLog.ingestion.notice("Bulk ingest: \(summary.headline, privacy: .public)")
        }
        return succeeded
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
        counter: IngestCounter? = nil,
        failures: IngestFailureLog? = nil,
        run: UUID? = nil,
        runs: IngestRunRepository? = nil
    ) async {
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        while let next = enumerator?.nextObject() as? URL {
            // Live Pause/Stop checkpoint — between files, so a Stop never
            // interrupts a document mid-commit and a Pause idles cleanly.
            guard await ingestControl.checkpoint() else {
                KalsmritikoshLog.ingestion.info("\(label, privacy: .public): stopped by user")
                break
            }
            let isRegular = (try? next.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isRegular else { continue }
            let fileURL = next
            // PI.3 — durable run state: mark this file in-flight before work so a
            // crash/quit leaves it as a resumable `running`/`pending` slot. All
            // run bookkeeping is best-effort (`try?`) — it must never alter the
            // ingest control flow or fail a file.
            if let run { try? await runs?.setFileState(run: run, path: fileURL.path, state: .running, atMillis: Self.nowMillis()) }
            await self.withIngestActivity(file: fileURL.lastPathComponent) {
                do {
                    // Per-file wall-clock timeout so ONE hung file can't freeze
                    // the whole corpus ingest (a .3gp video attachment blocked the
                    // re-ingest at 0% CPU). CONTAINERS (mbox/pst/nsf/zip) legitimately
                    // process HUNDREDS of nested messages + attachments in one
                    // ingest() call — a 91 MB Sent.mbox with 526 messages takes many
                    // minutes — so they get a large budget (1h); regular files get
                    // 180s (generous for a big PDF's OCR). A true hang still exceeds
                    // these and the loop moves on.
                    let ext = fileURL.pathExtension.lowercased()
                    let isContainer = ["mbox", "pst", "nsf", "zip", "mbx"].contains(ext)
                    let budget: Double = isContainer ? 3600 : 180
                    _ = try await Self.withFileTimeout(budget) { try await ingest.ingest(fileAt: fileURL) }
                    if let counter { await counter.increment() }
                    if let run { try? await runs?.setFileState(run: run, path: fileURL.path, state: .done, atMillis: Self.nowMillis()) }
                } catch is IngestTimeout {
                    KalsmritikoshLog.ingestion.error("\(label, privacy: .public): TIMEOUT after 180s on \(fileURL.lastPathComponent, privacy: .private) — skipped so the ingest can continue")
                    await failures?.record(IngestFailure(
                        fileName: fileURL.lastPathComponent, stage: .timeout,
                        reason: "exceeded the per-file time budget"))
                    if let run { try? await runs?.setFileState(run: run, path: fileURL.path, state: .failed, error: "timeout", atMillis: Self.nowMillis()) }
                } catch {
                    KalsmritikoshLog.ingestion.error("\(label, privacy: .public) failed for \(fileURL.lastPathComponent, privacy: .private): \(String(describing: error), privacy: .public)")
                    await failures?.record(IngestFailure(
                        fileName: fileURL.lastPathComponent, stage: .failed,
                        reason: String(describing: error).prefix(200).description))
                    if let run { try? await runs?.setFileState(run: run, path: fileURL.path, state: .failed, error: String(describing: error).prefix(200).description, atMillis: Self.nowMillis()) }
                }
            }
        }
    }

    /// Run `op` with a wall-clock timeout; throws `IngestTimeout` if it exceeds
    /// `seconds`. If `op` ignores cancellation (a blocking Speech/AV call), its
    /// task keeps running detached — but the caller is unblocked, so one hung
    /// file can't stall the whole ingest.
    struct IngestTimeout: Error {}

    /// Wall-clock milliseconds for the durable ingest-run ledger (the repository
    /// is deterministic and takes caller-supplied timestamps).
    nonisolated static func nowMillis() -> Double { Date().timeIntervalSince1970 * 1000 }

    nonisolated static func withFileTimeout<T: Sendable>(
        _ seconds: Double, _ op: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw IngestTimeout()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw IngestTimeout() }
            return result
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
