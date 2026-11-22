//
//  AppState+ShardImport.swift
//  Kalsmritikosh
//
//  Unified-path program (owner, 2026-11-22), PERF-14 … PERF-17 — the memory-sized shard import. A folder
//  import whose files the planner (IngestBatchPlanner) packs into MORE than one batch runs here; a
//  smaller one keeps the existing single-ledger path (AppState.ingestAllRoots).
//
//   1. Plan: the chosen folders are walked as the folder import walks them and packed into batches that
//      fit one worker's memory share (WorkerBudget, with the MemoryPressureGovernor's level).
//   2. Work: IngestWorkerPool runs the batches, re-asking the budget before each one. A worker opens its
//      own encrypted shard ledger (ShardLedger) and its own IngestCoordinator (IngestStackBuilder) and
//      imports its files there. A file the main ledger already holds (same URL, or the same bytes by
//      SHA-256) is not parsed into a shard: it goes through the main ledger's coordinator as before, so
//      re-reads, duplicates and new versions keep their existing handling.
//   3. Merge: when every worker is done, each shard is merged into the one ledger (ShardMerger, inside
//      `actor Database`), one shard at a time, and deleted once its merge is recorded.
//   4. Cross-shard steps: name reconciliation, the people-register refresh, the claim projection, and the
//      post-ingest checks (which refresh the retrieval caches). Unified path PERF-19 (owner 2026-11-22, round 2) —
//      not tested yet: each worker embeds its own shard's chunks with the main ledger's model before the
//      merge; the main drain still picks up any chunk left without a vector.
//
//  A merge interrupted by a quit or crash resumes at the next launch (`resumeInterruptedShardMerges`).
//
//  Not tested yet (owner 2026-11-22: implement now, test later).
//

import Foundation
import CryptoKit
import os

/// What one shard worker did, kept until its shard is merged (receipts name merged source versions).
nonisolated struct ShardWorkerReport: Sendable {
    var index: Int
    var shardURL: URL?
    var shardFiles: [(path: String, result: IngestCoordinator.Result)] = []
}

/// A file after the read stage: where it goes (PERF-19 / PERF-20).
nonisolated struct RoutedShardFile: Sendable {
    enum Route: Sendable { case shard, main, afterMerge }
    let url: URL
    let route: Route
}

/// Unified path PERF-20 (owner 2026-11-22, round 2) — not tested yet: which worker took which bytes in this run.
/// The first worker to read a content hash keeps it; the same bytes met by another worker are held until the
/// merges are done and then read through the main ledger, so they land as ONE source with its usual
/// duplicate / alias handling instead of two canonical sources from two shards.
actor ShardContentClaims {
    private var owner: [String: Int] = [:]
    private(set) var deferred: [URL] = []
    func claim(_ hash: String, worker: Int) -> Bool {
        if let o = owner[hash] { return o == worker }
        owner[hash] = worker
        return true
    }
    func `defer`(_ url: URL) { deferred.append(url) }
}

actor ShardWorkerReports {
    private(set) var reports: [ShardWorkerReport] = []
    func add(_ r: ShardWorkerReport) { reports.append(r) }
}

extension AppState {
    /// The plan for `roots` now, or nil when it fits one batch (the single-ledger path then runs).
    func shardImportPlan(for roots: [URL]) async -> IngestBatchPlan? {
        guard database != nil, !roots.isEmpty else { return nil }
        let pressure = await memoryPressure?.latestReportedLevel() ?? .normal
        let plan = await Task.detached(priority: .utility) {
            IngestBatchPlanner.plan(roots: roots, budget: WorkerBudget.current(pressure: pressure))
        }.value
        return plan.batches.count > 1 ? plan : nil
    }

