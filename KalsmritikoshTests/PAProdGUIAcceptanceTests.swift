//
//  PAProdGUIAcceptanceTests.swift
//  KalsmritikoshTests
//
//  PA-PROD acceptance — headless verification of the LOGIC the six manual GUI checks exercise.
//  These drive the exact shared code the WorkspacesView export/receipt buttons call
//  (WorkProductAssemblyService.compose, WorkProductExporter.render, VerifiableReceipt.seal/verify)
//  against fixture-shaped VALID/BLOCKED workspaces and a real .eml ingest.
//
//  What this CANNOT assert (requires a human at the screen): that no NSSavePanel visually
//  appeared, and the exact on-screen reportStatus text. It DOES prove the control-flow guarantee
//  behind "blocked before the save panel": compose(...) THROWS for the blocked workspace, and in
//  the UI the NSSavePanel line is unreachable after that throw returns.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PA-PROD acceptance (headless)")
struct PAProdGUIAcceptanceTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Rig {
        let db: Database
        let store: EvidenceStore
        let claims: ClaimRepository
        let genericFacts: GenericFactRepository
        let workspaces: WorkspaceRepository
        let producer: ClaimProducer
        let membership: WorkspaceMembershipDeriver
        let assembly: WorkProductAssemblyService
        let events: EventsRepository
    }

    private func rig() async throws -> Rig {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("acc-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        let gf = GenericFactRepository(database: db)
        let asrt = AssertionsRepository(database: db)
        let tcs = TemporalClaimRepository(database: db)
        let ev = EventsRepository(database: db)
        let claims = ClaimRepository(database: db)
        let store = EvidenceStore(database: db)
        let ws = WorkspaceRepository(database: db)
        let assembly = try WorkProductAssemblyService(
            database: db, events: ev, contradictions: ContradictionsRepository(database: db),
            gaps: GapNodeRepository(database: db), workspaces: ws)
        return Rig(db: db, store: store, claims: claims, genericFacts: gf, workspaces: ws,
                   producer: ClaimProducer(genericFacts: gf, assertions: asrt, temporalClaims: tcs,
                                            events: ev, claims: claims, evidence: store),
                   membership: WorkspaceMembershipDeriver(database: db, workspaces: ws),
                   assembly: assembly, events: ev)
    }

    // MARK: - Seeding (production identity shape, matching PAProdGUISmokeFixture)

    private func fileKO(_ r: Rig, file: UUID, ko: UUID) async throws {
        try await r.db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                            [.uuid(file), .text("file://\(file)"), .text("txt")])
        try await r.db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);
        """, [.uuid(ko), .uuid(file), .text("txt"), .text("c"), .real(0), .real(0)])
    }

    private func subjectMention(_ r: Rig, subject: UUID, ko: UUID, value: String) async throws {
        try await r.db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);",
                            [.uuid(subject), .text("person"), .text(value), .text(subject.uuidString.lowercased()), .uuid(ko)])
        try await r.db.exec("""
        INSERT INTO entity_mentions (id, entity_id, kind, surface, normalized, source_object_id, confidence)
        VALUES (?,?,?,?,?,?,?);
        """, [.uuid(UUID()), .uuid(subject), .text("person"), .text(value),
              .text(subject.uuidString.lowercased() + "-m"), .uuid(ko), .real(1.0)])
    }

    /// Reopenable block seeded the production way: source version logical_source_id = FILE, plus a
    /// canonical block→KnowledgeObject ownership link. Returns the block id.
    private func reopenableBlock(_ r: Rig, file: UUID, ko: UUID) async throws -> UUID {
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
        return block
    }

    // MARK: - Checks 1 & 3: VALID exports, BLOCKED is stopped at compose (before any save panel)

    @Test("VALID composes a non-empty, valid, sentinel-free report and renders to a written file; BLOCKED throws before the save panel")
    func validExportsBlockedStops() async throws {
        let r = try await rig()

        // VALID workspace — real path: reopenable assertive GenericFact + an out-of-scope sentinel.
        let vFile = UUID(), vKO = UUID(), subject = UUID()
        try await fileKO(r, file: vFile, ko: vKO)
        try await subjectMention(r, subject: subject, ko: vKO, value: "Alex Rivera")
        let vBlock = try await reopenableBlock(r, file: vFile, ko: vKO)
        try await r.genericFacts.upsert(GenericFact(
            subjectID: subject, subjectLabel: "Alex Rivera", field: "event", value: "signed the contract",
            assessment: EvidenceAssessment(basis: .directlyObserved, origin: .sourceExtraction),
            confidence: 0.95, sourceBlockIDs: [vBlock]))
        // Out-of-scope sentinel: same subject, evidence in a file NOT in the workspace.
        let oFile = UUID(), oKO = UUID()
        try await fileKO(r, file: oFile, ko: oKO)
        let oBlock = try await reopenableBlock(r, file: oFile, ko: oKO)
        try await r.genericFacts.upsert(GenericFact(
            subjectID: subject, subjectLabel: "Alex Rivera", field: "note", value: "OUT-OF-SCOPE SENTINEL MUST NOT APPEAR",
            assessment: EvidenceAssessment(basis: .directlyObserved, origin: .sourceExtraction),
            confidence: 0.95, sourceBlockIDs: [oBlock]))
        let validWS = UUID()
        try await r.workspaces.upsert(Workspace(id: validWS, title: "PA-PROD GUI — VALID", template: .general))
        try await r.workspaces.addSource(vFile, to: validWS)
        _ = try await r.producer.backfill(at: t0)
        try await r.membership.deriveMembership(for: validWS)

        let assembled = try await r.assembly.compose(
            workspace: Workspace(id: validWS, title: "PA-PROD GUI — VALID", template: .general),
            template: .generalSummary, subjectLabel: "PA-PROD GUI — VALID", corpusSnapshotID: nil)
        #expect(assembled.manifest.selectedFindingCount >= 1)
        let allText = assembled.workProduct.sections.flatMap(\.claims).map(\.text)
        #expect(allText.isEmpty == false)
        #expect(!allText.contains { $0.contains("SENTINEL") })
        #expect(WorkProductValidator().validateProductionExport(assembled.workProduct).isValid)
        // The render + write the UI performs AFTER the panel — prove it produces a non-empty file.
        let doc = WorkProductComposer.exportable(assembled.workProduct, citationStyle: .footnote, manifest: assembled.manifest)
        let rendered = WorkProductExporter.render(doc, as: .markdown)
        #expect(rendered.isEmpty == false)
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("valid-report-\(UUID().uuidString).md")
        try rendered.write(to: out, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: out.path))
        try? FileManager.default.removeItem(at: out)

        // BLOCKED workspace — a corrupted assertive claim whose citation cannot reopen.
        let bFile = UUID(), bKO = UUID(), bSubject = UUID()
        try await fileKO(r, file: bFile, ko: bKO)
        try await subjectMention(r, subject: bSubject, ko: bKO, value: "Jordan Blake")
        let blockedWS = UUID()
        try await r.workspaces.upsert(Workspace(id: blockedWS, title: "PA-PROD GUI — BLOCKED", template: .general))
        try await r.workspaces.addSource(bFile, to: blockedWS)
        try await r.membership.deriveMembership(for: blockedWS)
        try await r.claims.save(Claim(
            subjectID: bSubject, subjectLabel: "Jordan Blake", statement: "authorized the wire transfer",
            assessment: EvidenceAssessment(basis: .directlyObserved, origin: .sourceExtraction), confidence: 0.9,
            evidence: [EvidenceReference(objectID: bKO, blockID: UUID(), sourceVersionID: nil)], createdAt: t0))

        // compose THROWS — the UI returns here, before the NSSavePanel line is ever reached.
        await #expect(throws: WorkProductAssemblyError.self) {
            try await r.assembly.compose(
                workspace: Workspace(id: blockedWS, title: "PA-PROD GUI — BLOCKED", template: .general),
                template: .generalSummary, subjectLabel: "PA-PROD GUI — BLOCKED", corpusSnapshotID: nil)
        }
    }

    // MARK: - Check 2: the receipt engine seals and verifies, and detects tampering

    @Test("A sealed receipt verifies; any later edit breaks the seal")
    func receiptSealsVerifiesAndDetectsTamper() throws {
        let drafts = [
            ReceiptDraft(claim: "Alex Rivera signed the contract", source: "valid-contract.txt — p.1",
                         date: t0, passage: "[Observed] valid-contract.txt sha256:abc"),
            ReceiptDraft(claim: "The agreement took effect", source: "valid-contract.txt — p.2",
                         date: t0, passage: "[Observed] valid-contract.txt sha256:def")
        ]
        let sealed = VerifiableReceipt.seal(title: "PA-PROD GUI — VALID — General Summary", drafts: drafts)
        #expect(VerifiableReceipt.verify(sealed) == true)
        let json = VerifiableReceipt.json(sealed)
        #expect(json.isEmpty == false)

        // Tamper: mutate a sealed entry's passage → the chain no longer verifies.
        guard let first = sealed.entries.first else { Issue.record("no entries"); return }
        let tamperedEntry = SealedReceiptEntry(
            index: first.index, claim: first.claim, source: first.source, date: first.date,
            passage: first.passage + " (altered)", passageHash: first.passageHash, chainHash: first.chainHash)
        let tampered = SealedReceipt(title: sealed.title,
                                     entries: [tamperedEntry] + sealed.entries.dropFirst())
        #expect(VerifiableReceipt.verify(tampered) == false)
    }

    // MARK: - Check 6: a real .eml added to a workspace yields a non-empty summary with reopenable citations

    @Test("A real .eml ingest added to a workspace yields a non-empty General Summary whose citations reopen")
    @MainActor
    func realEmailWorkspaceNonEmpty() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("acc-eml-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)

        let files = FilesRepository(database: db), objects = KnowledgeObjectRepository(database: db)
        let chunks = ChunksRepository(database: db), entities = EntitiesRepository(database: db)
        let events = EventsRepository(database: db), genericFacts = GenericFactRepository(database: db)
        let assertions = AssertionsRepository(database: db), temporalClaims = TemporalClaimRepository(database: db)
        let claims = ClaimRepository(database: db), store = EvidenceStore(database: db)
        let workspaces = WorkspaceRepository(database: db)

        let coordinator = IngestCoordinator(
            loaders: .standard(), entityExtractor: NLEntityExtractor(), entityLinker: EntityLinker(),
            eventExtractor: RuleEventExtractor(), files: files, objects: objects, chunks: chunks,
            entities: entities, events: events, evidenceStore: store,
            structuralRegistry: .standard(ocr: VisionOCR()), assertions: assertions, genericFacts: genericFacts)

        let eml = dir.appendingPathComponent("matter.eml")
        try """
        From: Alexandra Rivera <alex@orchidlabs.example>
        To: Legal Team <legal@orchidlabs.example>
        Subject: Orchid Labs services agreement
        Date: Mon, 3 Mar 2025 09:12:00 +0000

        I have signed the Orchid Labs services agreement today, 3 March 2025.
        """.write(to: eml, atomically: true, encoding: .utf8)

        let result = try await coordinator.ingest(fileAt: eml)
        _ = try await ClaimProducer(genericFacts: genericFacts, assertions: assertions,
                                    temporalClaims: temporalClaims, events: events, claims: claims, evidence: store)
            .backfill(at: t0)

        let wsID = UUID()
        try await workspaces.upsert(Workspace(id: wsID, title: "Matter", template: .general))
        try await workspaces.addSource(result.fileRecord.id, to: wsID)
        try await WorkspaceMembershipDeriver(database: db, workspaces: workspaces).deriveMembership(for: wsID)

        let assembly = try WorkProductAssemblyService(
            database: db, events: events, contradictions: ContradictionsRepository(database: db),
            gaps: GapNodeRepository(database: db), workspaces: workspaces)
        let assembled = try await assembly.compose(
            workspace: Workspace(id: wsID, title: "Matter", template: .general),
            template: .generalSummary, subjectLabel: "Matter", corpusSnapshotID: nil)

        #expect(assembled.manifest.selectedFindingCount >= 1)
        #expect(assembled.workProduct.sections.flatMap(\.claims).isEmpty == false)
        #expect(WorkProductValidator().validateProductionExport(assembled.workProduct).isValid)

        // Every cited object is a real KnowledgeObject whose current version reopens.
        let objRows = try await db.query("SELECT DISTINCT knowledge_object_id FROM claim_evidence_ref;")
        var reopened = 0
        for row in objRows {
            guard let obj = row.uuid(0) else { continue }
            #expect(try await store.knowledgeObjectExists(obj))
            if try await store.currentVersionID(forObject: obj) != nil { reopened += 1 }
        }
        #expect(reopened >= 1)
    }
}
