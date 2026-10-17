//
//  IVFDiskVectorIndexTests.swift
//  KalsmritikoshTests
//
//  P9.3 step 4 — the disk-backed IVF index over the real v103 ledger tables.
//  Proves: build + probe recall parity vs the exact brute-force scan,
//  self-query always #1, incremental insert (immediately retrievable, no
//  rebuild), removal + cascade parity, the model-identity guard (dimension
//  mismatch no-ops; two models coexist without cross-talk), crash-recovery
//  reopen ('building' marker → not ready → rebuild completes), and the
//  reconcile pass that closes the build-vs-concurrent-insert race.
//  Deterministic synthetic vectors only.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("P9.3 — IVF disk vector index", .serialized)
struct IVFDiskVectorIndexTests {

    private let model = "bge-small.v1"
    private let dim = 32
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Rig {
        let db: Database
        let repo: ANNIndexRepository
        let index: IVFDiskVectorIndex
    }

    private func rig(dimension: Int = 32) async throws -> Rig {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let repo = ANNIndexRepository(database: db)
        return Rig(db: db, repo: repo,
                   index: IVFDiskVectorIndex(repository: repo, modelID: model, dimension: dimension))
    }

    /// Deterministic planted-cluster corpus (same generator family as the
    /// k-means tests): `clusters` centers, tight noise.
    private func corpus(count: Int, clusters: Int, seed: UInt64) -> [[Float]] {
        var rng = XorShift64Star(state: seed)
        func unit() -> Float { Float(Double(rng.next() % 1_000_000) / 1_000_000.0) - 0.5 }
        let centers: [[Float]] = (0..<clusters).map { c in
            (0..<dim).map { d in Float((c * 5 + d * 3) % 11) * 8.0 + 1.0 }
        }
        return (0..<count).map { i in
            let c = i % clusters
            return (0..<dim).map { d in centers[c][d] + unit() }
        }
    }

