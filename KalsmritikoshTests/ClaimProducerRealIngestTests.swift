//
//  ClaimProducerRealIngestTests.swift
//  KalsmritikoshTests
//
//  PA-PROD B6 — end-to-end through a REAL IngestCoordinator (not hand-seeded rows). Proves the
//  production identity path: ingest persists structural blocks + block→object ownership; the
//  producer projects Claims whose EvidenceReference.objectID is always a genuine knowledge_objects
//  row (never a file id); and a workspace over the ingested file assembles a NON-EMPTY, valid
//  registry-backed generalSummary.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PA-PROD B6 — real IngestCoordinator → non-empty generalSummary")
struct ClaimProducerRealIngestTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("A real ingest yields Claims with canonical object evidence and a non-empty generalSummary")
    @MainActor
    func realIngestProducesNonEmptySummary() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("b6-ingest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)

        let files = FilesRepository(database: db)
        let objects = KnowledgeObjectRepository(database: db)
        let chunks = ChunksRepository(database: db)
        let entities = EntitiesRepository(database: db)
        let events = EventsRepository(database: db)
        let genericFacts = GenericFactRepository(database: db)
        let assertions = AssertionsRepository(database: db)
        let temporalClaims = TemporalClaimRepository(database: db)
        let claims = ClaimRepository(database: db)
        let store = EvidenceStore(database: db)
        let workspaces = WorkspaceRepository(database: db)

        let coordinator = IngestCoordinator(
            universalRegistry: try UniversalParserRegistryBuilder.standard(ocr: VisionOCR()),
            entityExtractor: NLEntityExtractor(),
            entityLinker: EntityLinker(),
            eventExtractor: RuleEventExtractor(),
            files: files, objects: objects, chunks: chunks,
            entities: entities, events: events,
            evidenceStore: store,
                        assertions: assertions,
            genericFacts: genericFacts,
            intakeCoordinator: UniversalSourceIntakeCoordinator(repository: CanonicalSourceIntakeRepository(database: db)))

        // A real email — the product's primary input. The structured From/To header yields
        // canonical entities (with mentions → workspace membership) and the rule event extractor's
        // email path produces a header-dated event whose participants are those correspondents, so
        // there is a genuine subject-scoped Claim to select.
        let fileURL = dir.appendingPathComponent("matter.eml")
        try """
        From: Alexandra Rivera <alex@orchidlabs.example>
        To: Legal Team <legal@orchidlabs.example>
        Subject: Orchid Labs services agreement
        Date: Mon, 3 Mar 2025 09:12:00 +0000

        I have signed the Orchid Labs services agreement today, 3 March 2025.
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let result = try await coordinator.ingest(fileAt: fileURL)
        #expect(result.chunkCount > 0)

        // B6 invariant: ownership links were persisted for the ingested blocks.
        let ownershipCount = try await db.query("SELECT COUNT(*) FROM evidence_block_objects;").first?.int(0) ?? 0
        #expect(ownershipCount > 0)

        // Project the ledger into Claims (the boot backfill's work, run inline here).
        let producer = ClaimProducer(genericFacts: genericFacts, assertions: assertions,
                                     temporalClaims: temporalClaims, events: events, claims: claims, evidence: store)
        _ = try await producer.backfill(at: t0)

        // Every persisted EvidenceReference.objectID must be a real knowledge_objects row (never a
        // file id). Verify across ALL produced claims.
        let allClaimRows = try await db.query("SELECT DISTINCT knowledge_object_id FROM claim_evidence_ref;")
        for row in allClaimRows {
            let objID = try #require(row.uuid(0))
            #expect(try await store.knowledgeObjectExists(objID), "evidence objectID must be a real KnowledgeObject")
        }

        // A workspace over the ingested file assembles a NON-EMPTY, valid generalSummary.
        let wsID = UUID()
        try await workspaces.upsert(Workspace(id: wsID, title: "Matter", template: .general))
        try await workspaces.addSource(result.fileRecord.id, to: wsID)
        let deriver = WorkspaceMembershipDeriver(database: db, workspaces: workspaces)
        try await deriver.deriveMembership(for: wsID)

        let assembly = try WorkProductAssemblyService(
            database: db, events: events,
            contradictions: ContradictionsRepository(database: db),
            gaps: GapNodeRepository(database: db), workspaces: workspaces)
        let assembled = try await assembly.compose(
            workspace: Workspace(id: wsID, title: "Matter", template: .general),
            template: .generalSummary, subjectLabel: "Matter", corpusSnapshotID: nil,
            access: SensitiveAccessContext(scope: SensitiveScope(
                workspaceID: wsID, maximumSensitivity: .restricted,
                permitsPrivilegedMaterial: false, purpose: .export)))

        #expect(assembled.manifest.selectedFindingCount >= 1)                 // real data, not empty
        #expect(assembled.workProduct.sections.flatMap(\.claims).isEmpty == false)
        #expect(WorkProductValidator().validateProductionExport(assembled.workProduct).isValid)
    }
}
