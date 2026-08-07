//
//  IndexStrategySelectorTests.swift
//  KalsmritikoshTests
//
//  P9.3 steps 5–6 — the pure strategy decision (threshold + hysteresis
//  around the REAL RAM cap) and the ANNIndexCoordinator behaviours behind
//  the unchanged VectorStore surface: persisted-strategy serving, honest nil
//  (brute-force fallback) when nothing can serve, crash-marker resume via
//  maintain(), the 2× retrain trigger, same-call-chain freshness through
//  SQLiteVectorStore.upsert, and end-to-end store queries served by the
//  disk index. Synthetic only.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("P9.3 — strategy selector (pure decision)")
struct IndexStrategySelectorTests {

    private let ram: UInt64 = 16 * 1024 * 1024 * 1024

    @Test("Thresholds + 20% hysteresis around the real RAM cap")
    func decisionTable() {
        let cap = HNSWVectorIndex.maxInMemoryVectors(physicalMemoryBytes: ram)
        let low = Int(IndexStrategySelector.hysteresisFactor * Double(cap))

        // In-memory holds up to the cap; crossing it flips to disk.
        #expect(IndexStrategySelector.decide(current: .inMemoryHNSW, vectorCount: cap, physicalMemoryBytes: ram) == .inMemoryHNSW)
        #expect(IndexStrategySelector.decide(current: .inMemoryHNSW, vectorCount: cap + 1, physicalMemoryBytes: ram) == .diskIVF)

        // Disk holds INSIDE the hysteresis band (no flapping)…
        #expect(IndexStrategySelector.decide(current: .diskIVF, vectorCount: cap, physicalMemoryBytes: ram) == .diskIVF)
        #expect(IndexStrategySelector.decide(current: .diskIVF, vectorCount: low, physicalMemoryBytes: ram) == .diskIVF)
        // …and only returns to memory clearly below it.
        #expect(IndexStrategySelector.decide(current: .diskIVF, vectorCount: low - 1, physicalMemoryBytes: ram) == .inMemoryHNSW)

        // A bigger machine raises the cap monotonically.
        let bigCap = HNSWVectorIndex.maxInMemoryVectors(physicalMemoryBytes: ram * 4)
        #expect(bigCap >= cap)
    }
}

@Suite("P9.3 — ANN coordinator + store integration", .serialized)
struct ANNCoordinatorIntegrationTests {

    private let model = "bge-small.v1"
    private let dim = 32
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Rig {
        let db: Database
        let repo: ANNIndexRepository
        let ivf: IVFDiskVectorIndex
        let coordinator: ANNIndexCoordinator
        let store: SQLiteVectorStore
    }

    private func rig(capOverride: Int = 10) async throws -> Rig {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let repo = ANNIndexRepository(database: db)
        let ivf = IVFDiskVectorIndex(repository: repo, modelID: model, dimension: dim)
        // hnsw: nil — these tests exercise the disk strategy + fallback paths.
        // The tiny injected cap lets real strategy decisions fire on a
        // test-size corpus (the RAM-derived cap floors at 250k vectors).
        let coordinator = ANNIndexCoordinator(hnsw: nil, ivf: ivf, repository: repo,
                                              modelID: model, dimension: dim,
                                              inMemoryCapOverride: capOverride)
        let store = SQLiteVectorStore(database: db, ann: coordinator, modelID: model)
        return Rig(db: db, repo: repo, ivf: ivf, coordinator: coordinator, store: store)
    }

    /// Collision-free: the first component encodes the seed directly, so
    /// every vector is unique and self-hit assertions are unambiguous.
    private func vector(_ seed: Int) -> [Float] {
        var v = (0..<dim).map { d in Float((seed * 37 + d * 7) % 19) - 9 }
        v[0] = Float(seed) * 5
        return v
    }

    /// Real chunk row so the embedding + posting FKs hold.
    @discardableResult
    private func seedChunk(_ r: Rig) async throws -> UUID {
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
        return chunkID
    }

    @Test("Nothing can serve → coordinator answers nil and the store's brute force still answers correctly")
    func honestFallback() async throws {
        let r = try await rig()
        let id = try await seedChunk(r)
        try await r.store.upsert(chunkID: id, embedding: vector(1))

        // No strategy built: coordinator nil → store must brute-force.
        #expect(await r.coordinator.nearest(to: vector(1), limit: 5, storedCount: 1) == nil)
        let hits = try await r.store.nearest(to: vector(1), limit: 5, candidateChunkIDs: nil)
        #expect(hits.first?.chunkID == id, "brute-force fallback failed")
    }

    @Test("With the persisted strategy = diskIVF, store queries are served by the disk index end-to-end")
    func diskStrategyServes() async throws {
        let r = try await rig()
        var ids: [UUID] = []
        for i in 0..<60 {
            let id = try await seedChunk(r)
            try await r.store.upsert(chunkID: id, embedding: vector(i))
            ids.append(id)
        }
        try await r.ivf.rebuild(seed: 7, now: t0)
        try await r.repo.setStrategy(.diskIVF, for: model, at: t0)

        let hits = await r.coordinator.nearest(to: vector(10), limit: 5, storedCount: 60)
        #expect(hits != nil, "ready disk index must serve")
        #expect(hits?.first?.chunkID == ids[10])
        // And through the full store path:
        let storeHits = try await r.store.nearest(to: vector(10), limit: 5, candidateChunkIDs: nil)
        #expect(storeHits.first?.chunkID == ids[10])
    }