    /// Import `urls` (folders or files) through memory-sized shard workers. Small imports (one batch)
    /// go through the existing path. Returns how many files were imported.
    @discardableResult
    public func importWithShardWorkers(urls: [URL]) async -> Int {
        guard let ingest else { return 0 }
        let counter = IngestCounter()
        let failures = IngestFailureLog()
        guard let plan = await shardImportPlan(for: urls) else {
            for url in urls {
                await enumerateAndIngest(url: url, ingest: ingest, label: "Import", counter: counter, failures: failures)
            }
            return await counter.value
        }
        let runID = try? await ingestRuns?.startRun(totalFiles: plan.fileCount, atMillis: Self.nowMillis())
        await runShardImport(plan: plan, ingest: ingest, counter: counter, failures: failures,
                             run: runID, runs: ingestRuns, receipts: database.map { IntakeReceiptRepository(database: $0) },
                             arrivals: .folderReread)
        if let runID {
            let stopped = await ingestControl.isStopped
            do { try await ingestRuns?.finish(run: runID, status: stopped ? .paused : .completed, atMillis: Self.nowMillis()) } catch {
                KalsmritikoshLog.ingestion.error("Shard import: run not finished: \(String(describing: error), privacy: .public)")
            }
        }
        return await counter.value
    }

    /// The shard import proper, shared by `importWithShardWorkers` and the folder import
    /// (`ingestAllRoots`), which owns the run row, the progress total and the post-run steps.
    func runShardImport(plan: IngestBatchPlan, ingest: IngestCoordinator, counter: IngestCounter,
                        failures: IngestFailureLog, run: UUID?, runs: IngestRunRepository?,
                        receipts: IntakeReceiptRepository?, arrivals: IntakeArrivalHint) async {
        guard let main = database else { return }
        let shardRunID = run ?? UUID()
        let key = main.key
        let ledgerURL = main.url
        let vault = evidenceVault
        let chunker = await ingest.chunkerConfiguration()
        let control = ingestControl
        let governor = memoryPressure
        let reports = ShardWorkerReports()
        KalsmritikoshLog.ingestion.info("Shard import: \(plan.fileCount, privacy: .public) file(s) in \(plan.batches.count, privacy: .public) batch(es), run \(shardRunID.uuidString, privacy: .public)")
        // Unified path PERF-19 (owner 2026-11-22, round 2) — not tested yet: every stage's width follows the
        // memory-pressure governor live; shards embed their own chunks with the main ledger's model.
        await PipelineStages.installPressureResponder(on: governor)
        let setup = await ingest.embeddingSetup()
        let embedding: ShardEmbeddingSetup? = {
            guard let e = setup.embedder, let id = setup.modelID else { return nil }
            return ShardEmbeddingSetup(embedder: e, modelID: id, modelVersion: setup.modelVersion ?? "1")
        }()
        // Unified path PERF-20 (owner 2026-11-22, round 2) — not tested yet: one owner per content hash in the run.
        let claims = ShardContentClaims()
        let pool = IngestWorkerPool(pressure: { await governor?.latestReportedLevel() })
        await pool.run(plan.batches, shouldContinue: { !(await control.isStopped) }) { [weak self] index, batch in
            guard let self else { return }
            let report = await self.runShardWorker(index: index, batch: batch, runID: shardRunID, main: main, key: key,
                                                   ledgerURL: ledgerURL, vault: vault, chunker: chunker, mainIngest: ingest,
                                                   counter: counter, failures: failures, run: run, runs: runs,
                                                   receipts: receipts, arrivals: arrivals, embedding: embedding, claims: claims)
            await reports.add(report)
        }
        // Merge, one shard at a time, into the one ledger.
        let merger = ShardMerger(main: main)
        let proc = beginProcess("Joining the imported parts into your ledger…", total: plan.batches.count)
        for report in await reports.reports.sorted(by: { $0.index < $1.index }) {
            guard let shardURL = report.shardURL else { continue }
            // PERF-20: the receipts come from the shard's own sidecar (the same path a next-launch merge takes).
            let owed = ShardLedger.loadReceipts(for: shardURL)
            switch await merger.merge(runID: shardRunID, index: report.index, shardURL: shardURL) {
            case .merged:
                if let receipts { await Self.writeShardReceipts(owed, into: receipts) }
            case .failed(let why):
                KalsmritikoshLog.ingestion.error("Shard import: shard \(report.index, privacy: .public) not merged (kept for a retry): \(why, privacy: .public)")
                await failures.record(IngestFailure(fileName: "part \(report.index + 1) of the import (\(report.shardFiles.count) file(s))",
                                                    stage: .failed, reason: "not joined into the ledger yet: \(why.prefix(160))"))
            }
        }
        finishProcess(proc)
        // PERF-20: the same bytes another worker had already taken are read now, through the main ledger, so
        // they become an alias / duplicate of the one merged source.
        let deferred = await claims.deferred
        if !deferred.isEmpty {
            KalsmritikoshLog.ingestion.info("Shard import: \(deferred.count, privacy: .public) file(s) with the same content as another part are read through the ledger now")
            for url in deferred {
                guard await ingestControl.checkpoint() else { break }
                _ = await ingestOneShardFile(url, into: ingest, counter: counter, failures: failures, run: run, runs: runs,
                                             receipts: receipts, arrivals: arrivals, recordReceipt: true)
            }
        }
        await afterShardMerges()
    }

