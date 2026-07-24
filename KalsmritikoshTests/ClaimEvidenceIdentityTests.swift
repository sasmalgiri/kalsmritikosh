//
//  ClaimEvidenceIdentityTests.swift
//  KalsmritikoshTests
//
//  PA-PROD B6 — canonical EvidenceBlock → KnowledgeObject ownership. Proves the evidence-identity
//  correction: source_versions.logical_source_id stays at the FILE level, block→object ownership
//  is explicit, resolved EvidenceReferences carry a real KnowledgeObject id + reopenable version,
//  the resulting Claim passes B4 only for a workspace that owns the source, unowned/ambiguous
//  blocks are skipped (never guessed), and each block in a multi-object source keeps its own owner.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PA-PROD B6 — canonical evidence identity")
struct ClaimEvidenceIdentityTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Rig {
        let db: Database
        let store: EvidenceStore
        let claims: ClaimRepository
        let genericFacts: GenericFactRepository
        let events: EventsRepository
        let temporalClaims: TemporalClaimRepository
        let assertions: AssertionsRepository
        let workspaces: WorkspaceRepository
        let producer: ClaimProducer
    }

    private func rig() async throws -> Rig {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("b6-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        let store = EvidenceStore(database: db)
        let gf = GenericFactRepository(database: db)
        let ev = EventsRepository(database: db)
        let tcs = TemporalClaimRepository(database: db)
        let asrt = AssertionsRepository(database: db)
        let claims = ClaimRepository(database: db)
        return Rig(db: db, store: store, claims: claims, genericFacts: gf, events: ev,
                   temporalClaims: tcs, assertions: asrt, workspaces: WorkspaceRepository(database: db),
                   producer: ClaimProducer(genericFacts: gf, assertions: asrt, temporalClaims: tcs,
                                            events: ev, claims: claims, evidence: store))
    }

    // MARK: - Seeding (production-shaped identity)

    private func seedFileKO(_ r: Rig, file: UUID, ko: UUID) async throws {
        try await r.db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                            [.uuid(file), .text("file://\(file)"), .text("txt")])
        try await r.db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);
        """, [.uuid(ko), .uuid(file), .text("txt"), .text("c"), .real(0), .real(0)])
    }

    private func seedSubject(_ r: Rig, subject: UUID, ko: UUID) async throws {
        try await r.db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);",
                            [.uuid(subject), .text("person"), .text("S"), .text(subject.uuidString.lowercased()), .uuid(ko)])
        try await r.db.exec("""
        INSERT INTO entity_mentions (id, entity_id, kind, surface, normalized, source_object_id, confidence)
        VALUES (?,?,?,?,?,?,?);
        """, [.uuid(UUID()), .uuid(subject), .text("person"), .text("S"),
              .text(subject.uuidString.lowercased() + "-m"), .uuid(ko), .real(1.0)])
    }

    /// A file-level source version (logical_source_id = FILE, like production). Returns its id.
    @discardableResult
    private func seedVersion(_ r: Rig, file: UUID, doc: UUID) async throws -> UUID {
        let sv = UUID()
        try await r.db.exec("""
        INSERT INTO source_versions (id, logical_source_id, document_id, content_hash, valid_from, is_current, created_at)
        VALUES (?,?,?,?,?,1,?);
        """, [.uuid(sv), .uuid(file), .uuid(doc), .text("h"), .real(0), .real(0)])
        return sv
    }

    @discardableResult
    private func seedBlock(_ r: Rig, doc: UUID, sv: UUID) async throws -> UUID {
        let b = UUID()
        try await r.db.exec("""
        INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text, extraction_method, extraction_confidence)
        VALUES (?,?,?,?,?,?,?,?,?);
        """, [.uuid(b), .uuid(doc), .uuid(sv), .integer(0), .text("paragraph"), .text("t"), .text("t"), .text("native"), .real(1.0)])
        return b
    }

    private func link(_ r: Rig, block: UUID, ko: UUID) async throws {
        try await r.db.exec("""
        INSERT INTO evidence_block_objects (evidence_block_id, knowledge_object_id, linked_at) VALUES (?,?,?);
        """, [.uuid(block), .uuid(ko), .real(0)])
    }

    private func fact(_ r: Rig, subject: UUID, field: String, value: String, blocks: [UUID]) async throws {
        try await r.genericFacts.upsert(GenericFact(
            subjectID: subject, subjectLabel: "S", field: field, value: value,
            assessment: EvidenceAssessment(basis: .directlyObserved, origin: .sourceExtraction),
            confidence: 0.8, sourceBlockIDs: blocks))
    }

    // MARK: - Resolution identity

    @Test("A resolved block carries the canonical KnowledgeObject id and source-version id; logical_source_id stays the file")
    func resolvedReferenceCarriesObjectAndVersion() async throws {
        let r = try await rig()
        let file = UUID(), ko = UUID(), doc = UUID()
        try await seedFileKO(r, file: file, ko: ko)
        let sv = try await seedVersion(r, file: file, doc: doc)
        let block = try await seedBlock(r, doc: doc, sv: sv)
        try await link(r, block: block, ko: ko)
        // The source version is keyed at the FILE (not the KO).
        #expect(try await r.store.currentVersionID(forLogicalSource: file) == sv)
        // …yet the canonical resolver returns the KnowledgeObject owner + that version.
        #expect(try await r.store.resolveCanonicalBlocks([block])
                == [.resolved(ResolvedEvidenceBlock(blockID: block, knowledgeObjectID: ko, sourceVersionID: sv))])
    }

    // MARK: - B4 admission / exclusion by real object identity

    @Test("A workspace that owns the source admits the Claim; an outside-file Claim stays excluded")
    func workspaceAdmitsOwnedExcludesOutside() async throws {
        let r = try await rig()
        let subject = UUID()
        let inFile = UUID(), inKO = UUID(), inDoc = UUID()
        try await seedFileKO(r, file: inFile, ko: inKO)
        try await seedSubject(r, subject: subject, ko: inKO)
        let inBlock = try await seedBlock(r, doc: inDoc, sv: try await seedVersion(r, file: inFile, doc: inDoc))
        try await link(r, block: inBlock, ko: inKO)
        try await fact(r, subject: subject, field: "employer", value: "Inside", blocks: [inBlock])

        let outFile = UUID(), outKO = UUID(), outDoc = UUID()
        try await seedFileKO(r, file: outFile, ko: outKO)
        let outBlock = try await seedBlock(r, doc: outDoc, sv: try await seedVersion(r, file: outFile, doc: outDoc))
        try await link(r, block: outBlock, ko: outKO)
        try await fact(r, subject: subject, field: "employer", value: "Outside", blocks: [outBlock])

        _ = try await r.producer.backfill(at: t0)

        // Selection scoped to a workspace whose only source object is `inKO`.
        let selection = ClaimSelectionService(
            claims: r.claims, resolver: ClaimResolver(claims: r.claims, reviews: ClaimReviewRepository(database: r.db)),
            temporalClaims: r.temporalClaims, events: r.events)
        let ctx = try await selection.buildContext(
            scope: .workspace(id: UUID(), memberSubjectIDs: [subject], allowedObjectIDs: [inKO]), subjectLabel: "WS")
        #expect(ctx.selectedClaims.map { $0.resolved.claim.statement } == ["employer: Inside"])
    }

    // MARK: - Object-only evidence

    @Test("Object-only evidence resolves KnowledgeObject → file → current source version")
    func objectOnlyEvidenceResolves() async throws {
        let r = try await rig()
        let file = UUID(), ko = UUID(), doc = UUID(), subject = UUID()
        try await seedFileKO(r, file: file, ko: ko)
        try await seedSubject(r, subject: subject, ko: ko)
        let sv = try await seedVersion(r, file: file, doc: doc)   // current version for the file
        // An event cites the KnowledgeObject only (no block).
        try await r.events.insertBatch([Event(id: UUID(), kind: .other, date: t0, title: "Signing",
                                               entityIDs: [subject], sourceObjectID: ko, datePrecision: .day)])
        _ = try await r.producer.backfill(at: t0)
        let claim = try #require(try await r.claims.claims(subjectID: subject).first { $0.statement == "Signing" })
        let ref = try #require(claim.evidence.first)
        #expect(ref.objectID == ko)                 // a real KnowledgeObject id, not the file id
        #expect(ref.sourceVersionID == sv)          // resolved via KO → file → current version
    }

    // MARK: - Skip / never-guess

    @Test("An unowned block is skipped — no evidence is fabricated")
    func unownedBlockSkipped() async throws {
        let r = try await rig()
        let file = UUID(), ko = UUID(), doc = UUID(), subject = UUID()
        try await seedFileKO(r, file: file, ko: ko)
        try await seedSubject(r, subject: subject, ko: ko)
        let block = try await seedBlock(r, doc: doc, sv: try await seedVersion(r, file: file, doc: doc))
        // Deliberately NO ownership link for `block`.
        try await fact(r, subject: subject, field: "employer", value: "Ghost", blocks: [block])
        _ = try await r.producer.backfill(at: t0)
        let claim = try #require(try await r.claims.claims(subjectID: subject).first)
        #expect(claim.evidence.isEmpty)
        #expect(try await r.store.resolveCanonicalBlocks([block]) == [.unresolved(blockID: block)])
    }

    @Test("Ambiguous ownership (two objects) is reported, never guessed")
    func ambiguousOwnershipNotGuessed() async throws {
        let r = try await rig()
        let file = UUID(), koA = UUID(), koB = UUID(), doc = UUID(), subject = UUID()
        try await seedFileKO(r, file: file, ko: koA)
        try await r.db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);
        """, [.uuid(koB), .uuid(file), .text("txt"), .text("c"), .real(0), .real(0)])
        try await seedSubject(r, subject: subject, ko: koA)
        let block = try await seedBlock(r, doc: doc, sv: try await seedVersion(r, file: file, doc: doc))
        try await link(r, block: block, ko: koA)
        try await link(r, block: block, ko: koB)               // two distinct owners → ambiguous
        try await fact(r, subject: subject, field: "employer", value: "Split", blocks: [block])
        _ = try await r.producer.backfill(at: t0)
        #expect(try await r.store.resolveCanonicalBlocks([block]) == [.ambiguous(blockID: block)])
        #expect(try await r.claims.claims(subjectID: subject).first?.evidence.isEmpty == true)
    }

    // MARK: - Multi-object (MBOX-style) — each block keeps its own object

    @Test("In a two-KnowledgeObject source, each block resolves to its own object (no cross-linking)")
    func multiObjectNoCrossLink() async throws {
        let r = try await rig()
        let file = UUID(), koA = UUID(), koB = UUID(), docA = UUID(), docB = UUID()
        try await seedFileKO(r, file: file, ko: koA)
        try await r.db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);
        """, [.uuid(koB), .uuid(file), .text("txt"), .text("c"), .real(0), .real(0)])
        let svA = try await seedVersion(r, file: file, doc: docA)
        let svB = try await seedVersion(r, file: file, doc: docB)
        let blockA = try await seedBlock(r, doc: docA, sv: svA)
        let blockB = try await seedBlock(r, doc: docB, sv: svB)
        try await link(r, block: blockA, ko: koA)
        try await link(r, block: blockB, ko: koB)
        // Each block resolves to ITS message's object; neither leaks into the other's.
        #expect(try await r.store.resolveCanonicalBlocks([blockA])
                == [.resolved(ResolvedEvidenceBlock(blockID: blockA, knowledgeObjectID: koA, sourceVersionID: svA))])
        #expect(try await r.store.resolveCanonicalBlocks([blockB])
                == [.resolved(ResolvedEvidenceBlock(blockID: blockB, knowledgeObjectID: koB, sourceVersionID: svB))])
    }
}