    @Test("maintain() flips inMemoryHNSW → diskIVF past the cap, builds first, and the store keeps answering throughout")
    func strategyFlipToDisk() async throws {
        let r = try await rig(capOverride: 10)
        var ids: [UUID] = []
        for i in 0..<50 {
            let id = try await seedChunk(r)
            try await r.store.upsert(chunkID: id, embedding: vector(i))
            ids.append(id)
        }
        // Before maintain: persisted default is inMemoryHNSW; nothing built →
        // brute force serves (never empty, never throws).
        #expect(await r.coordinator.currentStrategy() == .inMemoryHNSW)
        #expect(try await r.store.nearest(to: vector(3), limit: 3, candidateChunkIDs: nil).first?.chunkID == ids[3])

        // 50 vectors > cap 10 → maintain builds the disk index THEN flips.
        await r.coordinator.maintain(now: t0)
        #expect(await r.coordinator.currentStrategy() == .diskIVF)
        let meta = try #require(try await r.repo.meta(for: model))
        #expect(meta.state == .ready)
        #expect(try await r.store.nearest(to: vector(3), limit: 3, candidateChunkIDs: nil).first?.chunkID == ids[3])

        // Shrink far below the hysteresis band → maintain flips back.
        for id in ids.dropFirst(5) { try await r.store.remove(chunkID: id) }
        await r.coordinator.maintain(now: t0)
        #expect(await r.coordinator.currentStrategy() == .inMemoryHNSW)
        // No HNSW is built in this rig → honest brute-force fallback again.
        #expect(try await r.store.nearest(to: vector(3), limit: 3, candidateChunkIDs: nil).first?.chunkID == ids[3])
    }

    @Test("A store upsert keeps the ready disk index fresh in the same call chain")
    func upsertFreshness() async throws {
        let r = try await rig()
        for i in 0..<40 {
            let id = try await seedChunk(r)
            try await r.store.upsert(chunkID: id, embedding: vector(i))
        }
        try await r.ivf.rebuild(seed: 9, now: t0)
        try await r.repo.setStrategy(.diskIVF, for: model, at: t0)
        let before = await r.ivf.size()

        // A NEW chunk upserted through the STORE — no rebuild, no reconcile.
        let novel: [Float] = (0..<dim).map { d in Float(d % 2 == 0 ? 70 : -70) }
        let novelID = try await seedChunk(r)
        try await r.store.upsert(chunkID: novelID, embedding: novel)

        #expect(await r.ivf.size() == before + 1)
        let hits = try await r.store.nearest(to: novel, limit: 3, candidateChunkIDs: nil)
        #expect(hits.first?.chunkID == novelID)
    }

    @Test("maintain() resumes a crash-marked disk build and completes it to ready")
    func maintainResumesCrashMarker() async throws {
        let r = try await rig()
        for i in 0..<50 {
            let id = try await seedChunk(r)
            try await r.store.upsert(chunkID: id, embedding: vector(i))
        }
        try await r.ivf.rebuild(seed: 11, now: t0)
        try await r.repo.setStrategy(.diskIVF, for: model, at: t0)
        // Crash marker: the index must refuse to serve until maintain repairs it.
        try await r.repo.setState(.building, for: model, at: t0)
        let fresh = IVFDiskVectorIndex(repository: r.repo, modelID: model, dimension: dim)
        let freshCoordinator = ANNIndexCoordinator(hnsw: nil, ivf: fresh, repository: r.repo,
                                                   modelID: model, dimension: dim,
                                                   inMemoryCapOverride: 10)
        await freshCoordinator.warm()
        #expect(await freshCoordinator.nearest(to: vector(1), limit: 5, storedCount: 50) == nil)

        await freshCoordinator.maintain(now: t0)
        let meta = try #require(try await r.repo.meta(for: model))
        #expect(meta.state == .ready)
        #expect(await freshCoordinator.nearest(to: vector(1), limit: 5, storedCount: 50) != nil)
    }

    @Test("maintain() retrains when the corpus outgrows the trained geometry (2×)")
    func maintainRetrainsOnGrowth() async throws {
        let r = try await rig()
        for i in 0..<30 {
            let id = try await seedChunk(r)
            try await r.store.upsert(chunkID: id, embedding: vector(i))
        }
        try await r.ivf.rebuild(seed: 13, now: t0)
        try await r.repo.setStrategy(.diskIVF, for: model, at: t0)
        #expect(try #require(try await r.repo.meta(for: model)).trainedVectorCount == 30)

        // Triple the corpus (past the 2× trigger), then maintain.
        for i in 30..<95 {
            let id = try await seedChunk(r)
            try await r.store.upsert(chunkID: id, embedding: vector(i))
        }
        await r.coordinator.maintain(now: t0)
        let meta = try #require(try await r.repo.meta(for: model))
        #expect(meta.trainedVectorCount == 95, "retrain did not fire: trained=\(meta.trainedVectorCount)")
        #expect(meta.state == .ready)
        #expect(await r.ivf.size() == 95)
    }
}
