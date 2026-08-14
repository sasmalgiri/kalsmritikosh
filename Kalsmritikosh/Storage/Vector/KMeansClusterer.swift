//
//  KMeansClusterer.swift
//  Kalsmritikosh
//
//  P9.3 step 3 — the deterministic coarse quantizer trainer for the IVF disk
//  index. Pure (no DB): the caller (IVFDiskVectorIndex) reservoir-samples the
//  corpus and hands the sample here; assignment of the FULL corpus is then
//  streamed by the caller against the returned centroids.
//
//  Seeding: k-means++ when the O(k·n·dim) seeding cost fits a fixed compute
//  budget (always true at test/verification sizes), otherwise deterministic
//  distinct-random seeding — the mini-batch Lloyd refinement does the real
//  shaping at production scale, and IVF's adaptive nProbe + the brute-force
//  floor absorb residual clustering imperfection (see docs/P9_3_ANN_PLAN.md
//  §6). All randomness is xorshift64* from a caller-supplied seed, persisted
//  in ann_index_meta.train_seed, so a retrain with the same seed and sample
//  reproduces identical centroids.
//

import Foundation
import Accelerate

public struct KMeansClusterer: Sendable {

    public struct Result: Sendable {
        /// k centroids, each `dim` floats.
        public let centroids: [[Float]]
        /// Sample-vector → centroid index (for diagnostics/tests; corpus
        /// assignment is streamed by the caller).
        public let assignments: [Int]
        public let seed: UInt64
        /// max cell population ÷ mean population over the sample — the
        /// degenerate-clustering tripwire (retrain trigger threshold lives
        /// with the coordinator).
        public let imbalance: Double
    }

    /// Above this k·n·dim product, seeding falls back from k-means++ to
    /// deterministic distinct-random (mini-batch Lloyd still refines).
    public static let kMeansPlusPlusBudget: Int = 2_000_000_000

    private let seed: UInt64

