//
//  LedgerContractTests.swift
//  KalsmritikoshTests
//
//  L4 (P1.11) — the ledger contract on every build. (1) A freshly ingested,
//  deliberately MIXED corpus (legal letter, invoice, résumé, email, sheet,
//  device plist) satisfies every rule after the drain converges. (2) Each rule
//  catches a seeded violation — a check that cannot fail proves nothing.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("L4 — the ledger contract", .serialized)
@MainActor
struct LedgerContractTests {

    private func freshDB(_ tag: String) throws -> (Database, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try Database(url: dir.appendingPathComponent("db.sqlite")), dir)
    }

    @Test("A mixed corpus, ingested and drained, satisfies every rule of the contract")
    func mixedCorpusHoldsTheContract() async throws {
        let (db, dir) = try freshDB("contract")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await SchemaMigrations.migrate(db)
        let objects = KnowledgeObjectRepository(database: db)
        let entities = EntitiesRepository(database: db)
        let events = EventsRepository(database: db)
        let facts = GenericFactRepository(database: db)
        let evidence = EvidenceStore(database: db)
        let coordinator = IngestCoordinator(
            universalRegistry: try UniversalParserRegistryBuilder.standard(ocr: VisionOCR()),
            entityExtractor: NLEntityExtractor(), entityLinker: EntityLinker(),
            entityQualityGate: EntityQualityGate(), eventExtractor: RuleEventExtractor(),
            files: FilesRepository(database: db), objects: objects, chunks: ChunksRepository(database: db),
            entities: entities, events: events, evidenceStore: evidence, genericFacts: facts,
            intakeCoordinator: UniversalSourceIntakeCoordinator(repository: CanonicalSourceIntakeRepository(database: db)))

        let gen = NoiseFixtureGenerator()
        let corpus: [(String, String)] = [
            ("grant.md", gen.noisyGrantLetter),
            ("invoice.txt", "TAX INVOICE\nInvoice number INV-42, invoice dated 5 May 2024.\nAmount due ₹20,000. Bill to: Orchid Ltd.\nGSTIN 27AAACC6814B1Z4"),
            ("resume.txt", "RESUME\nJane Roe\nMob: 9830012345\nEmail: jane.roe@example.com\nWork Experience\nAcme Pharma — Executive, 2019–2023\nEducation\nB.Tech, 2018\nDeclaration: the above is true."),
            ("note.eml", "From: Tarun <tarun@lawfirm.example>\nTo: owner@example.com\nSubject: Hearing notice for application 202331019665\nDate: Wed, 14 Aug 2024 10:00:00 +0530\n\nThe hearing is fixed for 14/08/2024. Please attend.\n"),
            ("sheet.csv", "Name,Amount,Date\nOrchid Ltd,20000,2024-05-05\nAcme Pharma,5000,2024-06-01\n"),
        ]
        for (name, text) in corpus {
            let url = dir.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            _ = try await coordinator.ingest(fileAt: url)
        }
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["Serial Number": "F2LXY1234567", "IMEI": "356938035643809"], format: .xml, options: 0)
        let plistURL = dir.appendingPathComponent("Info.plist")
        try plist.write(to: plistURL)
        _ = try await coordinator.ingest(fileAt: plistURL)

        _ = try await LedgerDrainCoordinator(database: db, objects: objects, entities: entities,
                                             events: events, facts: facts, evidence: evidence).drain()
        _ = try await ChunkReindexCoordinator(database: db).run()

        let violations = try await LedgerContractCheck(database: db).violations()
        #expect(violations.isEmpty, "\(LedgerContractCheck.render(violations))")
    }

    @Test("Each core rule catches a seeded violation")
    func rulesCatchSeededViolations() async throws {
        let (db, dir) = try freshDB("contract-bad")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await SchemaMigrations.migrate(db)
        let fileID = UUID(), ko = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?, ?, ?);",
                          [.uuid(fileID), .text("file:///x.txt"), .text("txt")])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?, ?, 'txt', 'b', 0, 0);
        """, [.uuid(ko), .uuid(fileID)])
        // fact.subject + fact.evidence + fact.plumbing (one bad fact trips all three)
        try await db.exec("""
        INSERT INTO generic_facts (id, subject_label, field, value, status, confidence, source_blocks_json, created_at,
            evidence_basis, review_disposition, proposal_origin, availability_status, conflict_status, producer_version)
        VALUES (?, '', 'contenttype', 'Content-Type: multipart/mixed; boundary=x', 'sourceAsserted', 0.5, '[]', 0,
            'sourceAsserted', 'unreviewed', 'sourceExtraction', 'present', 'none', \(DerivedProducerVersions.facts));
        """, [.uuid(UUID())])
        // event.unique — the same happening twice from one document
        for _ in 0..<2 {
            try await db.exec("""
            INSERT INTO events (id, kind, date, title, source_object_id) VALUES (?, 'other', 0, 'Archived entry', ?);
            """, [.uuid(UUID()), .uuid(ko)])
        }
        // claim.lineage — a live claim whose only source is gone
        let claim = UUID()
        try await db.exec("""
        INSERT INTO claims (id, subject_label, statement, created_at, evidence_basis, review_disposition, proposal_origin, availability_status, conflict_status)
        VALUES (?, 's', 'stmt', 0, 'sourceAsserted', 'unreviewed', 'sourceExtraction', 'present', 'none');
        """, [.uuid(claim)])
        try await db.exec("INSERT INTO claim_lineage (claim_id, source_kind, source_id) VALUES (?, 'event', ?);",
                          [.uuid(claim), .uuid(UUID())])
        // community.attributes — a date inside a topic community
        let date = UUID()
        try await db.exec("""
        INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence) VALUES (?, 'date', 'Mon, 26 Jul 2021', 'x', ?, 0.9);
        """, [.uuid(date), .uuid(ko)])
        try await db.exec("INSERT INTO entity_communities (community_id, entity_id, level, computed_at) VALUES ('c', ?, 0, 0);",
                          [.uuid(date)])
        // entity.phoneShape — a live "phone" of 20 digits
        try await db.exec("""
        INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence) VALUES (?, 'phoneNumber', '12345678901234567890', 'x', ?, 0.9);
        """, [.uuid(UUID()), .uuid(ko)])

        let fired = Set(try await LedgerContractCheck(database: db).violations().map(\.ruleID))
        for rule in ["fact.subject", "fact.evidence", "fact.plumbing", "event.unique",
                     "claim.lineage", "community.attributes", "entity.phoneShape"] {
            #expect(fired.contains(rule), "\(rule) did not fire on its seeded violation")
        }
    }
}
