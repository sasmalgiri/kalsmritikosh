//
//  ANNIndexCoordinator.swift
//  Kalsmritikosh
//
//  P9.3 step 5 (GOV-005) — the ONE owner of both ANN accelerators (in-memory
//  HNSW and disk-backed IVF) plus the persisted strategy decision.
//  SQLiteVectorStore consumes only this coordinator, so the VectorStore
//  protocol surface is unchanged and retrieval/ingest/backfill callers see
//  zero API difference.
//
//  Serving rule: the PERSISTED strategy (ann_index_meta.strategy) decides
//  which index answers. HNSW keeps its historical in-sync guard
//  (size >= storedCount — it is rebuilt at boot, not incrementally). IVF is
//  transactionally in sync by construction and serves whenever its state is
//  ready. When neither can serve, `nearest` returns nil and the store falls
//  through to the always-correct brute-force scan.
//
//  Freshness rule: `noteUpsert`/`noteRemove` are forwarded by the store from
//  INSIDE its upsert/remove calls. IVF applies them durably whenever it is
//  ready — even while HNSW is the serving strategy — so a later flip to disk
//  serves current data with no rebuild. HNSW ignores them (boot-rebuild
//  semantics, unchanged).
//
//  Strategy changes happen ONLY in `maintain()` (a BackgroundTaskScheduler
//  job): decide via IndexStrategySelector, rebuild the target side in the
//  background while the current strategy keeps serving, then flip the
//  persisted decision. A retrain fires when the corpus outgrows the trained
//  geometry (2× the trained count).
//

import Foundation
import OSLog