    /// Store one embedding as a REAL ledger row (file → KO → chunk →
    /// chunk_embeddings) so every FK holds. Returns the chunk id.
    @discardableResult
    private func storeEmbedding(_ r: Rig, _ vector: [Float], model: String? = nil) async throws -> UUID {
        let fileID = UUID(), koID = UUID(), chunkID = UUID()
        try await r.db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                            [.uuid(fileID), .text("file:///\(fileID).txt"), .text("text")])
        try await r.db.exec("""
            INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
            VALUES (?,?,?,?,?,?);
            """, [.uuid(koID), .uuid(fileID), .text("txt"), .text("body"), .real(1), .real(1)])
        try await r.db.exec("""
            INSERT INTO chunks (id, object_id, ordinal, text, char_start, char_end, created_at)
            VALUES (?,?,?,?,?,?,?);
            """, [.uuid(chunkID), .uuid(koID), .integer(0), .text("body"), .integer(0), .integer(4), .real(1)])
        let (q, scale) = VectorQuantization.quantize(vector)
        try await r.db.exec("""
            INSERT INTO chunk_embeddings (chunk_id, model_id, model_version, dim, q, scale, created_at)
            VALUES (?,?,?,?,?,?,?);
            """, [.uuid(chunkID), .text(model ?? self.model), .text("test"),
                  .integer(Int64(vector.count)), .blob(q), .real(scale), .real(1)])
        return chunkID
    }

    /// Exact brute-force top-K over the stored embeddings via the SAME kernel.
    private func bruteForceTop(_ r: Rig, query: [Float], limit: Int) async throws -> [UUID] {
        let rows = try await r.db.query(
            "SELECT chunk_id, q, scale FROM chunk_embeddings WHERE model_id = ?;", [.text(model)])
        guard let prepared = VectorQuantization.prepareQuery(query) else { return [] }
        var scored: [(UUID, Double)] = []
        for row in rows {
            guard let id = row.uuid(0), let q = row.blob(1), let scale = row.double(2),
                  let s = VectorQuantization.cosineScore(query: prepared, candidate: q, scale: scale) else { continue }
            scored.append((id, s))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    // MARK: - Build + probe

    @Test("Build + probe: recall@10 vs brute force ≥ 0.95, and a stored vector is its own #1 hit")
    func buildAndProbeRecall() async throws {
        let r = try await rig()
        let vectors = corpus(count: 400, clusters: 16, seed: 21)
        var ids: [UUID] = []
        for v in vectors { ids.append(try await storeEmbedding(r, v)) }

        try await r.index.rebuild(seed: 7, now: t0)
        #expect(await r.index.isReady())
        #expect(await r.index.size() == 400)

        var recallSum = 0.0
        var queries = 0
        for qi in stride(from: 0, to: 400, by: 20) {
            let query = vectors[qi]
            let expected = Set(try await bruteForceTop(r, query: query, limit: 10))
            let got = try await r.index.nearest(embedding: query, limit: 10)
            let gotIDs = Set(got.map(\.chunkID))
            recallSum += Double(expected.intersection(gotIDs).count) / Double(expected.count)
            queries += 1
            // Self-hit invariant: the stored vector itself is always #1.
            #expect(got.first?.chunkID == ids[qi], "query \(qi): self-hit missing from #1")
        }
        #expect(recallSum / Double(queries) >= 0.95,
                "IVF recall@10 \(recallSum / Double(queries)) below floor")
    }

    @Test("F11 — a tiny posting page bounds every fetch yet returns exactly the same neighbours")
    func pagedProbeBoundedAndIdentical() async throws {
        let r = try await rig()
        let vectors = corpus(count: 300, clusters: 4, seed: 33)   // few clusters → dense cells
        for v in vectors { try await storeEmbedding(r, v) }
        try await r.index.rebuild(seed: 7, now: t0)
        let paged = IVFDiskVectorIndex(repository: r.repo, modelID: model, dimension: dim, postingPageSize: 7)
        try await paged.rebuild(seed: 7, now: t0)   // warm its centroid cache over the same index
        for qi in stride(from: 0, to: 300, by: 37) {
            let a = try await r.index.nearest(embedding: vectors[qi], limit: 10)
            let b = try await paged.nearest(embedding: vectors[qi], limit: 10)
            #expect(a.map(\.chunkID) == b.map(\.chunkID), "query \(qi): paging changed the result")
        }
        // The repository page itself never exceeds its limit and walks a dense batch exactly once.
        let cells = Array(0..<IVFDiskVectorIndex.probeCellBatch)
        var cursor: (cell: Int, chunk: String)? = nil
        var seen = Set<UUID>(), pages = 0
        while true {
            let page = try await r.repo.postingsPage(inCells: cells, for: model, after: cursor, limit: 7)
            #expect(page.count <= 7)
            for p in page { #expect(seen.insert(p.chunkID).inserted, "a posting was returned twice") }
            pages += 1
            guard page.count == 7, let last = page.last else { break }
            cursor = (last.cellID, last.chunkID.uuidString)
        }
        #expect(seen.count == (try await r.repo.postings(inCells: cells, for: model)).count)
        #expect(pages > 1)
    }

    @Test("PERF-3: scan-budget probe bounds rows, and the cell ceiling scales sanely with K")
    func scanBudgetAndCeiling() async throws {
        // Candidate pool: a floor of 4000 rows, growing with the result count.
        #expect(IVFDiskVectorIndex.candidatePool(forLimit: 10) == 4_000)     // floor dominates
        #expect(IVFDiskVectorIndex.candidatePool(forLimit: 100) == 10_000)   // 100·100 > floor
        // Ceiling on cells ever considered: ≈ K/6, floored at 128, clamped to K.
        #expect(IVFDiskVectorIndex.maxNProbe(forCellCount: 16) == 16)        // clamped to K
        #expect(IVFDiskVectorIndex.maxNProbe(forCellCount: 179) == 128)      // 179/6≈29 → floor 128
        let k = IVFDiskVectorIndex.cellCount(forVectorCount: 500_000)
        #expect(k >= 2_800)
        #expect(IVFDiskVectorIndex.maxNProbe(forCellCount: k) >= 400)        // ~2828/6 ≈ 471
        #expect(IVFDiskVectorIndex.maxNProbe(forCellCount: k) <= k)
        #expect(IVFDiskVectorIndex.maxNProbe(forCellCount: 0) == 0)          // empty index
    }

    @Test("Incremental insert is immediately retrievable with no rebuild; posting count reconciles")
    func incrementalInsert() async throws {
        let r = try await rig()
        for v in corpus(count: 200, clusters: 8, seed: 33) { try await storeEmbedding(r, v) }
        try await r.index.rebuild(seed: 5, now: t0)

        // A distinctive new vector far from the planted grid.
        let novel: [Float] = (0..<dim).map { d in Float(d % 2 == 0 ? 90 : -90) }
        let novelID = try await storeEmbedding(r, novel)
        let (q, scale) = VectorQuantization.quantize(novel)
        #expect(try await r.index.insert(chunkID: novelID, q: q, scale: scale, now: t0))

        #expect(await r.index.size() == 201)
        let got = try await r.index.nearest(embedding: novel, limit: 3)
        #expect(got.first?.chunkID == novelID)
    }

    @Test("Removal makes a chunk unreturnable; raw chunk deletion cascades to the same result")
    func removalAndCascade() async throws {
        let r = try await rig()
        let vectors = corpus(count: 100, clusters: 4, seed: 44)
        var ids: [UUID] = []
        for v in vectors { ids.append(try await storeEmbedding(r, v)) }
        try await r.index.rebuild(seed: 9, now: t0)

        try await r.index.remove(chunkID: ids[0])
        #expect(await r.index.size() == 99)
        let got = try await r.index.nearest(embedding: vectors[0], limit: 5)
        #expect(!got.map(\.chunkID).contains(ids[0]))

        try await r.db.exec("DELETE FROM chunks WHERE id = ?;", [.uuid(ids[1])])
        #expect(await r.index.size() == 98)
    }

    @Test("Model-identity guard: a wrong-dimension insert no-ops; two models coexist without cross-talk")
    func modelIdentityGuard() async throws {
        let r = try await rig()
        for v in corpus(count: 100, clusters: 4, seed: 55) { try await storeEmbedding(r, v) }
        try await r.index.rebuild(seed: 11, now: t0)

        // Wrong dimension → refused, nothing written.
        let sizeBefore = await r.index.size()
        let inserted = try await r.index.insert(chunkID: UUID(), q: Data(repeating: 1, count: 8), scale: 0.1, now: t0)
        #expect(!inserted)
        #expect(await r.index.size() == sizeBefore)

        // A second model's embedding for a NEW chunk never appears in this
        // model's probes (postings are model-scoped by key).
        let foreignVec: [Float] = (0..<dim).map { _ in 42 }
        let foreignChunk = try await storeEmbedding(r, foreignVec, model: "apple.nl.v1")
        let got = try await r.index.nearest(embedding: foreignVec, limit: 10)
        #expect(!got.map(\.chunkID).contains(foreignChunk))
    }

    @Test("Crash recovery: a 'building' marker reports not-ready after reload; a rebuild completes to ready")
    func crashRecoveryReopen() async throws {
        let r = try await rig()
        for v in corpus(count: 120, clusters: 4, seed: 66) { try await storeEmbedding(r, v) }
        try await r.index.rebuild(seed: 13, now: t0)
        #expect(await r.index.load())

        // Simulate a crash mid-build: durable marker says building.
        try await r.repo.setState(.building, for: model, at: t0)
        let fresh = IVFDiskVectorIndex(repository: r.repo, modelID: model, dimension: dim)
        #expect(!(await fresh.load()), "a 'building' crash marker must not report ready")
        #expect(try await fresh.nearest(embedding: corpus(count: 1, clusters: 1, seed: 1)[0], limit: 5).isEmpty)

        // The background rebuild completes and the index serves again.
        try await fresh.rebuild(seed: 13, now: t0)
        #expect(await fresh.isReady())
        #expect(await fresh.size() == 120)
    }

    @Test("Reconcile closes the build-vs-concurrent-insert race: embeddings without postings get indexed")
    func reconcileClosesRace() async throws {
        let r = try await rig()
        let vectors = corpus(count: 150, clusters: 8, seed: 77)
        for v in vectors { try await storeEmbedding(r, v) }
        try await r.index.rebuild(seed: 17, now: t0)

        // A vector stored AFTER the populate pass (simulating the race) —
        // present in chunk_embeddings, absent from postings.
        let late: [Float] = (0..<dim).map { d in Float(d) * 3.3 + 200 }
        let lateID = try await storeEmbedding(r, late)
        #expect(await r.index.size() == 150)

        let added = try await r.index.reconcile(now: t0)
        #expect(added == 1)
        #expect(await r.index.size() == 151)
        let got = try await r.index.nearest(embedding: late, limit: 3)
        #expect(got.first?.chunkID == lateID)
        // Idempotent.
        #expect(try await r.index.reconcile(now: t0) == 0)
    }

    // MARK: - F11 generation switch

    private actor Flag { var done = false; func set() { done = true }; func isSet() -> Bool { done } }

    @Test("F11 — the live generation keeps serving while a rebuild runs; the new one replaces it atomically")
    func servesDuringRebuild() async throws {
        let r = try await rig()
        let vectors = corpus(count: 600, clusters: 12, seed: 91)
        var ids: [UUID] = []
        for v in vectors { ids.append(try await storeEmbedding(r, v)) }
        try await r.index.rebuild(seed: 7, now: t0)
        #expect(await r.index.isReady())

        let finished = Flag()
        let index = r.index, t0 = self.t0
        let rebuild = Task { try await index.rebuild(seed: 99, now: t0); await finished.set() }
        var probes = 0, misses = 0, notReady = 0
        var i = 0
        while !(await finished.isSet()) {
            if !(await r.index.isReady()) { notReady += 1 }
            let got = try await r.index.nearest(embedding: vectors[i % vectors.count], limit: 5)
            probes += 1
            if got.first?.chunkID != ids[i % ids.count] { misses += 1 }
            i += 1
            await Task.yield()
        }
        try await rebuild.value
        #expect(probes > 0, "no probe interleaved with the rebuild — the test proved nothing")
        #expect(notReady == 0, "the index must stay ready while its next generation is built")
        #expect(misses == 0, "every probe during the rebuild found its own vector first")

        // The new generation is live, complete, and the staging namespace is gone.
        #expect(await r.index.size() == 600)
        #expect(try await r.repo.meta(for: model)?.trainSeed == 99)
        #expect(try await r.repo.meta(for: "\(model)@next") == nil)
        #expect(try await r.repo.postingCount(for: "\(model)@next") == 0)
        #expect(try await r.index.nearest(embedding: vectors[3], limit: 5).first?.chunkID == ids[3])
    }

    @Test("F11 — a staged generation left by a crash is discarded; the live one was never touched")
    func staleStagingDiscarded() async throws {
        let r = try await rig()
        let vectors = corpus(count: 160, clusters: 4, seed: 55)
        var ids: [UUID] = []
        for v in vectors { ids.append(try await storeEmbedding(r, v)) }
        try await r.index.rebuild(seed: 3, now: t0)
        // A crash mid-rebuild leaves a half-filled staging namespace behind.
        let staging = "\(model)@next"
        try await r.repo.ensureMeta(modelID: staging, dimension: dim, at: t0)
        try await r.repo.replaceCells([ANNCell(cellID: 0, centroid: Data(count: dim * 4), vectorCount: 0)], for: staging, at: t0)
        try await r.repo.insertPostings([ANNPosting(cellID: 0, chunkID: ids[0], q: Data(count: dim), scale: 1)], for: staging)
        // The live index still serves on a fresh load.
        let reopened = IVFDiskVectorIndex(repository: r.repo, modelID: model, dimension: dim)
        #expect(await reopened.load())
        #expect(try await reopened.nearest(embedding: vectors[9], limit: 3).first?.chunkID == ids[9])
        // The next rebuild starts the staging over and promotes cleanly.
        try await reopened.rebuild(seed: 4, now: t0)
        #expect(await reopened.size() == 160)
        #expect(try await r.repo.meta(for: staging) == nil)
        #expect(try await r.repo.cells(for: staging).isEmpty)
    }
}
