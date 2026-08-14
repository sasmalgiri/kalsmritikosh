//
//  ANNBenchmark.swift
//  Kalsmritikosh
//
//  P9.3 step 8 (GOV-005) — the deterministic ANN benchmark harness. Seeds a
//  synthetic planted-cluster corpus as REAL ledger rows (one KO, N chunks +
//  embeddings, batched), builds the disk IVF index, and records the metrics
//  the SC1 owner-hardware run reports: train/build seconds, incremental
//  insert p50, query p50/p95 (warm), recall@10 vs the exact brute-force
//  scan, the brute-force baseline latency, and disk bytes added. CI-safe
//  sizes run in the test suite; the owner scale run passes larger sizes
//  (100k/500k/1M+) via the documented entry — marketing figures remain
//  tested-figure-only (SHIP_DECISIONS).
//

import Foundation

public struct ANNBenchmark: Sendable {

    public struct Metrics: Sendable {
        public let size: Int
        public let cellCount: Int
        public let buildSeconds: Double         // train + populate + reconcile
        public let insertP50Ms: Double
        public let queryP50Ms: Double
        public let queryP95Ms: Double
        public let bruteForceP50Ms: Double
        public let recallAt10: Double           // vs exact brute force
        public let diskBytesAdded: Int64        // ann_* tables footprint
    }

    public let queryCount: Int
    public let insertCount: Int

    public init(queryCount: Int = 50, insertCount: Int = 100) {
        self.queryCount = queryCount
        self.insertCount = insertCount
    }

    /// Run the benchmark at each corpus size on a FRESH throwaway ledger.
    public func run(sizes: [Int], dimension: Int = 384, seed: UInt64 = 0xA11CE) async throws -> [Metrics] {
        var out: [Metrics] = []
        for size in sizes {
            out.append(try await runOne(size: size, dimension: dimension, seed: seed))
        }
        return out
    }