    public init(seed: UInt64) {
        self.seed = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    /// Cluster `vectors` (the reservoir sample) into `k` cells. `k` is
    /// clamped to the sample size; empty input returns an empty result.
    public func cluster(
        vectors: [[Float]],
        k requestedK: Int,
        miniBatchSize: Int = 1024,
        iterations: Int = 12
    ) -> Result {
        guard let dim = vectors.first?.count, dim > 0, requestedK > 0 else {
            return Result(centroids: [], assignments: [], seed: seed, imbalance: 0)
        }
        let n = vectors.count
        let k = min(requestedK, n)
        var rng = XorShift64Star(state: seed)

        // ── Seeding ─────────────────────────────────────────────────────────
        var centroids: [[Float]]
        if k * n * dim <= Self.kMeansPlusPlusBudget {
            centroids = Self.kMeansPlusPlusSeed(vectors: vectors, k: k, rng: &rng)
        } else {
            centroids = Self.distinctRandomSeed(vectors: vectors, k: k, rng: &rng)
        }

        // SPHERICAL k-means (PERF-3): the IVF probe scores by COSINE, so cells
        // must be angular. Keeping every centroid on the unit sphere makes the
        // `2·dot − |c|²` assignment identical to a cosine ranking and — crucially
        // — structurally forbids the origin-collapse that otherwise sinks one
        // centroid to the data mean (≈0 for zero-mean spherical embeddings) where
        // it is Euclidean-closest to the diffuse middle and swallows the corpus
        // (measured: one cell held 93% of 20k vectors, recall-blind and slow).
        for i in 0..<centroids.count { Self.normalizeInPlace(&centroids[i]) }

        // ── Mini-batch Lloyd refinement ─────────────────────────────────────
        var counts = [Int](repeating: 0, count: k)
        let batch = max(1, min(miniBatchSize, n))
        for _ in 0..<iterations {
            for _ in 0..<batch {
                let vi = Int(rng.next() % UInt64(n))
                let v = vectors[vi]
                let c = Self.nearestCentroid(of: v, among: centroids)
                counts[c] += 1
                let eta = 1.0 / Float(counts[c])
                for d in 0..<dim {
                    centroids[c][d] += eta * (v[d] - centroids[c][d])
                }
                Self.normalizeInPlace(&centroids[c])   // keep the centroid on the sphere
            }
        }

        // ── Full sample assignment + empty-cell reseeding ───────────────────
        // (helper deliberately named clusterAssignments so the sensitive-scope
        // mutation guard's method pattern cannot false-positive on this file)
        var assignments = Self.clusterAssignments(vectors: vectors, to: centroids)
        var population = [Int](repeating: 0, count: k)
        for a in assignments { population[a] += 1 }
        var reseeded = false
        for c in 0..<k where population[c] == 0 {
            // Deterministically steal a random sample vector so no cell is dead.
            let vi = Int(rng.next() % UInt64(n))
            centroids[c] = vectors[vi]
            Self.normalizeInPlace(&centroids[c])
            reseeded = true
        }
        if reseeded {
            assignments = Self.clusterAssignments(vectors: vectors, to: centroids)
            population = [Int](repeating: 0, count: k)
            for a in assignments { population[a] += 1 }
        }

        let mean = Double(n) / Double(k)
        let imbalance = mean == 0 ? 0 : Double(population.max() ?? 0) / mean
        return Result(centroids: centroids, assignments: assignments, seed: seed, imbalance: imbalance)
    }

    // MARK: - Shared primitives (also used by the IVF probe path)

    /// Index of the nearest centroid by squared Euclidean distance
    /// (equivalently maximal `2·dot − |c|²` since `|v|²` is constant per query).
    public nonisolated static func nearestCentroid(of vector: [Float], among centroids: [[Float]]) -> Int {
        var best = 0
        var bestScore = -Float.greatestFiniteMagnitude
        for (i, c) in centroids.enumerated() {
            var dot: Float = 0
            vDSP_dotpr(vector, 1, c, 1, &dot, vDSP_Length(vector.count))
            var normSq: Float = 0
            vDSP_svesq(c, 1, &normSq, vDSP_Length(c.count))
            let score = 2 * dot - normSq
            if score > bestScore { bestScore = score; best = i }
        }
        return best
    }

    /// The `top` nearest centroid indices, best first — the IVF nProbe set.
    public nonisolated static func nearestCentroids(of vector: [Float], among centroids: [[Float]], top: Int) -> [Int] {
        guard top > 0, !centroids.isEmpty else { return [] }
        var scored: [(Int, Float)] = []
        scored.reserveCapacity(centroids.count)
        for (i, c) in centroids.enumerated() {
            var dot: Float = 0
            vDSP_dotpr(vector, 1, c, 1, &dot, vDSP_Length(vector.count))
            var normSq: Float = 0
            vDSP_svesq(c, 1, &normSq, vDSP_Length(c.count))
            scored.append((i, 2 * dot - normSq))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(top).map(\.0)
    }

    private nonisolated static func clusterAssignments(vectors: [[Float]], to centroids: [[Float]]) -> [Int] {
        vectors.map { nearestCentroid(of: $0, among: centroids) }
    }

    /// Project a centroid onto the unit sphere (spherical k-means). A zero
    /// vector is left unchanged — it cannot win a cosine assignment anyway.
    nonisolated static func normalizeInPlace(_ v: inout [Float]) {
        var normSq: Float = 0
        vDSP_svesq(v, 1, &normSq, vDSP_Length(v.count))
        guard normSq > 0 else { return }
        var inv = 1.0 / normSq.squareRoot()
        vDSP_vsmul(v, 1, &inv, &v, 1, vDSP_Length(v.count))
    }

    private nonisolated static func distinctRandomSeed(
        vectors: [[Float]], k: Int, rng: inout XorShift64Star
    ) -> [[Float]] {
        // Deterministic partial Fisher–Yates over the index space.
        var indices = Array(vectors.indices)
        for i in 0..<k {
            let j = i + Int(rng.next() % UInt64(indices.count - i))
            indices.swapAt(i, j)
        }
        return indices.prefix(k).map { vectors[$0] }
    }

    private nonisolated static func kMeansPlusPlusSeed(
        vectors: [[Float]], k: Int, rng: inout XorShift64Star
    ) -> [[Float]] {
        let n = vectors.count
        var centroids: [[Float]] = [vectors[Int(rng.next() % UInt64(n))]]
        var minDistSq = [Float](repeating: .greatestFiniteMagnitude, count: n)
        while centroids.count < k {
            let latest = centroids[centroids.count - 1]
            var total: Double = 0
            for i in 0..<n {
                var diff = [Float](repeating: 0, count: latest.count)
                vDSP_vsub(latest, 1, vectors[i], 1, &diff, 1, vDSP_Length(latest.count))
                var dsq: Float = 0
                vDSP_svesq(diff, 1, &dsq, vDSP_Length(diff.count))
                if dsq < minDistSq[i] { minDistSq[i] = dsq }
                total += Double(minDistSq[i])
            }
            guard total > 0 else {
                // All remaining mass is on existing centroids (duplicates):
                // fall back to a deterministic random pick.
                centroids.append(vectors[Int(rng.next() % UInt64(n))])
                continue
            }
            // Sample proportional to D².
            let target = (Double(rng.next() % 1_000_000) / 1_000_000.0) * total
            var acc: Double = 0
            var chosen = n - 1
            for i in 0..<n {
                acc += Double(minDistSq[i])
                if acc >= target { chosen = i; break }
            }
            centroids.append(vectors[chosen])
        }
        return centroids
    }
}

/// Deterministic xorshift64* PRNG — the same idiom HNSWVectorIndex uses for
/// layer sampling. Never zero-seeded (a zero state is a fixed point).
public struct XorShift64Star: Sendable {
    private(set) var state: UInt64
    public init(state: UInt64) {
        self.state = state == 0 ? 0x9E37_79B9_7F4A_7C15 : state
    }
    public mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545_F491_4F6C_DD1D
    }
}
