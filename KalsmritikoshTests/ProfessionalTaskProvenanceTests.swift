//
//  ProfessionalTaskProvenanceTests.swift
//  KalsmritikoshTests
//
//  OPS-002.1 — confirmation provenance hardening. Locks the four corrections:
//   1. "Exact evidence" for deterministic-rule deadline confirmation means a candidate-scoped
//      `deadlineBasis` link resolving to exact cited evidence (an EvidenceBlock tied to a source
//      version, or a Claim with an exact block+version evidence reference) — Entity/Event/Gap/
//      Contradiction/context-role links never qualify.
//   2. A Task's primary Issue must live in the SAME workspace.
//   3. Confirmed Deadlines attach only to operational tasks (open/inProgress/blocked) — never
//      candidate/completed/cancelled/archived. Candidate PROPOSALS remain allowed on candidate
//      tasks.
//   4. Deterministic-rule identity (rule ID + version) is PERSISTED on the task review ledger
//      (schema v70) and survives reopening the database — validated-then-discarded is a bug.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("OPS-002.1 — confirmation provenance (v70)")
struct ProfessionalTaskProvenanceTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let due = Date(timeIntervalSince1970: 1_700_600_000)

    private struct Rig {
        let db: Database
        let url: URL
        let tasks: ProfessionalTaskRepository
        let deadlines: DeadlineRepository
        let workspaceID: UUID
        let taskID: UUID
        let koID: UUID
        let evidenceBlockID: UUID
    }

    private func rig() async throws -> Rig {
        let url = MigrationFixtureBuilder.newTemporaryURL()
        let db = try await MigrationFixtureBuilder.database(atVersion: 0, at: url)
        try await SchemaMigrations.migrate(db)
        let ws = UUID(), f = UUID(), ko = UUID(), doc = UUID(), sv = UUID(), block = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, template_type, created_at, updated_at) VALUES (?,?,?,?,?);",
                          [.uuid(ws), .text("WS"), .text("general"), .real(0), .real(0)])
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                          [.uuid(f), .text("file://\(f)"), .text("txt")])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);
        """, [.uuid(ko), .uuid(f), .text("txt"), .text("c"), .real(0), .real(0)])
        try await db.exec("INSERT INTO workspace_sources (workspace_id, file_id, added_at) VALUES (?,?,?);",
                          [.uuid(ws), .uuid(f), .real(0)])
        try await db.exec("""
        INSERT INTO source_versions (id, logical_source_id, document_id, content_hash, valid_from, is_current, created_at)
        VALUES (?,?,?,?,?,1,?);
        """, [.uuid(sv), .uuid(f), .uuid(doc), .text(String(repeating: "cd", count: 32)), .real(0), .real(0)])
        try await db.exec("""
        INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text, extraction_method, extraction_confidence)
        VALUES (?,?,?,?,?,?,?,?,?);
        """, [.uuid(block), .uuid(doc), .uuid(sv), .integer(0), .text("paragraph"),
              .text("due on the 17th"), .text("due on the 17th"), .text("native"), .real(1.0)])
        try await db.exec("INSERT INTO evidence_block_objects (evidence_block_id, knowledge_object_id, linked_at) VALUES (?,?,?);",
                          [.uuid(block), .uuid(ko), .real(0)])
        let tasks = ProfessionalTaskRepository(database: db)
        let task = try await tasks.createConfirmed(workspaceID: ws, primaryIssueID: nil,
                                                   title: "Respond", detail: nil, type: .action,
                                                   priority: .high, owner: nil,
                                                   authority: .user(actor: "u"), at: t0)
        return Rig(db: db, url: url, tasks: tasks, deadlines: DeadlineRepository(database: db),
                   workspaceID: ws, taskID: task.id, koID: ko, evidenceBlockID: block)
    }

    private func dayValue() -> DeadlineValue {
        DeadlineValue(date: due, precision: .day, timeZoneIdentifier: "UTC")
    }

    private func pendingCandidate(_ r: Rig, task: UUID? = nil, at date: Date? = nil) async throws -> DeadlineCandidate {
        try await r.deadlines.createCandidate(taskID: task ?? r.taskID, value: dayValue(), kind: .due,
                                              origin: .sourceExtraction, confidence: 0.9,
                                              proposedBy: "extractor", ruleID: nil, ruleVersion: nil,
                                              at: date ?? t0)
    }

    private func ruleConfirmation(at date: Date) -> DeadlineConfirmation {
        DeadlineConfirmation(kind: .deterministicRule, confirmedBy: "engine", confirmedAt: date,
                             reason: "30-day rule", ruleID: "resp-30d", ruleVersion: "2")
    }

    private func userConfirmation(at date: Date) -> DeadlineConfirmation {
        DeadlineConfirmation(kind: .user, confirmedBy: "u", confirmedAt: date,
                             reason: nil, ruleID: nil, ruleVersion: nil)
    }

    // MARK: - Correction 1: exact evidence (tests 1, 2, 3)

    @Test("Non-exact and context-role links never satisfy rule confirmation; an exact deadlineBasis EvidenceBlock does")
    func exactEvidenceGate() async throws {
        let r = try await rig()
        // Entity target with deadlineBasis role — a resolvable canonical object, but NOT exact
        // cited evidence.
        let entity = UUID()
        try await r.db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);",
                            [.uuid(entity), .text("person"), .text("S"), .text(entity.uuidString.lowercased()), .uuid(r.koID)])
        try await r.db.exec("INSERT INTO workspace_entities (workspace_id, entity_id, added_at) VALUES (?,?,?);",
                            [.uuid(r.workspaceID), .uuid(entity), .real(0)])
        let c1 = try await pendingCandidate(r)
        _ = try await r.tasks.addEvidenceLink(taskID: r.taskID, scope: .deadlineCandidate(c1.id),
                                              target: .entity(entity), role: .deadlineBasis, at: t0)
        // A bare KnowledgeObject target is not exact either.
        _ = try await r.tasks.addEvidenceLink(taskID: r.taskID, scope: .deadlineCandidate(c1.id),
                                              target: .knowledgeObject(r.koID), role: .deadlineBasis, at: t0)
        await #expect(throws: DeadlineError.ruleEvidenceRequired) {
            _ = try await r.deadlines.confirmCandidate(id: c1.id, confirmation: self.ruleConfirmation(at: self.t0), at: self.t0)
        }
        // The EXACT block linked with a CONTEXT role does not qualify — role matters.
        let c2 = try await pendingCandidate(r, at: t0.addingTimeInterval(1))
        _ = try await r.tasks.addEvidenceLink(taskID: r.taskID, scope: .deadlineCandidate(c2.id),
                                              target: .evidenceBlock(r.evidenceBlockID), role: .context, at: t0)
        await #expect(throws: DeadlineError.ruleEvidenceRequired) {
            _ = try await r.deadlines.confirmCandidate(id: c2.id, confirmation: self.ruleConfirmation(at: self.t0), at: self.t0)
        }
        // A task-scoped deadlineBasis link (not scoped to THIS candidate) does not qualify.
        let c3 = try await pendingCandidate(r, at: t0.addingTimeInterval(2))
        _ = try await r.tasks.addEvidenceLink(taskID: r.taskID, scope: .task,
                                              target: .evidenceBlock(r.evidenceBlockID), role: .deadlineBasis, at: t0)
        await #expect(throws: DeadlineError.ruleEvidenceRequired) {
            _ = try await r.deadlines.confirmCandidate(id: c3.id, confirmation: self.ruleConfirmation(at: self.t0), at: self.t0)
        }
        // Candidate-scoped + deadlineBasis + EvidenceBlock tied to a source version → qualifies.
        _ = try await r.tasks.addEvidenceLink(taskID: r.taskID, scope: .deadlineCandidate(c3.id),
                                              target: .evidenceBlock(r.evidenceBlockID), role: .deadlineBasis,
                                              at: t0.addingTimeInterval(3))
        let d = try await r.deadlines.confirmCandidate(id: c3.id, confirmation: ruleConfirmation(at: t0.addingTimeInterval(4)),
                                                       at: t0.addingTimeInterval(4))
        #expect(d.sourceCandidateID == c3.id)
        #expect(d.confirmation.ruleID == "resp-30d")
        // A block whose source_version_id is NULL is not "tied to a source version" → refused.
        let orphanBlock = UUID(), orphanDoc = UUID()
        try await r.db.exec("""
        INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text, extraction_method, extraction_confidence)
        VALUES (?,?,NULL,?,?,?,?,?,?);
        """, [.uuid(orphanBlock), .uuid(orphanDoc), .integer(0), .text("paragraph"),
              .text("t"), .text("t"), .text("native"), .real(1.0)])
        let c4 = try await pendingCandidate(r, at: t0.addingTimeInterval(5))
        _ = try await r.tasks.addEvidenceLink(taskID: r.taskID, scope: .deadlineCandidate(c4.id),
                                              target: .evidenceBlock(orphanBlock), role: .deadlineBasis, at: t0)
        await #expect(throws: DeadlineError.ruleEvidenceRequired) {
            _ = try await r.deadlines.confirmCandidate(id: c4.id, confirmation: self.ruleConfirmation(at: self.t0), at: self.t0)
        }
    }

    // MARK: - Correction 2: cross-workspace primary Issue (test 4)

    @Test("A Task cannot anchor to another workspace's Issue; the same workspace is accepted")
    func crossWorkspacePrimaryIssueRejected() async throws {
        let r = try await rig()
        let wsB = UUID()
        try await r.db.exec("INSERT INTO workspaces (id, title, template_type, created_at, updated_at) VALUES (?,?,?,?,?);",
                            [.uuid(wsB), .text("WS-B"), .text("general"), .real(0), .real(0)])
        let issueRepo = ProfessionalIssueRepository(database: r.db)
        let foreign = try await issueRepo.create(workspaceID: wsB, title: "B-issue", detail: nil,
                                                 type: .question, priority: .normal, reviewer: "u", at: t0)
        await #expect(throws: ProfessionalTaskError.crossWorkspacePrimaryIssue(foreign.id)) {
            _ = try await r.tasks.createConfirmed(workspaceID: r.workspaceID, primaryIssueID: foreign.id,
                                                  title: "X", detail: nil, type: .action,
                                                  priority: .normal, owner: nil,
                                                  authority: .user(actor: "u"), at: self.t0)
        }
        await #expect(throws: ProfessionalTaskError.crossWorkspacePrimaryIssue(foreign.id)) {
            _ = try await r.tasks.createCandidate(workspaceID: r.workspaceID, primaryIssueID: foreign.id,
                                                  title: "X", detail: nil, type: .action,
                                                  priority: .normal, owner: nil,
                                                  origin: .automationProposed, proposedBy: "bot", at: self.t0)
        }
        // Same-workspace issue anchors fine; a ghost issue still reports not-found.
        let local = try await issueRepo.create(workspaceID: r.workspaceID, title: "A-issue", detail: nil,
                                               type: .question, priority: .normal, reviewer: "u", at: t0)
        let ok = try await r.tasks.createConfirmed(workspaceID: r.workspaceID, primaryIssueID: local.id,
                                                   title: "Anchored", detail: nil, type: .action,
                                                   priority: .normal, owner: nil,
                                                   authority: .user(actor: "u"), at: t0)
        #expect(ok.primaryIssueID == local.id)
        let ghost = UUID()
        await #expect(throws: ProfessionalTaskError.issueNotFound(ghost)) {
            _ = try await r.tasks.createConfirmed(workspaceID: r.workspaceID, primaryIssueID: ghost,
                                                  title: "X", detail: nil, type: .action,
                                                  priority: .normal, owner: nil,
                                                  authority: .user(actor: "u"), at: self.t0)
        }
    }

    // MARK: - Correction 3: operational-task gate (test 5)

    @Test("Confirmed Deadlines attach only to open/inProgress/blocked tasks; proposals stay allowed on candidates")
    func deadlinesRequireOperationalTask() async throws {
        let r = try await rig()
        // A candidate task may RECEIVE candidate proposals…
        let candidateTask = try await r.tasks.createCandidate(workspaceID: r.workspaceID, primaryIssueID: nil,
                                                              title: "Proposed", detail: nil, type: .action,
                                                              priority: .normal, owner: nil,
                                                              origin: .modelProposed, proposedBy: "m", at: t0)
        let proposal = try await pendingCandidate(r, task: candidateTask.id)
        #expect(proposal.status == .pending)
        // …but they cannot become operational Deadlines until the task is confirmed.
        await #expect(throws: DeadlineError.taskNotOperational(.candidate)) {
            _ = try await r.deadlines.confirmCandidate(id: proposal.id, confirmation: self.userConfirmation(at: self.t0), at: self.t0)
        }
        await #expect(throws: DeadlineError.taskNotOperational(.candidate)) {
            _ = try await r.deadlines.createConfirmedDeadline(taskID: candidateTask.id, value: self.dayValue(),
                                                              kind: .due, confirmation: self.userConfirmation(at: self.t0), at: self.t0)
        }
        // Closed tasks are equally refused: completed / cancelled / archived.
        let completed = try await r.tasks.createConfirmed(workspaceID: r.workspaceID, primaryIssueID: nil,
                                                          title: "Done", detail: nil, type: .action,
                                                          priority: .normal, owner: nil,
                                                          authority: .user(actor: "u"), at: t0)
        let staleCandidate = try await pendingCandidate(r, task: completed.id, at: t0.addingTimeInterval(1))
        _ = try await r.tasks.complete(taskID: completed.id, reviewer: "u", reason: nil, at: t0.addingTimeInterval(2))
        await #expect(throws: DeadlineError.taskNotOperational(.completed)) {
            _ = try await r.deadlines.confirmCandidate(id: staleCandidate.id, confirmation: self.userConfirmation(at: self.t0), at: self.t0)
        }
        let cancelled = try await r.tasks.createConfirmed(workspaceID: r.workspaceID, primaryIssueID: nil,
                                                          title: "Dropped", detail: nil, type: .action,
                                                          priority: .normal, owner: nil,
                                                          authority: .user(actor: "u"), at: t0)
        _ = try await r.tasks.transition(taskID: cancelled.id, to: .cancelled, reviewer: "u", reason: nil, at: t0.addingTimeInterval(3))
        await #expect(throws: DeadlineError.taskNotOperational(.cancelled)) {
            _ = try await r.deadlines.createConfirmedDeadline(taskID: cancelled.id, value: self.dayValue(),
                                                              kind: .due, confirmation: self.userConfirmation(at: self.t0), at: self.t0)
        }
        let archived = try await r.tasks.createConfirmed(workspaceID: r.workspaceID, primaryIssueID: nil,
                                                         title: "Filed away", detail: nil, type: .action,
                                                         priority: .normal, owner: nil,
                                                         authority: .user(actor: "u"), at: t0)
        try await r.tasks.archive(taskID: archived.id, reviewer: "u", reason: nil, at: t0.addingTimeInterval(4))
        await #expect(throws: DeadlineError.taskNotOperational(.archived)) {
            _ = try await r.deadlines.createConfirmedDeadline(taskID: archived.id, value: self.dayValue(),
                                                              kind: .due, confirmation: self.userConfirmation(at: self.t0), at: self.t0)
        }
        // Every OPERATIONAL status works: open (rig task), inProgress, blocked.
        _ = try await r.deadlines.createConfirmedDeadline(taskID: r.taskID, value: dayValue(), kind: .due,
                                                          confirmation: userConfirmation(at: t0.addingTimeInterval(5)),
                                                          at: t0.addingTimeInterval(5))
        _ = try await r.tasks.transition(taskID: r.taskID, to: .inProgress, reviewer: "u", reason: nil, at: t0.addingTimeInterval(6))
        let cInProgress = try await pendingCandidate(r, at: t0.addingTimeInterval(7))
        _ = try await r.deadlines.confirmCandidate(id: cInProgress.id,
                                                   confirmation: userConfirmation(at: t0.addingTimeInterval(8)),
                                                   at: t0.addingTimeInterval(8))
        _ = try await r.tasks.transition(taskID: r.taskID, to: .blocked, reviewer: "u", reason: nil, at: t0.addingTimeInterval(9))
        let cBlocked = try await pendingCandidate(r, at: t0.addingTimeInterval(10))
        _ = try await r.deadlines.confirmCandidate(id: cBlocked.id,
                                                   confirmation: userConfirmation(at: t0.addingTimeInterval(11)),
                                                   at: t0.addingTimeInterval(11))
        #expect(try await r.deadlines.deadlines(taskID: r.taskID).count == 3)
    }

    // MARK: - OPS-002.2: exact evidence PAIRS (mismatched block/version never qualifies)

    @Test("A Claim reference pairing a real block with a DIFFERENT real source version is refused; the matching pair succeeds")
    func mismatchedEvidencePairRefused() async throws {
        let r = try await rig()
        // A second, unrelated REAL source version (different document) in the same workspace.
        let svB = UUID(), docB = UUID()
        try await r.db.exec("""
        INSERT INTO source_versions (id, logical_source_id, document_id, content_hash, valid_from, is_current, created_at)
        VALUES (?,?,?,?,?,1,?);
        """, [.uuid(svB), .uuid(UUID()), .uuid(docB), .text(String(repeating: "ef", count: 32)), .real(0), .real(0)])
        // A claim whose evidence reference cites the rig's REAL block but version B — both IDs
        // resolve individually, yet the block does NOT belong to that source version.
        let claim = UUID()
        try await r.db.exec("""
        INSERT INTO claims (id, subject_id, subject_label, statement, confidence, created_at,
                            evidence_basis, review_disposition, proposal_origin, availability_status, conflict_status)
        VALUES (?,?,?,?,?,?,?,?,?,?,?);
        """, [.uuid(claim), .uuid(UUID()), .text("S"), .text("due on the 17th"), .real(0.9), .real(1000),
              .text("directlyObserved"), .text("unreviewed"), .text("sourceExtraction"),
              .text("available"), .text("none")])
        try await r.db.exec("""
        INSERT INTO claim_evidence_ref (claim_id, ordinal, knowledge_object_id, evidence_block_id, source_version_id, evidence_role)
        VALUES (?,?,?,?,?,?);
        """, [.uuid(claim), .integer(0), .uuid(r.koID), .uuid(r.evidenceBlockID), .uuid(svB), .text("supports")])

        let c = try await pendingCandidate(r)
        _ = try await r.tasks.addEvidenceLink(taskID: r.taskID, scope: .deadlineCandidate(c.id),
                                              target: .claim(claim), role: .deadlineBasis, at: t0)
        await #expect(throws: DeadlineError.ruleEvidenceRequired) {
            _ = try await r.deadlines.confirmCandidate(id: c.id, confirmation: self.ruleConfirmation(at: self.t0), at: self.t0)
        }
        #expect(try await r.deadlines.deadlines(taskID: r.taskID).isEmpty)
        // Correct the reference to the block's OWN source version — now the pair binds exactly.
        let svA = try #require(try await r.db.query(
            "SELECT source_version_id FROM evidence_blocks WHERE id = ?;", [.uuid(r.evidenceBlockID)]).first?.uuid(0))
        try await r.db.exec("UPDATE claim_evidence_ref SET source_version_id = ? WHERE claim_id = ?;",
                            [.uuid(svA), .uuid(claim)])
        let d = try await r.deadlines.confirmCandidate(id: c.id, confirmation: ruleConfirmation(at: t0.addingTimeInterval(1)),
                                                       at: t0.addingTimeInterval(1))
        #expect(d.sourceCandidateID == c.id)
    }

    // MARK: - OPS-002.2: validation executes inside the non-interleavable savepoint

    @Test("State mutated after the candidate was read cannot produce a Deadline; refusals change nothing")
    func staleValidationCannotCreateDeadline() async throws {
        let r = try await rig()
        // (3) The candidate is read/created while its task is open; the task completes BEFORE the
        // confirmation transaction — the in-transaction validation must see `completed`.
        let doomedTask = try await r.tasks.createConfirmed(workspaceID: r.workspaceID, primaryIssueID: nil,
                                                           title: "Will complete", detail: nil, type: .action,
                                                           priority: .normal, owner: nil,
                                                           authority: .user(actor: "u"), at: t0)
        let stale = try await pendingCandidate(r, task: doomedTask.id)
        _ = try await r.tasks.complete(taskID: doomedTask.id, reviewer: "u", reason: nil, at: t0.addingTimeInterval(1))
        await #expect(throws: DeadlineError.taskNotOperational(.completed)) {
            _ = try await r.deadlines.confirmCandidate(id: stale.id, confirmation: self.userConfirmation(at: self.t0), at: self.t0)
        }
        // (7) The refused transaction changed NOTHING: candidate still pending, only its
        // `created` review, no deadline rows, no deadline reviews.
        #expect(try #require(try await r.deadlines.candidate(id: stale.id)).status == .pending)
        #expect(try await r.deadlines.candidateReviews(candidateID: stale.id).map(\.action) == [.created])
        #expect(try await r.deadlines.deadlines(taskID: doomedTask.id).isEmpty)
        #expect(Int(try await r.db.query("SELECT COUNT(*) FROM deadline_reviews;", []).first?.int(0) ?? -1) == 0)

        // (4) Direct creation against a task archived before the transaction.
        let archived = try await r.tasks.createConfirmed(workspaceID: r.workspaceID, primaryIssueID: nil,
                                                         title: "Will archive", detail: nil, type: .action,
                                                         priority: .normal, owner: nil,
                                                         authority: .user(actor: "u"), at: t0)
        try await r.tasks.archive(taskID: archived.id, reviewer: "u", reason: nil, at: t0.addingTimeInterval(2))
        await #expect(throws: DeadlineError.taskNotOperational(.archived)) {
            _ = try await r.deadlines.createConfirmedDeadline(taskID: archived.id, value: self.dayValue(),
                                                              kind: .due, confirmation: self.userConfirmation(at: self.t0), at: self.t0)
        }
        #expect(try await r.deadlines.deadlines(taskID: archived.id).isEmpty)

        // (5) A candidate rejected before the transaction cannot confirm.
        let rejected = try await pendingCandidate(r, at: t0.addingTimeInterval(3))
        try await r.deadlines.rejectCandidate(id: rejected.id, reviewer: "u", reason: "noise", at: t0.addingTimeInterval(4))
        await #expect(throws: DeadlineError.candidateNotPending(.rejected)) {
            _ = try await r.deadlines.confirmCandidate(id: rejected.id, confirmation: self.userConfirmation(at: self.t0), at: self.t0)
        }

        // (6) A rule-confirmable candidate whose exact evidence link is REMOVED before the
        // transaction — the in-transaction evidence check must see the removal.
        let ruleCandidate = try await pendingCandidate(r, at: t0.addingTimeInterval(5))
        let link = try await r.tasks.addEvidenceLink(taskID: r.taskID, scope: .deadlineCandidate(ruleCandidate.id),
                                                     target: .evidenceBlock(r.evidenceBlockID), role: .deadlineBasis, at: t0)
        try await r.tasks.removeEvidenceLink(id: link.id)
        await #expect(throws: DeadlineError.ruleEvidenceRequired) {
            _ = try await r.deadlines.confirmCandidate(id: ruleCandidate.id, confirmation: self.ruleConfirmation(at: self.t0), at: self.t0)
        }
        #expect(try #require(try await r.deadlines.candidate(id: ruleCandidate.id)).status == .pending)
        #expect(try await r.deadlines.deadlines(taskID: r.taskID).isEmpty)
    }

    @Test("Two concurrent confirmations of one candidate yield exactly one Deadline")
    func concurrentConfirmationsYieldOneDeadline() async throws {
        let r = try await rig()
        let c = try await pendingCandidate(r)
        // Both confirmations race through the SAME repository/database. The transactional
        // validate-and-write means exactly one sees `pending` and wins; the other must fail
        // with candidateNotPending — never a second row (UNIQUE(source_candidate_id) backstops).
        async let first = r.deadlines.confirmCandidate(id: c.id, confirmation: userConfirmation(at: t0.addingTimeInterval(1)),
                                                       at: t0.addingTimeInterval(1))
        async let second = r.deadlines.confirmCandidate(id: c.id, confirmation: userConfirmation(at: t0.addingTimeInterval(1)),
                                                        at: t0.addingTimeInterval(1))
        var successes = 0
        do { _ = try await first; successes += 1 } catch { }
        do { _ = try await second; successes += 1 } catch { }
        #expect(successes == 1, "expected exactly one winning confirmation")
        let rows = Int(try await r.db.query(
            "SELECT COUNT(*) FROM deadlines WHERE source_candidate_id = ?;", [.uuid(c.id)]).first?.int(0) ?? -1)
        #expect(rows == 1)
        #expect(try #require(try await r.deadlines.candidate(id: c.id)).status == .promoted)
    }

    // MARK: - Correction 4: persisted rule identity (test 6)

    @Test("Task confirmation authority — including rule ID and version — survives database reopening")
    func ruleIdentitySurvivesReopen() async throws {
        let r = try await rig()
        // A rule-authored open task and a rule-confirmed candidate task.
        let ruleTask = try await r.tasks.createConfirmed(
            workspaceID: r.workspaceID, primaryIssueID: nil, title: "Rule-born", detail: nil,
            type: .review, priority: .normal, owner: nil,
            authority: .deterministicRule(ruleID: "intake-7", version: "3", actor: "engine"), at: t0)
        let candidate = try await r.tasks.createCandidate(
            workspaceID: r.workspaceID, primaryIssueID: nil, title: "Proposed", detail: nil,
            type: .action, priority: .normal, owner: nil,
            origin: .sourceExtraction, proposedBy: "extractor", at: t0)
        _ = try await r.tasks.confirmCandidate(
            taskID: candidate.id,
            authority: .deterministicRule(ruleID: "triage-2", version: "1", actor: "engine"),
            reason: "matched intake rule", at: t0.addingTimeInterval(1))
        _ = try await r.tasks.confirmCandidate(taskID: (try await r.tasks.createCandidate(
            workspaceID: r.workspaceID, primaryIssueID: nil, title: "User-confirmed", detail: nil,
            type: .action, priority: .normal, owner: nil,
            origin: .modelProposed, proposedBy: "m", at: t0)).id,
            authority: .user(actor: "u"), reason: nil, at: t0.addingTimeInterval(2))

        // Reopen the SAME file with a fresh Database — the ledger must PROVE the authority.
        let reopened = try MigrationFixtureBuilder.reopen(at: r.url)
        let repo2 = ProfessionalTaskRepository(database: reopened)

        let born = try #require(try await repo2.reviews(taskID: ruleTask.id).first)
        #expect(born.action == .created)
        #expect(born.authorityKind == .deterministicRule)
        #expect(born.ruleID == "intake-7")
        #expect(born.ruleVersion == "3")

        let confirmedRow = try #require(try await repo2.reviews(taskID: candidate.id).last)
        #expect(confirmedRow.action == .candidateConfirmed)
        #expect(confirmedRow.authorityKind == .deterministicRule)
        #expect(confirmedRow.ruleID == "triage-2")
        #expect(confirmedRow.ruleVersion == "1")

        // User authority is recorded as such, with no invented rule identity; a candidate's
        // `created` row (no confirming authority) stays NULL.
        let userConfirmed = try await repo2.tasks(workspaceID: r.workspaceID)
            .first { $0.title == "User-confirmed" }
        let userRows = try await repo2.reviews(taskID: try #require(userConfirmed).id)
        #expect(userRows.first?.authorityKind == nil)              // proposal creation — no authority
        #expect(userRows.last?.authorityKind == .user)
        #expect(userRows.last?.ruleID == nil)
        #expect(userRows.last?.ruleVersion == nil)
    }
}
