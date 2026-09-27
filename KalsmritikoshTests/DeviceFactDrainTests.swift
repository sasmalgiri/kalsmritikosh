//
//  DeviceFactDrainTests.swift
//  KalsmritikoshTests
//
//  P1.1 — device facts must survive the ledger drain. Before the fix the
//  producer stamped a private version (1) into generic_facts, whose era is
//  DerivedProducerVersions.facts, so the drain's orphan sweep deleted every
//  device fact on each refresh; and the drain's re-derivation never ran the
//  device producer, so an era bump dropped them for good.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("P1.1 — device facts survive the drain", .serialized)
@MainActor
struct DeviceFactDrainTests {

    @Test("Ingest → era-current device facts; aged → drain re-derives them; a second drain changes nothing")
    func deviceFactsSurviveDrain() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("devdrain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
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

        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["Serial Number": "F2LXY1234567", "IMEI": "356938035643809",
                               "Device Name": "Field Laptop"],
            format: .xml, options: 0)
        let url = dir.appendingPathComponent("Info.plist")
        try plist.write(to: url)
        _ = try await coordinator.ingest(fileAt: url)

        // Only the DEVICE producer's rows (its fields are DeviceIdentity's);
        // the open-field extractor may also record "Serial Number" under its
        // own label, which is a separate, legitimate fact. Fields are stored
        // lower-cased.
        let deviceFields = DeviceIdentity.Field.allCases.filter(\.isStrongIdentity).map { $0.rawValue.lowercased() }
        func deviceRows() async throws -> [(value: String, version: Int)] {
            let marks = deviceFields.map { _ in "?" }.joined(separator: ",")
            return try await db.query("""
            SELECT value, COALESCE(producer_version, 0) FROM generic_facts
            WHERE lower(field) IN (\(marks)) ORDER BY value;
            """, deviceFields.map { .text($0) }).map { ($0.string(0) ?? "", Int($0.int(1) ?? 0)) }
        }

        let ingested = try await deviceRows()
        #expect(ingested.count == 2, "ingest wrote both strong device identifiers")
        #expect(ingested.allSatisfy { $0.version == DerivedProducerVersions.facts },
                "device facts carry the facts era, not a private version")

        let drain = LedgerDrainCoordinator(database: db, objects: objects, entities: entities,
                                           events: events, facts: facts, evidence: evidence)
        _ = try await drain.drain()
        #expect(try await deviceRows().count == 2, "a drain over a current ledger keeps device facts")

        // Age to legacy (as an era bump would) — the drain must RE-DERIVE them.
        try await db.exec("UPDATE generic_facts SET producer_version = NULL;", [])
        _ = try await drain.drain()
        let rederived = try await deviceRows()
        #expect(rederived.map(\.value) == ["356938035643809", "F2LXY1234567"])
        #expect(rederived.allSatisfy { $0.version == DerivedProducerVersions.facts })

        let before = try await db.query("SELECT COUNT(*) FROM generic_facts;", []).first?.int(0)
        _ = try await drain.drain()
        let after = try await db.query("SELECT COUNT(*) FROM generic_facts;", []).first?.int(0)
        #expect(before == after, "the second drain is a no-op")
    }
}
