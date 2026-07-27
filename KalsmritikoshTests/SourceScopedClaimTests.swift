//
//  SourceScopedClaimTests.swift
//  KalsmritikoshTests
//
//  PA-DOC-001 — source-scoped Claims for plain documents. A ledger fact with NO entity subject
//  but exact reopenable evidence becomes a Claim anchored (explicitly) to its owning
//  KnowledgeObject, so a workspace built from ordinary documents produces a non-empty report
//  without inventing an entity subject. Entity-scoped claims still require workspace membership;
//  source-scoped claims are selected only when their anchor object is a workspace source; a fact
//  that later gains an entity subject supersedes its source-scoped fallback (no duplicates).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PA-DOC-001 — source-scoped claims")
struct SourceScopedClaimTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func hex(_ c: Character) -> String { String(repeating: c, count: 64) }

    private struct Rig {
        let db: Database
        let files: FilesRepository
        let workspaces: WorkspaceRepository
        let membership: WorkspaceMembershipDeriver
        let genericFacts: GenericFactRepository
        let claims: ClaimRepository
        let producer: ClaimProducer
        let assembly: WorkProductAssemblyService
    }

    private func rig() async throws -> Rig {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("doc-\(UUID().uuidString).sqlite")
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
                   genericFacts: gf, claims: claims, producer: producer, assembly: assembly)
    }

    /// A file + KO + a reopenable block owned by that KO + a GenericFact citing it. When
    /// `subject` is provided, the entity + a mention are seeded too (entity-scoped); when nil the
    /// fact is subject-less (source-scoped). Returns (file, ko, factID).
    @discardableResult
    private func seedDocFact(_ r: Rig, subject: UUID? = nil, value: String,
                             factID: UUID = UUID(), file: UUID = UUID(), ko: UUID = UUID()) async throws -> (file: UUID, ko: UUID, fact: UUID, block: UUID) {
        try await r.files.upsert(FileRecord(id: file, url: URL(fileURLWithPath: "/doc/\(file).txt"),
                                            sourceType: .txt, ingestedAt: t0, contentHash: hex("a")))
        try await r.db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);
        """, [.uuid(ko), .uuid(file), .text("txt"), .text("c"), .real(0), .real(0)])
        let sv = UUID(), block = UUID(), doc = UUID()
        try await r.db.exec("""
        INSERT INTO source_versions (id, logical_source_id, document_id, content_hash, valid_from, is_current, created_at)
        VALUES (?,?,?,?,?,1,?);
        """, [.uuid(sv), .uuid(file), .uuid(doc), .text(hex("a")), .real(0), .real(0)])
        try await r.db.exec("""
        INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text, extraction_method, extraction_confidence)
        VALUES (?,?,?,?,?,?,?,?,?);
        """, [.uuid(block), .uuid(doc), .uuid(sv), .integer(0), .text("paragraph"), .text("t"), .text("t"), .text("native"), .real(1.0)])
        try await r.db.exec("""
        INSERT INTO evidence_block_objects (evidence_block_id, knowledge_object_id, linked_at) VALUES (?,?,?);
        """, [.uuid(block), .uuid(ko), .real(0)])
        if let subject {
            try await r.db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);",
                                [.uuid(subject), .text("person"), .text("S"), .text(subject.uuidString.lowercased()), .uuid(ko)])
            try await r.db.exec("""
            INSERT INTO entity_mentions (id, entity_id, kind, surface, normalized, source_object_id, confidence)
            VALUES (?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(subject), .text("person"), .text("S"),
                  .text(subject.uuidString.lowercased() + "-m"), .uuid(ko), .real(1.0)])
        }
        try await r.genericFacts.upsert(GenericFact(
            id: factID, subjectID: subject, subjectLabel: "Document", field: "event", value: value,
            assessment: EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction),
            confidence: 0.8, sourceBlockIDs: [block]))
        return (file, ko, factID, block)
    }

    private func workspace(_ r: Rig, sources: [UUID]) async throws -> Workspace.ID {
        let ws = UUID()
        try await r.workspaces.upsert(Workspace(id: ws, title: "WS", template: .general))
        for s in sources { try await r.workspaces.addSource(s, to: ws) }
        try await r.membership.deriveMembership(for: ws)
        return ws
    }

    private func compose(_ r: Rig, _ ws: Workspace.ID) async throws -> AssembledWorkProduct {
        let access = SensitiveAccessContext(scope: SensitiveScope(
            workspaceID: ws, maximumSensitivity: .restricted,
            permitsPrivilegedMaterial: false, purpose: .export))
        return try await r.assembly.compose(workspace: Workspace(id: ws, title: "WS", template: .general),
                                            template: .generalSummary, subjectLabel: "WS",
                                            corpusSnapshotID: nil, access: access)
    }

    // MARK: - Source-scoped production + selection

    @Test("A subject-less fact becomes a source-scoped Claim (no fabricated subject) and fills a plain-doc report")
    func sourceScopedProducedAndSelected() async throws {
        let r = try await rig()
        let s = try await seedDocFact(r, subject: nil, value: "signed the agreement")
        _ = try await r.producer.backfill(at: t0)

        // The produced claim is source-scoped: no subject fabricated, anchored to the KO.
        let scoped = try await r.claims.claims(inKnowledgeObjectScopes: [s.ko])
        let claim = try #require(scoped.first)
        #expect(claim.subjectID == nil)
        #expect(claim.scope == .knowledgeObject(s.ko))

        let ws = try await workspace(r, sources: [s.file])
        let assembled = try await compose(r, ws)
        #expect(assembled.manifest.selectedFindingCount >= 1)                 // non-empty plain-doc report
        #expect(assembled.workProduct.sections.flatMap(\.claims).isEmpty == false)
        #expect(WorkProductValidator().validateProductionExport(assembled.workProduct).isValid)
    }

    @Test("A source-scoped Claim cannot leak into a workspace that does not hold its anchor object")
    func sourceScopedNoLeak() async throws {
        let r = try await rig()
        let a = try await seedDocFact(r, subject: nil, value: "in A")
        let b = try await seedDocFact(r, subject: nil, value: "in B")
        _ = try await r.producer.backfill(at: t0)
        let wsA = try await workspace(r, sources: [a.file])
        let wsB = try await workspace(r, sources: [b.file])
        let textsA = try await compose(r, wsA).workProduct.sections.flatMap(\.claims).map(\.text)
        let textsB = try await compose(r, wsB).workProduct.sections.flatMap(\.claims).map(\.text)
        #expect(textsA.contains { $0.contains("in A") })
        #expect(!textsA.contains { $0.contains("in B") })
        #expect(textsB.contains { $0.contains("in B") })
        #expect(!textsB.contains { $0.contains("in A") })
    }

    @Test("A subjectful Claim still requires workspace entity membership even when its evidence is in scope")
    func subjectfulRequiresMembership() async throws {
        let r = try await rig()
        // Entity S is mentioned ONLY in file X (not a workspace source), but its fact's evidence
        // block lives in the workspace's source object KO_w. So evidence is in scope yet S is not
        // a derived member → the entity claim must be excluded.
        let subject = UUID()
        let fileW = UUID(), koW = UUID(), fileX = UUID(), koX = UUID(), factID = UUID()
        // Workspace source W: file + KO + reopenable block owned by KO_w.
        try await r.files.upsert(FileRecord(id: fileW, url: URL(fileURLWithPath: "/doc/\(fileW).txt"),
                                            sourceType: .txt, ingestedAt: t0, contentHash: hex("a")))
        try await r.db.exec("INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);",
                            [.uuid(koW), .uuid(fileW), .text("txt"), .text("c"), .real(0), .real(0)])
        let sv = UUID(), block = UUID(), doc = UUID()
        try await r.db.exec("INSERT INTO source_versions (id, logical_source_id, document_id, content_hash, valid_from, is_current, created_at) VALUES (?,?,?,?,?,1,?);",
                            [.uuid(sv), .uuid(fileW), .uuid(doc), .text(hex("a")), .real(0), .real(0)])
        try await r.db.exec("INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text, extraction_method, extraction_confidence) VALUES (?,?,?,?,?,?,?,?,?);",
                            [.uuid(block), .uuid(doc), .uuid(sv), .integer(0), .text("paragraph"), .text("t"), .text("t"), .text("native"), .real(1.0)])
        try await r.db.exec("INSERT INTO evidence_block_objects (evidence_block_id, knowledge_object_id, linked_at) VALUES (?,?,?);",
                            [.uuid(block), .uuid(koW), .real(0)])
        // File X: where S is actually mentioned (NOT a workspace source).
        try await r.files.upsert(FileRecord(id: fileX, url: URL(fileURLWithPath: "/doc/\(fileX).txt"), sourceType: .txt, ingestedAt: t0))
        try await r.db.exec("INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);",
                            [.uuid(koX), .uuid(fileX), .text("txt"), .text("c"), .real(0), .real(0)])
        try await r.db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);",
                            [.uuid(subject), .text("person"), .text("S"), .text(subject.uuidString.lowercased()), .uuid(koX)])
        try await r.db.exec("""
        INSERT INTO entity_mentions (id, entity_id, kind, surface, normalized, source_object_id, confidence)
        VALUES (?,?,?,?,?,?,?);
        """, [.uuid(UUID()), .uuid(subject), .text("person"), .text("S"),
              .text(subject.uuidString.lowercased() + "-m"), .uuid(koX), .real(1.0)])
        // The entity fact: subject S, evidence block in KO_w.
        try await r.genericFacts.upsert(GenericFact(
            id: factID, subjectID: subject, subjectLabel: "S", field: "event", value: "member-only fact",
            assessment: EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction),
            confidence: 0.8, sourceBlockIDs: [block]))
        _ = try await r.producer.backfill(at: t0)

        let ws = try await workspace(r, sources: [fileW])                  // S is NOT mentioned in W
        #expect(try await r.workspaces.entityIDs(in: ws).contains(subject) == false)
        let texts = try await compose(r, ws).workProduct.sections.flatMap(\.claims).map(\.text)
        #expect(!texts.contains { $0.contains("member-only fact") })       // evidence in scope, but S not a member
    }

    @Test("Source-scoped and entity-scoped candidates dedupe to distinct rows")
    func mixedScopeDedupe() async throws {
        let r = try await rig()
        let subject = UUID()
        let ent = try await seedDocFact(r, subject: subject, value: "entity fact")
        let src = try await seedDocFact(r, subject: nil, value: "source fact")
        _ = try await r.producer.backfill(at: t0)
        let ws = try await workspace(r, sources: [ent.file, src.file])
        let claims = try await compose(r, ws).workProduct.sections.flatMap(\.claims)
        let ids = claims.map(\.id)
        #expect(Set(ids).count == ids.count)                               // no duplicate occurrence ids
        let sourceIDs = claims.compactMap(\.sourceClaimID)
        #expect(Set(sourceIDs).count >= 2)                                 // both the entity + source claim present
    }

    // MARK: - Upgrade path

    @Test("A fact that later gains an entity subject supersedes its source-scoped fallback (no duplicates)")
    func upgradeSupersedesSourceScoped() async throws {
        let r = try await rig()
        let factID = UUID()
        let s = try await seedDocFact(r, subject: nil, value: "the fact", factID: factID)
        _ = try await r.producer.backfill(at: t0)
        let sourceScopedID = try #require(try await r.claims.claims(inKnowledgeObjectScopes: [s.ko]).first).id

        // The SAME fact now gains an entity subject (re-upsert with the same fact id + a mention).
        let subject = UUID()
        try await r.db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);",
                            [.uuid(subject), .text("person"), .text("S"), .text(subject.uuidString.lowercased()), .uuid(s.ko)])
        try await r.db.exec("""
        INSERT INTO entity_mentions (id, entity_id, kind, surface, normalized, source_object_id, confidence)
        VALUES (?,?,?,?,?,?,?);
        """, [.uuid(UUID()), .uuid(subject), .text("person"), .text("S"),
              .text(subject.uuidString.lowercased() + "-m"), .uuid(s.ko), .real(1.0)])
        try await r.genericFacts.upsert(GenericFact(
            id: factID, subjectID: subject, subjectLabel: "Document", field: "event", value: "the fact",
            assessment: EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction),
            confidence: 0.8, sourceBlockIDs: [s.block]))
        _ = try await r.producer.produce(forSubjectID: subject, at: t0)

        // The old source-scoped claim is gone; exactly one active claim remains for the fact.
        #expect(try await r.claims.claim(id: sourceScopedID) == nil)
        #expect(try await r.claims.claims(inKnowledgeObjectScopes: [s.ko]).isEmpty)
        let entityClaims = try await r.claims.claims(subjectID: subject)
        #expect(entityClaims.count == 1)
        #expect(entityClaims.first?.scope == .entity(subject))
    }

    // MARK: - Reviews / usage survive reprojection

    @Test("Reviews and usage on a claim survive an unchanged reprojection")
    func reviewsUsageSurviveReprojection() async throws {
        let r = try await rig()
        let s = try await seedDocFact(r, subject: nil, value: "reviewed fact")
        _ = try await r.producer.backfill(at: t0)
        let id = try #require(try await r.claims.claims(inKnowledgeObjectScopes: [s.ko]).first).id
        let reviews = ClaimReviewRepository(database: r.db)
        let usage = ClaimUsageRepository(database: r.db)
        try await reviews.record(ClaimReview(claimID: id, disposition: .confirmed, reviewer: "u", reviewedAt: t0))
        try await usage.record(ClaimUsage(claimID: id, context: .workProduct, usedAt: t0))
        _ = try await r.producer.backfill(at: t0.addingTimeInterval(999))   // reproject
        #expect(try await reviews.currentDisposition(claimID: id) == .confirmed)
        #expect(try await usage.usageCount(claimID: id) == 1)
        #expect(try await r.claims.claim(id: id) != nil)                    // same claim, updated in place
    }

    // MARK: - Chronology honesty + report/receipt parity

    @Test("An undated source-scoped claim is labelled honestly in the chronology")
    func chronologyLabelsUndated() async throws {
        let r = try await rig()
        let s = try await seedDocFact(r, subject: nil, value: "undated doc fact")
        _ = try await r.producer.backfill(at: t0)
        let ws = try await workspace(r, sources: [s.file])
        let chronology = try #require(try await compose(r, ws).workProduct.sections.first { $0.title == "Chronology" })
        #expect(chronology.claims.contains { $0.text.contains("Undated") && $0.text.contains("undated doc fact") })
    }

    @Test("Report and receipt use the identical scoped selection for a plain-doc workspace")
    func reportReceiptIdenticalSelection() async throws {
        let r = try await rig()
        let s = try await seedDocFact(r, subject: nil, value: "shared doc fact")
        _ = try await r.producer.backfill(at: t0)
        let ws = try await workspace(r, sources: [s.file])
        let a = try await compose(r, ws)
        let b = try await compose(r, ws)
        let ax = a.workProduct.sections.flatMap(\.claims).map { [$0.text, $0.status.rawValue] }
        let bx = b.workProduct.sections.flatMap(\.claims).map { [$0.text, $0.status.rawValue] }
        #expect(ax == bx)
        // The receipt builds over the same assembled product and verifies.
        let sealed = try WorkProductReceiptBuilder().build(from: a)
        #expect(VerifiableReceipt.verify(sealed) == true)
    }

    // MARK: - Real plain-document ingests

    @Test("A real .txt ingest yields a reopenable source-scoped Claim and a non-empty summary")
    @MainActor
    func realTxtSourceScoped() async throws {
        try await realDocCase(filename: "receipt.txt", contents: "Payment record\nPaid to Rajesh Kumar. Amount ₹3,800 on 12/01/2024.")
    }

    @Test("A second non-email document type (.md) also yields a source-scoped Claim and a non-empty summary")
    @MainActor
    func realMarkdownSourceScoped() async throws {
        try await realDocCase(filename: "invoice.md", contents: "# Invoice\n\nPaid to Acme Ltd. Amount ₹4,200 on 03/01/2025.")
    }

    @MainActor
    private func realDocCase(filename: String, contents: String) async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("doc-real-\(UUID().uuidString)", isDirectory: true)
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

        let url = dir.appendingPathComponent(filename)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        let result = try await ingest.ingest(fileAt: url)
        _ = try await producer.backfill(at: t0)

        // At least one source-scoped claim (subject-less, anchored to a KnowledgeObject) exists —
        // proving a plain document with no entity subject still yields a claim, without inventing one.
        let objectIDs = try await objects.objectIDs(inFileIDs: [result.fileRecord.id])
        let scoped = try await claims.claims(inKnowledgeObjectScopes: objectIDs)
        #expect(scoped.isEmpty == false)
        #expect(scoped.allSatisfy { $0.subjectID == nil })

        let wsID = UUID()
        try await workspaces.upsert(Workspace(id: wsID, title: "Docs", template: .general))
        try await workspaces.addSource(result.fileRecord.id, to: wsID)
        try await membership.deriveMembership(for: wsID)
        let assembly = try WorkProductAssemblyService(
            database: db, events: events, contradictions: ContradictionsRepository(database: db),
            gaps: GapNodeRepository(database: db), workspaces: workspaces)
        let assembled = try await assembly.compose(
            workspace: Workspace(id: wsID, title: "Docs", template: .general),
            template: .generalSummary, subjectLabel: "Docs", corpusSnapshotID: nil,
            access: SensitiveAccessContext(scope: SensitiveScope(
                workspaceID: wsID, maximumSensitivity: .restricted,
                permitsPrivilegedMaterial: false, purpose: .export)))
        #expect(assembled.manifest.selectedFindingCount >= 1)
        #expect(WorkProductValidator().validateProductionExport(assembled.workProduct).isValid)
    }
}
