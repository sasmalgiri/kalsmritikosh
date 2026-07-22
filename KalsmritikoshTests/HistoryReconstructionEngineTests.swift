//
//  HistoryReconstructionEngineTests.swift
//  Kalsmritikosh Tests
//
//  Universal History program, Phase 7 (HIST-050). The engine streams a full
//  reconstruction from a canonical subject: resolve → collect → project → outline
//  → reconcile → verified. Subject scope holds end-to-end (unrelated activity never
//  appears), and a non-entity subject FAILS explicitly (no silent global fallback).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("HIST Phase 7 — reconstruction engine (end to end)")
struct HistoryReconstructionEngineTests {

    private let clock = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeDB() async throws -> Database {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hre-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("t.sqlite"))
        try await SchemaMigrations.migrate(db)
        try await db.exec("PRAGMA foreign_keys=OFF;", [])
        return db
    }
    private func insertEntity(_ db: Database, _ id: UUID, _ value: String) async throws {
        try await db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence, attributes_json, quality_tier) VALUES (?, 'person', ?, ?, ?, 0.9, '{}', 'T2');",
                          [.uuid(id), .text(value), .text(value.lowercased()), .uuid(UUID())])
    }
    private func insertEvent(_ db: Database, title: String, participant: UUID) async throws {
        let ev = UUID()
        try await db.exec("INSERT INTO events (id, kind, date, title, source_object_id) VALUES (?, 'contractSigned', 1072915200, ?, ?);",
                          [.uuid(ev), .text(title), .uuid(UUID())])
        try await db.exec("INSERT INTO event_entities (event_id, entity_id) VALUES (?, ?);", [.uuid(ev), .uuid(participant)])
    }

    private func engine(_ db: Database) -> HistoryReconstructionEngine {
        HistoryReconstructionEngine(
            entities: EntitiesRepository(database: db), events: EventsRepository(database: db),
            assertions: AssertionsRepository(database: db), genericFacts: GenericFactRepository(database: db),
            relationships: RelationshipsRepository(database: db), clock: { self.clock })
    }

    @Test("Full reconstruction streams a verified outline scoped to the subject")
    func endToEnd() async throws {
        let db = try await makeDB()
        let subject = UUID(), unrelated = UUID()
        try await insertEntity(db, subject, "Subject A")
        try await insertEntity(db, unrelated, "Subject B")
        try await insertEvent(db, title: "MSA signed", participant: subject)
        try await insertEvent(db, title: "Unrelated deal", participant: unrelated)

        var updates: [HistoryUpdate] = []
        for await u in engine(db).reconstruct(subject: .person(subject), request: HistoryRequest()) {
            updates.append(u)
        }

        // Ordered lifecycle emitted.
        #expect(updates.contains { if case .resolvingSubject = $0 { return true }; return false })
        #expect(updates.contains { if case .outlineReady = $0 { return true }; return false })

        // Final verified result, scoped to the subject.
        guard case .verified(let result)? = updates.last(where: { if case .verified = $0 { return true }; return false }) else {
            Issue.record("expected a .verified update"); return
        }
        let titles = result.outline.items.map(\.title)
        #expect(titles.contains("MSA signed"))
        #expect(!titles.contains("Unrelated deal"))          // subject scope holds end-to-end
        #expect(result.outline.everyItemChaptered)
        #expect(result.engineVersion == HistoryReconstructionEngine.version)
    }

    @Test("A non-entity subject fails explicitly — never a silent global history")
    func nonEntitySubjectFails() async throws {
        let db = try await makeDB()
        try await insertEvent(db, title: "Some global event", participant: UUID())
        var failed = false
        for await u in engine(db).reconstruct(subject: .topic(UUID()), request: HistoryRequest()) {
            if case .failed = u { failed = true }
            if case .verified = u { Issue.record("must not verify a non-entity subject") }
        }
        #expect(failed)
    }
}