    private func runOne(size: Int, dimension: Int, seed: UInt64) async throws -> Metrics {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("annbench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("bench.sqlite"))
        try await SchemaMigrations.migrate(db)
        try await db.exec("PRAGMA foreign_keys = ON;")

        let model = "bench.v1"
        let clusterCount = max(8, size / 200)
        // Representative embedding geometry: an L2-NORMALIZED unit vector per
        // point (like real BGE output), deterministic per-index i, drawn from a
        // well-separated planted-cluster center plus tight per-vector noise.
        // Deliberately NO unbounded index-proportional axis — an earlier
        // `v[0] = i·0.01` term reached 5000 at 500k, ~50× every other dim, and
        // under int8 quantization collapsed all other dimensions to 0–2, making
        // recall@10 a quantization-noise tie that worsened purely with corpus
        // size (a benchmark artifact, not an index defect). The unit-test corpus
        // — no dominant axis — already measures ≥0.95 recall through this index.
        //
        // Cluster centers are independent random directions (seeded by c), so
        // every cluster is genuinely distinct (no modular-pattern collapse) and
        // the true top-K neighbours of a point are its cluster-mates — a
        // localizable neighborhood IVF can recover, the way real embeddings do.
        func randomUnit(seededBy s: UInt64, count: Int) -> [Float] {
            var r = XorShift64Star(state: s | 1)
            func g() -> Float { Float(Double(r.next() % 2_000_000) / 1_000_000.0 - 1.0) }  // [-1,1)
            var v = (0..<count).map { _ in g() }
            var norm: Float = 0
            for x in v { norm += x * x }
            norm = norm.squareRoot()
            if norm > 0 { for d in 0..<count { v[d] /= norm } }
            return v
        }
        let centers: [[Float]] = (0..<clusterCount).map {
            randomUnit(seededBy: seed &+ 0xC0FFEE &+ UInt64($0) &* 0x9E3779B97F4A7C15, count: dimension)
        }
        func vector(_ i: Int) -> [Float] {
            let c = i % clusterCount
            // Per-index deterministic RNG (odd, non-zero) so a query vector is a
            // genuine stored point across the seed/query passes.
            var r = XorShift64Star(state: (seed &+ UInt64(bitPattern: Int64(i)) &* 0x9E3779B97F4A7C15) | 1)
            func noise() -> Float { Float(Double(r.next() % 2_000_000) / 1_000_000.0 - 1.0) }  // [-1,1)
            let center = centers[c]
            var v = (0..<dimension).map { d in center[d] + noise() * 0.15 }   // tight cluster
            var norm: Float = 0
            for x in v { norm += x * x }
            norm = norm.squareRoot()
            if norm > 0 { for d in 0..<dimension { v[d] /= norm } }
            return v
        }

        // ── Seed the corpus as real ledger rows (batched) ───────────────────
        let fileID = UUID(), koID = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                          [.uuid(fileID), .text("file:///bench.txt"), .text("text")])
        try await db.exec("""
            INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
            VALUES (?,?,?,?,?,?);
            """, [.uuid(koID), .uuid(fileID), .text("txt"), .text("bench"), .real(1), .real(1)])
        var chunkIDs: [UUID] = []
        chunkIDs.reserveCapacity(size)
        var i = 0
        while i < size {
            let n = min(100, size - i)
            var chunkSQL: [String] = [], chunkBind: [SQLValue] = []
            var embSQL: [String] = [], embBind: [SQLValue] = []
            for j in 0..<n {
                let chunkID = UUID()
                chunkIDs.append(chunkID)
                chunkSQL.append("(?,?,?,?,?,?,?)")
                chunkBind.append(contentsOf: [.uuid(chunkID), .uuid(koID), .integer(Int64(i + j)),
                                              .text("c\(i + j)"), .integer(0), .integer(2), .real(1)])
                let (q, scale) = VectorQuantization.quantize(vector(i + j))
                embSQL.append("(?,?,?,?,?,?,?)")
                embBind.append(contentsOf: [.uuid(chunkID), .text(model), .text("1"),
                                            .integer(Int64(dimension)), .blob(q), .real(scale), .real(1)])
            }
            try await db.exec("INSERT INTO chunks (id, object_id, ordinal, text, char_start, char_end, created_at) VALUES \(chunkSQL.joined(separator: ","));", chunkBind)
            try await db.exec("INSERT INTO chunk_embeddings (chunk_id, model_id, model_version, dim, q, scale, created_at) VALUES \(embSQL.joined(separator: ","));", embBind)
            i += n
        }

        func dbBytes() async -> Int64 {
            let pages = (try? await db.query("PRAGMA page_count;", []))?.first?.int(0) ?? 0
            let pageSize = (try? await db.query("PRAGMA page_size;", []))?.first?.int(0) ?? 0
            return pages * pageSize
        }
        let bytesBefore = await dbBytes()

        // ── Build ───────────────────────────────────────────────────────────
        let repo = ANNIndexRepository(database: db)
        let index = IVFDiskVectorIndex(repository: repo, modelID: model, dimension: dimension)
        let buildStart = Date()
        try await index.rebuild(seed: seed)
        let buildSeconds = Date().timeIntervalSince(buildStart)
        let cellCount = (try? await repo.meta(for: model))?.cellCount ?? 0
        let bytesAfter = await dbBytes()

        // ── Brute-force baseline + recall reference (same kernel) ───────────
        func bruteTop(_ query: [Float], limit: Int) async throws -> [UUID] {
            let rows = try await db.query(
                "SELECT chunk_id, q, scale FROM chunk_embeddings WHERE model_id = ?;", [.text(model)])
            guard let prepared = VectorQuantization.prepareQuery(query) else { return [] }
            var scored: [(UUID, Double)] = []
            for row in rows {
                guard let id = row.uuid(0), let q = row.blob(1), let s = row.double(2),
                      let score = VectorQuantization.cosineScore(query: prepared, candidate: q, scale: s) else { continue }
                scored.append((id, score))
            }
            return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
        }

        var queryLatencies: [Double] = []
        var bruteLatencies: [Double] = []
        var recallSum = 0.0
        let stride = max(1, size / queryCount)
        var queries = 0
        for qi in Swift.stride(from: 0, to: size, by: stride) {
            let query = vector(qi)
            let t0 = Date()
            let hits = try await index.nearest(embedding: query, limit: 10)
            queryLatencies.append(Date().timeIntervalSince(t0) * 1000)
            let t1 = Date()
            let expected = try await bruteTop(query, limit: 10)
            bruteLatencies.append(Date().timeIntervalSince(t1) * 1000)
            let got = Set(hits.map(\.chunkID))
            if !expected.isEmpty {
                recallSum += Double(got.intersection(Set(expected)).count) / Double(expected.count)
                queries += 1
            }
        }

        // ── Incremental insert p50 ──────────────────────────────────────────
        var insertLatencies: [Double] = []
        for k in 0..<insertCount {
            let chunkID = UUID()
            try await db.exec("INSERT INTO chunks (id, object_id, ordinal, text, char_start, char_end, created_at) VALUES (?,?,?,?,?,?,?);",
                              [.uuid(chunkID), .uuid(koID), .integer(Int64(size + k)), .text("x"), .integer(0), .integer(1), .real(1)])
            let (q, scale) = VectorQuantization.quantize(vector(size + k))
            let t0 = Date()
            _ = try await index.insert(chunkID: chunkID, q: q, scale: scale)
            insertLatencies.append(Date().timeIntervalSince(t0) * 1000)
        }

        func percentile(_ values: [Double], _ p: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            let idx = min(sorted.count - 1, Int(Double(sorted.count) * p))
            return sorted[idx]
        }

        return Metrics(
            size: size,
            cellCount: cellCount,
            buildSeconds: buildSeconds,
            insertP50Ms: percentile(insertLatencies, 0.5),
            queryP50Ms: percentile(queryLatencies, 0.5),
            queryP95Ms: percentile(queryLatencies, 0.95),
            bruteForceP50Ms: percentile(bruteLatencies, 0.5),
            recallAt10: queries == 0 ? 0 : recallSum / Double(queries),
            diskBytesAdded: bytesAfter - bytesBefore
        )
    }

    /// eval-report-style markdown table.
    public static func renderMarkdown(_ metrics: [Metrics]) -> String {
        var out = "# ANN benchmark (IVF disk index, deterministic synthetic corpus)\n\n"
        out += "| size | cells | build s | insert p50 ms | query p50 ms | query p95 ms | brute p50 ms | recall@10 | disk bytes |\n"
        out += "|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n"
        for m in metrics {
            out += String(format: "| %d | %d | %.2f | %.2f | %.2f | %.2f | %.2f | %.3f | %d |\n",
                          m.size, m.cellCount, m.buildSeconds, m.insertP50Ms,
                          m.queryP50Ms, m.queryP95Ms, m.bruteForceP50Ms, m.recallAt10, m.diskBytesAdded)
        }
        return out
    }
}
