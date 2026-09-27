//
//  EventDeduperTests.swift
//  KalsmritikoshTests
//
//  P1.10 — one document states one happening once; different documents are
//  never merged; the survivor keeps every participant and the repeat count.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("P1.10 — same-source event repeats collapse")
struct EventDeduperTests {
    let doc = UUID(), other = UUID()
    let day = Date(timeIntervalSince1970: 1_724_140_800)   // 2024-08-20

    @Test("Seven identical 'Archived entry' events from one report become one, with every participant and a count")
    func collapsesRepeats() {
        let people = (0..<7).map { _ in UUID() }
        let repeats = people.enumerated().map { i, p in
            Event(kind: .emailReceived, date: day.addingTimeInterval(Double(i) * 60),
                  title: "Archived entry — GDPR_Report_sasmal.pdf", entityIDs: [p],
                  sourceObjectID: doc, confidence: Confidence(i == 3 ? 0.9 : 0.5))
        }
        let out = EventDeduper.collapse(repeats)
        #expect(out.count == 1)
        #expect(out[0].id == repeats[3].id, "the highest-confidence member survives")
        #expect(Set(out[0].entityIDs) == Set(people), "no participant is lost")
        if case .int(let n)? = out[0].attributes["occurrences"]?.value { #expect(n == 7) } else { Issue.record("no count") }
    }

    @Test("Different documents, different days, kinds or titles are never merged")
    func keepsDistinct() {
        let base = Event(kind: .emailReceived, date: day, title: "hi", sourceObjectID: doc)
        let events = [
            base,
            Event(kind: .emailReceived, date: day, title: "hi", sourceObjectID: other),        // other source
            Event(kind: .emailReceived, date: day.addingTimeInterval(86_400), title: "hi", sourceObjectID: doc), // next day
            Event(kind: .other, date: day, title: "hi", sourceObjectID: doc),                   // other kind
            Event(kind: .emailReceived, date: day, title: "hello", sourceObjectID: doc),        // other title
            Event(kind: .emailReceived, date: day, title: "  HI ", sourceObjectID: doc),         // same after normalising
        ]
        let out = EventDeduper.collapse(events)
        #expect(out.count == 5)
        #expect([base.id, events[5].id].contains(out.first?.id ?? UUID()),
                "the first-seen group leads; its survivor is one of its members")
        #expect(out.map(\.sourceObjectID).filter { $0 == other }.count == 1, "the other document's event survives")
    }
}

@Suite("P1.5 — orphaned claim projections", .serialized)
struct OrphanClaimSweepTests {

    @Test("Unreviewed orphan removed · reviewed orphan only marked · live claim untouched")
    func sweep() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claims-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        let fileID = UUID(), ko = UUID(), liveEvent = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?, ?, ?);",
                          [.uuid(fileID), .text("file:///x.txt"), .text("txt")])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?, ?, 'txt', 'b', 0, 0);
        """, [.uuid(ko), .uuid(fileID)])
        try await db.exec("""
        INSERT INTO events (id, kind, date, title, source_object_id, producer_version) VALUES (?, 'other', 0, 'live', ?, \(DerivedProducerVersions.events));
        """, [.uuid(liveEvent), .uuid(ko)])
        let orphan = UUID(), reviewed = UUID(), live = UUID()
        for (id, source) in [(orphan, UUID()), (reviewed, UUID()), (live, liveEvent)] {
            try await db.exec("""
            INSERT INTO claims (id, subject_label, statement, created_at, evidence_basis, review_disposition, proposal_origin, availability_status, conflict_status)
            VALUES (?, 's', 'stmt', 0, 'sourceAsserted', 'unreviewed', 'sourceExtraction', 'present', 'none');
            """, [.uuid(id)])
            try await db.exec("INSERT INTO claim_lineage (claim_id, source_kind, source_id) VALUES (?, 'event', ?);",
                              [.uuid(id), .uuid(source)])
        }
        try await db.exec("INSERT INTO claim_reviews (id, claim_id, disposition, reviewer, reviewed_at) VALUES (?, ?, 'confirmed', 'owner', 0);",
                          [.uuid(UUID()), .uuid(reviewed)])

        let drain = LedgerDrainCoordinator(database: db, objects: KnowledgeObjectRepository(database: db),
                                           entities: EntitiesRepository(database: db), events: EventsRepository(database: db),
                                           facts: GenericFactRepository(database: db), evidence: EvidenceStore(database: db))
        let receipt = try await drain.drain()
        #expect(receipt.orphanClaimsRemoved == 1 && receipt.orphanClaimsMarked == 1)
        let rows = try await db.query("SELECT id, availability_status FROM claims;", [])
        let status = Dictionary(uniqueKeysWithValues: rows.map { ($0.uuid(0)!, $0.string(1) ?? "") })
        #expect(status[orphan] == nil, "an unreviewed, unused orphan projection is removed")
        #expect(status[reviewed] == "missingEvidence", "a reviewed orphan is kept and marked, never destroyed")
        #expect(status[live] == "present", "a claim whose source exists is untouched")
    }
}

@Suite("P4.2 — milestone ids are stable across rebuilds")
struct StableEventIDTests {
    @Test("The same happening gets the same id every rebuild; a different one does not")
    func stable() {
        let src = UUID()
        let d = Date(timeIntervalSince1970: 1_732_752_000)   // 28 Nov 2024
        func e(_ title: String, _ date: Date = d) -> Event {
            Event(kind: .other, date: date, title: title, summary: "granted", sourceObjectID: src)
        }
        let a = EventDeduper.withStableID(e("Patent granted")), b = EventDeduper.withStableID(e("Patent granted"))
        #expect(a.id == b.id, "two rebuilds, one row identity")
        #expect(EventDeduper.withStableID(e("Hearing held")).id != a.id)
        #expect(EventDeduper.withStableID(e("Patent granted", d.addingTimeInterval(86_400 * 3))).id != a.id)
        #expect(a.title == "Patent granted" && a.sourceObjectID == src, "content untouched")
    }
}
