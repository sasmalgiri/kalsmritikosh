//
//  KMeansClustererTests.swift
//  KalsmritikoshTests
//
//  P9.3 step 3 — the deterministic coarse-quantizer trainer. Proves seed
//  determinism, planted-cluster recovery, the imbalance tripwire, empty-cell
//  reseeding, k clamping, and the nProbe nearest-centroids helper. Pure; no
//  DB; deterministic PRNG only.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("P9.3 — k-means coarse quantizer")
struct KMeansClustererTests {

    /// A planted mixture: `clusters` well-separated centers with tight noise.
    private func plantedCorpus(clusters: Int, perCluster: Int, dim: Int, seed: UInt64)
        -> (vectors: [[Float]], truth: [Int]) {
        var rng = XorShift64Star(state: seed)
        func unit() -> Float { Float(Double(rng.next() % 1_000_000) / 1_000_000.0) - 0.5 }
        // Centers on a scaled grid so separation >> noise.
        let centers: [[Float]] = (0..<clusters).map { c in
            (0..<dim).map { d in Float((c * 7 + d * 3) % 13) * 10.0 }
        }
        var vectors: [[Float]] = []
        var truth: [Int] = []
        for c in 0..<clusters {
            for _ in 0..<perCluster {
                vectors.append((0..<dim).map { d in centers[c][d] + unit() })
                truth.append(c)
            }
        }
        return (vectors, truth)
    }

    @Test("Identical seed + sample produce identical centroids; a different seed differs")
    func determinism() {
        let (vectors, _) = plantedCorpus(clusters: 8, perCluster: 40, dim: 16, seed: 42)
        let a = KMeansClusterer(seed: 7).cluster(vectors: vectors, k: 8)
        let b = KMeansClusterer(seed: 7).cluster(vectors: vectors, k: 8)
        #expect(a.centroids == b.centroids)
        #expect(a.assignments == b.assignments)
        let c = KMeansClusterer(seed: 8).cluster(vectors: vectors, k: 8)
        #expect(a.centroids != c.centroids)
    }

    @Test("A planted well-separated mixture is recovered: co-clustered truth stays co-clustered")
    func plantedRecovery() {
        let (vectors, truth) = plantedCorpus(clusters: 8, perCluster: 50, dim: 16, seed: 99)
        let result = KMeansClusterer(seed: 3).cluster(vectors: vectors, k: 8, iterations: 20)
        #expect(result.centroids.count == 8)
        // Purity: every learned cell should be dominated by ONE truth cluster.
        var cellTruth: [Int: [Int: Int]] = [:]
        for (i, cell) in result.assignments.enumerated() {
            cellTruth[cell, default: [:]][truth[i], default: 0] += 1
        }
        var pure = 0, total = 0
        for (_, hist) in cellTruth {
            let cellTotal = hist.values.reduce(0, +)
            pure += hist.values.max() ?? 0
            total += cellTotal
        }
        #expect(Double(pure) / Double(total) >= 0.95,
                "cluster purity \(Double(pure) / Double(total)) too low")
        // Balanced planted data should not trip the imbalance alarm badly.
        #expect(result.imbalance < 4.0)
    }

    @Test("A degenerate all-identical corpus flags heavy imbalance instead of crashing")
    func degenerateImbalance() {
        let vectors = Array(repeating: [Float](repeating: 1, count: 8), count: 200)
        let result = KMeansClusterer(seed: 5).cluster(vectors: vectors, k: 10)
        #expect(result.centroids.count == 10)
        #expect(result.assignments.count == 200)
        // All mass lands in one cell → imbalance ≈ k.
        #expect(result.imbalance >= 8.0)
    }

    @Test("No learned cell is left empty on ordinary data (empty-cell reseeding)")
    func noEmptyCells() {
        let (vectors, _) = plantedCorpus(clusters: 4, perCluster: 100, dim: 8, seed: 11)
        // Ask for MORE cells than natural clusters — reseeding must still
        // give every cell at least a chance; assert none is empty.
        let result = KMeansClusterer(seed: 13).cluster(vectors: vectors, k: 12, iterations: 20)
        var population = [Int](repeating: 0, count: 12)
        for a in result.assignments { population[a] += 1 }
        #expect(!population.contains(0), "empty cell survived reseeding: \(population)")
    }

    @Test("k clamps to the sample size; empty input yields an empty result")
    func clampsAndEmpty() {
        let vectors: [[Float]] = [[1, 0], [0, 1], [1, 1]]
        let r = KMeansClusterer(seed: 1).cluster(vectors: vectors, k: 50)
        #expect(r.centroids.count == 3)
        let empty = KMeansClusterer(seed: 1).cluster(vectors: [], k: 4)
        #expect(empty.centroids.isEmpty && empty.assignments.isEmpty)
    }

    @Test("nearestCentroids returns the nProbe set best-first")
    func nearestCentroidsOrdering() {
        let centroids: [[Float]] = [[0, 0], [10, 0], [0, 10], [10, 10]]
        let probes = KMeansClusterer.nearestCentroids(of: [9, 1], among: centroids, top: 2)
        #expect(probes == [1, 0] || probes == [1, 3])   // nearest is clearly centroid 1
        #expect(probes.first == 1)
        #expect(KMeansClusterer.nearestCentroids(of: [9, 1], among: centroids, top: 0).isEmpty)
    }
}
