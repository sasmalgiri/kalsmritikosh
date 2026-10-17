//
//  ScopedRecallTests.swift
//  KalsmritikoshTests
//
//  F08 — a small case whose evidence sits behind higher-ranked chunks from OUTSIDE the case must
//  still be retrieved: the scope predicate goes inside the candidate query, before LIMIT.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("F08 — case evidence is not crowded out by the global corpus")
struct ScopedRecallTests {

    /// Stands in for the shared retriever: global keyword search truncated to its top 25 BEFORE any
    /// case filtering — exactly the ordering that starved small cases.
    private struct GlobalTopK: Retriever {
        let chunks: ChunksRepository
        func retrieve(for intent: UserIntent, layers: [RetrievalLayer]) async throws -> RetrievalResult {
            let hits = try await chunks.searchFTS(intent.rawQuestion, limit: 25)
            return RetrievalResult(chunks: hits.map { RetrievedChunk(chunk: $0, score: 1, viaLayer: .metadata) })
        }
        func retrieve(for intent: UserIntent, layers: [RetrievalLayer], access: SensitiveAccessContext) async throws -> AuthorizedRetrievalResult {
            AuthorizedRetrievalResult(result: try await retrieve(for: intent, layers: layers), accessContext: access)
        }
    }

    private func seed() async throws -> (Database, ChunksRepository, authorized: UUID, caseChunk: UUID) {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let repo = ChunksRepository(database: db)
        func object() async throws -> UUID {
            let file = UUID(), ko = UUID()
            try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                              [.uuid(file), .text("file://sr-\(file)"), .text("txt")])
            try await db.exec("""
            INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);
            """, [.uuid(ko), .uuid(file), .text("txt"), .text("c"), .real(0), .real(0)])
            return ko
        }
        // 30 outside chunks that mention the term MANY times (they outrank the case chunk).
        let outsideVersion = UUID(), outsideKO = try await object()
        try await repo.insertBatch((0..<30).map { i in
            Chunk(objectID: outsideKO, ordinal: i, text: "zanthorite zanthorite zanthorite ledger copy \(i)",
                  characterRange: 0..<40, sourceVersionID: outsideVersion)
        })
        // ONE case chunk that mentions it once.
        let caseVersion = UUID(), caseKO = try await object()
        let caseChunk = Chunk(objectID: caseKO, ordinal: 0, text: "The zanthorite invoice was signed by the vendor.",
                              characterRange: 0..<48, sourceVersionID: caseVersion)
        try await repo.insertBatch([caseChunk])
        return (db, repo, caseVersion, caseChunk.id)
    }

    @Test("Without scoped recall the case chunk is starved; with it, it is retrieved")
    func caseChunkRecovered() async throws {
        let (db, repo, authorized, caseChunk) = try await seed()
        let intent = UserIntent(kind: .factualLookup, scope: .global, rawQuestion: "zanthorite invoice")
        let access = SensitiveAccessContext.testUnrestricted()
        let evidence = EvidenceStore(database: db)

        let starved = SourceScopedRetriever(base: GlobalTopK(chunks: repo), evidence: evidence, scope: .authorizing([authorized]))
        let before = try await starved.retrieve(for: intent, layers: [.metadata], access: access)
        #expect(before.result.chunks.isEmpty, "precondition: the global top-25 held no case chunk")

        let recalled = SourceScopedRetriever(base: GlobalTopK(chunks: repo), evidence: evidence, scope: .authorizing([authorized]),
                                             scopedRecall: .init(chunks: repo, sensitivePolicy: nil))
        let after = try await recalled.retrieve(for: intent, layers: [.metadata], access: access)
        #expect(after.result.chunks.map(\.chunk.id) == [caseChunk])
        #expect(after.result.chunks.allSatisfy { $0.chunk.sourceVersionID == authorized })   // never widens the scope
    }

    @Test("An empty authorized set still yields nothing (recall never widens the boundary)")
    func emptyScopeStaysEmpty() async throws {
        let (db, repo, _, _) = try await seed()
        let intent = UserIntent(kind: .factualLookup, scope: .global, rawQuestion: "zanthorite")
        let d = SourceScopedRetriever(base: GlobalTopK(chunks: repo), evidence: EvidenceStore(database: db),
                                      scope: .authorizing([]), scopedRecall: .init(chunks: repo, sensitivePolicy: nil))
        #expect(try await d.retrieve(for: intent, layers: [.metadata], access: .testUnrestricted()).result.chunks.isEmpty)
    }

    // MARK: - F08b — vector / event / entity / graph lanes

    /// A base retriever that ranks every lane GLOBALLY and truncates each before case filtering.
    private struct GlobalLanes: Retriever {
        let events: EventsRepository, entities: EntitiesRepository, vectors: any VectorStore, embedder: any Embedder
        let chunks: ChunksRepository
        func retrieve(for intent: UserIntent, layers: [RetrievalLayer]) async throws -> RetrievalResult {
            let q = await embedder.embed(intent.rawQuestion)
            let hits = try await vectors.nearest(to: q, limit: 5, candidateChunkIDs: nil)
            let vchunks = try await chunks.findByIDs(hits.map(\.chunkID)).map { RetrievedChunk(chunk: $0, score: 1, viaLayer: .vector) }
            let ev = try await events.recent(limit: 20)
            let en = try await entities.find(byValue: intent.entityHints.first ?? "", limit: 10)
            return RetrievalResult(chunks: vchunks, events: ev, entities: en)
        }
        func retrieve(for intent: UserIntent, layers: [RetrievalLayer], access: SensitiveAccessContext) async throws -> AuthorizedRetrievalResult {
            AuthorizedRetrievalResult(result: try await retrieve(for: intent, layers: layers), accessContext: access)
        }
    }

    /// In-memory vector store honouring `candidateChunkIDs` exactly as the real stores do.
    @MainActor private final class MemoryVectors: VectorStore {
        var rows: [Chunk.ID: [Float]] = [:]
        func upsert(chunkID: Chunk.ID, embedding: [Float]) { rows[chunkID] = embedding }
        func remove(chunkID: Chunk.ID) { rows[chunkID] = nil }
        func nearest(to e: [Float], limit: Int, candidateChunkIDs: [Chunk.ID]?) -> [VectorHit] {
            let pool = candidateChunkIDs.map { Set($0) }
            return rows.filter { pool?.contains($0.key) ?? true }
                .map { VectorHit(chunkID: $0.key, score: Double(zip($0.value, e).map { $0 * $1 }.reduce(0, +))) }
                .sorted { $0.score > $1.score }.prefix(limit).map { $0 }
        }
    }
    private struct AxisEmbedder: Embedder {
        var dimension: Int { 2 }
        func embed(_ text: String) async -> [Float] { [1, 0] }
        func embedBatch(_ texts: [String]) async -> [[Float]] { texts.map { _ in [1, 0] } }
    }

    private struct LaneRig {
        let db: Database; let chunks: ChunksRepository; let events: EventsRepository
        let entities: EntitiesRepository; let relationships: RelationshipsRepository; let vectors: MemoryVectors
        let caseVersion: UUID; let caseKO: UUID; let outsideKO: UUID
    }

    /// A case version and an outside version, each a real current source_versions row for its file.
    @MainActor private func laneRig() async throws -> LaneRig {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        func source() async throws -> (version: UUID, ko: UUID) {
            let file = UUID(), ko = UUID(), version = UUID()
            try await db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                              [.uuid(file), .text("file://lane-\(file)"), .text("txt"), .text("available")])
            try await db.exec("""
                INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                    filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(version), .uuid(file), .text(String(repeating: "b", count: 64)), .real(1), .integer(1), .real(1),
                      .text("f.txt"), .text("txt"), .text("magicBytes"), .integer(1), .text("referenced"),
                      .text("referenceRecorded"), .real(1)])
            try await db.exec("""
                INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);
                """, [.uuid(ko), .uuid(file), .text("txt"), .text("c"), .real(0), .real(0)])
            return (version, ko)
        }
        let outside = try await source(), inCase = try await source()
        return LaneRig(db: db, chunks: ChunksRepository(database: db), events: EventsRepository(database: db),
                       entities: EntitiesRepository(database: db), relationships: RelationshipsRepository(database: db),
                       vectors: MemoryVectors(), caseVersion: inCase.version, caseKO: inCase.ko, outsideKO: outside.ko)
    }

    @MainActor private func retrievers(_ r: LaneRig) -> (starved: SourceScopedRetriever, recalled: SourceScopedRetriever) {
        let base = GlobalLanes(events: r.events, entities: r.entities, vectors: r.vectors, embedder: AxisEmbedder(), chunks: r.chunks)
        let evidence = EvidenceStore(database: r.db)
        return (SourceScopedRetriever(base: base, evidence: evidence, scope: .authorizing([r.caseVersion])),
                SourceScopedRetriever(base: base, evidence: evidence, scope: .authorizing([r.caseVersion]),
                    scopedRecall: .init(chunks: r.chunks, sensitivePolicy: nil, vectors: r.vectors, embedder: AxisEmbedder(),
                                        events: r.events, entities: r.entities, relationships: r.relationships)))
    }

    @Test("Vector lane: a case chunk behind closer outside neighbours is recovered by a case-restricted scan")
    @MainActor func vectorLaneRecovered() async throws {
        let r = try await laneRig()
        let outside = (0..<30).map { i in Chunk(objectID: r.outsideKO, ordinal: i, text: "outside \(i)", characterRange: 0..<9) }
        let caseChunk = Chunk(objectID: r.caseKO, ordinal: 0, text: "case passage", characterRange: 0..<12, sourceVersionID: r.caseVersion)
        try await r.chunks.insertBatch(outside + [caseChunk])
        for c in outside { await r.vectors.upsert(chunkID: c.id, embedding: [1, 0]) }        // exact match
        await r.vectors.upsert(chunkID: caseChunk.id, embedding: [0.6, 0.8])                   // weaker
        // No keyword overlap: only the vector lane can find the case chunk.
        let intent = UserIntent(kind: .factualLookup, scope: .global, rawQuestion: "semantically related wording")
        let (starved, recalled) = retrievers(r)
        #expect(try await starved.retrieve(for: intent, layers: [.vector], access: .testUnrestricted()).result.chunks.isEmpty)
        let got = try await recalled.retrieve(for: intent, layers: [.vector], access: .testUnrestricted()).result.chunks
        #expect(got.map(\.chunk.id) == [caseChunk.id])
        #expect(got.first?.viaLayer == .vector)
    }

    @Test("Event lane: the case's event behind 60 newer outside events is recovered, timeframe honoured")
    @MainActor func eventLaneRecovered() async throws {
        let r = try await laneRig()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try await r.events.insertBatch((0..<60).map { i in
            Event(kind: .other, date: base.addingTimeInterval(Double(i) * 86_400), title: "outside \(i)", entityIDs: [],
                  sourceObjectID: r.outsideKO, datePrecision: .day)
        })
        let caseEvent = Event(kind: .contractSigned, date: base.addingTimeInterval(-86_400 * 30), title: "Case contract signed",
                              entityIDs: [], sourceObjectID: r.caseKO, datePrecision: .day)
        let outOfWindow = Event(kind: .other, date: base.addingTimeInterval(-86_400 * 400), title: "Case old note",
                                entityIDs: [], sourceObjectID: r.caseKO, datePrecision: .day)
        try await r.events.insertBatch([caseEvent, outOfWindow])
        let intent = UserIntent(kind: .factualLookup, scope: .global,
                                timeframe: .init(start: base.addingTimeInterval(-86_400 * 60), end: base),
                                rawQuestion: "when was it signed")
        let (starved, recalled) = retrievers(r)
        #expect(try await starved.retrieve(for: intent, layers: [.timeline], access: .testUnrestricted()).result.events.isEmpty)
        let got = try await recalled.retrieve(for: intent, layers: [.timeline], access: .testUnrestricted()).result.events
        #expect(got.map(\.id) == [caseEvent.id], "only the case event inside the question's timeframe")
    }

    @Test("Entity + graph lanes: a case entity behind many same-name outside entities, and its case relationship")
    @MainActor func entityAndGraphLanesRecovered() async throws {
        let r = try await laneRig()
        _ = try await r.entities.insertBatch((0..<40).map {
            Entity(kind: .organization, value: "Zanthor Trading \($0)", sourceObjectID: r.outsideKO, confidence: .high)
        })
        let map = try await r.entities.insertBatch([
            Entity(kind: .organization, value: "Zanthor Case Holdings", sourceObjectID: r.caseKO, confidence: .low),
            Entity(kind: .person, value: "Mira Castellan", sourceObjectID: r.caseKO, confidence: .low)])
        let ids = try await r.db.query("SELECT id, value FROM entities WHERE source_object_id = ?;", [.uuid(r.caseKO)])
        let holdings = try #require(ids.first { $0.string(1) == "Zanthor Case Holdings" }?.uuid(0))
        let person = try #require(ids.first { $0.string(1) == "Mira Castellan" }?.uuid(0))
        _ = map
        let rel = Relationship(kind: .worksWith, fromEntityID: person, toEntityID: holdings, sourceObjectID: r.caseKO)
        try await r.relationships.insertBatch([rel])
        let intent = UserIntent(kind: .factualLookup, scope: .global, entityHints: ["Zanthor"],
                                rawQuestion: "who works with Zanthor")
        let (starved, recalled) = retrievers(r)
        let before = try await starved.retrieve(for: intent, layers: [.entity], access: .testUnrestricted()).result
        #expect(before.entities.isEmpty, "precondition: the global top-10 held only outside entities")
        let got = try await recalled.retrieve(for: intent, layers: [.entity], access: .testUnrestricted()).result
        #expect(got.entities.map(\.id) == [holdings])
        #expect(got.relationships.map(\.id) == [rel.id], "the case relationship touching the recovered entity")
    }
}
