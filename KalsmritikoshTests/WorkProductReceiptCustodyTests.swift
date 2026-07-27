//
//  WorkProductReceiptCustodyTests.swift
//  KalsmritikoshTests
//
//  PA-REC-001 — work-product receipts pinned to the EXACT cited source version's custody hash.
//  Proves: assembled citations carry the source-version content hash (normalized SHA-256); the
//  manifest counts one hash per version (dedup across summary/chronology); the receipt embeds and
//  verifies the hash and breaks on tamper; a citation to an OLD version keeps that version's hash
//  after a newer version becomes current (current file hash never overwrites it); and a material
//  citation with no recorded version hash blocks the receipt while a reopenable normal report
//  still exports.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PA-REC-001 — receipt custody-hash binding")
struct WorkProductReceiptCustodyTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func hex(_ c: Character) -> String { String(repeating: c, count: 64) }

    private struct Rig {
        let db: Database
        let files: FilesRepository
        let workspaces: WorkspaceRepository
        let membership: WorkspaceMembershipDeriver
        let genericFacts: GenericFactRepository
        let producer: ClaimProducer
        let assembly: WorkProductAssemblyService
    }

    private func rig() async throws -> Rig {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rec-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        let files = FilesRepository(database: db)
        let workspaces = WorkspaceRepository(database: db)
        let gf = GenericFactRepository(database: db)
        let asrt = AssertionsRepository(database: db)
        let tcs = TemporalClaimRepository(database: db)
        let events = EventsRepository(database: db)
        let claims = ClaimRepository(database: db)
        let store = EvidenceStore(database: db)
        let membership = WorkspaceMembershipDeriver(database: db, workspaces: workspaces)
        let producer = ClaimProducer(genericFacts: gf, assertions: asrt, temporalClaims: tcs, events: events, claims: claims, evidence: store)
        let assembly = try WorkProductAssemblyService(
            database: db, events: events, contradictions: ContradictionsRepository(database: db),
            gaps: GapNodeRepository(database: db), workspaces: workspaces)
        return Rig(db: db, files: files, workspaces: workspaces, membership: membership,
                   genericFacts: gf, producer: producer, assembly: assembly)
    }

    /// file + KO + subject(+mention) + a workspace whose source is that file. Returns the pieces.
    private func seedWorkspaceSubject(_ r: Rig) async throws -> (file: UUID, ko: UUID, subject: UUID, ws: Workspace.ID) {
        let file = UUID(), ko = UUID(), subject = UUID()
        try await r.files.upsert(FileRecord(id: file, url: URL(fileURLWithPath: "/rec/\(file).txt"),
                                            sourceType: .txt, ingestedAt: t0, contentHash: hex("f")))
        try await r.db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);
        """, [.uuid(ko), .uuid(file), .text("txt"), .text("c"), .real(0), .real(0)])
        try await r.db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);",
                            [.uuid(subject), .text("person"), .text("S"), .text(subject.uuidString.lowercased()), .uuid(ko)])
        try await r.db.exec("""
        INSERT INTO entity_mentions (id, entity_id, kind, surface, normalized, source_object_id, confidence)
        VALUES (?,?,?,?,?,?,?);
        """, [.uuid(UUID()), .uuid(subject), .text("person"), .text("S"),
              .text(subject.uuidString.lowercased() + "-m"), .uuid(ko), .real(1.0)])
        let ws = UUID()
        try await r.workspaces.upsert(Workspace(id: ws, title: "WS", template: .general))
        try await r.workspaces.addSource(file, to: ws)
        return (file, ko, subject, ws)
    }

    /// A reopenable GenericFact citing a specific source version (logical = file) with a chosen
    /// content hash + current flag. Returns the source-version id.
    @discardableResult
    private func seedFact(_ r: Rig, file: UUID, ko: UUID, subject: UUID,
                          versionHash: String, isCurrent: Bool = true, value: String = "did the thing") async throws -> UUID {
        let sv = UUID(), block = UUID(), doc = UUID()
        try await r.db.exec("""
        INSERT INTO source_versions (id, logical_source_id, document_id, content_hash, valid_from, is_current, created_at)
        VALUES (?,?,?,?,?,?,?);
        """, [.uuid(sv), .uuid(file), .uuid(doc), .text(versionHash), .real(0), .integer(isCurrent ? 1 : 0), .real(0)])
        try await r.db.exec("""
        INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text, extraction_method, extraction_confidence)
        VALUES (?,?,?,?,?,?,?,?,?);
        """, [.uuid(block), .uuid(doc), .uuid(sv), .integer(0), .text("paragraph"), .text("t"), .text("t"), .text("native"), .real(1.0)])
        try await r.db.exec("""
        INSERT INTO evidence_block_objects (evidence_block_id, knowledge_object_id, linked_at) VALUES (?,?,?);
        """, [.uuid(block), .uuid(ko), .real(0)])
        try await r.genericFacts.upsert(GenericFact(
            subjectID: subject, subjectLabel: "S", field: "event", value: value,
            assessment: EvidenceAssessment(basis: .directlyObserved, origin: .sourceExtraction),
            confidence: 0.9, sourceBlockIDs: [block]))
        return sv
    }

    private func compose(_ r: Rig, _ ws: Workspace.ID) async throws -> AssembledWorkProduct {
        try await r.membership.deriveMembership(for: ws)
        _ = try await r.producer.backfill(at: t0)
        return try await r.assembly.compose(
            workspace: Workspace(id: ws, title: "WS", template: .general),
            template: .generalSummary, subjectLabel: "WS", corpusSnapshotID: nil,
            access: SensitiveAccessContext(scope: SensitiveScope(
                workspaceID: ws, maximumSensitivity: .restricted,
                permitsPrivilegedMaterial: false, purpose: .export)))
    }

    private func materialCitations(_ a: AssembledWorkProduct) -> [CitationRecord] {
        a.workProduct.sections.flatMap(\.claims).flatMap(\.supporting)
    }

    // MARK: - Hash populated + manifest

    @Test("Assembled citations carry the exact source-version custody hash and the manifest records it once")
    func custodyHashPopulatedAndCountedOnce() async throws {
        let r = try await rig()
        let s = try await seedWorkspaceSubject(r)
        let sv = try await seedFact(r, file: s.file, ko: s.ko, subject: s.subject, versionHash: hex("a"))
        let assembled = try await compose(r, s.ws)

        let cites = materialCitations(assembled).filter { $0.sourceVersionID == sv }
        #expect(cites.isEmpty == false)
        #expect(cites.allSatisfy { $0.sourceHash == hex("a") })                 // exact version hash
        #expect(cites.allSatisfy { EvidenceStore.normalizedSHA256($0.sourceHash ?? "") == hex("a") })  // normalized 64-hex
        // Rendered in both Sourced summary and Chronology → one recorded hash, not per-occurrence.
        #expect(cites.count >= 2)
        #expect(assembled.manifest.sourceHashes == [hex("a")])
        #expect(assembled.manifest.sourceVersionIDs == [sv.uuidString])
    }

    // MARK: - Receipt embeds + verifies + tamper

    @Test("The receipt embeds the custody hash, verifies, and breaks on tamper")
    func receiptEmbedsVerifiesAndTamper() async throws {
        let r = try await rig()
        let s = try await seedWorkspaceSubject(r)
        _ = try await seedFact(r, file: s.file, ko: s.ko, subject: s.subject, versionHash: hex("b"))
        let assembled = try await compose(r, s.ws)

        let sealed = try WorkProductReceiptBuilder().build(from: assembled)
        #expect(VerifiableReceipt.verify(sealed) == true)
        let json = VerifiableReceipt.json(sealed)
        #expect(json.contains("sha256:\(hex("b"))"))
        #expect(!json.contains("(unresolved)"))

        // Tamper an entry's passage → chain no longer verifies.
        guard let first = sealed.entries.first else { Issue.record("no entries"); return }
        let tampered = SealedReceipt(title: sealed.title, entries:
            [SealedReceiptEntry(index: first.index, claim: first.claim, source: first.source, date: first.date,
                                passage: first.passage + " (altered)", passageHash: first.passageHash, chainHash: first.chainHash)]
            + sealed.entries.dropFirst())
        #expect(VerifiableReceipt.verify(tampered) == false)
    }

    // MARK: - Old version retains its hash

    @Test("A citation to an older source version keeps that version's hash after a newer one becomes current")
    func oldVersionRetainsHash() async throws {
        let r = try await rig()
        let s = try await seedWorkspaceSubject(r)
        // The fact cites the OLD version (H_old, now retired). A NEWER version is current (H_new),
        // and the file's current content hash is different again — none may overwrite H_old.
        let oldSV = try await seedFact(r, file: s.file, ko: s.ko, subject: s.subject, versionHash: hex("1"), isCurrent: false)
        try await r.db.exec("""
        INSERT INTO source_versions (id, logical_source_id, document_id, content_hash, valid_from, is_current, created_at)
        VALUES (?,?,?,?,?,1,?);
        """, [.uuid(UUID()), .uuid(s.file), .uuid(UUID()), .text(hex("2")), .real(1), .real(1)])
        try await r.files.updateURL(id: s.file, to: URL(fileURLWithPath: "/rec/\(s.file).txt"))  // touch; current hash stays hex("f")

        let assembled = try await compose(r, s.ws)
        let cites = materialCitations(assembled).filter { $0.sourceVersionID == oldSV }
        #expect(cites.isEmpty == false)
        #expect(cites.allSatisfy { $0.sourceHash == hex("1") })                 // OLD version's hash, not hex("2")/hex("f")
        #expect(assembled.manifest.sourceHashes == [hex("1")])
    }

    // MARK: - Missing hash: blocks receipt, not the normal report

    @Test("A material citation with no recorded version hash blocks the receipt but not a reopenable report")
    func missingHashBlocksReceiptNotReport() async throws {
        let r = try await rig()
        let s = try await seedWorkspaceSubject(r)
        // Reopenable (has a source version) but the version's content hash is blank → no custody hash.
        _ = try await seedFact(r, file: s.file, ko: s.ko, subject: s.subject, versionHash: "")
        let assembled = try await compose(r, s.ws)

        // The normal report still composes and validates (citation reopens via sourceVersionID).
        #expect(assembled.manifest.selectedFindingCount >= 1)
        #expect(WorkProductValidator().validateProductionExport(assembled.workProduct).isValid)
        #expect(materialCitations(assembled).contains { $0.sourceVersionID != nil && $0.sourceHash == nil })

        // …but the custody-pinned receipt fails closed.
        #expect(throws: WorkProductReceiptError.missingCustodyHashes(count: 1)) {
            try WorkProductReceiptBuilder().build(from: assembled)
        }
    }

    // MARK: - Real ingest

    @Test("A real .eml export carries exact-version custody hashes and a verifying receipt")
    @MainActor
    func realEmailCustodyHashes() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rec-eml-\(UUID().uuidString)", isDirectory: true)
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
        _ = try await producer.backfill(at: t0)

        let wsID = UUID()
        try await workspaces.upsert(Workspace(id: wsID, title: "Matter", template: .general))
        try await workspaces.addSource(result.fileRecord.id, to: wsID)
        try await membership.deriveMembership(for: wsID)

        let assembly = try WorkProductAssemblyService(
            database: db, events: events, contradictions: ContradictionsRepository(database: db),
            gaps: GapNodeRepository(database: db), workspaces: workspaces)
        let assembled = try await assembly.compose(
            workspace: Workspace(id: wsID, title: "Matter", template: .general),
            template: .generalSummary, subjectLabel: "Matter", corpusSnapshotID: nil,
            access: SensitiveAccessContext(scope: SensitiveScope(
                workspaceID: wsID, maximumSensitivity: .restricted,
                permitsPrivilegedMaterial: false, purpose: .export)))

        // Every material citation has a normalized 64-char hash equal to its source_versions row.
        let cited = assembled.workProduct.sections.flatMap(\.claims).flatMap(\.supporting).filter { $0.sourceVersionID != nil }
        #expect(cited.isEmpty == false)
        for c in cited {
            let h = try #require(c.sourceHash)
            #expect(EvidenceStore.normalizedSHA256(h) == h)
            let expected = try await store.contentHashes(forSourceVersionIDs: [c.sourceVersionID!])[c.sourceVersionID!]
            #expect(h == expected)
        }
        #expect(assembled.manifest.sourceHashes.isEmpty == false)
        let sealed = try WorkProductReceiptBuilder().build(from: assembled)
        #expect(VerifiableReceipt.verify(sealed) == true)
        #expect(VerifiableReceipt.json(sealed).contains("sha256:"))
    }
}
