//
//  GenericFactHistoryCitationTests.swift
//  Kalsmritikosh Tests
//
//  S0.5 (foundation correction). A GenericFact carries only EvidenceBlock ids. Before
//  the fix, a HistoryItem projected from a GenericFact-only claim had an EMPTY evidence
//  array (the projector read only `sourceObjectIDs`), violating trust rule 1 — "no
//  history item without provenance" — and failing the chronology composer's
//  `everyRowCited` gate. These tests prove the block→object resolution path end-to-end:
//  persist a block → resolve it → project → cited HistoryItem → cited chronology row →
//  persisted artifact reopens the same evidence.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("S0.5 — GenericFact-only history items carry exact citations")
struct GenericFactHistoryCitationTests {

    private let clock = Date(timeIntervalSince1970: 1_700_000_000)

    private func freshDB() async throws -> Database {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("t.sqlite"))
        try await SchemaMigrations.migrate(db)
        return db
    }

    private func genericFactMaterial(subject: UUID, block: UUID) -> HistoryMaterial {
        let fact = GenericFact(subjectID: subject, subjectLabel: "S", field: "employer",
                               value: "Orchid Chemicals", status: .sourceAsserted, confidence: 0.7,
                               sourceBlockIDs: [block])
        return HistoryMaterial(
            subject: ResolvedHistorySubject(subject: .person(subject), displayName: "S",
                                            canonicalEntityID: subject, resolutionConfidence: 1.0),
            genericFacts: [fact],
            provenance: MaterialProvenance(canonicalEntityID: subject, eventCount: 0, assertionCount: 0,
                genericFactCount: 1, relationshipCount: 0, unscopedSubject: false))
    }

    // MARK: - Projector-level (pure)

    @Test("Without resolution the GenericFact-only item is uncited (the bug); with resolution it is cited")
    func projectionRequiresResolution() {
        let subject = UUID(), block = UUID(), object = UUID(), version = UUID()
        let m = genericFactMaterial(subject: subject, block: block)
        let projector = TemporalEventProjector(now: clock)
        let claims = projector.projectClaims(from: m)
        #expect(claims.count == 1)
        #expect(claims[0].sourceObjectIDs.isEmpty)          // GenericFact carries no object id
        #expect(claims[0].sourceBlockIDs == [block])

        // Pre-fix behaviour (no resolution map): evidence is empty — the defect.
        let uncited = projector.projectItems(from: m, claims: claims)
        #expect(uncited.count == 1)
        #expect(uncited[0].evidence.isEmpty)

        // With the block resolved to its object, the item carries a real citation.
        let resolution = [block: ResolvedEvidenceReference(objectID: object, blockID: block, sourceVersionID: version)]
        let cited = projector.projectItems(from: m, claims: claims, blockResolution: resolution)
        #expect(cited.count == 1)
        let ref = try! #require(cited[0].evidence.first)
        #expect(ref.objectID == object)                     // object resolved
        #expect(ref.blockID == block)                       // block preserved
        #expect(ref.sourceVersionID == version)
    }

    @Test("The chronology row for a GenericFact-only item passes everyRowCited once resolved")
    func chronologyRowCited() {
        let subject = UUID(), block = UUID(), object = UUID()
        let m = genericFactMaterial(subject: subject, block: block)
        let projector = TemporalEventProjector(now: clock)
        let claims = projector.projectClaims(from: m)
        let resolution = [block: ResolvedEvidenceReference(objectID: object, blockID: block)]
        let items = projector.projectItems(from: m, claims: claims, blockResolution: resolution)
        let outline = HistoryOutlineBuilder().build(material: m, items: items, corpusSnapshotID: nil)

        let section = HistoryChronologyComposer().compose(outline: outline)
        #expect(section.rows.count == 1)
        #expect(section.everyRowCited)                      // the citation gate now holds
        #expect(section.rows[0].evidenceObjectIDs == [object])
    }

    // MARK: - DB-backed end-to-end (resolve → project → persist → reopen)

    @Test("A persisted block resolves to its KnowledgeObject, and the artifact reopens the evidence")
    func endToEnd() async throws {
        let db = try await freshDB()
        let store = EvidenceStore(database: db)

        // Persist ONE evidence block (no events, no assertions) under a known object.
        let objectID = UUID(), docID = UUID(), versionID = UUID(), subject = UUID()
        let block = EvidenceBlock(documentID: docID, ordinal: 1, kind: .paragraph,
                                  rawText: "Orchid Chemicals Ltd — Executive Director, 2004.")
        let doc = ParsedDocument(id: docID, logicalSourceID: objectID, sourceVersionID: versionID,
                                 filename: "cv.txt", detectedType: .txt, contentHash: "h", blocks: [block])
        try await store.persist(doc, parser: "txt", parserVersion: "1", startedAt: clock)

        // Block → object resolution (the new repository operation).
        let resolved = try await store.resolveEvidenceBlocks([block.id])
        #expect(resolved.count == 1)
        let r = try #require(resolved.first)
        #expect(r.objectID == objectID)                     // logical_source_id IS the KO id
        #expect(r.blockID == block.id)
        #expect(r.sourceVersionID == versionID)

        // Project a GenericFact-only claim through the resolution → cited item.
        let m = genericFactMaterial(subject: subject, block: block.id)
        let projector = TemporalEventProjector(now: clock)
        let claims = projector.projectClaims(from: m)
        let items = projector.projectItems(from: m, claims: claims,
                                           blockResolution: [r.blockID: r])
        #expect(items.count == 1)
        #expect(items[0].evidence.first?.objectID == objectID)

        // Persist as a history artifact and reopen — the evidence survives round-trip.
        let outline = HistoryOutlineBuilder().build(material: m, items: items, corpusSnapshotID: nil)
        let result = HistoryReconstructionResult(subject: m.subject, outline: outline, claims: claims,
                                                 engineVersion: "history-engine-1", generatedAt: clock)
        let repo = HistoryArtifactRepository(database: db)
        let id = try await repo.save(result, at: clock)
        #expect(try await repo.header(id: id) != nil)
        #expect(try await repo.evidenceCount(itemID: items[0].id) >= 1)   // reopens the citation
    }
}
