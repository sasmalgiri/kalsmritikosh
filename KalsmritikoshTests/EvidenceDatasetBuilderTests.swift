//
//  EvidenceDatasetBuilderTests.swift
//  KalsmritikoshTests
//
//  Proves DataLab can build a dataset FROM the ingested ledger with every
//  populated source cell drill-through bound to its canonical object.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("EvidenceDatasetBuilder — build from evidence")
struct EvidenceDatasetBuilderTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func seededLedger() async throws -> (db: Database, workspaceID: UUID, koID: UUID) {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db)

        let wsID = UUID()
        try await db.exec("""
        INSERT INTO workspaces (id, title, template_type, description, status, default_date_start,
                                default_date_end, default_scope_json, created_at, updated_at, archived_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?);
        """, [.uuid(wsID), .text("Matter"), .text("investigation"), .null, .text("active"),
              .null, .null, .text("{}"), .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970), .null])

        let fileID = UUID(), koID = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                          [.uuid(fileID), .text("file://\(fileID)"), .text("pdf")])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?,?,?,?,?,?);
        """, [.uuid(koID), .uuid(fileID), .text("pdf"), .text("body"), .date(t0), .date(t0)])
        return (db, wsID, koID)
    }

    private func insertEvent(_ db: Database, koID: UUID, title: String, summary: String, day: Int) async throws {
        let d = Date(timeIntervalSince1970: t0.timeIntervalSince1970 + Double(day) * 86_400)
        try await db.exec("""
        INSERT INTO events (id, kind, date, end_date, title, summary, source_object_id, confidence,
                            attributes_json, date_confidence, quality_tier, date_precision, status)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
        """, [.uuid(UUID()), .text("meetingHeld"), .date(d), .null, .text(title), .text(summary),
              .uuid(koID), .real(0.8), .text("{}"), .real(0.9), .text("T2"), .integer(5), .text("observed")])
    }

    private func insertEntity(_ db: Database, koID: UUID, kind: String, value: String) async throws {
        try await db.exec("""
        INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence, attributes_json)
        VALUES (?,?,?,?,?,?, '{}');
        """, [.uuid(UUID()), .text(kind), .text(value), .text(value.lowercased()), .uuid(koID), .real(0.8)])
    }

    @Test("Timeline build creates one bound row per event, fully provenanced")
    func timelineBuild() async throws {
        let (db, wsID, koID) = try await seededLedger()
        try await insertEvent(db, koID: koID, title: "Kickoff meeting", summary: "Project start", day: 1)
        try await insertEvent(db, koID: koID, title: "Delivery delayed", summary: "Supplier ABC", day: 2)

        let builder = EvidenceDatasetBuilder(
            datasets: WorkbenchDatasetRepository(database: db),
            events: EventsRepository(database: db),
            entities: EntitiesRepository(database: db),
            relationships: RelationshipsRepository(database: db))

        let result = try await builder.buildTimeline(
            workspaceID: wsID, title: "Timeline", allowedObjectIDs: nil, actor: "Tester", at: t0)

        #expect(result.rowsAdded == 2)
        #expect(result.record.fields.map(\.name) == ["Date", "Event", "Details"])
        #expect(result.boundCells >= 4)                       // 2 events × (Date + Event) at least
        #expect(!result.record.bindings.isEmpty)
        #expect(result.record.isFullyProvenanced, "every source cell must drill through")
        // Every binding points at a real event.
        #expect(result.record.bindings.allSatisfy { $0.targetKind == .event })
    }

    @Test("Timeline honours workspace scoping (empty allowed set → no rows)")
    func timelineScoping() async throws {
        let (db, wsID, koID) = try await seededLedger()
        try await insertEvent(db, koID: koID, title: "Event", summary: "x", day: 1)
        let builder = EvidenceDatasetBuilder(
            datasets: WorkbenchDatasetRepository(database: db),
            events: EventsRepository(database: db),
            entities: EntitiesRepository(database: db),
            relationships: RelationshipsRepository(database: db))
        // An allowed set that excludes this event's source object → nothing eligible.
        let result = try await builder.buildTimeline(
            workspaceID: wsID, title: "Timeline", allowedObjectIDs: [UUID()], actor: "Tester", at: t0)
        #expect(result.rowsAdded == 0)
        #expect(result.record.rows.isEmpty)
    }

    @Test("People build binds the Name cell of each entity to that entity")
    func peopleBuild() async throws {
        let (db, wsID, koID) = try await seededLedger()
        try await insertEntity(db, koID: koID, kind: "person", value: "Alice Martin")
        try await insertEntity(db, koID: koID, kind: "organization", value: "Acme Corp")

        let builder = EvidenceDatasetBuilder(
            datasets: WorkbenchDatasetRepository(database: db),
            events: EventsRepository(database: db),
            entities: EntitiesRepository(database: db),
            relationships: RelationshipsRepository(database: db))

        let result = try await builder.buildEntities(
            workspaceID: wsID, title: "People", kinds: [.person, .organization], actor: "Tester", at: t0)

        #expect(result.rowsAdded == 2)
        #expect(result.record.fields.map(\.name) == ["Name", "Kind"])
        #expect(result.boundCells == 2)                       // one Name binding per entity
        #expect(result.record.bindings.allSatisfy { $0.targetKind == .entity })
        #expect(result.record.isFullyProvenanced, "Name source cells must drill through")
    }

    @Test("Payments build binds payer & payee to their entities, fully provenanced")
    func paymentsBuild() async throws {
        let (db, wsID, koID) = try await seededLedger()
        let payer = UUID(), payee = UUID()
        for (id, kind, value) in [(payer, "organization", "Acme Corp"), (payee, "vendor", "Vendor X")] {
            try await db.exec("""
            INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence, attributes_json)
            VALUES (?,?,?,?,?,?, '{}');
            """, [.uuid(id), .text(kind), .text(value), .text(value.lowercased()), .uuid(koID), .real(0.8)])
        }
        try await db.exec("""
        INSERT INTO relationships (id, kind, from_entity_id, to_entity_id, via_event_id,
                                   source_object_id, confidence, attributes_json, weight, evidence_object_ids_json)
        VALUES (?, 'paid', ?, ?, NULL, ?, 0.8, '{}', 4, ?);
        """, [.uuid(UUID()), .uuid(payer), .uuid(payee), .uuid(koID),
              .text("[\"\(koID.uuidString)\",\"other\"]")])

        let builder = EvidenceDatasetBuilder(
            datasets: WorkbenchDatasetRepository(database: db),
            events: EventsRepository(database: db),
            entities: EntitiesRepository(database: db),
            relationships: RelationshipsRepository(database: db))

        let result = try await builder.buildPayments(
            workspaceID: wsID, title: "Payments", actor: "Tester", at: t0)

        #expect(result.rowsAdded == 1)
        #expect(result.record.fields.map(\.name) == ["Payer", "Payee", "Times observed", "Source documents"])
        #expect(result.boundCells == 2)   // Payer + Payee bound to entities
        #expect(result.record.bindings.allSatisfy { $0.targetKind == .entity })
        #expect(result.record.isFullyProvenanced, "party cells must drill through")

        let values = Set(result.record.cells.compactMap { $0.value })
        #expect(values.contains("Acme Corp"))
        #expect(values.contains("Vendor X"))
        #expect(values.contains("4"))       // times observed (weight)
        #expect(values.contains("2"))       // source documents (evidence count)
    }
}