    /// Write the intake receipts a merged shard owed (PERF-20).
    nonisolated static func writeShardReceipts(_ lines: [ShardReceiptLine], into receipts: IntakeReceiptRepository) async {
        for line in lines {
            await receipts.recordReceived(run: line.run, path: line.path, channel: line.channel,
                                          sourceVersionID: line.sourceVersionID, intakeOutcome: line.intakeOutcome)
        }
    }

    /// One worker: its shard, its coordinator, its files.
    ///
    /// Unified path PERF-19 (owner 2026-11-22, round 2) — not tested yet: the worker is a staged pipeline. A READ
    /// stage (up to the read width, process-wide) takes each file's custody hash (SHA-256 of its bytes) and
    /// asks the main ledger whether it already holds it, and hands the routed file on through a bounded
    /// channel (back-pressure: it never runs more than two widths ahead). The worker parses, cleans,
    /// chunks, extracts and writes each routed file into its own shard ledger (its coordinator; OCR per
    /// page and PDF page ranges run concurrently inside, bounded by their stages), and finally embeds the
    /// shard's chunks in batches with the main ledger's model before the shard is closed for the merge.
    nonisolated func runShardWorker(index: Int, batch: IngestBatch, runID: UUID, main: Database, key: LedgerKey?,
                                    ledgerURL: URL, vault: EvidenceVault?, chunker: Chunker, mainIngest: IngestCoordinator,
                                    counter: IngestCounter, failures: IngestFailureLog, run: UUID?, runs: IngestRunRepository?,
                                    receipts: IntakeReceiptRepository?, arrivals: IntakeArrivalHint,
                                    embedding: ShardEmbeddingSetup? = nil,
                                    claims: ShardContentClaims? = nil) async -> ShardWorkerReport {
        var report = ShardWorkerReport(index: index)
        let control = ingestControl
        let readWidth = await PipelineStages.currentWidth(.read)
        let routed = BoundedChannel<RoutedShardFile>(capacity: max(4, readWidth * 2))
        let files = batch.files
        async let reading: Void = StagedPipeline.feed(files, stage: .read, into: routed,
                                                      shouldContinue: { !(await control.isStopped) }) { f in
            let hash = Self.sha256Hex(of: f.url)
            let holds = await Self.mainLedgerHolds(f.url, contentHash: hash, main: main)
            var route: RoutedShardFile.Route = holds ? .main : .shard
            // Unified path PERF-20 (owner 2026-11-22, round 2) — not tested yet: the same bytes already taken by
            // ANOTHER worker of this run wait until the merge, then go through the main ledger (one source).
            if route == .shard, let hash, let claims, !(await claims.claim(hash, worker: index)) { route = .afterMerge }
            return RoutedShardFile(url: f.url, route: route)
        }

        var shard: ShardLedger?
        var shardIngest: IngestCoordinator?
        var shardUnavailable = false
        var shardFileCount = 0
        while let item = await routed.receive() {
            guard await control.checkpoint() else {
                KalsmritikoshLog.ingestion.info("Shard import: worker \(index, privacy: .public) stopped by user")
                break
            }
            switch item.route {
            case .afterMerge:
                await claims?.defer(item.url)
                continue
            case .main:
                // Files the main ledger already holds go through its own coordinator (re-reads, duplicates, versions).
                _ = await ingestOneShardFile(item.url, into: mainIngest, counter: counter, failures: failures, run: run, runs: runs,
                                             receipts: receipts, arrivals: arrivals, recordReceipt: true)
                continue
            case .shard:
                break
            }
            if shardIngest == nil, !shardUnavailable {
                do {
                    let opened = try await ShardLedger.open(runID: runID, index: index, besideLedgerAt: ledgerURL, key: key)
                    shard = opened
                    report.shardURL = opened.url
                    try await main.recordShard(runID: runID, index: index, path: opened.url.path, state: "writing", files: files.count)
                    do {
                        shardIngest = try await IngestStackBuilder.makeConfiguredCoordinator(database: opened.database, vault: vault,
                                                                                            chunker: chunker, embedding: embedding)
                    } catch {
                        KalsmritikoshLog.ingestion.error("Shard import: shard \(index, privacy: .public) pipeline not built: \(String(describing: error), privacy: .public)")
                        await opened.close()
                        do { try await main.setShardState(runID: runID, index: index, state: "failed", error: "pipeline not built: \(error)") } catch {
                            KalsmritikoshLog.storage.error("Shard import: state not recorded: \(String(describing: error), privacy: .public)")
                        }
                        shard = nil
                        report.shardURL = nil
                        shardUnavailable = true
                    }
                } catch {
                    KalsmritikoshLog.ingestion.error("Shard import: shard \(index, privacy: .public) could not be opened — its files go to the main ledger: \(String(describing: error), privacy: .public)")
                    if let opened = shard { await opened.close() }
                    shard = nil
                    report.shardURL = nil
                    shardUnavailable = true
                }
            }
            guard let target = shardIngest else {
                _ = await ingestOneShardFile(item.url, into: mainIngest, counter: counter, failures: failures, run: run, runs: runs,
                                             receipts: receipts, arrivals: arrivals, recordReceipt: true)
                continue
            }
            if let result = await ingestOneShardFile(item.url, into: target, counter: counter, failures: failures, run: run,
                                                     runs: runs, receipts: receipts, arrivals: arrivals, recordReceipt: false) {
                report.shardFiles.append((item.url.path, result))
                shardFileCount += 1
            }
        }
        // A stop: the read stage stops handing files on (its waiting sends return).
        await routed.finish()
        await reading

        guard let shard, let shardIngest else { return report }
        // Embedding stage: the shard's chunks, in batches, with the main ledger's model (the merge copies them).
        if embedding != nil, !(await control.isStopped) {
            await shardIngest.drainEmbeddingsNow()
        }
        await shardIngest.shutdown()
        await shard.close()
        // Unified path PERF-20 (owner 2026-11-22, round 2) — not tested yet: the receipts this shard owes, kept
        // beside it so a merge at the next launch still writes them.
        if let run {
            ShardLedger.writeReceipts(report.shardFiles.map { f in
                ShardReceiptLine(run: run, path: f.path, channel: arrivals.channel(for: URL(fileURLWithPath: f.path)),
                                 sourceVersionID: f.result.sourceVersionID, intakeOutcome: f.result.intakeOutcome)
            }, for: shard.url)
        }
        do { try await main.setShardState(runID: runID, index: index, state: "written") } catch {
            KalsmritikoshLog.storage.error("Shard import: written state not recorded: \(String(describing: error), privacy: .public)")
        }
        KalsmritikoshLog.ingestion.info("Shard import: worker \(index, privacy: .public) wrote \(shardFileCount, privacy: .public) file(s) into its shard")
        return report
    }

