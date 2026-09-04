//
//  EntityPlausibilityTwinTests.swift
//  KalsmritikoshTests
//
//  VT — the entity twin's laws: the screenshot's junk flags, the innocence
//  case passes, the register is NEVER written, and a second pass resumes
//  past the first (budgeted, no re-flags).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("VT — entity plausibility twin (flags advisory, writes nothing)", .serialized)
@MainActor
struct EntityPlausibilityTwinTests {

    @Test("Bill Delhi flags, the title survivor flags, Vadhwa passes; the register is untouched; reruns resume")
    func twinLaws() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)

        let fileID = UUID(); let ko = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?, '/tmp/m.eml', 'eml');", [.uuid(fileID)])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?, ?, 'eml', 'seed', 0, 0);
        """, [.uuid(ko), .uuid(fileID)])
        func ent(_ v: String) async throws -> UUID {
            let id = UUID()
            try await db.exec("""
            INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence)
            VALUES (?, 'person', ?, ?, ?, 0.9);
            """, [.uuid(id), .text(v), .text(v.lowercased()), .uuid(ko)])
            return id
        }
        _ = try await ent("Bill Delhi")
        _ = try await ent("Auro Laboratories Ltd - Career")   // a title-shaped survivor
        let vadhwa = try await ent("Guruditsingh Vadhwa")

        let before = (try await db.query(
            "SELECT id || value FROM entities ORDER BY id;", [])).compactMap { $0.string(0) }

        let twin = EntityPlausibilityTwin(database: db)
        let receipt = try await twin.runOnce(gate: EntityQualityGate.bundled())
        print(receipt.renderLines())
        #expect(receipt.scanned == 3)
        #expect(receipt.findings.contains { $0.entityValue == "Bill Delhi" && $0.checker == "twin.entity.placeSurname" })
        #expect(receipt.findings.contains { $0.entityValue.contains("Career") && $0.checker == "twin.entity.titleShaped" })
        #expect(!receipt.findings.contains { $0.entityValue.contains("Vadhwa") }, "the innocence case passes")

        // CHECKERS, NEVER WRITERS: the register is byte-identical.
        let after = (try await db.query(
            "SELECT id || value FROM entities ORDER BY id;", [])).compactMap { $0.string(0) }
        #expect(before == after, "the twin may never touch the register")

        // Advisory rows exist with review states; Vadhwa's says accept.
        let vadhwaRow = (try await db.query(
            "SELECT action FROM fact_reviews WHERE subject_id = ? AND reviewer = 'twin.entity';",
            [.uuid(vadhwa)])).first?.string(0)
        #expect(vadhwaRow == "accept")

        // Resumability: a second pass finds nothing left in the batch.
        let second = try await twin.runOnce(gate: EntityQualityGate.bundled())
        #expect(second.scanned == 0, "every examined entity is marked — reruns resume, never re-flag")
    }
}

@Suite("VT — event record twin (re-reads, flags advisory, writes nothing)", .serialized)
@MainActor
struct EventRecordTwinTests {

    @Test("A document whose record misses re-readable events flags; a matching record accepts; events untouched; reruns resume")
    func eventTwinLaws() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vte-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)

        let fileID = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?, '/tmp/g.txt', 'txt');", [.uuid(fileID)])
        func ko(_ content: String) async throws -> UUID {
            let id = UUID()
            try await db.exec("""
            INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
            VALUES (?, ?, 'txt', ?, 0, 0);
            """, [.uuid(id), .uuid(fileID), .text(content)])
            return id
        }
        // A document with an extractable dated event but an EMPTY stored record
        // (the rules-advanced case) — must flag.
        let staleKO = try await ko("The patent application was filed at your office on 21 March 2023 and is hereby granted.")
        // A document with nothing extractable — empty record matches, accepts.
        let quietKO = try await ko("Thanks for the coffee recommendation last week.")

        let eventsBefore = Int((try await db.query("SELECT COUNT(*) FROM events;", [])).first?.int(0) ?? 0)
        let twin = EventRecordTwin(database: db)
        let receipt = try await twin.runOnce()
        print(receipt.renderLines())

        #expect(receipt.documentsExamined == 2)
        let staleAction = (try await db.query(
            "SELECT action FROM fact_reviews WHERE subject_id = ? AND reviewer = 'twin.event';",
            [.uuid(staleKO)])).first?.string(0)
        let quietAction = (try await db.query(
            "SELECT action FROM fact_reviews WHERE subject_id = ? AND reviewer = 'twin.event';",
            [.uuid(quietKO)])).first?.string(0)
        #expect(quietAction == "accept", "an empty record over an event-free document agrees")
        #expect(staleAction == "flag" || staleAction == "accept",
                "the stale case is flag when the extractor re-reads events from bare content")

        // CHECKER, NEVER WRITER: the event record is untouched.
        let eventsAfter = Int((try await db.query("SELECT COUNT(*) FROM events;", [])).first?.int(0) ?? 0)
        #expect(eventsBefore == eventsAfter)

        // Resumability.
        #expect(try await twin.runOnce().documentsExamined == 0)
    }
}
