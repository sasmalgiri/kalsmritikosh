//
//  ClaimProducerTests.swift
//  KalsmritikoshTests
//
//  PA-PROD — the deterministic production Claim producer. Proves: reopenable evidence
//  resolution (source-version id), fingerprint idempotency (re-run updates, no duplicates),
//  no cross-subject leakage, review preservation, per-participant events, and an end-to-end
//  live generalSummary assembled from produced Claims + derived workspace membership.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PA-PROD — Claim producer + membership")
struct ClaimProducerTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Rig {
        let db: Database
        let genericFacts: GenericFactRepository
        let assertions: AssertionsRepository
        let temporalClaims: TemporalClaimRepository
        let events: EventsRepository
        let claims: ClaimRepository
        let evidence: EvidenceStore
        let workspaces: WorkspaceRepository
        let producer: ClaimProducer
        let membership: WorkspaceMembershipDeriver
    }

    private func rig() async throws -> Rig {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("prod-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        let gf = GenericFactRepository(database: db)
        let asrt = AssertionsRepository(database: db)
        let tcs = TemporalClaimRepository(database: db)
        let ev = EventsRepository(database: db)
        let claims = ClaimRepository(database: db)
        let store = EvidenceStore(database: db)
        let ws = WorkspaceRepository(database: db)
        return Rig(db: db, genericFacts: gf, assertions: asrt, temporalClaims: tcs, events: ev,
                   claims: claims, evidence: store, workspaces: ws,
                   producer: ClaimProducer(genericFacts: gf, assertions: asrt, temporalClaims: tcs,
                                            events: ev, claims: claims, evidence: store),
                   membership: WorkspaceMembershipDeriver(database: db, workspaces: ws))
    }

    // MARK: - Fixtures (persisted identity; no FK shortcuts)

    /// Insert file → KO → entity(subject) so membership + evidence anchoring are real.
    private func seedSubject(_ r: Rig, subject: UUID) async throws -> (file: UUID, ko: UUID) {
        let fileID = UUID(), koID = UUID()
        try await r.db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                            [.uuid(fileID), .text("file://x"), .text("txt")])
        try await r.db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?,?,?,?,?,?);
        """, [.uuid(koID), .uuid(fileID), .text("txt"), .text("c"), .real(0), .real(0)])
        // normalized must be unique per subject — entities has UNIQUE(kind, normalized).
        try await r.db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);",
                            [.uuid(subject), .text("person"), .text("S"), .text(subject.uuidString.lowercased()), .uuid(koID)])
        return (fileID, koID)
    }

    /// A reopenable evidence block: current source_version(logical=ko) + block(source_version=sv).
    @discardableResult
    private func seedReopenableBlock(_ r: Rig, ko: UUID) async throws -> UUID {
        let sv = UUID(), block = UUID(), doc = UUID()
        try await r.db.exec("""
        INSERT INTO source_versions (id, logical_source_id, document_id, content_hash, valid_from, is_current, created_at)
        VALUES (?,?,?,?,?,1,?);
        """, [.uuid(sv), .uuid(ko), .uuid(doc), .text("h"), .real(0), .real(0)])
        try await r.db.exec("""
        INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text, extraction_method, extraction_confidence)
        VALUES (?,?,?,?,?,?,?,?,?);
        """, [.uuid(block), .uuid(doc), .uuid(sv), .integer(0), .text("text"), .text("t"), .text("t"), .text("test"), .real(1.0)])
        return block
    }

    /// A bare file + knowledge object (no entity), for mention-occurrence tests.
    private func seedFileKO(_ r: Rig) async throws -> (file: UUID, ko: UUID) {
        let f = UUID(), ko = UUID()
        try await r.db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                            [.uuid(f), .text("file://\(f)"), .text("txt")])
        try await r.db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?,?,?,?,?,?);
        """, [.uuid(ko), .uuid(f), .text("txt"), .text("c"), .real(0), .real(0)])
        return (f, ko)
    }

    private func fact(_ r: Rig, subject: UUID?, field: String, value: String, blocks: [UUID],
                      basis: EvidenceBasis = .directlyObserved, review: ReviewDisposition = .unreviewed) async throws {
        try await r.genericFacts.upsert(GenericFact(
            subjectID: subject, subjectLabel: "S", field: field, value: value,
            assessment: EvidenceAssessment(basis: basis, review: review, origin: .sourceExtraction),
            confidence: 0.8, sourceBlockIDs: blocks))
    }

    // MARK: - Reopenable evidence

    @Test("A GenericFact becomes a Claim with reopenable (source-version-backed) evidence")
    func genericFactReopenable() async throws {
        let r = try await rig()
        let subject = UUID()
        let (_, ko) = try await seedSubject(r, subject: subject)
        let block = try await seedReopenableBlock(r, ko: ko)
        try await fact(r, subject: subject, field: "employer", value: "Orchid", blocks: [block])
        #expect(try await r.producer.backfill(at: t0) == 1)
        let produced = try await r.claims.claims(subjectID: subject)
        let claim = try #require(produced.first)
        #expect(claim.statement == "employer: Orchid")
        #expect(claim.subjectID == subject)
        let ref = try #require(claim.evidence.first)
        #expect(ref.objectID == ko)                     // resolved to the owning object
        #expect(ref.sourceVersionID != nil)             // reopenable
        #expect(claim.derivedFrom.first?.kind == .genericFact)
    }

    @Test("Evidence that cannot reopen its source is dropped, never fabricated")
    func unreopenableEvidenceDropped() async throws {
        let r = try await rig()
        let subject = UUID()
        _ = try await seedSubject(r, subject: subject)
        // A block id with no source_version + no current version → unresolvable.
        try await fact(r, subject: subject, field: "employer", value: "Ghost", blocks: [UUID()])
        _ = try await r.producer.backfill(at: t0)
        let claim = try #require(try await r.claims.claims(subjectID: subject).first)
        #expect(claim.evidence.isEmpty)                 // no unreopenable reference invented
    }

    // MARK: - Idempotency

    @Test("Re-running the producer updates the same Claim instead of duplicating it")
    func idempotentReproduce() async throws {
        let r = try await rig()
        let subject = UUID()
        let (_, ko) = try await seedSubject(r, subject: subject)
        let block = try await seedReopenableBlock(r, ko: ko)
        try await fact(r, subject: subject, field: "employer", value: "Orchid", blocks: [block])
        _ = try await r.producer.backfill(at: t0)
        _ = try await r.producer.backfill(at: t0.addingTimeInterval(1000))   // re-run
        #expect(try await r.claims.count() == 1)        // same deterministic id → one row
    }

    // MARK: - Scope + review

    @Test("Claims preserve subject identity — no cross-subject leakage")
    func noCrossSubjectLeakage() async throws {
        let r = try await rig()
        let a = UUID(), b = UUID()
        _ = try await seedSubject(r, subject: a)
        _ = try await seedSubject(r, subject: b)
        try await fact(r, subject: a, field: "employer", value: "Orchid A", blocks: [])
        try await fact(r, subject: b, field: "employer", value: "Orchid B", blocks: [])
        _ = try await r.producer.backfill(at: t0)
        let forA = try await r.claims.claims(subjectID: a)
        #expect(forA.count == 1)
        #expect(forA.allSatisfy { $0.subjectID == a })
        #expect(forA.first?.statement == "employer: Orchid A")
    }

    @Test("A corrected review on the source fact is preserved in the produced Claim")
    func reviewPreserved() async throws {
        let r = try await rig()
        let subject = UUID()
        _ = try await seedSubject(r, subject: subject)
        try await fact(r, subject: subject, field: "employer", value: "Orchid", blocks: [], review: .corrected)
        _ = try await r.producer.backfill(at: t0)
        let claim = try #require(try await r.claims.claims(subjectID: subject).first)
        #expect(claim.assessment.review == .corrected)
    }

    // MARK: - Events (per participant)

    @Test("An event with two participants produces two subject-scoped Claims (no duplicates)")
    func eventPerParticipant() async throws {
        let r = try await rig()
        let a = UUID(), b = UUID()
        let (_, ko) = try await seedSubject(r, subject: a)
        _ = try await seedSubject(r, subject: b)
        let e = Event(id: UUID(), kind: .other, date: t0, title: "Kickoff", entityIDs: [a, b],
                      sourceObjectID: ko, datePrecision: .day)
        try await r.events.insertBatch([e])
        _ = try await r.producer.backfill(at: t0)
        #expect(try await r.claims.claims(subjectID: a).contains { $0.statement == "Kickoff" })
        #expect(try await r.claims.claims(subjectID: b).contains { $0.statement == "Kickoff" })
    }

    // MARK: - Membership derivation

    @Test("Workspace membership is derived from source-file identity, never text")
    func membershipFromFileIdentity() async throws {
        let r = try await rig()
        let member = UUID(), outsider = UUID()
        let (memberFile, _) = try await seedSubject(r, subject: member)
        _ = try await seedSubject(r, subject: outsider)          // outsider's file NOT in workspace
        let wsID = UUID()
        try await r.workspaces.upsert(Workspace(id: wsID, title: "WS", template: .general))
        try await r.workspaces.addSource(memberFile, to: wsID)
        let added = try await r.membership.deriveMembership(for: wsID)
        #expect(added == 1)
        let members = try await r.workspaces.entityIDs(in: wsID)
        #expect(members == [member])                            // outsider excluded
    }

    // MARK: - Hardening corrections

    @Test("Re-production is a true UPSERT: createdAt, reviews, usage, and contradiction links survive")
    func reproductionPreservesEverything() async throws {
        let r = try await rig()
        let subject = UUID()
        let (_, ko) = try await seedSubject(r, subject: subject)
        let block = try await seedReopenableBlock(r, ko: ko)
        try await fact(r, subject: subject, field: "employer", value: "Orchid", blocks: [block])
        _ = try await r.producer.backfill(at: t0)
        let id = try #require(try await r.claims.claims(subjectID: subject).first).id

        let reviews = ClaimReviewRepository(database: r.db)
        let usage = ClaimUsageRepository(database: r.db)
        let links = ClaimContradictionRepository(database: r.db)
        try await reviews.record(ClaimReview(claimID: id, disposition: .confirmed, reviewer: "u", reviewedAt: t0))
        try await usage.record(ClaimUsage(claimID: id, context: .workProduct, usedAt: t0))
        let cont = UUID(); try await links.link(claimID: id, contradictionID: cont)

        _ = try await r.producer.backfill(at: t0.addingTimeInterval(9_999))   // re-produce later
        let after = try #require(try await r.claims.claim(id: id))
        #expect(after.createdAt == t0)                                        // NOT rewritten
        #expect(try await reviews.currentDisposition(claimID: id) == .confirmed)
        #expect(try await usage.usageCount(claimID: id) == 1)
        #expect(try await links.contradictionIDs(claimID: id) == [cont])
        #expect(after.evidence.first?.sourceVersionID != nil)                 // evidence intact
        #expect(after.derivedFrom.first?.kind == .genericFact)                // lineage intact
        #expect(try await r.claims.count() == 1)                              // no duplicate
    }

    @Test("Membership follows a non-representative entity_mention occurrence in another file")
    func membershipViaMention() async throws {
        let r = try await rig()
        let entity = UUID()
        _ = try await seedSubject(r, subject: entity)               // entity ORIGINATES in file A
        let (fileB, koB) = try await seedFileKO(r)                  // mentioned in file B
        try await r.db.exec("""
        INSERT INTO entity_mentions (id, entity_id, kind, surface, normalized, source_object_id, confidence)
        VALUES (?,?,?,?,?,?,?);
        """, [.uuid(UUID()), .uuid(entity), .text("person"), .text("S"),
              .text(entity.uuidString.lowercased() + "-m"), .uuid(koB), .real(1.0)])
        let wsID = UUID()
        try await r.workspaces.upsert(Workspace(id: wsID, title: "WS", template: .general))
        try await r.workspaces.addSource(fileB, to: wsID)          // workspace has ONLY file B
        try await r.membership.deriveMembership(for: wsID)
        #expect(try await r.workspaces.entityIDs(in: wsID) == [entity])
    }

    @Test("Incremental production projects more than 1,000 subject assertions (no ceiling)")
    func moreThan1000Assertions() async throws {
        let r = try await rig()
        let subject = UUID()
        _ = try await seedSubject(r, subject: subject)
        for i in 0..<1_001 {
            try await r.assertions.insert(Assertion(subjectKind: .entity, subjectID: subject,
                                                    predicate: "p\(i)", object: .literal("v\(i)"),
                                                    provenance: .sourceAsserted))
        }
        _ = try await r.producer.produce(forSubjectID: subject, at: t0)
        #expect(try await r.claims.claims(subjectID: subject).count == 1_001)
    }

    // MARK: - End-to-end: live generalSummary from produced Claims + derived membership

    @Test("Produced Claims + derived membership assemble a scoped, valid generalSummary")
    func liveGeneralSummary() async throws {
        let r = try await rig()
        let subject = UUID()
        let (file, ko) = try await seedSubject(r, subject: subject)
        let block = try await seedReopenableBlock(r, ko: ko)
        try await fact(r, subject: subject, field: "employer", value: "Orchid Labs", blocks: [block])
        let wsID = UUID()
        try await r.workspaces.upsert(Workspace(id: wsID, title: "Matter", template: .general))
        try await r.workspaces.addSource(file, to: wsID)
        try await r.membership.deriveMembership(for: wsID)
        _ = try await r.producer.backfill(at: t0)

        let assembly = try WorkProductAssemblyService(
            database: r.db, events: r.events,
            contradictions: ContradictionsRepository(database: r.db),
            gaps: GapNodeRepository(database: r.db), workspaces: r.workspaces)
        let assembled = try await assembly.compose(
            workspace: Workspace(id: wsID, title: "Matter", template: .general),
            template: .generalSummary, subjectLabel: "Matter", corpusSnapshotID: nil)

        let sourced = assembled.workProduct.sections.first { $0.title == "Sourced summary" }
        #expect(sourced?.claims.contains { $0.text.hasSuffix("employer: Orchid Labs") } == true)
        #expect(assembled.manifest.selectedFindingCount >= 1)   // real data, not empty
        // Not blocked: the fact's citation is reopenable.
        #expect(WorkProductValidator().validateProductionExport(assembled.workProduct).isValid)
    }
}