    /// One file through `coordinator`, with the folder import's time budget, run row and failure log.
    /// A receipt is written now only for the main ledger (a shard's source version exists in the ledger
    /// only after its merge).
    nonisolated func ingestOneShardFile(_ fileURL: URL, into coordinator: IngestCoordinator, counter: IngestCounter,
                                        failures: IngestFailureLog, run: UUID?, runs: IngestRunRepository?,
                                        receipts: IntakeReceiptRepository?, arrivals: IntakeArrivalHint,
                                        recordReceipt: Bool) async -> IngestCoordinator.Result? {
        if let run { await Self.setRunFileState(runs, run: run, path: fileURL.path, state: .running) }
        return await withIngestActivity(file: fileURL.lastPathComponent) { () async -> IngestCoordinator.Result? in
            let ext = fileURL.pathExtension.lowercased()
            let budget: Double = ["mbox", "pst", "nsf", "zip", "mbx"].contains(ext) ? 3600 : 180
            do {
                let result = try await Self.withFileTimeout(budget) { try await coordinator.ingest(fileAt: fileURL) }
                await counter.increment()
                if let run { await Self.setRunFileState(runs, run: run, path: fileURL.path, state: .done) }
                if recordReceipt, let run, let receipts {
                    await receipts.recordReceived(run: run, path: fileURL.path, channel: arrivals.channel(for: fileURL),
                                                  sourceVersionID: result.sourceVersionID, intakeOutcome: result.intakeOutcome)
                }
                return result
            } catch is IngestTimeout {
                KalsmritikoshLog.ingestion.error("Shard import: TIMEOUT on \(fileURL.lastPathComponent, privacy: .private) — skipped")
                await failures.record(IngestFailure(fileName: fileURL.lastPathComponent, stage: .timeout,
                                                    reason: "exceeded the per-file time budget"))
                if let run { await Self.setRunFileState(runs, run: run, path: fileURL.path, state: .failed, error: "timeout") }
                if let run, let receipts { await receipts.recordFailed(run: run, path: fileURL.path, channel: arrivals.channel(for: fileURL), timedOut: true) }
                return nil
            } catch {
                KalsmritikoshLog.ingestion.error("Shard import failed for \(fileURL.lastPathComponent, privacy: .private): \(String(describing: error), privacy: .private)")
                let reason = String(describing: error).prefix(200).description
                await failures.record(IngestFailure(fileName: fileURL.lastPathComponent, stage: .failed, reason: reason))
                if let run { await Self.setRunFileState(runs, run: run, path: fileURL.path, state: .failed, error: reason) }
                if let run, let receipts { await receipts.recordFailed(run: run, path: fileURL.path, channel: arrivals.channel(for: fileURL), timedOut: false) }
                return nil
            }
        }
    }

