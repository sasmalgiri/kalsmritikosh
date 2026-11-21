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
//      post-ingest checks (which refresh the retrieval caches). Embeddings of the merged chunks are made by
//      the main ledger's background embedding drain, which picks up every chunk without a vector.
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
        let pool = IngestWorkerPool(pressure: { await governor?.latestReportedLevel() })
        await pool.run(plan.batches, shouldContinue: { !(await control.isStopped) }) { [weak self] index, batch in
            guard let self else { return }
            let report = await self.runShardWorker(index: index, batch: batch, runID: shardRunID, main: main, key: key,
                                                   ledgerURL: ledgerURL, vault: vault, chunker: chunker, mainIngest: ingest,
                                                   counter: counter, failures: failures, run: run, runs: runs,
                                                   receipts: receipts, arrivals: arrivals)
            await reports.add(report)
        }
        // Merge, one shard at a time, into the one ledger.
        let merger = ShardMerger(main: main)
        let proc = beginProcess("Joining the imported parts into your ledger…", total: plan.batches.count)
        for report in await reports.reports.sorted(by: { $0.index < $1.index }) {
            guard let shardURL = report.shardURL else { continue }
            switch await merger.merge(runID: shardRunID, index: report.index, shardURL: shardURL) {
            case .merged:
                if let run, let receipts {
                    for f in report.shardFiles {
                        await receipts.recordReceived(run: run, path: f.path, channel: arrivals.channel(for: URL(fileURLWithPath: f.path)),
                                                      sourceVersionID: f.result.sourceVersionID, intakeOutcome: f.result.intakeOutcome)
                    }
                }
            case .failed(let why):
                KalsmritikoshLog.ingestion.error("Shard import: shard \(report.index, privacy: .public) not merged (kept for a retry): \(why, privacy: .public)")
                await failures.record(IngestFailure(fileName: "part \(report.index + 1) of the import (\(report.shardFiles.count) file(s))",
                                                    stage: .failed, reason: "not joined into the ledger yet: \(why.prefix(160))"))
            }
        }
        finishProcess(proc)
        await afterShardMerges()
    }

    /// One worker: its shard, its coordinator, its files.
    nonisolated func runShardWorker(index: Int, batch: IngestBatch, runID: UUID, main: Database, key: LedgerKey?,
                                    ledgerURL: URL, vault: EvidenceVault?, chunker: Chunker, mainIngest: IngestCoordinator,
                                    counter: IngestCounter, failures: IngestFailureLog, run: UUID?, runs: IngestRunRepository?,
                                    receipts: IntakeReceiptRepository?, arrivals: IntakeArrivalHint) async -> ShardWorkerReport {
        var report = ShardWorkerReport(index: index)
        // Files the main ledger already holds go through its own coordinator (re-reads, duplicates, versions).
        var shardFiles: [URL] = []
        var mainFiles: [URL] = []
        for f in batch.files {
            if await Self.mainLedgerHolds(f.url, main: main) { mainFiles.append(f.url) } else { shardFiles.append(f.url) }
        }
        for url in mainFiles {
            guard await ingestControl.checkpoint() else { return report }
            _ = await ingestOneShardFile(url, into: mainIngest, counter: counter, failures: failures, run: run, runs: runs,
                                         receipts: receipts, arrivals: arrivals, recordReceipt: true)
        }
        guard !shardFiles.isEmpty else { return report }
        let shard: ShardLedger
        do {
            shard = try await ShardLedger.open(runID: runID, index: index, besideLedgerAt: ledgerURL, key: key)
            try await main.recordShard(runID: runID, index: index, path: shard.url.path, state: "writing", files: shardFiles.count)
        } catch {
            KalsmritikoshLog.ingestion.error("Shard import: shard \(index, privacy: .public) could not be opened — its files go to the main ledger: \(String(describing: error), privacy: .public)")
            for url in shardFiles {
                guard await ingestControl.checkpoint() else { break }
                _ = await ingestOneShardFile(url, into: mainIngest, counter: counter, failures: failures, run: run, runs: runs,
                                             receipts: receipts, arrivals: arrivals, recordReceipt: true)
            }
            return report
        }
        report.shardURL = shard.url
        let shardIngest: IngestCoordinator
        do {
            shardIngest = try await IngestStackBuilder.makeConfiguredCoordinator(database: shard.database, vault: vault, chunker: chunker)
        } catch {
            KalsmritikoshLog.ingestion.error("Shard import: shard \(index, privacy: .public) pipeline not built: \(String(describing: error), privacy: .public)")
            await shard.close()
            do { try await main.setShardState(runID: runID, index: index, state: "failed", error: "pipeline not built: \(error)") } catch {
                KalsmritikoshLog.storage.error("Shard import: state not recorded: \(String(describing: error), privacy: .public)")
            }
            report.shardURL = nil
            for url in shardFiles {
                guard await ingestControl.checkpoint() else { break }
                _ = await ingestOneShardFile(url, into: mainIngest, counter: counter, failures: failures, run: run, runs: runs,
                                             receipts: receipts, arrivals: arrivals, recordReceipt: true)
            }
            return report
        }
        for url in shardFiles {
            guard await ingestControl.checkpoint() else {
                KalsmritikoshLog.ingestion.info("Shard import: worker \(index, privacy: .public) stopped by user")
                break
            }
            if let result = await ingestOneShardFile(url, into: shardIngest, counter: counter, failures: failures, run: run,
                                                     runs: runs, receipts: receipts, arrivals: arrivals, recordReceipt: false) {
                report.shardFiles.append((url.path, result))
            }
        }
        await shardIngest.shutdown()
        await shard.close()
        do { try await main.setShardState(runID: runID, index: index, state: "written") } catch {
            KalsmritikoshLog.storage.error("Shard import: written state not recorded: \(String(describing: error), privacy: .public)")
        }
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
        do {
            let byURL = try await main.query("SELECT 1 FROM files WHERE url = ? OR url = ? LIMIT 1;",
                                             [.text(url.absoluteString), .text(url.standardizedFileURL.absoluteString)])
            if !byURL.isEmpty { return true }
            guard let hash = sha256Hex(of: url) else { return false }
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
        var merged = 0
        for record in pending {
            if case .merged = await merger.merge(runID: record.runID, index: record.index, shardURL: URL(fileURLWithPath: record.path)) {
                merged += 1
            }
        }
        if merged > 0 {
            await afterShardMerges()
            await runPostIngestChecksSinceLast()
        }
    }
}
