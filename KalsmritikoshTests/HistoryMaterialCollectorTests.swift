//
//  HistoryMaterialCollectorTests.swift
//  KalsmritikoshTests
//
//  Universal History program, Phase 2 (HIST-030/031/033). The collector gathers a
//  subject's events, assertions, typed facts and relationships BY CANONICAL ID, and
//  crucially does NOT leak an unrelated entity's activity — the program's #1 release
//  gate (subject scope leakage = 0).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("HIST Phase 2 — material collection is ID-scoped (no leakage)")
struct HistoryMaterialCollectorTests {

    private func makeDB() async throws -> Database {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("histmat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("t.sqlite"))
        try await SchemaMigrations.migrate(db)
        try await db.exec("PRAGMA foreign_keys=OFF;", [])
        return db
    }

    private func insertEntity(_ db: Database, _ id: UUID, _ value: String) async throws {
        try await db.exec("""
        INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence, attributes_json, quality_tier)
        VALUES (?, 'person', ?, ?, ?, 0.9, '{}', 'T2');
        """, [.uuid(id), .text(value), .text(value.lowercased()), .uuid(UUID())])
    }
    private func insertEvent(_ db: Database, _ id: UUID, title: String, source: UUID, participant: UUID) async throws {
        try await db.exec("INSERT INTO events (id, kind, date, title, source_object_id) VALUES (?, 'contractSigned', 0, ?, ?);",
                           [.uuid(id), .text(title), .uuid(source)])
        try await db.exec("INSERT INTO event_entities (event_id, entity_id) VALUES (?, ?);", [.uuid(id), .uuid(participant)])
    }
    private func insertAssertion(_ db: Database, subject: UUID, predicate: String, evidence: UUID) async throws {
        try await db.exec("""
        INSERT INTO assertions (id, subject_kind, subject_id, predicate, object_kind, object_value, recorded_at, evidence_object_ids_json)
        VALUES (?, 'entity', ?, ?, 'literal', 'v', 1, ?);
        """, [.uuid(UUID()), .uuid(subject), .text(predicate), .text("[\"\(evidence.uuidString)\"]")])
    }
    private func insertRelationship(_ db: Database, from: UUID, to: UUID, source: UUID) async throws {
        try await db.exec("""
        INSERT INTO relationships (id, kind, from_entity_id, to_entity_id, source_object_id, confidence)
        VALUES (?, 'affiliated', ?, ?, ?, 0.8);
        """, [.uuid(UUID()), .uuid(from), .uuid(to), .uuid(source)])
    }

    @Test("Collects the subject's material only; an unrelated entity's event never leaks in")
    func idScopedNoLeakage() async throws {
        let db = try await makeDB()
        let subject = UUID(), unrelated = UUID(), neighbour = UUID()
        try await insertEntity(db, subject, "Shirshendu Sasmal")
        try await insertEntity(db, unrelated, "Someone Else")
        try await insertEntity(db, neighbour, "EcoSanskriti")

        let subjEventSrc = UUID(), otherEventSrc = UUID(), relSrc = UUID(), assertEvid = UUID()
        try await insertEvent(db, UUID(), title: "Joined Orchid", source: subjEventSrc, participant: subject)
        try await insertEvent(db, UUID(), title: "Unrelated activity", source: otherEventSrc, participant: unrelated)
        try await insertAssertion(db, subject: subject, predicate: "worked_for", evidence: assertEvid)
        try await insertRelationship(db, from: subject, to: neighbour, source: relSrc)

        let entities = EntitiesRepository(database: db)
        let facts = GenericFactRepository(database: db)
        try await facts.upsert(GenericFact(
            subjectID: subject, subjectLabel: "Shirshendu Sasmal", field: "employer",
            value: "Orchid Chemicals", status: .sourceAsserted, confidence: 0.8, sourceBlockIDs: [UUID()]))

        let collector = HistoryMaterialCollector(
            events: EventsRepository(database: db),
            assertions: AssertionsRepository(database: db),
            genericFacts: facts,
            relationships: RelationshipsRepository(database: db))
        let resolver = HistorySubjectResolver(entities: entities)

        let resolved = try #require(try await resolver.resolve(entityID: subject))
        let material = try await collector.collect(for: resolved)

        // SUBJECT SCOPE LEAKAGE = 0: only the subject's event, not the unrelated one.
        #expect(material.events.count == 1)
        #expect(material.events.first?.title == "Joined Orchid")
        #expect(material.assertions.count == 1)
        #expect(material.genericFacts.count == 1)
        #expect(material.relationships.count == 1)
        #expect(material.firstDegreeEntityIDs == [neighbour])
        // Evidence footprint unions the subject's sources (not the unrelated event's).
        #expect(material.evidenceObjectIDs.contains(subjEventSrc))
        #expect(material.evidenceObjectIDs.contains(relSrc))
        #expect(!material.evidenceObjectIDs.contains(otherEventSrc))
        #expect(!material.isEmpty)
        #expect(material.provenance.unscopedSubject == false)
    }

    @Test("A corpus/topic subject (no canonical id) returns empty, flagged — never global activity")
    func unscopedSubjectIsEmptyNotGlobal() async throws {
        let db = try await makeDB()
        // Seed an event so a naive global collector WOULD return something.
        try await insertEvent(db, UUID(), title: "Some global event", source: UUID(), participant: UUID())
        let collector = HistoryMaterialCollector(
            events: EventsRepository(database: db),
            assertions: AssertionsRepository(database: db),
            genericFacts: GenericFactRepository(database: db),
            relationships: RelationshipsRepository(database: db))
        let corpusSubject = ResolvedHistorySubject(
            subject: .corpus, displayName: "corpus", canonicalEntityID: nil, resolutionConfidence: 1.0)
        let material = try await collector.collect(for: corpusSubject)
        #expect(material.isEmpty)                       // NOT the global event
        #expect(material.provenance.unscopedSubject == true)
    }
}