    nonisolated static func setRunFileState(_ runs: IngestRunRepository?, run: UUID, path: String, state: IngestFileState,
                                            error: String? = nil) async {
        do { try await runs?.setFileState(run: run, path: path, state: state, error: error, atMillis: nowMillis()) } catch {
            KalsmritikoshLog.ingestion.error("Shard import: run file state not recorded: \(String(describing: error), privacy: .public)")
        }
    }

    /// Does the main ledger already hold this file — the same URL, or the same bytes?
    nonisolated static func mainLedgerHolds(_ url: URL, main: Database) async -> Bool {
        await mainLedgerHolds(url, contentHash: sha256Hex(of: url), main: main)
    }

    /// The same, with the custody hash already taken by the read stage (PERF-19).
    nonisolated static func mainLedgerHolds(_ url: URL, contentHash: String?, main: Database) async -> Bool {
        do {
            let byURL = try await main.query("SELECT 1 FROM files WHERE url = ? OR url = ? LIMIT 1;",
                                             [.text(url.absoluteString), .text(url.standardizedFileURL.absoluteString)])
            if !byURL.isEmpty { return true }
            guard let hash = contentHash else { return false }
            let byHash = try await main.query("""
                SELECT 1 FROM files WHERE content_hash = ? UNION ALL SELECT 1 FROM source_versions WHERE content_hash = ? LIMIT 1;
                """, [.text(hash), .text(hash)])
            return !byHash.isEmpty
        } catch {
            KalsmritikoshLog.ingestion.error("Shard import: main-ledger check failed (file goes to the main ledger): \(String(describing: error), privacy: .public)")
            return true
        }
    }

