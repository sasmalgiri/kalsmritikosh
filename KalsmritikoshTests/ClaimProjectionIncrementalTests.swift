//
//  ClaimProjectionIncrementalTests.swift
//  KalsmritikoshTests
//
//  PA-PROD Commit B3 — the incremental post-ingest projection hook (ClaimProjectionBackfill
//  .projectSource) that the IngestCoordinator fires after a real ingest. Proves: a committed
//  source's affected subjects project into Claims; derived membership refreshes for ONLY the
//  workspaces that hold the source; the pass is idempotent; and it never throws.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PA-PROD B3 — incremental per-source projection")
struct ClaimProjectionIncrementalTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Rig {
        let db: Database
        let claims: ClaimRepository
        let workspaces: WorkspaceRepository
        let backfill: ClaimProjectionBackfill
    }

    private func rig() async throws -> Rig {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("b3-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        let gf = GenericFactRepository(database: db)
        let tcs = TemporalClaimRepository(database: db)
        let asrt = AssertionsRepository(database: db)
        let ev = EventsRepository(database: db)
        let claims = ClaimRepository(database: db)
        let store = EvidenceStore(database: db)
        let ws = WorkspaceRepository(database: db)
        let producer = ClaimProducer(genericFacts: gf, assertions: asrt, temporalClaims: tcs, events: ev, claims: claims, evidence: store)
        let membership = WorkspaceMembershipDeriver(database: db, workspaces: ws)
        let backfill = ClaimProjectionBackfill(producer: producer, progress: ClaimProjectionProgressRepository(database: db),
                                               membership: membership, genericFacts: gf, temporalClaims: tcs,
                                               assertions: asrt, events: ev)
        return Rig(db: db, claims: claims, workspaces: ws, backfill: backfill)
    }

    /// A file + KO + an entity mentioned in that file + one GenericFact about the entity.
    /// Returns (fileID, subjectID). The GenericFact gives `produce(forSubjectID:)` something
    /// to project into a Claim.
    private func seedFileWithSubjectFact(_ r: Rig) async throws -> (file: UUID, subject: UUID) {
        let file = UUID(), ko = UUID(), subject = UUID()
        try await r.db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                            [.uuid(file), .text("file://\(file)"), .text("txt")])
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
        try await GenericFactRepository(database: r.db).upsert(GenericFact(
            id: UUID(), subjectID: subject, subjectLabel: "S", field: "employer", value: "Orchid",
            assessment: EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction),
            confidence: 0.8, sourceBlockIDs: []))
        return (file, subject)
    }

    private func workspace(_ r: Rig) async throws -> Workspace.ID {
        let id = UUID()
        try await r.workspaces.upsert(Workspace(id: id, title: "WS", template: .general))
        return id
    }

    @Test("A committed source projects its subject into a Claim and into holding-workspace membership")
    func projectsSubjectAndMembership() async throws {
        let r = try await rig()
        let (file, subject) = try await seedFileWithSubjectFact(r)
        let ws = try await workspace(r)
        try await r.workspaces.addSource(file, to: ws)

        await r.backfill.projectSource(fileID: file, at: t0)

        #expect(try await r.claims.claims(subjectID: subject).count == 1)   // the employer fact
        #expect(try await r.workspaces.entityIDs(in: ws) == [subject])      // derived membership
    }

    @Test("Membership refresh is scoped to workspaces that hold the source — no leak")
    func membershipScopedToHoldingWorkspaces() async throws {
        let r = try await rig()
        let (file, subject) = try await seedFileWithSubjectFact(r)
        let holding = try await workspace(r)
        let other = try await workspace(r)
        try await r.workspaces.addSource(file, to: holding)                 // only `holding` has it

        await r.backfill.projectSource(fileID: file, at: t0)

        #expect(try await r.workspaces.entityIDs(in: holding) == [subject])
        #expect(try await r.workspaces.entityIDs(in: other).isEmpty)
    }

    @Test("Re-firing the hook for the same source produces no duplicate Claims")
    func idempotentRepeat() async throws {
        let r = try await rig()
        let (file, _) = try await seedFileWithSubjectFact(r)
        let ws = try await workspace(r)
        try await r.workspaces.addSource(file, to: ws)

        await r.backfill.projectSource(fileID: file, at: t0)
        let first = try await r.claims.count()
        await r.backfill.projectSource(fileID: file, at: t0.addingTimeInterval(60))
        #expect(try await r.claims.count() == first)                        // UPSERT → stable
    }

    @Test("A source with no occurrence-linked subjects is a safe no-op (never throws)")
    func emptySourceNoOp() async throws {
        let r = try await rig()
        // A file that exists but has no mentioned entities.
        let file = UUID(), ko = UUID()
        try await r.db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                            [.uuid(file), .text("file://\(file)"), .text("txt")])
        try await r.db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);
        """, [.uuid(ko), .uuid(file), .text("txt"), .text("c"), .real(0), .real(0)])

        await r.backfill.projectSource(fileID: file, at: t0)                // must not throw
        #expect(try await r.claims.count() == 0)
    }

    @Test("Incremental projection after a full backfill leaves the Claim set consistent (no duplicates)")
    func coexistsWithFullBackfill() async throws {
        let r = try await rig()
        let (file, subject) = try await seedFileWithSubjectFact(r)
        let ws = try await workspace(r)
        try await r.workspaces.addSource(file, to: ws)

        await r.backfill.run(at: t0)                                        // full pass first
        let afterBackfill = try await r.claims.count()
        await r.backfill.projectSource(fileID: file, at: t0.addingTimeInterval(30))
        #expect(try await r.claims.count() == afterBackfill)                // no new rows
        #expect(try await r.claims.claims(subjectID: subject).count == 1)
        #expect(try await r.workspaces.entityIDs(in: ws) == [subject])
    }
}
