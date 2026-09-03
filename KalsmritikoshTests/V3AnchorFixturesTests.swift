//
//  V3AnchorFixturesTests.swift
//  KalsmritikoshTests
//
//  V3 3d (F2) — the anchor fixture suite: twelve documents naming one patent
//  become ONE anchor over twelve sources; the same digits under two fields are
//  two anchors that never cross-thread; "Nil Nil" neither survives nor folds;
//  a surname OCR variant folds by EXPLAINABLE substitution (never similarity);
//  and a patent's milestone chain threads onto one anchor entity id.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("V3 3d (F2) — anchor fixtures")
struct V3AnchorFixturesTests {

    // MARK: - Ingest rig (entities/events/facts wired, like production)

    private struct Rig {
        let db: Database
        let coordinator: IngestCoordinator
        let entities: EntitiesRepository
        let facts: GenericFactRepository
        let dir: URL
    }

    @MainActor
    private func makeRig() async throws -> Rig {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("f2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        let objects = KnowledgeObjectRepository(database: db)
        let entities = EntitiesRepository(database: db)
        let facts = GenericFactRepository(database: db)
        let coordinator = IngestCoordinator(
            universalRegistry: try UniversalParserRegistryBuilder.standard(ocr: VisionOCR()),
            entityExtractor: NLEntityExtractor(), entityLinker: EntityLinker(),
            entityQualityGate: EntityQualityGate(), eventExtractor: RuleEventExtractor(),
            files: FilesRepository(database: db), objects: objects, chunks: ChunksRepository(database: db),
            entities: entities, events: EventsRepository(database: db),
            evidenceStore: EvidenceStore(database: db),
            genericFacts: facts,
            intakeCoordinator: UniversalSourceIntakeCoordinator(repository: CanonicalSourceIntakeRepository(database: db)))
        return Rig(db: db, coordinator: coordinator, entities: entities, facts: facts, dir: dir)
    }

    @MainActor
    private func ingest(_ rig: Rig, _ text: String, _ name: String) async throws {
        let url = rig.dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        _ = try await rig.coordinator.ingest(fileAt: url)
    }

    // MARK: - Fixtures

    @Test("Twelve documents naming one patent → ONE anchor over twelve sources")
    @MainActor
    func twelveDocumentsOneAnchor() async throws {
        let rig = try await makeRig()
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        for i in 1...12 {
            try await ingest(rig, "Indian Patent No. 555489 was granted. Circulation note \(i).", "note-\(i).txt")
        }
        #expect(try await rig.entities.count(of: .identifierAnchor) == 1, "twelve mentions must resolve to ONE anchor")
        let patentFacts = try await rig.facts.all(pageSize: 5_000)
            .filter { $0.field == "patentnumber" }
        #expect(patentFacts.count >= 12, "expected a patent fact per source, got \(patentFacts.count)")
        let subjects = Set(patentFacts.compactMap(\.subjectID))
        #expect(subjects.count == 1, "twelve sources' facts must all bind to the ONE anchor")
    }

    @Test("Anchor coincidence live: same digits under two fields → TWO anchors, never cross-threaded")
    @MainActor
    func anchorCoincidenceLive() async throws {
        let rig = try await makeRig()
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        try await ingest(rig, "Patent No. 555489 was hereby granted. Application No. 555489 was filed at your office on 11 March 2023.", "coincidence.txt")
        #expect(try await rig.entities.count(of: .identifierAnchor) == 2, "patent 555489 and application 555489 are two anchors")
        let anchors = try await rig.entities.allAnchors()
        let keys = Set(anchors.compactMap(\.normalizedValue))
        #expect(keys.contains("patentnumber|555489"))
        #expect(keys.contains("applicationnumber|555489"))
    }

    @Test("\"Nil Nil\" neither survives as a person nor folds into a real name")
    @MainActor
    func nilNilNeitherSurvivesNorFolds() async throws {
        let rig = try await makeRig()
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        try await ingest(rig, """
        From: Nil Nil <nil.nil@example.com>
        To: Shabana Khan <s.khan@example.com>
        Subject: Status

        Body about the matter.
        """, "nil.eml")
        let people = try await rig.db.query("SELECT value FROM entities WHERE kind = 'person'", [])
            .compactMap { $0.string(0) }
        #expect(!people.contains { $0.lowercased() == "nil nil" }, "Nil Nil survived as a person")
        // It never became a variant OF anyone either — no person value contains "nil nil".
        #expect(!people.contains { $0.lowercased().contains("nil nil") })
    }

    @Test("Milestone chain threads onto ONE anchor entity id; a coincident invoice anchor is never threaded")
    @MainActor
    func milestoneChainThreadsOneAnchor() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("f2m-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        let fileID = UUID(), ko = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?, ?, ?);", [.uuid(fileID), .text("file:///m"), .text("text")])
        try await db.exec("INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?, ?, ?, ?, 0, 0);",
                          [.uuid(ko), .uuid(fileID), .text("text"), .text("m")])
        let entities = EntitiesRepository(database: db)
        let gen = NoiseFixtureGenerator()
        let patentAnchor = try await entities.resolveOrCreateAnchor(field: "patentNumber", value: gen.patentNumber, sourceObjectID: ko)
        let invoiceAnchor = try await entities.resolveOrCreateAnchor(field: "invoiceNumber", value: gen.patentNumber, sourceObjectID: ko)

        // A real grant letter — its "date of grant"/"date of filing" phrasings are
        // what PatentLegalEventExtractor recognizes.
        let milestones = PatentLegalEventExtractor.extract(text: gen.noisyGrantLetter, sourceObjectID: ko, entityIDs: [patentAnchor])
        #expect(!milestones.isEmpty, "no milestones extracted from the patent letter")
        for m in milestones {
            #expect(m.entityIDs.contains(patentAnchor), "milestone \(m.kind) did not thread the patent anchor")
            #expect(!m.entityIDs.contains(invoiceAnchor), "patent milestone cross-threaded the coincident invoice anchor")
        }
    }

    // MARK: - Surname OCR fold (explainable substitution, never similarity)

    @Test("Sasmal/Sasrnal folds as person (rn↔m explains it); Nair/Singh + Sharma/Verma never fold")
    func surnameOCRFold() {
        // The mechanism: an explainable letter-group substitution.
        #expect(NameOCRConfusion.surnameExplainable("sasmal", "sasrnal"), "rn↔m must explain Sasmal/Sasrnal")
        #expect(NameOCRConfusion.surnameExplainable("david", "davicl"), "cl↔d must explain David/Davicl")
        #expect(!NameOCRConfusion.surnameExplainable("nair", "singh"))
        #expect(!NameOCRConfusion.surnameExplainable("sharma", "verma"))

        // The reconciler predicate: given name exact + explainable surname; the
        // impostors never fold even though they share a given name.
        #expect(AppState.plausibleOCRVariant(winner: "shirshendu sasmal", loser: "shirshendu sasrnal"))
        #expect(!AppState.plausibleOCRVariant(winner: "priya nair", loser: "priya singh"))
        #expect(!AppState.plausibleOCRVariant(winner: "anil sharma", loser: "anil verma"))
        // Different given name never folds even with an explainable surname.
        #expect(!AppState.plausibleOCRVariant(winner: "shirshendu sasmal", loser: "rakesh sasrnal"))
    }
}