    /// SHA-256 of a file's bytes (hex), read in 1 MiB pieces; nil when unreadable.
    nonisolated static func sha256Hex(of url: URL) -> String? {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch {
            KalsmritikoshLog.ingestion.error("Shard import: \(url.lastPathComponent, privacy: .private) unreadable for the content check: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        defer {
            do { try handle.close() } catch {
                KalsmritikoshLog.ingestion.error("Shard import: file handle not closed: \(error.localizedDescription, privacy: .public)")
            }
        }
        var hasher = SHA256()
        do {
            while true {
                let piece = try autoreleasepool { try handle.read(upToCount: 1_048_576) } ?? Data()
                if piece.isEmpty { break }
                hasher.update(data: piece)
            }
        } catch {
            KalsmritikoshLog.ingestion.error("Shard import: content check read failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The steps that span shards, after the merges.
    func afterShardMerges() async {
        // Unified path PERF-20 (owner 2026-11-22, round 2) — not tested yet: the merged custody / review events are
        // sealed into the main audit chain in their own order, through the chain's API (never copied raw).
        if let chain = auditChain {
            do {
                let sealed = try await chain.seal()
                if sealed > 0 { KalsmritikoshLog.storage.info("Shard import: \(sealed, privacy: .public) merged audit event(s) sealed") }
            } catch {
                KalsmritikoshLog.storage.error("Shard import: merged audit events not sealed (the next seal pass takes them): \(String(describing: error), privacy: .public)")
            }
        }
        // PERF-20: the in-memory bond graph learns the merged bonds now, not at the next launch.
        if let cache = bondGraphCache, let bonds = factBonds, let entities, let events {
            await cache.warm(bonds: bonds, entities: entities, events: events)
        }
        let folded = await reconcileEntityNames()
        if folded > 0 { KalsmritikoshLog.knowledge.info("Shard import: \(folded, privacy: .public) name variant(s) folded after the merge") }
        // Unified path IN-18 (owner 2026-11-22) — not tested yet: the refresh's merges are recorded in the audit.
        await refreshEntityRegisterAndAudit(context: "Shard import")
        if let projection = claimProjection { await projection.run(at: Date()) }
        await refreshRetrievalCaches()
        await ingest?.startBackgroundEmbeddingDrain()
    }

    /// Shards a quit or crash left unmerged are merged now (boot). A shard whose file is gone is marked
    /// failed; its files are re-read by the interrupted-run resume.
    public func resumeInterruptedShardMerges() async {
        guard let main = database else { return }
        let pending: [ShardMergeRecord]
        do { pending = try await main.unmergedShards() } catch {
            KalsmritikoshLog.storage.error("Shard import: merge log unreadable at launch: \(String(describing: error), privacy: .public)")
            return
        }
        guard !pending.isEmpty else { return }
        KalsmritikoshLog.storage.info("Shard import: \(pending.count, privacy: .public) shard(s) left unmerged — merging now")
        let merger = ShardMerger(main: main)
        let receipts = IntakeReceiptRepository(database: main)
        var merged = 0
        for record in pending {
            let shardURL = URL(fileURLWithPath: record.path)
            // Unified path PERF-20 (owner 2026-11-22, round 2) — not tested yet: a shard merged at the next launch
            // still writes the intake receipts its worker kept beside it.
            let owed = ShardLedger.loadReceipts(for: shardURL)
            if case .merged = await merger.merge(runID: record.runID, index: record.index, shardURL: shardURL) {
                merged += 1
                await Self.writeShardReceipts(owed, into: receipts)
            }
        }
        if merged > 0 {
            await afterShardMerges()
            await runPostIngestChecksSinceLast()
        }
    }
}
