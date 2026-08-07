//
//  IVFDiskVectorIndex.swift
//  Kalsmritikosh
//
//  P9.3 step 4 (GOV-005) — the disk-backed ANN: an IVF (inverted-file) index
//  whose durable state lives entirely in the single ledger (migration v103).
//  Centroids are cached in RAM (~K × dim × 4 bytes, corpus-independent);
//  posting lists are clustered rows read as sequential range scans. A probe
//  scores the query against every centroid (one vDSP pass), visits nProbe
//  cells (adaptive 32 → 128 when hits run short), and scores candidates with
//  the SAME shared kernel (VectorQuantization) that ingest and brute force
//  use — the three scoring sites cannot drift.
//
//  Staleness is structurally prevented on the steady path: `insert` writes
//  the posting durably in the same actor call the vector store makes from
//  its `upsert`. The build-vs-concurrent-insert race is closed by
//  `reconcile()` (embeddings LEFT JOIN postings) which runs at the end of
//  every build and is idempotent. `state='building'` in ann_index_meta is
//  the crash marker: a reopen that finds it reports not-ready (queries fall
//  back to the brute-force scan) until the background rebuild completes.
//

import Foundation
import OSLog

public actor IVFDiskVectorIndex {

    public struct Hit: Sendable {
        public let chunkID: UUID
        public let score: Double
    }

    // Probe tuning (plan §1): default nProbe, escalation ceiling, and the
    // score floor below which an escalation is attempted even with enough hits.
    public static let defaultNProbe = 32
    public static let maxNProbe = 128
    public static let escalationScoreFloor = 0.30

    /// K ≈ 4·√N clamped to a sane band (plan §1).
    public nonisolated static func cellCount(forVectorCount n: Int) -> Int {
        guard n > 0 else { return 0 }
        return min(4096, max(16, Int((4.0 * Double(n).squareRoot()).rounded())))
    }

    /// Build pages this many embeddings at a time — peak memory is one page.
    public static let buildPageSize = 4096
    /// Reservoir-sample ceiling for k-means training.
    public static let trainingSampleCap = 32_768

    private let repository: ANNIndexRepository
    private let modelID: String
    private let dimension: Int

    /// RAM cache of the coarse quantizer (loaded from ann_cells).
    private var centroids: [[Float]] = []
    private var ready = false

    public init(repository: ANNIndexRepository, modelID: String, dimension: Int) {
        self.repository = repository
        self.modelID = modelID
        self.dimension = dimension
    }

    // MARK: - State

    /// Ready = meta says ready AND the centroid cache is warm. Cheap to call.
    public func isReady() -> Bool { ready && !centroids.isEmpty }

    public func size() async -> Int {
        (try? await repository.postingCount(for: modelID)) ?? 0
    }

    /// Warm the centroid cache from the ledger. Returns readiness. A meta row
    /// stuck at 'building' (crash marker) reports NOT ready — the coordinator
    /// resumes the rebuild in the background while queries brute-force.
    @discardableResult
    public func load() async -> Bool {
        ready = false
        centroids = []
        guard let meta = try? await repository.meta(for: modelID),
              meta.state == .ready, meta.dimension == dimension else { return false }
        guard let cells = try? await repository.cells(for: modelID), !cells.isEmpty else { return false }
        centroids = cells.map { Self.floats(fromCentroid: $0.centroid) }
        ready = centroids.allSatisfy { $0.count == dimension }
        if !ready { centroids = [] }
        return ready
    }

    // MARK: - Build / retrain

    /// Full (re)build: stream-train the coarse quantizer from a reservoir
    /// sample, then stream-assign every stored embedding into posting lists.
    /// Idempotent and resumable — a crash leaves state='building' and the
    /// next call starts over from the durable inputs (chunk_embeddings).
    public func rebuild(seed: UInt64, now: Date = Date()) async throws {
        try await repository.ensureMeta(modelID: modelID, dimension: dimension, at: now)
        let total = try await repository.embeddingCount(for: modelID)
        guard total > 0 else {
            KalsmritikoshLog.storage.info("IVF rebuild skipped — no stored embeddings for \(self.modelID, privacy: .public)")
            return
        }
        try await repository.setState(.building, for: modelID, at: now)
        ready = false

        // ── Reservoir sample (deterministic) ────────────────────────────────
        var rng = XorShift64Star(state: seed)
        var sample: [[Float]] = []
        sample.reserveCapacity(min(total, Self.trainingSampleCap))
        var seen = 0
        var cursor: Int64 = 0
        while true {
            let page = try await repository.embeddingPage(for: modelID, afterRowid: cursor, limit: Self.buildPageSize)
            guard !page.isEmpty else { break }
            for row in page {
                guard row.q.count == dimension else { continue }
                seen += 1
                let vector = Self.dequantize(row.q, scale: row.scale)
                if sample.count < Self.trainingSampleCap {
                    sample.append(vector)
                } else {
                    let j = Int(rng.next() % UInt64(seen))
                    if j < Self.trainingSampleCap { sample[j] = vector }
                }
            }
            cursor = page.last!.rowid
            await Task.yield()   // keep the DB actor responsive to readers
        }
        guard !sample.isEmpty else {
            try await repository.setState(.empty, for: modelID, at: now)
            return
        }

        // ── Train ───────────────────────────────────────────────────────────
        let k = Self.cellCount(forVectorCount: total)
        let result = KMeansClusterer(seed: seed).cluster(vectors: sample, k: k)
        let trained = result.centroids
        try await repository.replaceCells(
            trained.enumerated().map { ANNCell(cellID: $0.offset, centroid: Self.centroidData($0.element), vectorCount: 0) },
            for: modelID, at: now)
        try await repository.recordTraining(cellCount: trained.count, trainedVectorCount: total,
                                            seed: seed, for: modelID, at: now)

        // ── Populate (streamed, batched, idempotent) ────────────────────────
        try await repository.deleteAllPostings(for: modelID)
        var occupancy = [Int](repeating: 0, count: trained.count)
        cursor = 0
        while true {
            let page = try await repository.embeddingPage(for: modelID, afterRowid: cursor, limit: Self.buildPageSize)
            guard !page.isEmpty else { break }
            var postings: [ANNPosting] = []
            postings.reserveCapacity(page.count)
            for row in page where row.q.count == dimension {
                let cell = KMeansClusterer.nearestCentroid(of: Self.dequantize(row.q, scale: row.scale), among: trained)
                occupancy[cell] += 1
                postings.append(ANNPosting(cellID: cell, chunkID: row.chunkID, q: row.q, scale: row.scale))
            }
            try await repository.insertPostings(postings, for: modelID)
            cursor = page.last!.rowid
            await Task.yield()
        }
        for (cell, count) in occupancy.enumerated() where count > 0 {
            try await repository.adjustCellCount(cellID: cell, by: count, for: modelID, at: now)
        }

        // ── Close the concurrent-insert race, then flip ready ───────────────
        centroids = trained
        try await reconcile(now: now)
        try await repository.setState(.ready, for: modelID, at: now)
        ready = true
        KalsmritikoshLog.storage.info("IVF rebuild complete — \(trained.count, privacy: .public) cells over \(total, privacy: .public) vectors (\(self.modelID, privacy: .public))")
    }

    /// Insert postings for any stored embedding that has none (idempotent).
    /// Runs at the end of every build; also the DataHealthCheck repair.
    /// Returns the number of postings added.
    @discardableResult
    public func reconcile(now: Date = Date()) async throws -> Int {
        guard !centroids.isEmpty else { return 0 }
        var added = 0
        while true {
            let missing = try await repository.embeddingsMissingPostings(for: modelID, limit: Self.buildPageSize)
            guard !missing.isEmpty else { break }
            var postings: [ANNPosting] = []
            postings.reserveCapacity(missing.count)
            for row in missing where row.q.count == dimension {
                let cell = KMeansClusterer.nearestCentroid(of: Self.dequantize(row.q, scale: row.scale), among: centroids)
                postings.append(ANNPosting(cellID: cell, chunkID: row.chunkID, q: row.q, scale: row.scale))
            }
            guard !postings.isEmpty else { break }
            try await repository.insertPostings(postings, for: modelID)
            added += postings.count
            for p in postings {
                try await repository.adjustCellCount(cellID: p.cellID, by: 1, for: modelID, at: now)
            }
            await Task.yield()
        }
        return added
    }

    // MARK: - Incremental maintenance (forwarded from SQLiteVectorStore.upsert/remove)

    /// Durably insert one vector's posting in the SAME call chain as the
    /// ledger write — the index can never be stale on the steady path.
    /// Returns false (no-op) when the index is not ready or the dimension
    /// mismatches (the model-identity guard); reconcile/rebuild covers those.
    @discardableResult
    public func insert(chunkID: UUID, q: Data, scale: Double, now: Date = Date()) async throws -> Bool {
        guard isReady(), q.count == dimension else { return false }
        let cell = KMeansClusterer.nearestCentroid(of: Self.dequantize(q, scale: scale), among: centroids)
        try await repository.insertPostings(
            [ANNPosting(cellID: cell, chunkID: chunkID, q: q, scale: scale)], for: modelID)
        try await repository.adjustCellCount(cellID: cell, by: 1, for: modelID, at: now)
        return true
    }

    public func remove(chunkID: UUID) async throws {
        try await repository.removePosting(chunkID: chunkID, for: modelID)
    }

    // MARK: - Probe

    /// nProbe search with adaptive escalation. Deterministic for a given
    /// ledger state. Returns [] when not ready (caller falls back).
    public func nearest(embedding: [Float], limit: Int) async throws -> [Hit] {
        guard isReady(), limit > 0, embedding.count == dimension,
              let query = VectorQuantization.prepareQuery(embedding) else { return [] }

        let ranked = KMeansClusterer.nearestCentroids(of: embedding, among: centroids, top: Self.maxNProbe)
        var probed = 0
        var top = BoundedTopK(limit: limit)
        var nProbe = min(Self.defaultNProbe, ranked.count)
        while true {
            while probed < nProbe {
                let cell = ranked[probed]
                probed += 1
                for posting in try await repository.postings(inCell: cell, for: modelID) {
                    if let score = VectorQuantization.cosineScore(query: query, candidate: posting.q, scale: posting.scale) {
                        top.offer(posting.chunkID, score)
                    }
                }
            }
            let hits = top.sortedDescending()
            let enough = hits.count >= limit && (hits.first?.1 ?? -1) >= Self.escalationScoreFloor
            if enough || nProbe >= ranked.count {
                return hits.map { Hit(chunkID: $0.0, score: $0.1) }
            }
            nProbe = min(nProbe * 2, ranked.count)   // escalate and continue
        }
    }

    // MARK: - Encoding helpers

    /// float32 LE encoding for ann_cells.centroid.
    nonisolated static func centroidData(_ centroid: [Float]) -> Data {
        centroid.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    nonisolated static func floats(fromCentroid data: Data) -> [Float] {
        guard data.count % 4 == 0 else { return [] }
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }

    /// Dequantize a stored int8 vector to floats (value × scale).
    nonisolated static func dequantize(_ blob: Data, scale: Double) -> [Float] {
        let floats = VectorQuantization.floats(fromInt8: blob)
        let s = Float(scale)
        return floats.map { $0 * s }
    }
}
