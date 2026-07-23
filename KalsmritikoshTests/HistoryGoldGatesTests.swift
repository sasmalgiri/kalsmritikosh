//
//  HistoryGoldGatesTests.swift
//  Kalsmritikosh Tests
//
//  Universal History program, Phase 11 (TEST-301/302/304/305). Deterministic gold
//  GATES exercised through the full engine over a realistic ledger state:
//    • subject scope leakage = 0 (TEST-301)
//    • every material item carries evidence (TEST-302, citation-backed)
//    • deterministic outline stability (TEST-304) — same ledger → same outline
//    • no-model history (TEST-305) — a useful outline is produced with NO LLM
//  (The literal file→ingest→history E2E remains an owner/app-run test.)
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("HIST Phase 11 — gold gates (engine, deterministic)")
struct HistoryGoldGatesTests {

    private let clock = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeDB() async throws -> Database {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gold-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("t.sqlite"))
        try await SchemaMigrations.migrate(db)
        try await db.exec("PRAGMA foreign_keys=OFF;", [])
        return db
    }
    private func entity(_ db: Database, _ id: UUID, _ v: String) async throws {
        try await db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence, attributes_json, quality_tier) VALUES (?, 'person', ?, ?, ?, 0.9, '{}', 'T2');",
                          [.uuid(id), .text(v), .text(v.lowercased()), .uuid(UUID())])
    }
    private func event(_ db: Database, title: String, participant: UUID, source: UUID, kind: String = "contractSigned", date: Double = 1_072_915_200) async throws {
        let ev = UUID()
        try await db.exec("INSERT INTO events (id, kind, date, title, source_object_id) VALUES (?, ?, ?, ?, ?);",
                          [.uuid(ev), .text(kind), .real(date), .text(title), .uuid(source)])
        try await db.exec("INSERT INTO event_entities (event_id, entity_id) VALUES (?, ?);", [.uuid(ev), .uuid(participant)])
    }
    private func assertion(_ db: Database, subject: UUID, predicate: String, evidence: UUID) async throws {
        try await db.exec("INSERT INTO assertions (id, subject_kind, subject_id, predicate, object_kind, object_value, recorded_at, evidence_object_ids_json) VALUES (?, 'entity', ?, ?, 'literal', 'v', 1, ?);",
                          [.uuid(UUID()), .uuid(subject), .text(predicate), .text("[\"\(evidence.uuidString)\"]")])
    }

    private func engine(_ db: Database) -> HistoryReconstructionEngine {
        HistoryReconstructionEngine(
            entities: EntitiesRepository(database: db), events: EventsRepository(database: db),
            assertions: AssertionsRepository(database: db), genericFacts: GenericFactRepository(database: db),
            relationships: RelationshipsRepository(database: db), clock: { self.clock })
    }
    private func verified(_ updates: [HistoryUpdate]) -> HistoryReconstructionResult? {
        for u in updates.reversed() { if case .verified(let r) = u { return r } }
        return nil
    }
    private func run(_ e: HistoryReconstructionEngine, _ s: UUID) async -> [HistoryUpdate] {
        var out: [HistoryUpdate] = []
        for await u in e.reconstruct(subject: .person(s), request: HistoryRequest()) { out.append(u) }
        return out
    }

    @Test("Gates: no leakage, every item cited, no-model useful output")
    func coreGates() async throws {
        let db = try await makeDB()
        let s = UUID(), other = UUID(), evEvidence = UUID(), assertEvidence = UUID()
        try await entity(db, s, "Subject A")
        try await entity(db, other, "Subject B")
        try await event(db, title: "MSA signed", participant: s, source: evEvidence)
        try await event(db, title: "Unrelated deal", participant: other, source: UUID())
        try await assertion(db, subject: s, predicate: "worked_for", evidence: assertEvidence)

        let result = try #require(verified(await run(engine(db), s)))
        let items = result.outline.items

        // TEST-305 no-model: a useful outline exists with zero LLM involvement.
        #expect(!items.isEmpty)
        // TEST-301 subject leakage = 0.
        #expect(items.contains { $0.title == "MSA signed" })
        #expect(!items.contains { $0.title == "Unrelated deal" })
        // TEST-302 every material item is evidence-backed.
        #expect(items.allSatisfy { !$0.evidence.isEmpty })
    }

    @Test("TEST-304: deterministic outline stability — same ledger → same outline")
    func deterministicStability() async throws {
        let db = try await makeDB()
        let s = UUID(), ev = UUID(), asrt = UUID()
        try await entity(db, s, "Subject A")
        try await event(db, title: "MSA signed", participant: s, source: ev)
        try await event(db, title: "Invoice paid", participant: s, source: UUID(), kind: "invoicePaid", date: 1_136_073_600)
        try await assertion(db, subject: s, predicate: "held_role", evidence: asrt)

        let r1 = try #require(verified(await run(engine(db), s)))
        let r2 = try #require(verified(await run(engine(db), s)))
        #expect(r1.outline.items.map(\.id) == r2.outline.items.map(\.id))
        #expect(r1.outline.chapters.map(\.title) == r2.outline.chapters.map(\.title))
        #expect(r1.outline.gaps.map(\.kind) == r2.outline.gaps.map(\.kind))
    }
}
