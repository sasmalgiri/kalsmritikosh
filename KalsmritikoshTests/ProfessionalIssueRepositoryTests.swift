//
//  ProfessionalIssueRepositoryTests.swift
//  KalsmritikoshTests
//
//  OPS-001 — the shared Issue Engine's truth invariants: atomic create/transition with an
//  append-only review ledger; fail-closed link validation (existence, duplicates, cross-workspace
//  boundary); the lifecycle matrix (archived terminal, dismissed reopen-only, supersede→archive);
//  CANONICAL ISOLATION (issue operations never mutate a linked Claim, never resolve a linked
//  contradiction, never dismiss a linked gap); workspace-deletion cascade removes ONLY issue
//  working state; and durable reopen.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("OPS-001 — professional issue repository")
struct ProfessionalIssueRepositoryTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Rig {
        let db: Database
        let url: URL
        let repo: ProfessionalIssueRepository
        let workspaceID: UUID
    }

    /// Latest-schema DB + one workspace (with a source file + KO so boundary checks are real).
    private func rig() async throws -> Rig {
        let url = MigrationFixtureBuilder.newTemporaryURL()
        let db = try await MigrationFixtureBuilder.database(atVersion: 0, at: url)
        try await SchemaMigrations.migrate(db)
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, template_type, created_at, updated_at) VALUES (?,?,?,?,?);",
                          [.uuid(ws), .text("WS-A"), .text("general"), .real(0), .real(0)])
        return Rig(db: db, url: url, repo: ProfessionalIssueRepository(database: db), workspaceID: ws)
    }

    /// A file that IS a source of `workspace`, with its KnowledgeObject. Returns (file, ko).
    @discardableResult
    private func seedSource(_ r: Rig, workspace: UUID) async throws -> (file: UUID, ko: UUID) {
        let f = UUID(), ko = UUID()
        try await r.db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                            [.uuid(f), .text("file://\(f)"), .text("txt")])
        try await r.db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);
        """, [.uuid(ko), .uuid(f), .text("txt"), .text("c"), .real(0), .real(0)])
        try await r.db.exec("INSERT INTO workspace_sources (workspace_id, file_id, added_at) VALUES (?,?,?);",
                            [.uuid(workspace), .uuid(f), .real(0)])
        return (f, ko)
    }

    /// A canonical claim whose single evidence ref anchors to `ko` (so its boundary = ko's file).
    @discardableResult
    private func seedClaim(_ r: Rig, ko: UUID, statement: String = "employer: Orchid") async throws -> UUID {
        let id = UUID()
        try await r.db.exec("""
        INSERT INTO claims (id, subject_id, subject_label, statement, confidence, created_at,
                            evidence_basis, review_disposition, proposal_origin, availability_status, conflict_status)
        VALUES (?,?,?,?,?,?,?,?,?,?,?);
        """, [.uuid(id), .uuid(UUID()), .text("S"), .text(statement), .real(0.8), .real(1000),
              .text("directlyObserved"), .text("unreviewed"), .text("sourceExtraction"),
              .text("available"), .text("none")])
        try await r.db.exec("""
        INSERT INTO claim_evidence_ref (claim_id, ordinal, knowledge_object_id, evidence_role) VALUES (?,?,?,?);
        """, [.uuid(id), .integer(0), .uuid(ko), .text("supports")])
        return id
    }

    private func issueCount(_ r: Rig, table: String) async throws -> Int {
        Int(try await r.db.query("SELECT COUNT(*) FROM \(table);", []).first?.int(0) ?? -1)
    }

    // MARK: - Create + audit (cases 3, 20)

    @Test("Creating an Issue writes the row and its `created` review atomically")
    func createIsAtomicWithReview() async throws {
        let r = try await rig()
        let issue = try await r.repo.create(workspaceID: r.workspaceID, title: "  Who signed?  ",
                                            detail: "d", type: .question, priority: .high,
                                            reviewer: "u", at: t0)
        #expect(issue.title == "Who signed?")           // trimmed
        #expect(issue.status == .open)
        let loaded = try #require(try await r.repo.issue(id: issue.id))
        #expect(loaded == issue)
        let reviews = try await r.repo.reviews(issueID: issue.id)
        #expect(reviews.count == 1)
        #expect(reviews.first?.action == .created)
        #expect(reviews.first?.newStatus == .open)
        // Blank title rejected.
        await #expect(throws: ProfessionalIssueError.blankTitle) {
            _ = try await r.repo.create(workspaceID: r.workspaceID, title: "   ", detail: nil,
                                        type: .other, priority: .low, reviewer: "u", at: t0)
        }
        #expect(try await MigrationFaultHarness.integrityOK(r.db))
        #expect(try await MigrationFaultHarness.foreignKeyViolationCount(r.db) == 0)
    }

    // MARK: - Listing + filtering (case 4)

    @Test("Issues list and filter by workspace, status and type")
    func listAndFilter() async throws {
        let r = try await rig()
        let q = try await r.repo.create(workspaceID: r.workspaceID, title: "Q", detail: nil,
                                        type: .question, priority: .normal, reviewer: "u", at: t0)
        _ = try await r.repo.create(workspaceID: r.workspaceID, title: "Risk", detail: nil,
                                    type: .risk, priority: .high, reviewer: "u", at: t0.addingTimeInterval(1))
        try await r.repo.transition(issueID: q.id, to: .resolved, reviewer: "u", reason: nil, at: t0.addingTimeInterval(2))
        // Another workspace's issue must not leak into the list.
        let wsB = UUID()
        try await r.db.exec("INSERT INTO workspaces (id, title, template_type, created_at, updated_at) VALUES (?,?,?,?,?);",
                            [.uuid(wsB), .text("WS-B"), .text("general"), .real(0), .real(0)])
        _ = try await r.repo.create(workspaceID: wsB, title: "Other WS", detail: nil,
                                    type: .lead, priority: .low, reviewer: "u", at: t0)

        #expect(try await r.repo.issues(workspaceID: r.workspaceID).count == 2)
        let openRisks = try await r.repo.issues(workspaceID: r.workspaceID, statuses: [.open], types: [.risk])
        #expect(openRisks.map(\.title) == ["Risk"])
        let resolved = try await r.repo.issues(workspaceID: r.workspaceID, statuses: [.resolved], types: [])
        #expect(resolved.map(\.title) == ["Q"])
    }

    // MARK: - Links (cases 5, 6, 7, 8)

    @Test("Every supported canonical target kind links and reads back")
    func linkEveryTargetKind() async throws {
        let r = try await rig()
        let (file, ko) = try await seedSource(r, workspace: r.workspaceID)
        let claim = try await seedClaim(r, ko: ko)
        let event = UUID(), entity = UUID(), block = UUID(), sv = UUID(), contradiction = UUID(), gap = UUID()
        try await r.db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);",
                            [.uuid(entity), .text("person"), .text("S"), .text(entity.uuidString.lowercased()), .uuid(ko)])
        try await r.db.exec("INSERT INTO workspace_entities (workspace_id, entity_id, added_at) VALUES (?,?,?);",
                            [.uuid(r.workspaceID), .uuid(entity), .real(0)])
        try await r.db.exec("""
        INSERT INTO events (id, kind, date, title, source_object_id, confidence, attributes_json, date_confidence, quality_tier, date_precision, status)
        VALUES (?,?,?,?,?,?,?,?,?,?,?);
        """, [.uuid(event), .text("other"), .date(t0), .text("E"), .uuid(ko), .real(0.8), .text("{}"),
              .real(0.8), .text("t2"), .integer(5), .text("asserted")])
        let doc = UUID()
        try await r.db.exec("""
        INSERT INTO source_versions (id, logical_source_id, document_id, content_hash, valid_from, is_current, created_at)
        VALUES (?,?,?,?,?,1,?);
        """, [.uuid(sv), .uuid(file), .uuid(doc), .text(String(repeating: "ab", count: 32)), .real(0), .real(0)])
        try await r.db.exec("""
        INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text, extraction_method, extraction_confidence)
        VALUES (?,?,?,?,?,?,?,?,?);
        """, [.uuid(block), .uuid(doc), .uuid(sv), .integer(0), .text("paragraph"), .text("t"), .text("t"), .text("native"), .real(1.0)])
        try await r.db.exec("INSERT INTO evidence_block_objects (evidence_block_id, knowledge_object_id, linked_at) VALUES (?,?,?);",
                            [.uuid(block), .uuid(ko), .real(0)])
        try await r.db.exec("""
        INSERT INTO contradictions (id, description, claim_a, claim_b, severity, status, detected_at)
        VALUES (?,?,?,?,?,?,?);
        """, [.uuid(contradiction), .text("d"), .text("A"), .text("B"), .text("medium"), .text("open"), .real(0)])
        try await r.db.exec("""
        INSERT INTO gap_nodes (id, kind, description, reason, confidence, detected_at, dismissed)
        VALUES (?,?,?,?,?,?,0);
        """, [.uuid(gap), .text("sequenceHole"), .text("g"), .text("r"), .real(0.5), .real(0)])

        let issue = try await r.repo.create(workspaceID: r.workspaceID, title: "Links", detail: nil,
                                            type: .evidenceConcern, priority: .normal, reviewer: "u", at: t0)
        let targets: [IssueLinkTarget] = [.claim(claim), .event(event), .entity(entity),
                                          .evidenceBlock(block), .knowledgeObject(ko),
                                          .sourceVersion(sv), .contradiction(contradiction), .gap(gap)]
        for target in targets {
            _ = try await r.repo.addLink(issueID: issue.id, target: target, role: .related, at: t0)
        }
        let links = try await r.repo.links(issueID: issue.id)
        #expect(Set(links.map(\.target)) == Set(targets))

        // Duplicate rejected; unresolvable target rejected; missing issue rejected.
        await #expect(throws: ProfessionalIssueError.duplicateLink) {
            _ = try await r.repo.addLink(issueID: issue.id, target: .claim(claim), role: .related, at: t0)
        }
        let ghost = UUID()
        await #expect(throws: ProfessionalIssueError.targetNotFound(kind: "claim", id: ghost)) {
            _ = try await r.repo.addLink(issueID: issue.id, target: .claim(ghost), role: .related, at: t0)
        }
        await #expect(throws: (any Error).self) {
            _ = try await r.repo.addLink(issueID: UUID(), target: .claim(claim), role: .related, at: t0)
        }
    }

    @Test("A target belonging exclusively to another workspace is rejected; shared/unscoped accepted")
    func crossWorkspaceLinkRejected() async throws {
        let r = try await rig()
        // Workspace B with its own exclusive source + KO + claim + member entity.
        let wsB = UUID()
        try await r.db.exec("INSERT INTO workspaces (id, title, template_type, created_at, updated_at) VALUES (?,?,?,?,?);",
                            [.uuid(wsB), .text("WS-B"), .text("general"), .real(0), .real(0)])
        let rigB = Rig(db: r.db, url: r.url, repo: r.repo, workspaceID: wsB)
        let (fileB, koB) = try await seedSource(rigB, workspace: wsB)
        let claimB = try await seedClaim(r, ko: koB)
        let entityB = UUID()
        try await r.db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);",
                            [.uuid(entityB), .text("person"), .text("B"), .text(entityB.uuidString.lowercased()), .uuid(koB)])
        try await r.db.exec("INSERT INTO workspace_entities (workspace_id, entity_id, added_at) VALUES (?,?,?);",
                            [.uuid(wsB), .uuid(entityB), .real(0)])

        let issue = try await r.repo.create(workspaceID: r.workspaceID, title: "A-issue", detail: nil,
                                            type: .question, priority: .normal, reviewer: "u", at: t0)
        // KO / claim / entity determinably bound to workspace B only → rejected in workspace A.
        await #expect(throws: ProfessionalIssueError.crossWorkspaceLink(kind: "knowledgeObject", id: koB)) {
            _ = try await r.repo.addLink(issueID: issue.id, target: .knowledgeObject(koB), role: .related, at: t0)
        }
        await #expect(throws: ProfessionalIssueError.crossWorkspaceLink(kind: "claim", id: claimB)) {
            _ = try await r.repo.addLink(issueID: issue.id, target: .claim(claimB), role: .related, at: t0)
        }
        await #expect(throws: ProfessionalIssueError.crossWorkspaceLink(kind: "entity", id: entityB)) {
            _ = try await r.repo.addLink(issueID: issue.id, target: .entity(entityB), role: .related, at: t0)
        }
        // A file shared into workspace A as well → accepted.
        try await r.db.exec("INSERT INTO workspace_sources (workspace_id, file_id, added_at) VALUES (?,?,?);",
                            [.uuid(r.workspaceID), .uuid(fileB), .real(0)])
        _ = try await r.repo.addLink(issueID: issue.id, target: .knowledgeObject(koB), role: .related, at: t0)
        // A KO whose file is in NO workspace (indeterminable) → accepted on existence.
        let orphanFile = UUID(), orphanKO = UUID()
        try await r.db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                            [.uuid(orphanFile), .text("file://\(orphanFile)"), .text("txt")])
        try await r.db.exec("INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);",
                            [.uuid(orphanKO), .uuid(orphanFile), .text("txt"), .text("c"), .real(0), .real(0)])
        _ = try await r.repo.addLink(issueID: issue.id, target: .knowledgeObject(orphanKO), role: .related, at: t0)
    }

    // MARK: - Lifecycle + audit (cases 9, 10, 11, 12)

    @Test("A status transition writes the exact audit row")
    func transitionWritesAudit() async throws {
        let r = try await rig()
        let issue = try await r.repo.create(workspaceID: r.workspaceID, title: "T", detail: nil,
                                            type: .question, priority: .normal, reviewer: "u", at: t0)
        _ = try await r.repo.transition(issueID: issue.id, to: .inReview, reviewer: "rev",
                                        reason: "looking", at: t0.addingTimeInterval(60))
        let reviews = try await r.repo.reviews(issueID: issue.id)
        #expect(reviews.count == 2)
        let tr = try #require(reviews.last)
        #expect(tr.action == .statusChanged)
        #expect(tr.priorStatus == .open)
        #expect(tr.newStatus == .inReview)
        #expect(tr.reviewer == "rev")
        #expect(tr.reason == "looking")
        #expect(tr.reviewedAt == t0.addingTimeInterval(60))
    }

    @Test("A failed review write rolls the status change back")
    func failedReviewRollsBackStatus() async throws {
        let r = try await rig()
        let issue = try await r.repo.create(workspaceID: r.workspaceID, title: "RB", detail: nil,
                                            type: .question, priority: .normal, reviewer: "u", at: t0)
        await r.repo.setInjectFailure(.beforeReviewInsert)
        await #expect(throws: (any Error).self) {
            _ = try await r.repo.transition(issueID: issue.id, to: .resolved, reviewer: "u", reason: nil, at: t0)
        }
        await r.repo.setInjectFailure(nil)
        let loaded = try #require(try await r.repo.issue(id: issue.id))
        #expect(loaded.status == .open, "status changed despite the failed ledger write")
        #expect(loaded.closedAt == nil)
        #expect(try await r.repo.reviews(issueID: issue.id).count == 1)   // only `created`
    }

    @Test("Resolve → reopen lifecycle (closedAt set then cleared, reopened action recorded)")
    func resolveReopenLifecycle() async throws {
        let r = try await rig()
        let issue = try await r.repo.create(workspaceID: r.workspaceID, title: "L", detail: nil,
                                            type: .question, priority: .normal, reviewer: "u", at: t0)
        let resolved = try await r.repo.transition(issueID: issue.id, to: .resolved, reviewer: "u",
                                                   reason: "answered", at: t0.addingTimeInterval(1))
        #expect(resolved.closedAt != nil)
        let reopened = try await r.repo.transition(issueID: issue.id, to: .open, reviewer: "u",
                                                   reason: "new info", at: t0.addingTimeInterval(2))
        #expect(reopened.status == .open)
        #expect(reopened.closedAt == nil)
        let actions = try await r.repo.reviews(issueID: issue.id).map(\.action)
        #expect(actions == [.created, .resolved, .reopened])
    }

    @Test("Dismiss/supersede/archive rules: dismissed reopen-only; superseded→archive; archived terminal")
    func dismissSupersedeArchive() async throws {
        let r = try await rig()
        // Dismissed: only an explicit reopen is legal. (Strictly increasing timestamps — the
        // ledger orders by reviewed_at, so ties would make `.last` nondeterministic.)
        let d = try await r.repo.create(workspaceID: r.workspaceID, title: "D", detail: nil,
                                        type: .risk, priority: .low, reviewer: "u", at: t0)
        _ = try await r.repo.transition(issueID: d.id, to: .dismissed, reviewer: "u", reason: nil, at: t0.addingTimeInterval(1))
        await #expect(throws: ProfessionalIssueError.invalidTransition(from: .dismissed, to: .resolved)) {
            _ = try await r.repo.transition(issueID: d.id, to: .resolved, reviewer: "u", reason: nil, at: t0.addingTimeInterval(2))
        }
        _ = try await r.repo.transition(issueID: d.id, to: .open, reviewer: "u", reason: nil, at: t0.addingTimeInterval(3))
        #expect(try await r.repo.reviews(issueID: d.id).last?.action == .reopened)

        // Superseded: may only be archived.
        let s = try await r.repo.create(workspaceID: r.workspaceID, title: "S", detail: nil,
                                        type: .lead, priority: .low, reviewer: "u", at: t0)
        _ = try await r.repo.transition(issueID: s.id, to: .superseded, reviewer: "u", reason: nil, at: t0)
        await #expect(throws: ProfessionalIssueError.invalidTransition(from: .superseded, to: .open)) {
            _ = try await r.repo.transition(issueID: s.id, to: .open, reviewer: "u", reason: nil, at: t0)
        }
        try await r.repo.archive(issueID: s.id, reviewer: "u", reason: nil, at: t0)

        // Archived is terminal — closing/reopening an archived issue is rejected.
        await #expect(throws: ProfessionalIssueError.invalidTransition(from: .archived, to: .resolved)) {
            _ = try await r.repo.transition(issueID: s.id, to: .resolved, reviewer: "u", reason: nil, at: t0)
        }
        await #expect(throws: ProfessionalIssueError.invalidTransition(from: .archived, to: .archived)) {
            try await r.repo.archive(issueID: s.id, reviewer: "u", reason: nil, at: t0)
        }
    }

    // MARK: - Archive preservation (case 13)

    @Test("Archiving preserves links and the full review history")
    func archivePreservesLinksAndReviews() async throws {
        let r = try await rig()
        let (_, ko) = try await seedSource(r, workspace: r.workspaceID)
        let claim = try await seedClaim(r, ko: ko)
        let issue = try await r.repo.create(workspaceID: r.workspaceID, title: "A", detail: nil,
                                            type: .findingCandidate, priority: .normal, reviewer: "u", at: t0)
        _ = try await r.repo.addLink(issueID: issue.id, target: .claim(claim), role: .supports, at: t0)
        try await r.repo.archive(issueID: issue.id, reviewer: "u", reason: "done", at: t0.addingTimeInterval(9))
        #expect(try await r.repo.links(issueID: issue.id).count == 1)
        let reviews = try await r.repo.reviews(issueID: issue.id)
        #expect(reviews.map(\.action) == [.created, .archived])
        #expect(try #require(try await r.repo.issue(id: issue.id)).status == .archived)
    }

    // MARK: - Canonical isolation (cases 14, 15, 16)

    @Test("Issue operations never mutate the linked Claim, contradiction or gap")
    func canonicalIsolation() async throws {
        let r = try await rig()
        let (_, ko) = try await seedSource(r, workspace: r.workspaceID)
        let claim = try await seedClaim(r, ko: ko, statement: "immutable statement")
        let contradiction = UUID(), gap = UUID()
        try await r.db.exec("""
        INSERT INTO contradictions (id, description, claim_a, claim_b, severity, status, detected_at)
        VALUES (?,?,?,?,?,?,?);
        """, [.uuid(contradiction), .text("d"), .text("A"), .text("B"), .text("high"), .text("open"), .real(0)])
        try await r.db.exec("""
        INSERT INTO gap_nodes (id, kind, description, reason, confidence, detected_at, dismissed)
        VALUES (?,?,?,?,?,?,0);
        """, [.uuid(gap), .text("sequenceHole"), .text("g"), .text("r"), .real(0.5), .real(0)])

        func canonicalFingerprint() async throws -> [String] {
            var out: [String] = []
            let c = try await r.db.query(
                "SELECT statement, review_disposition, evidence_basis FROM claims WHERE id = ?;", [.uuid(claim)]).first
            out.append("\(c?.string(0) ?? "")|\(c?.string(1) ?? "")|\(c?.string(2) ?? "")")
            out.append(try await r.db.query("SELECT status FROM contradictions WHERE id = ?;", [.uuid(contradiction)]).first?.string(0) ?? "")
            out.append(String(try await r.db.query("SELECT dismissed FROM gap_nodes WHERE id = ?;", [.uuid(gap)]).first?.int(0) ?? -1))
            return out
        }
        let before = try await canonicalFingerprint()

        let issue = try await r.repo.create(workspaceID: r.workspaceID, title: "Iso", detail: nil,
                                            type: .contradictionReview, priority: .critical, reviewer: "u", at: t0)
        _ = try await r.repo.addLink(issueID: issue.id, target: .claim(claim), role: .requiresReview, at: t0)
        _ = try await r.repo.addLink(issueID: issue.id, target: .contradiction(contradiction), role: .triggeredBy, at: t0)
        _ = try await r.repo.addLink(issueID: issue.id, target: .gap(gap), role: .related, at: t0)
        _ = try await r.repo.transition(issueID: issue.id, to: .resolved, reviewer: "u", reason: "handled", at: t0)
        _ = try await r.repo.transition(issueID: issue.id, to: .archived, reviewer: "u", reason: nil, at: t0)

        // Resolving/archiving the WORKING issue changed nothing canonical: claim statement/review/
        // basis identical, contradiction still open, gap still undismissed.
        #expect(try await canonicalFingerprint() == before)
    }

    // MARK: - Workspace cascade (case 17)

    @Test("Deleting a workspace removes Issue working state but leaves canonical evidence intact")
    func workspaceDeletionCascades() async throws {
        let r = try await rig()
        let (file, ko) = try await seedSource(r, workspace: r.workspaceID)
        let claim = try await seedClaim(r, ko: ko)
        let issue = try await r.repo.create(workspaceID: r.workspaceID, title: "Gone", detail: nil,
                                            type: .question, priority: .normal, reviewer: "u", at: t0)
        _ = try await r.repo.addLink(issueID: issue.id, target: .claim(claim), role: .related, at: t0)

        try await r.db.exec("DELETE FROM workspaces WHERE id = ?;", [.uuid(r.workspaceID)])

        #expect(try await issueCount(r, table: "professional_issues") == 0)
        #expect(try await issueCount(r, table: "professional_issue_links") == 0)
        #expect(try await issueCount(r, table: "professional_issue_reviews") == 0)
        // Canonical evidence untouched by the working-state cascade.
        #expect(Int(try await r.db.query("SELECT COUNT(*) FROM claims WHERE id = ?;", [.uuid(claim)]).first?.int(0) ?? 0) == 1)
        #expect(Int(try await r.db.query("SELECT COUNT(*) FROM knowledge_objects WHERE id = ?;", [.uuid(ko)]).first?.int(0) ?? 0) == 1)
        #expect(Int(try await r.db.query("SELECT COUNT(*) FROM files WHERE id = ?;", [.uuid(file)]).first?.int(0) ?? 0) == 1)
        #expect(try await MigrationFaultHarness.foreignKeyViolationCount(r.db) == 0)
    }

    // MARK: - Durability (case 18)

    @Test("Reopening the database recovers the exact Issue state, links and reviews")
    func reopenRecoversState() async throws {
        let r = try await rig()
        let (_, ko) = try await seedSource(r, workspace: r.workspaceID)
        let claim = try await seedClaim(r, ko: ko)
        let issue = try await r.repo.create(workspaceID: r.workspaceID, title: "Durable", detail: "d",
                                            type: .lead, priority: .critical, reviewer: "u", at: t0)
        _ = try await r.repo.addLink(issueID: issue.id, target: .claim(claim), role: .supports, at: t0)
        _ = try await r.repo.transition(issueID: issue.id, to: .inReview, reviewer: "u", reason: "r", at: t0.addingTimeInterval(5))

        let reopenedDB = try MigrationFixtureBuilder.reopen(at: r.url)
        let repo2 = ProfessionalIssueRepository(database: reopenedDB)
        let loaded = try #require(try await repo2.issue(id: issue.id))
        #expect(loaded.title == "Durable")
        #expect(loaded.status == .inReview)
        #expect(loaded.priority == .critical)
        #expect(try await repo2.links(issueID: issue.id).map(\.target) == [.claim(claim)])
        #expect(try await repo2.reviews(issueID: issue.id).map(\.action) == [.created, .statusChanged])
    }
}
