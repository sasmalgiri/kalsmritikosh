//
//  WorkspaceSourceCoordinatorTests.swift
//  KalsmritikoshTests
//
//  PA-UI-001 — the workspace source-management service. Proves candidate eligibility, add/remove
//  behaviour, projection + membership reconciliation, the preserve-not-delete contract on removal,
//  cross-workspace reuse, and the B4 boundary updating as sources change. One integration test
//  drives a real IngestCoordinator .eml so adding a source enables a non-empty General Summary.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PA-UI-001 — workspace source management")
struct WorkspaceSourceCoordinatorTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Rig {
        let db: Database
        let files: FilesRepository
        let objects: KnowledgeObjectRepository
        let workspaces: WorkspaceRepository
        let membership: WorkspaceMembershipDeriver
        let genericFacts: GenericFactRepository
        let claims: ClaimRepository
        let store: EvidenceStore
        let events: EventsRepository
        let coordinator: WorkspaceSourceCoordinator
        let assembly: WorkProductAssemblyService
    }

    private func rig() async throws -> Rig {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wsrc-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        let files = FilesRepository(database: db)
        let objects = KnowledgeObjectRepository(database: db)
        let workspaces = WorkspaceRepository(database: db)
        let gf = GenericFactRepository(database: db)
        let asrt = AssertionsRepository(database: db)
        let tcs = TemporalClaimRepository(database: db)
        let events = EventsRepository(database: db)
        let claims = ClaimRepository(database: db)
        let store = EvidenceStore(database: db)
        let membership = WorkspaceMembershipDeriver(database: db, workspaces: workspaces)
        let producer = ClaimProducer(genericFacts: gf, assertions: asrt, temporalClaims: tcs,
                                     events: events, claims: claims, evidence: store)
        let projection = ClaimProjectionBackfill(producer: producer, progress: ClaimProjectionProgressRepository(database: db),
                                                 membership: membership, genericFacts: gf, temporalClaims: tcs,
                                                 assertions: asrt, events: events)
        let coordinator = WorkspaceSourceCoordinator(files: files, objects: objects, workspaces: workspaces,
                                                     membership: membership, projection: projection)
        let assembly = try WorkProductAssemblyService(
            database: db, events: events, contradictions: ContradictionsRepository(database: db),
            gaps: GapNodeRepository(database: db), workspaces: workspaces)
        return Rig(db: db, files: files, objects: objects, workspaces: workspaces, membership: membership,
                   genericFacts: gf, claims: claims, store: store, events: events,
                   coordinator: coordinator, assembly: assembly)
    }

    // MARK: - Seeding

    @discardableResult
    private func seedFile(_ r: Rig, aliasOf: UUID? = nil, availability: FileAvailability = .available,
                          ingested: Bool = true, sourceType: SourceType = .txt) async throws -> UUID {
        let id = UUID()
        try await r.files.upsert(FileRecord(
            id: id, url: URL(fileURLWithPath: "/pa-ui/\(id).txt"), sourceType: sourceType,
            ingestedAt: ingested ? t0 : nil, aliasOf: aliasOf, availability: availability))
        return id
    }

    private func seedKO(_ r: Rig, file: UUID) async throws -> UUID {
        let ko = UUID()
        try await r.db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);
        """, [.uuid(ko), .uuid(file), .text("txt"), .text("c"), .real(0), .real(0)])
        return ko
    }

    private func seedSubjectMention(_ r: Rig, subject: UUID, ko: UUID) async throws {
        try await r.db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);",
                            [.uuid(subject), .text("person"), .text("S"), .text(subject.uuidString.lowercased()), .uuid(ko)])
        try await seedMention(r, subject: subject, ko: ko)
    }

    /// An additional mention of an ALREADY-seeded entity in another KO (no new entity row).
    private func seedMention(_ r: Rig, subject: UUID, ko: UUID) async throws {
        try await r.db.exec("""
        INSERT INTO entity_mentions (id, entity_id, kind, surface, normalized, source_object_id, confidence)
        VALUES (?,?,?,?,?,?,?);
        """, [.uuid(UUID()), .uuid(subject), .text("person"), .text("S"),
              .text(subject.uuidString.lowercased() + "-\(ko.uuidString.prefix(6))"), .uuid(ko), .real(1.0)])
    }

    /// A reopenable, subject-scoped GenericFact owned by `file`/`ko` (production identity shape).
    private func seedReopenableFact(_ r: Rig, file: UUID, ko: UUID, subject: UUID) async throws {
        let sv = UUID(), block = UUID(), doc = UUID()
        try await r.db.exec("""
        INSERT INTO source_versions (id, logical_source_id, document_id, content_hash, valid_from, is_current, created_at)
        VALUES (?,?,?,?,?,1,?);
        """, [.uuid(sv), .uuid(file), .uuid(doc), .text("h"), .real(0), .real(0)])
        try await r.db.exec("""
        INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text, extraction_method, extraction_confidence)
        VALUES (?,?,?,?,?,?,?,?,?);
        """, [.uuid(block), .uuid(doc), .uuid(sv), .integer(0), .text("paragraph"), .text("t"), .text("t"), .text("native"), .real(1.0)])
        try await r.db.exec("""
        INSERT INTO evidence_block_objects (evidence_block_id, knowledge_object_id, linked_at) VALUES (?,?,?);
        """, [.uuid(block), .uuid(ko), .real(0)])
        try await r.genericFacts.upsert(GenericFact(
            subjectID: subject, subjectLabel: "S", field: "event", value: "did the thing",
            assessment: EvidenceAssessment(basis: .directlyObserved, origin: .sourceExtraction),
            confidence: 0.9, sourceBlockIDs: [block]))
    }

    private func workspace(_ r: Rig) async throws -> Workspace.ID {
        let id = UUID()
        try await r.workspaces.upsert(Workspace(id: id, title: "WS", template: .general))
        return id
    }

    private func summaryFindingCount(_ r: Rig, _ wsID: Workspace.ID) async throws -> Int {
        let assembled = try await r.assembly.compose(
            workspace: Workspace(id: wsID, title: "WS", template: .general),
            template: .generalSummary, subjectLabel: "WS", corpusSnapshotID: nil,
            access: SensitiveAccessContext(scope: SensitiveScope(
                workspaceID: wsID, maximumSensitivity: .restricted,
                permitsPrivilegedMaterial: false, purpose: .export)))
        return assembled.manifest.selectedFindingCount
    }

    // MARK: - Candidate eligibility

    @Test("Candidates exclude alias rows, un-ingested rows, and files already in the workspace")
    func candidateEligibility() async throws {
        let r = try await rig()
        let ws = try await workspace(r)
        let ingested = try await seedFile(r); _ = try await seedKO(r, file: ingested)     // eligible
        let alias = try await seedFile(r, aliasOf: ingested); _ = try await seedKO(r, file: alias) // alias → excluded
        _ = try await seedFile(r, ingested: false)                                        // no KO → excluded
        let already = try await seedFile(r); _ = try await seedKO(r, file: already)
        try await r.workspaces.addSource(already, to: ws)                                 // already in ws → excluded

        let ids = try await r.coordinator.candidates(for: ws).map(\.fileID)
        #expect(ids == [ingested])
    }

    @Test("Candidate availability is preserved for display and ordering puts available first")
    func availabilityPreservedAndOrdered() async throws {
        let r = try await rig()
        let ws = try await workspace(r)
        let offline = try await seedFile(r, availability: .offlineRoot); _ = try await seedKO(r, file: offline)
        let available = try await seedFile(r, availability: .available); _ = try await seedKO(r, file: available)
        let cands = try await r.coordinator.candidates(for: ws)
        #expect(cands.first?.fileID == available)                       // available before offline
        #expect(cands.first?.availability == .available)
        #expect(cands.contains { $0.fileID == offline && $0.availability == .offlineRoot })
    }

    // MARK: - Add / membership / boundary

    @Test("Adding a source derives its subject, enables a non-empty summary, and is idempotent")
    func addDerivesAndEnables() async throws {
        let r = try await rig()
        let ws = try await workspace(r)
        let file = try await seedFile(r), ko = try await seedKO(r, file: file), subject = UUID()
        try await seedSubjectMention(r, subject: subject, ko: ko)
        try await seedReopenableFact(r, file: file, ko: ko, subject: subject)

        #expect(try await summaryFindingCount(r, ws) == 0)              // empty before

        try await r.coordinator.addSources([file], to: ws, at: t0)
        #expect(try await r.workspaces.entityIDs(in: ws) == [subject])  // derived member
        #expect(try await summaryFindingCount(r, ws) >= 1)              // now non-empty (B4 admits)
        #expect(try await r.coordinator.currentSources(in: ws).map(\.fileID) == [file])

        // Idempotent: re-adding the same file changes nothing.
        try await r.coordinator.addSources([file], to: ws, at: t0.addingTimeInterval(10))
        #expect(try await r.workspaces.sourceIDs(in: ws) == [file])
    }

    @Test("Adding only an unrelated source keeps an outside-file Claim excluded (B4 boundary honored)")
    func outOfScopeSourceStaysExcluded() async throws {
        let r = try await rig()
        let ws = try await workspace(r)
        // The subject's evidence is owned by fileA, and the subject is mentioned in BOTH files.
        let fileA = try await seedFile(r), koA = try await seedKO(r, file: fileA)
        let fileB = try await seedFile(r), koB = try await seedKO(r, file: fileB)
        let subject = UUID()
        try await seedSubjectMention(r, subject: subject, ko: koA)                // entity + mention in A
        try await seedMention(r, subject: subject, ko: koB)                       // also mentioned in B
        try await seedReopenableFact(r, file: fileA, ko: koA, subject: subject)   // evidence in A only

        try await r.coordinator.addSources([fileB], to: ws, at: t0)               // add only B
        #expect(try await r.workspaces.entityIDs(in: ws) == [subject])            // subject IS a member (mentioned in B)
        #expect(try await summaryFindingCount(r, ws) == 0)                        // …but its A-evidence claim is out of scope
        try await r.coordinator.addSources([fileA], to: ws, at: t0)               // now add A
        #expect(try await summaryFindingCount(r, ws) >= 1)                        // boundary now admits it
    }

    // MARK: - Remove / preserve-not-delete

    @Test("Removing a source drops its derived entities, empties the report, but deletes nothing")
    func removePreservesEverything() async throws {
        let r = try await rig()
        let ws = try await workspace(r)
        let file = try await seedFile(r), ko = try await seedKO(r, file: file), subject = UUID()
        try await seedSubjectMention(r, subject: subject, ko: ko)
        try await seedReopenableFact(r, file: file, ko: ko, subject: subject)
        try await r.coordinator.addSources([file], to: ws, at: t0)
        let claimsBefore = try await r.claims.count()
        #expect(claimsBefore >= 1)

        try await r.coordinator.removeSource(file, from: ws, at: t0)
        #expect(try await r.workspaces.sourceIDs(in: ws).isEmpty)
        #expect(try await r.workspaces.entityIDs(in: ws).isEmpty)                  // derived dropped
        #expect(try await summaryFindingCount(r, ws) == 0)                         // gone from the report
        // …but the file, its KO, and the canonical Claims all remain in the archive.
        #expect(try await r.files.all().contains { $0.id == file })
        #expect(try await r.objects.fileIDsWithObjects().contains(file))   // KO for `file` still present
        #expect(try await r.claims.count() == claimsBefore)
    }

    @Test("A manually-added entity survives derived-membership reconciliation on source removal")
    func manualEntitySurvivesRemoval() async throws {
        let r = try await rig()
        let ws = try await workspace(r)
        let file = try await seedFile(r), ko = try await seedKO(r, file: file), subject = UUID()
        try await seedSubjectMention(r, subject: subject, ko: ko)
        try await seedReopenableFact(r, file: file, ko: ko, subject: subject)
        // A manual member, seeded as a bare entity (exists for the FK; not occurrence-linked).
        let manual = UUID(); let mFile = try await seedFile(r); let mKO = try await seedKO(r, file: mFile)
        try await r.db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);",
                            [.uuid(manual), .text("person"), .text("M"), .text(manual.uuidString.lowercased()), .uuid(mKO)])
        try await r.workspaces.addEntity(manual, to: ws)

        try await r.coordinator.addSources([file], to: ws, at: t0)
        #expect(Set(try await r.workspaces.entityIDs(in: ws)) == [manual, subject])
        try await r.coordinator.removeSource(file, from: ws, at: t0)
        #expect(try await r.workspaces.entityIDs(in: ws) == [manual])              // manual survives
    }

    @Test("The same source stays usable in another workspace after removal from one")
    func sameSourceInAnotherWorkspace() async throws {
        let r = try await rig()
        let wsA = try await workspace(r), wsB = try await workspace(r)
        let file = try await seedFile(r), ko = try await seedKO(r, file: file), subject = UUID()
        try await seedSubjectMention(r, subject: subject, ko: ko)
        try await seedReopenableFact(r, file: file, ko: ko, subject: subject)
        try await r.coordinator.addSources([file], to: wsA, at: t0)
        try await r.coordinator.addSources([file], to: wsB, at: t0)
        #expect(try await summaryFindingCount(r, wsA) >= 1)
        #expect(try await summaryFindingCount(r, wsB) >= 1)

        try await r.coordinator.removeSource(file, from: wsA, at: t0)
        #expect(try await summaryFindingCount(r, wsA) == 0)                        // gone from A
        #expect(try await summaryFindingCount(r, wsB) >= 1)                        // still in B
    }

    // MARK: - Validation

    @Test("Adding only ineligible files throws rather than silently succeeding")
    func addIneligibleThrows() async throws {
        let r = try await rig()
        let ws = try await workspace(r)
        let canonical = try await seedFile(r); _ = try await seedKO(r, file: canonical)
        let alias = try await seedFile(r, aliasOf: canonical); _ = try await seedKO(r, file: alias) // alias → ineligible
        let unIngested = try await seedFile(r, ingested: false)                    // no KO → ineligible
        await #expect(throws: WorkspaceSourceError.noEligibleSources) {
            try await r.coordinator.addSources([alias, unIngested], to: ws, at: t0)
        }
    }

    // MARK: - Integration: a real .eml ingest

    @Test("A real ingested .eml added to a workspace derives membership and yields a non-empty summary")
    @MainActor
    func realEmailAddedYieldsSummary() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wsrc-eml-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)

        let files = FilesRepository(database: db), objects = KnowledgeObjectRepository(database: db)
        let chunks = ChunksRepository(database: db), entities = EntitiesRepository(database: db)
        let events = EventsRepository(database: db), gf = GenericFactRepository(database: db)
        let asrt = AssertionsRepository(database: db), tcs = TemporalClaimRepository(database: db)
        let claims = ClaimRepository(database: db), store = EvidenceStore(database: db)
        let workspaces = WorkspaceRepository(database: db)
        let membership = WorkspaceMembershipDeriver(database: db, workspaces: workspaces)
        let producer = ClaimProducer(genericFacts: gf, assertions: asrt, temporalClaims: tcs, events: events, claims: claims, evidence: store)
        let projection = ClaimProjectionBackfill(producer: producer, progress: ClaimProjectionProgressRepository(database: db),
                                                 membership: membership, genericFacts: gf, temporalClaims: tcs, assertions: asrt, events: events)
        let coordinator = WorkspaceSourceCoordinator(files: files, objects: objects, workspaces: workspaces, membership: membership, projection: projection)

        let ingest = IngestCoordinator(
            loaders: .standard(), entityExtractor: NLEntityExtractor(), entityLinker: EntityLinker(),
            eventExtractor: RuleEventExtractor(), files: files, objects: objects, chunks: chunks,
            entities: entities, events: events, evidenceStore: store,
            structuralRegistry: .standard(ocr: VisionOCR()), assertions: asrt, genericFacts: gf)

        let eml = dir.appendingPathComponent("matter.eml")
        try """
        From: Alexandra Rivera <alex@orchidlabs.example>
        To: Legal Team <legal@orchidlabs.example>
        Subject: Orchid Labs services agreement
        Date: Mon, 3 Mar 2025 09:12:00 +0000

        I have signed the Orchid Labs services agreement today, 3 March 2025.
        """.write(to: eml, atomically: true, encoding: .utf8)
        let result = try await ingest.ingest(fileAt: eml)

        let wsID = UUID()
        try await workspaces.upsert(Workspace(id: wsID, title: "Matter", template: .general))
        // The file is a genuine candidate, and adding it through the coordinator populates the workspace.
        #expect(try await coordinator.candidates(for: wsID).contains { $0.fileID == result.fileRecord.id })
        try await coordinator.addSources([result.fileRecord.id], to: wsID, at: t0)
        #expect(try await workspaces.entityIDs(in: wsID).isEmpty == false)

        let assembly = try WorkProductAssemblyService(
            database: db, events: events, contradictions: ContradictionsRepository(database: db),
            gaps: GapNodeRepository(database: db), workspaces: workspaces)
        let assembled = try await assembly.compose(
            workspace: Workspace(id: wsID, title: "Matter", template: .general),
            template: .generalSummary, subjectLabel: "Matter", corpusSnapshotID: nil,
            access: SensitiveAccessContext(scope: SensitiveScope(
                workspaceID: wsID, maximumSensitivity: .restricted,
                permitsPrivilegedMaterial: false, purpose: .export)))
        #expect(assembled.manifest.selectedFindingCount >= 1)
        #expect(WorkProductValidator().validateProductionExport(assembled.workProduct).isValid)
    }
}