public actor ANNIndexCoordinator {

    /// Corpus growth beyond the trained size that triggers an IVF retrain.
    public static let retrainGrowthFactor = 2.0

    private let hnsw: HNSWVectorIndex?
    private let ivf: IVFDiskVectorIndex
    private let repository: ANNIndexRepository
    private let modelID: String
    private let dimension: Int
    private let physicalMemoryBytes: UInt64
    /// Test seam: when set, the selector uses this cap instead of the
    /// RAM-derived one (whose floor is 250k vectors — far beyond what an
    /// integration test can seed). Production leaves it nil.
    private let inMemoryCapOverride: Int?
    /// Deterministic default training seed (persisted per build; a retrain
    /// reuses the recorded seed so identical inputs reproduce identical cells).
    private let defaultTrainSeed: UInt64

    private var maintenanceRunning = false

    public init(
        hnsw: HNSWVectorIndex?,
        ivf: IVFDiskVectorIndex,
        repository: ANNIndexRepository,
        modelID: String,
        dimension: Int,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        inMemoryCapOverride: Int? = nil,
        defaultTrainSeed: UInt64 = 0x516B_5F9E_A3C1_D7B2
    ) {
        self.hnsw = hnsw
        self.ivf = ivf
        self.repository = repository
        self.modelID = modelID
        self.dimension = dimension
        self.physicalMemoryBytes = physicalMemoryBytes
        self.inMemoryCapOverride = inMemoryCapOverride
        self.defaultTrainSeed = defaultTrainSeed
    }

    // MARK: - Boot

    /// Warm the persisted strategy's index. HNSW's (potentially long) boot
    /// build stays the caller's existing detached-task job; warming here is
    /// cheap: metadata + centroid cache only.
    public func warm() async {
        do {
            try await repository.ensureMeta(modelID: modelID, dimension: dimension, at: Date())
        } catch {
            KalsmritikoshLog.storage.error("ANN coordinator warm: ensureMeta failed — \(String(describing: error), privacy: .public)")
        }
        if await currentStrategy() == .diskIVF {
            _ = await ivf.load()
        }
    }

    public func currentStrategy() async -> ANNStrategy {
        (try? await repository.meta(for: modelID))?.strategy ?? .inMemoryHNSW
    }

    // MARK: - Serving

    /// The strategy-selected answer, or nil when no index can serve (the
    /// store then brute-forces — always correct, never silent-empty).
    public func nearest(to embedding: [Float], limit: Int, storedCount: Int) async -> [VectorHit]? {
        switch await currentStrategy() {
        case .inMemoryHNSW:
            guard let hnsw, await hnsw.isBuilt() else { return nil }
            let annSize = await hnsw.size()
            // Historical in-sync guard: a boot-built index smaller than the
            // ledger would silently drop this session's vectors.
            guard annSize > 0, annSize >= storedCount else { return nil }
            return await hnsw.nearest(to: embedding, limit: limit)
        case .diskIVF:
            guard await ivf.isReady() else { return nil }
            guard let hits = try? await ivf.nearest(embedding: embedding, limit: limit) else { return nil }
            return hits.map { VectorHit(chunkID: $0.chunkID, score: $0.score) }
        }
    }

    // MARK: - Freshness (forwarded from SQLiteVectorStore.upsert/remove)

    /// Keep the disk index durably fresh regardless of the serving strategy.
    /// Never throws into the ingest path — a failed posting is repaired by
    /// the next reconcile pass.
    public func noteUpsert(chunkID: UUID, q: Data, scale: Double) async {
        do {
            _ = try await ivf.insert(chunkID: chunkID, q: q, scale: scale)
        } catch {
            KalsmritikoshLog.storage.error("ANN noteUpsert failed (reconcile will repair) — \(String(describing: error), privacy: .public)")
        }
    }

    public func noteRemove(chunkID: UUID) async {
        do {
            try await ivf.remove(chunkID: chunkID)
        } catch {
            KalsmritikoshLog.storage.error("ANN noteRemove failed — \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Background maintenance (BackgroundTaskScheduler job body)

    /// Decide → rebuild the target side → flip the persisted strategy.
    /// Re-entrant-safe; queries keep serving the CURRENT strategy (or brute
    /// force) throughout a rebuild.
    public func maintain(now: Date = Date()) async {
        guard !maintenanceRunning else { return }
        maintenanceRunning = true
        defer { maintenanceRunning = false }
        do {
            try await repository.ensureMeta(modelID: modelID, dimension: dimension, at: now)
            guard let meta = try await repository.meta(for: modelID) else { return }
            let count = try await repository.embeddingCount(for: modelID)
            let cap = inMemoryCapOverride
                ?? HNSWVectorIndex.maxInMemoryVectors(physicalMemoryBytes: physicalMemoryBytes)
            let target = IndexStrategySelector.decide(
                current: meta.strategy, vectorCount: count, cap: cap)

            if target != meta.strategy {
                switch target {
                case .diskIVF:
                    // Build the disk side FIRST, then flip — the old strategy
                    // serves until the new one is ready.
                    let seed = meta.trainSeed == 0 ? defaultTrainSeed : meta.trainSeed
                    try await ivf.rebuild(seed: seed, now: now)
                    try await repository.setStrategy(.diskIVF, for: modelID, at: now)
                    KalsmritikoshLog.storage.info("ANN strategy flipped to diskIVF (\(count, privacy: .public) vectors)")
                case .inMemoryHNSW:
                    // Flip the decision; the HNSW boot-build path (existing
                    // warm task on next boot, or an already-built index this
                    // session) takes over. Until built, brute force serves.
                    try await repository.setStrategy(.inMemoryHNSW, for: modelID, at: now)
                    KalsmritikoshLog.storage.info("ANN strategy flipped to inMemoryHNSW (\(count, privacy: .public) vectors)")
                }
                return
            }

            // Same strategy — steady-state disk maintenance.
            if meta.strategy == .diskIVF {
                if meta.state == .building || meta.state == .empty {
                    // Crash marker / never-built: (re)build now.
                    let seed = meta.trainSeed == 0 ? defaultTrainSeed : meta.trainSeed
                    try await ivf.rebuild(seed: seed, now: now)
                } else if meta.trainedVectorCount > 0,
                          Double(count) > Self.retrainGrowthFactor * Double(meta.trainedVectorCount) {
                    // Corpus outgrew the trained geometry — retrain.
                    let seed = meta.trainSeed == 0 ? defaultTrainSeed : meta.trainSeed
                    KalsmritikoshLog.storage.info("ANN retrain — corpus \(count, privacy: .public) > 2× trained \(meta.trainedVectorCount, privacy: .public)")
                    try await ivf.rebuild(seed: seed, now: now)
                } else if await ivf.isReady() {
                    // Cheap steady-state repair of any missed postings.
                    let repaired = try await ivf.reconcile(now: now)
                    if repaired > 0 {
                        KalsmritikoshLog.storage.info("ANN reconcile repaired \(repaired, privacy: .public) posting(s)")
                    }
                }
            }
        } catch {
            KalsmritikoshLog.storage.error("ANN maintain failed — \(String(describing: error), privacy: .public)")
        }
    }
}
