//
//  AnchorWriterBindingTests.swift
//  KalsmritikoshTests
//
//  V3 3c — THE WRITER BINDING. Proves the anchor identity contract at the REPO
//  layer (beyond IdentifierAnchor's pure-service tests) and end-to-end through
//  the wired ingest path:
//    • resolve-or-create is idempotent — two identifier facts with the same
//      (field, canonicalValue) resolve to EXACTLY ONE anchor row (the owner's
//      required repo-layer assertion), enforced by UNIQUE(kind, normalized) on
//      the identity key;
//    • the coincidence rule (D2) — the same digits under two fields are TWO
//      anchors, never conflated;
//    • the mixed-window bridge is INERT with no anchors and hits once one exists;
//    • the wired ingest binds every identifier fact's subject to its anchor.
//
//  An anchor's source_object_id carries a FOREIGN KEY into knowledge_objects, so
//  the repo-level tests seed one real KO row (anchors are cross-document, but the
//  row records a first-sighting KO). The wired test uses a real ingest.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("V3 3c — anchor writer binding")
struct AnchorWriterBindingTests {

    private func freshDB() async throws -> Database {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("anchor-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        return db
    }

    /// A fresh migrated DB plus one real knowledge_objects row (with its files
    /// parent) so anchor inserts satisfy the source_object_id foreign key.
    private func freshDBWithKO() async throws -> (Database, UUID) {
        let db = try await freshDB()
        let fileID = UUID(), koID = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?, ?, ?);",
                          [.uuid(fileID), .text("file:///anchor-test"), .text("text")])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?, ?, ?, ?, 0, 0);
        """, [.uuid(koID), .uuid(fileID), .text("text"), .text("anchor test body")])
        return (db, koID)
    }

    @Test("Repo idempotency: two facts, same (field, canonicalValue) → exactly ONE anchor row")
    func resolveOrCreateIdempotent() async throws {
        let (db, ko) = try await freshDBWithKO()
        let repo = EntitiesRepository(database: db)
        // Two "facts" for the same patent under spelling/spacing variants.
        let a = try await repo.resolveOrCreateAnchor(field: "patentNumber", value: "Patent No. 555489", sourceObjectID: ko)
        let b = try await repo.resolveOrCreateAnchor(field: "patentnumber", value: "555489", sourceObjectID: ko)
        #expect(a == b, "the same (field, canonicalValue) must resolve to one anchor id")
        #expect(try await repo.count(of: .identifierAnchor) == 1, "exactly one anchor row for one identity")
    }

    @Test("Coincidence (D2): same digits under two fields → TWO anchors, never conflated")
    func coincidenceTwoAnchors() async throws {
        let (db, ko) = try await freshDBWithKO()
        let repo = EntitiesRepository(database: db)
        let patent = try await repo.resolveOrCreateAnchor(field: "patentNumber", value: "555489", sourceObjectID: ko)
        let invoice = try await repo.resolveOrCreateAnchor(field: "invoiceNumber", value: "555489", sourceObjectID: ko)
        #expect(patent != invoice, "patent 555489 and invoice 555489 must be distinct anchors")
        #expect(try await repo.count(of: .identifierAnchor) == 2)
        // anchorKeys carries both identity keys → the two ids.
        let keys = try await repo.anchorKeys()
        #expect(keys[IdentifierAnchor.identityKey(field: "patentNumber", value: "555489")] == patent)
        #expect(keys[IdentifierAnchor.identityKey(field: "invoiceNumber", value: "555489")] == invoice)
    }

    @Test("Mixed-window bridge is inert with no anchors, hits once one exists")
    func bridgeGatedByExistence() async throws {
        // Empty ledger → no anchor → bridge returns nil (inert by construction).
        #expect(IdentifierAnchor.bridge(field: "patentNumber", value: "555489", anchorsByKey: [:]) == nil)
        // With the anchor present, a v≤1 fact for the same value bridges to it.
        let (db, ko) = try await freshDBWithKO()
        let repo = EntitiesRepository(database: db)
        let id = try await repo.resolveOrCreateAnchor(field: "patentNumber", value: "555489", sourceObjectID: ko)
        let keys = try await repo.anchorKeys()
        #expect(IdentifierAnchor.bridge(field: "patentnumber", value: "Patent No. 555489", anchorsByKey: keys) == id)
        // A different (uncreated) value still bridges nothing.
        #expect(IdentifierAnchor.bridge(field: "patentNumber", value: "999999", anchorsByKey: keys) == nil)
    }

    @Test("withSubjectID persists through the fact repository")
    func subjectBindingRoundTrips() async throws {
        let (db, ko) = try await freshDBWithKO()
        let facts = GenericFactRepository(database: db)
        let anchors = EntitiesRepository(database: db)
        let anchorID = try await anchors.resolveOrCreateAnchor(field: "patentNumber", value: "555489", sourceObjectID: ko)
        let bound = GenericFact(subjectLabel: "doc", field: "patentNumber", value: "555489",
                                status: .sourceAsserted, confidence: 0.9, sourceBlockIDs: [UUID()],
                                producerVersion: DerivedProducerVersions.facts).withSubjectID(anchorID)
        try await facts.upsert(bound)
        let readBack = try await facts.facts(subjectID: anchorID)
        #expect(readBack.count == 1)
        #expect(readBack.first?.subjectID == anchorID, "the bound subject must round-trip")
    }

    @Test("Wired ingest binds identifier facts to a single anchor per identity")
    @MainActor
    func wiredIngestBindsSubjects() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("anchor-wired-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)

        let objects = KnowledgeObjectRepository(database: db)
        let anchors = EntitiesRepository(database: db)
        let facts = GenericFactRepository(database: db)
        // A real coordinator with the entities repo wired (the production path
        // that binds anchors). evidenceStore is required so structural blocks
        // persist and deriveGenericFacts runs.
        let coordinator = IngestCoordinator(
            universalRegistry: try UniversalParserRegistryBuilder.standard(ocr: VisionOCR()),
            entityExtractor: NLEntityExtractor(),
            entityLinker: EntityLinker(),
            eventExtractor: RuleEventExtractor(),
            files: FilesRepository(database: db), objects: objects, chunks: ChunksRepository(database: db),
            entities: anchors, events: EventsRepository(database: db),
            evidenceStore: EvidenceStore(database: db),
            genericFacts: facts,
            intakeCoordinator: UniversalSourceIntakeCoordinator(repository: CanonicalSourceIntakeRepository(database: db)))

        // The SAME patent number twice (idempotency through the wired path) plus a
        // distinct application number.
        let fileURL = dir.appendingPathComponent("grant.txt")
        try """
        Indian Patent No. 555489 was granted on 12 March 2024 to Orchid Labs.
        This letter confirms the grant of Patent No. 555489.
        Application No. 202211045678 was filed on 5 May 2022.
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        _ = try await coordinator.ingest(fileAt: fileURL)

        // The wired path created identifier anchors — and the patent, seen twice,
        // is ONE anchor row (repo idempotency end-to-end).
        #expect(try await anchors.count(of: .identifierAnchor) >= 1, "ingest created no identifier anchor")

        // Every identifier-shaped fact carries a bound subject, and facts sharing
        // an identity share the SAME anchor id.
        let all = try await facts.all(pageSize: 5_000)
        let idFacts = all.filter { FactSchemaRegistry.expectedShape(of: $0.field) == .identifier }
        #expect(!idFacts.isEmpty, "ingest produced no identifier facts to bind")
        var byKey: [String: UUID] = [:]
        for f in idFacts {
            #expect(f.subjectID != nil, "identifier fact \(f.field)=\(f.value) was not bound to an anchor")
            let key = IdentifierAnchor.identityKey(field: f.field, value: f.value)
            if let existing = byKey[key] {
                #expect(existing == f.subjectID, "two facts for one identity bound to different anchors")
            } else {
                byKey[key] = f.subjectID
            }
        }
        // Distinct identities === distinct anchor ids, and the count agrees.
        #expect(Set(byKey.values).count == byKey.count)
        #expect(try await anchors.count(of: .identifierAnchor) == byKey.count,
                "one anchor row per distinct identity — no duplicates, no orphans")
    }

    @Test("V3 3d — leading-punctuation strip folds with the clean sibling in EITHER arrival order → one clean person")
    func leadingPunctuationFoldsBothOrders() async throws {
        for order in [[", Shabana Khan", "Shabana Khan"], ["Shabana Khan", ", Shabana Khan"]] {
            let (db, ko) = try await freshDBWithKO()
            let repo = EntitiesRepository(database: db)
            for name in order {
                _ = try await repo.insertBatch([Entity(kind: .person, value: name, sourceObjectID: ko)])
            }
            let count = Int((try await db.query("SELECT COUNT(*) FROM entities WHERE kind = 'person'", [])).first?.int(0) ?? -1)
            let value = (try await db.query("SELECT value FROM entities WHERE kind = 'person' LIMIT 1", [])).first?.string(0)
            #expect(count == 1, "order \(order): expected ONE folded person, got \(count) — the strip created a duplicate")
            #expect(value == "Shabana Khan", "order \(order): stored display kept a header artifact: \(value ?? "nil")")
        }
    }
}
