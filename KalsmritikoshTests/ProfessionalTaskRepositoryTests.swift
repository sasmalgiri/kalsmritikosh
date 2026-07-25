//
//  ProfessionalTaskRepositoryTests.swift
//  KalsmritikoshTests
//
//  OPS-002 — the Task Engine's truth invariants: automation/model/source tasks are BORN
//  candidates and cannot do active work before an explicit user/rule confirmation (audited);
//  status changes are atomic with their append-only review ledger (failed ledger write rolls
//  back); dependencies are same-workspace, acyclic, non-self, non-duplicate, and a blocking
//  predecessor prevents completion; evidence links carry IDs only and are validated by the SHARED
//  fail-closed WorkflowTargetValidator; task lifecycle never mutates canonical evidence; workspace
//  deletion removes ONLY workflow state; state is durable across reopen.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("OPS-002 — professional task repository")
struct ProfessionalTaskRepositoryTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Rig {
        let db: Database
        let url: URL
        let repo: ProfessionalTaskRepository
        let workspaceID: UUID
    }

    private func rig() async throws -> Rig {
        let url = MigrationFixtureBuilder.newTemporaryURL()
        let db = try await MigrationFixtureBuilder.database(atVersion: 0, at: url)
        try await SchemaMigrations.migrate(db)
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, template_type, created_at, updated_at) VALUES (?,?,?,?,?);",
                          [.uuid(ws), .text("WS-A"), .text("general"), .real(0), .real(0)])
        return Rig(db: db, url: url, repo: ProfessionalTaskRepository(database: db), workspaceID: ws)
    }

    private func addWorkspace(_ r: Rig, title: String) async throws -> UUID {
        let ws = UUID()
        try await r.db.exec("INSERT INTO workspaces (id, title, template_type, created_at, updated_at) VALUES (?,?,?,?,?);",
                            [.uuid(ws), .text(title), .text("general"), .real(0), .real(0)])
        return ws
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

    private func openTask(_ r: Rig, title: String = "T", workspace: UUID? = nil,
                          at date: Date? = nil) async throws -> ProfessionalTask {
        try await r.repo.createConfirmed(workspaceID: workspace ?? r.workspaceID, primaryIssueID: nil,
                                         title: title, detail: nil, type: .action, priority: .normal,
                                         owner: nil, authority: .user(actor: "u"), at: date ?? t0)
    }

    private func count(_ r: Rig, _ table: String) async throws -> Int {
        Int(try await r.db.query("SELECT COUNT(*) FROM \(table);", []).first?.int(0) ?? -1)
    }

    // MARK: - Origin safety (cases 3, 4, 5)

    @Test("Automation/model/source-created tasks are BORN candidates; user/rule go through createConfirmed")
    func automationTasksStartAsCandidate() async throws {
        let r = try await rig()
        for origin in [ProfessionalTaskOrigin.sourceExtraction, .modelProposed, .automationProposed, .importedLegacy] {
            let t = try await r.repo.createCandidate(workspaceID: r.workspaceID, primaryIssueID: nil,
                                                     title: "P-\(origin.rawValue)", detail: nil,
                                                     type: .action, priority: .normal, owner: nil,
                                                     origin: origin, proposedBy: "extractor", at: t0)
            #expect(t.status == .candidate)
            #expect(t.origin == origin)
            #expect(try await r.repo.reviews(taskID: t.id).map(\.action) == [.created])
        }
        // There is no candidate path for user/rule origins — they must carry validated authority.
        await #expect(throws: ProfessionalTaskError.invalidCandidateOrigin(.userCreated)) {
            _ = try await r.repo.createCandidate(workspaceID: r.workspaceID, primaryIssueID: nil,
                                                 title: "X", detail: nil, type: .action,
                                                 priority: .normal, owner: nil,
                                                 origin: .userCreated, proposedBy: "x", at: t0)
        }
        let user = try await openTask(r, title: "U")
        #expect(user.status == .open)
        #expect(user.origin == .userCreated)
        let rule = try await r.repo.createConfirmed(workspaceID: r.workspaceID, primaryIssueID: nil,
                                                    title: "R", detail: nil, type: .review,
                                                    priority: .high, owner: nil,
                                                    authority: .deterministicRule(ruleID: "rule-7", version: "1", actor: "engine"),
                                                    at: t0)
        #expect(rule.origin == .deterministicRule)
        // Blank authority is rejected before any write.
        await #expect(throws: ProfessionalTaskError.blankAuthority) {
            _ = try await r.repo.createConfirmed(workspaceID: r.workspaceID, primaryIssueID: nil,
                                                 title: "B", detail: nil, type: .action,
                                                 priority: .normal, owner: nil,
                                                 authority: .user(actor: "   "), at: t0)
        }
        await #expect(throws: ProfessionalTaskError.blankAuthority) {
            _ = try await r.repo.createConfirmed(workspaceID: r.workspaceID, primaryIssueID: nil,
                                                 title: "B", detail: nil, type: .action,
                                                 priority: .normal, owner: nil,
                                                 authority: .deterministicRule(ruleID: "", version: "1", actor: "e"), at: t0)
        }
    }

    @Test("A candidate task cannot do active work before confirmation; confirmation is audited")
    func candidateMustBeConfirmedFirst() async throws {
        let r = try await rig()
        let c = try await r.repo.createCandidate(workspaceID: r.workspaceID, primaryIssueID: nil,
                                                 title: "C", detail: nil, type: .action,
                                                 priority: .normal, owner: nil,
                                                 origin: .automationProposed, proposedBy: "bot", at: t0)
        // No active-work transitions from .candidate.
        for to in [ProfessionalTaskStatus.inProgress, .blocked] {
            await #expect(throws: ProfessionalTaskError.invalidTransition(from: .candidate, to: to)) {
                _ = try await r.repo.transition(taskID: c.id, to: to, reviewer: "u", reason: nil, at: t0)
            }
        }
        await #expect(throws: ProfessionalTaskError.invalidTransition(from: .candidate, to: .completed)) {
            _ = try await r.repo.complete(taskID: c.id, reviewer: "u", reason: nil, at: t0)
        }
        // candidate→open only via confirmCandidate, never via raw transition.
        await #expect(throws: ProfessionalTaskError.invalidTransition(from: .candidate, to: .open)) {
            _ = try await r.repo.transition(taskID: c.id, to: .open, reviewer: "u", reason: nil, at: t0)
        }
        let confirmed = try await r.repo.confirmCandidate(taskID: c.id, authority: .user(actor: "u"),
                                                          reason: "valid", at: t0.addingTimeInterval(1))
        #expect(confirmed.status == .open)
        let reviews = try await r.repo.reviews(taskID: c.id)
        #expect(reviews.map(\.action) == [.created, .candidateConfirmed])
        #expect(reviews.last?.priorStatus == .candidate)
        #expect(reviews.last?.newStatus == .open)
        // Re-confirming an open task fails; a candidate may still be cancelled (proposal rejection).
        await #expect(throws: ProfessionalTaskError.invalidTransition(from: .open, to: .open)) {
            _ = try await r.repo.confirmCandidate(taskID: c.id, authority: .user(actor: "u"), reason: nil, at: t0)
        }
        let c2 = try await r.repo.createCandidate(workspaceID: r.workspaceID, primaryIssueID: nil,
                                                  title: "C2", detail: nil, type: .action,
                                                  priority: .normal, owner: nil,
                                                  origin: .modelProposed, proposedBy: "m", at: t0)
        _ = try await r.repo.transition(taskID: c2.id, to: .cancelled, reviewer: "u", reason: "noise", at: t0.addingTimeInterval(2))
        #expect(try await r.repo.reviews(taskID: c2.id).last?.action == .cancelled)
    }

    // MARK: - Atomic ledger (case 6)

    @Test("A failed review write rolls the status change back")
    func failedReviewRollsBackStatus() async throws {
        let r = try await rig()
        let t = try await openTask(r)
        await r.repo.setInjectFailure(.beforeReviewInsert)
        await #expect(throws: (any Error).self) {
            _ = try await r.repo.transition(taskID: t.id, to: .inProgress, reviewer: "u", reason: nil, at: t0)
        }
        await r.repo.setInjectFailure(nil)
        let loaded = try #require(try await r.repo.task(id: t.id))
        #expect(loaded.status == .open, "status changed despite the failed ledger write")
        #expect(try await r.repo.reviews(taskID: t.id).count == 1)   // only `created`
        #expect(try await MigrationFaultHarness.integrityOK(r.db))
    }

    // MARK: - Dependencies (cases 7, 8)

    @Test("Self, ghost, cross-workspace, duplicate and cyclic blocking dependencies are rejected")
    func dependencyRules() async throws {
        let r = try await rig()
        let a = try await openTask(r, title: "A")
        let b = try await openTask(r, title: "B", at: t0.addingTimeInterval(1))
        let c = try await openTask(r, title: "C", at: t0.addingTimeInterval(2))
        await #expect(throws: ProfessionalTaskError.selfDependency) {
            _ = try await r.repo.addDependency(taskID: a.id, dependsOn: a.id, kind: .blocking, at: t0)
        }
        let ghost = UUID()
        await #expect(throws: ProfessionalTaskError.dependencyTaskNotFound(ghost)) {
            _ = try await r.repo.addDependency(taskID: a.id, dependsOn: ghost, kind: .blocking, at: t0)
        }
        let wsB = try await addWorkspace(r, title: "WS-B")
        let foreign = try await openTask(r, title: "F", workspace: wsB)
        await #expect(throws: ProfessionalTaskError.crossWorkspaceDependency) {
            _ = try await r.repo.addDependency(taskID: a.id, dependsOn: foreign.id, kind: .blocking, at: t0)
        }
        _ = try await r.repo.addDependency(taskID: a.id, dependsOn: b.id, kind: .blocking, at: t0)
        await #expect(throws: ProfessionalTaskError.duplicateDependency) {
            _ = try await r.repo.addDependency(taskID: a.id, dependsOn: b.id, kind: .blocking, at: t0)
        }
        // a→b→c committed; c→a would close the blocking cycle.
        _ = try await r.repo.addDependency(taskID: b.id, dependsOn: c.id, kind: .blocking, at: t0)
        await #expect(throws: ProfessionalTaskError.dependencyCycle) {
            _ = try await r.repo.addDependency(taskID: c.id, dependsOn: a.id, kind: .blocking, at: t0)
        }
        // An informational back-edge is fine (it never blocks, so it cannot deadlock work).
        _ = try await r.repo.addDependency(taskID: c.id, dependsOn: a.id, kind: .informational, at: t0)
        #expect(try await r.repo.dependencies(taskID: a.id).count == 1)
    }

    @Test("An incomplete blocking predecessor prevents completion; informational links never block")
    func blockingPredecessorPreventsCompletion() async throws {
        let r = try await rig()
        let main = try await openTask(r, title: "Main")
        let pre = try await openTask(r, title: "Pre", at: t0.addingTimeInterval(1))
        let info = try await openTask(r, title: "Info", at: t0.addingTimeInterval(2))
        _ = try await r.repo.addDependency(taskID: main.id, dependsOn: pre.id, kind: .blocking, at: t0)
        _ = try await r.repo.addDependency(taskID: main.id, dependsOn: info.id, kind: .informational, at: t0)

        await #expect(throws: ProfessionalTaskError.blockedByIncompleteDependency(pre.id)) {
            _ = try await r.repo.complete(taskID: main.id, reviewer: "u", reason: nil, at: t0.addingTimeInterval(3))
        }
        _ = try await r.repo.complete(taskID: pre.id, reviewer: "u", reason: nil, at: t0.addingTimeInterval(4))
        // `info` is still open — informational edges never block.
        let done = try await r.repo.complete(taskID: main.id, reviewer: "u", reason: "done", at: t0.addingTimeInterval(5))
        #expect(done.status == .completed)
        #expect(done.completedAt == t0.addingTimeInterval(5))
        #expect(try await r.repo.reviews(taskID: main.id).last?.action == .completed)
        // Reopen clears completedAt and is audited.
        let reopened = try await r.repo.reopen(taskID: main.id, reviewer: "u", reason: "redo", at: t0.addingTimeInterval(6))
        #expect(reopened.status == .open)
        #expect(reopened.completedAt == nil)
        #expect(try await r.repo.reviews(taskID: main.id).last?.action == .reopened)
    }

    // MARK: - Evidence links (case 9)

    @Test("Evidence targets must exist and obey workspace scope; scopes must belong to the task")
    func evidenceLinkValidation() async throws {
        let r = try await rig()
        let (_, ko) = try await seedSource(r, workspace: r.workspaceID)
        let claim = try await seedClaim(r, ko: ko)
        let task = try await openTask(r)

        let link = try await r.repo.addEvidenceLink(taskID: task.id, scope: .task,
                                                    target: .claim(claim), role: .basis, at: t0)
        #expect(try await r.repo.evidenceLinks(taskID: task.id) == [link])
        await #expect(throws: ProfessionalTaskError.duplicateLink) {
            _ = try await r.repo.addEvidenceLink(taskID: task.id, scope: .task,
                                                 target: .claim(claim), role: .basis, at: t0)
        }
        let ghost = UUID()
        await #expect(throws: ProfessionalTaskError.targetNotFound(kind: "claim", id: ghost)) {
            _ = try await r.repo.addEvidenceLink(taskID: task.id, scope: .task,
                                                 target: .claim(ghost), role: .basis, at: t0)
        }
        // A claim bound exclusively to another workspace is rejected (shared validator).
        let wsB = try await addWorkspace(r, title: "WS-B")
        let (_, koB) = try await seedSource(r, workspace: wsB)
        let claimB = try await seedClaim(r, ko: koB)
        await #expect(throws: ProfessionalTaskError.crossWorkspaceLink(kind: "claim", id: claimB)) {
            _ = try await r.repo.addEvidenceLink(taskID: task.id, scope: .task,
                                                 target: .claim(claimB), role: .context, at: t0)
        }
        // Candidate/deadline scopes must exist AND belong to THIS task.
        await #expect(throws: ProfessionalTaskError.scopeObjectNotFound) {
            _ = try await r.repo.addEvidenceLink(taskID: task.id, scope: .deadlineCandidate(UUID()),
                                                 target: .claim(claim), role: .deadlineBasis, at: t0)
        }
        let otherTask = try await openTask(r, title: "Other", at: t0.addingTimeInterval(1))
        let deadlines = DeadlineRepository(database: r.db)
        let foreignCandidate = try await deadlines.createCandidate(
            taskID: otherTask.id, value: DeadlineValue(date: t0, precision: .day, timeZoneIdentifier: "UTC"),
            kind: .due, origin: .sourceExtraction, confidence: 0.9, proposedBy: "x",
            ruleID: nil, ruleVersion: nil, at: t0)
        await #expect(throws: ProfessionalTaskError.scopeDoesNotBelongToTask) {
            _ = try await r.repo.addEvidenceLink(taskID: task.id, scope: .deadlineCandidate(foreignCandidate.id),
                                                 target: .claim(claim), role: .deadlineBasis, at: t0)
        }
        // A candidate of THIS task scopes fine, and the link reads back with its scope.
        let mine = try await deadlines.createCandidate(
            taskID: task.id, value: DeadlineValue(date: t0, precision: .day, timeZoneIdentifier: "UTC"),
            kind: .due, origin: .sourceExtraction, confidence: 0.9, proposedBy: "x",
            ruleID: nil, ruleVersion: nil, at: t0)
        let scoped = try await r.repo.addEvidenceLink(taskID: task.id, scope: .deadlineCandidate(mine.id),
                                                      target: .claim(claim), role: .deadlineBasis,
                                                      at: t0.addingTimeInterval(1))
        #expect(scoped.scope == .deadlineCandidate(mine.id))
        #expect(try await r.repo.evidenceLinks(taskID: task.id).count == 2)
        try await r.repo.removeEvidenceLink(id: scoped.id)
        #expect(try await r.repo.evidenceLinks(taskID: task.id).count == 1)
    }

    // MARK: - Canonical isolation (case 10)

    @Test("Task lifecycle never mutates linked Claims, contradictions or gaps")
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

        let task = try await openTask(r, title: "Iso")
        _ = try await r.repo.addEvidenceLink(taskID: task.id, scope: .task, target: .claim(claim),
                                             role: .completionEvidence, at: t0)
        _ = try await r.repo.addEvidenceLink(taskID: task.id, scope: .task, target: .contradiction(contradiction),
                                             role: .requiresReview, at: t0)
        _ = try await r.repo.addEvidenceLink(taskID: task.id, scope: .task, target: .gap(gap),
                                             role: .context, at: t0)
        _ = try await r.repo.transition(taskID: task.id, to: .inProgress, reviewer: "u", reason: nil, at: t0.addingTimeInterval(1))
        _ = try await r.repo.complete(taskID: task.id, reviewer: "u", reason: "workflow done", at: t0.addingTimeInterval(2))
        try await r.repo.archive(taskID: task.id, reviewer: "u", reason: nil, at: t0.addingTimeInterval(3))

        // COMPLETING the task confirmed nothing: claim/review/contradiction/gap all unchanged.
        #expect(try await canonicalFingerprint() == before)
    }

    // MARK: - Archive preservation (case 23)

    @Test("Archiving preserves evidence links and the full review history")
    func archivePreservesHistory() async throws {
        let r = try await rig()
        let (_, ko) = try await seedSource(r, workspace: r.workspaceID)
        let claim = try await seedClaim(r, ko: ko)
        let task = try await openTask(r)
        _ = try await r.repo.addEvidenceLink(taskID: task.id, scope: .task, target: .claim(claim),
                                             role: .basis, at: t0)
        _ = try await r.repo.transition(taskID: task.id, to: .inProgress, reviewer: "u", reason: nil, at: t0.addingTimeInterval(1))
        try await r.repo.archive(taskID: task.id, reviewer: "u", reason: "closing out", at: t0.addingTimeInterval(2))
        #expect(try await r.repo.evidenceLinks(taskID: task.id).count == 1)
        let reviews = try await r.repo.reviews(taskID: task.id)
        #expect(reviews.map(\.action) == [.created, .statusChanged, .archived])
        let loaded = try #require(try await r.repo.task(id: task.id))
        #expect(loaded.status == .archived)
        #expect(loaded.archivedAt == t0.addingTimeInterval(2))
        // Archived is terminal.
        await #expect(throws: ProfessionalTaskError.invalidTransition(from: .archived, to: .open)) {
            _ = try await r.repo.transition(taskID: task.id, to: .open, reviewer: "u", reason: nil, at: t0)
        }
    }

    // MARK: - Workspace cascade (case 24)

    @Test("Workspace deletion removes Task/Deadline workflow state only; canonical evidence survives")
    func workspaceDeletionCascades() async throws {
        let r = try await rig()
        let (file, ko) = try await seedSource(r, workspace: r.workspaceID)
        let claim = try await seedClaim(r, ko: ko)
        let task = try await openTask(r, title: "Doomed")
        let pre = try await openTask(r, title: "Pre", at: t0.addingTimeInterval(1))
        _ = try await r.repo.addDependency(taskID: task.id, dependsOn: pre.id, kind: .blocking, at: t0)
        _ = try await r.repo.addEvidenceLink(taskID: task.id, scope: .task, target: .claim(claim),
                                             role: .basis, at: t0)
        let deadlines = DeadlineRepository(database: r.db)
        let candidate = try await deadlines.createCandidate(
            taskID: task.id, value: DeadlineValue(date: t0.addingTimeInterval(86_400), precision: .day, timeZoneIdentifier: "UTC"),
            kind: .due, origin: .sourceExtraction, confidence: 0.9, proposedBy: "x",
            ruleID: nil, ruleVersion: nil, at: t0)
        _ = try await deadlines.confirmCandidate(
            id: candidate.id,
            confirmation: DeadlineConfirmation(kind: .user, confirmedBy: "u", confirmedAt: t0.addingTimeInterval(2),
                                               reason: nil, ruleID: nil, ruleVersion: nil),
            at: t0.addingTimeInterval(2))

        try await r.db.exec("DELETE FROM workspaces WHERE id = ?;", [.uuid(r.workspaceID)])

        for table in ["professional_tasks", "professional_task_dependencies", "deadline_candidates",
                      "deadlines", "professional_task_evidence_links", "professional_task_reviews",
                      "deadline_candidate_reviews", "deadline_reviews"] {
            #expect(try await count(r, table) == 0, "\(table) rows survived the workspace cascade")
        }
        // Canonical evidence untouched.
        #expect(Int(try await r.db.query("SELECT COUNT(*) FROM claims WHERE id = ?;", [.uuid(claim)]).first?.int(0) ?? 0) == 1)
        #expect(Int(try await r.db.query("SELECT COUNT(*) FROM knowledge_objects WHERE id = ?;", [.uuid(ko)]).first?.int(0) ?? 0) == 1)
        #expect(Int(try await r.db.query("SELECT COUNT(*) FROM files WHERE id = ?;", [.uuid(file)]).first?.int(0) ?? 0) == 1)
        #expect(try await MigrationFaultHarness.foreignKeyViolationCount(r.db) == 0)
    }

    // MARK: - Durability (case 25)

    @Test("Reopening the database recovers exact task state, dependencies, links and reviews")
    func reopenRecoversState() async throws {
        let r = try await rig()
        let (_, ko) = try await seedSource(r, workspace: r.workspaceID)
        let claim = try await seedClaim(r, ko: ko)
        let task = try await openTask(r, title: "Durable")
        let pre = try await openTask(r, title: "Pre", at: t0.addingTimeInterval(1))
        _ = try await r.repo.addDependency(taskID: task.id, dependsOn: pre.id, kind: .informational, at: t0)
        _ = try await r.repo.addEvidenceLink(taskID: task.id, scope: .task, target: .claim(claim),
                                             role: .basis, at: t0)
        _ = try await r.repo.transition(taskID: task.id, to: .inProgress, reviewer: "u", reason: "go", at: t0.addingTimeInterval(2))

        let reopenedDB = try MigrationFixtureBuilder.reopen(at: r.url)
        let repo2 = ProfessionalTaskRepository(database: reopenedDB)
        let loaded = try #require(try await repo2.task(id: task.id))
        #expect(loaded.title == "Durable")
        #expect(loaded.status == .inProgress)
        #expect(loaded.origin == .userCreated)
        #expect(try await repo2.dependencies(taskID: task.id).map(\.dependsOnTaskID) == [pre.id])
        #expect(try await repo2.evidenceLinks(taskID: task.id).map(\.target) == [.claim(claim)])
        #expect(try await repo2.reviews(taskID: task.id).map(\.action) == [.created, .statusChanged])
    }
}
