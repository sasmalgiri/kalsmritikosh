//
//  DeadlineRepositoryTests.swift
//  KalsmritikoshTests
//
//  OPS-002 — THE truth rule under test: `DeadlineCandidate ≠ Deadline`. An extracted or
//  model-proposed date only ever creates a candidate; confirmation inserts a SEPARATE Deadline
//  row and preserves the candidate (origin, confidence, evidence, review history); a promoted
//  candidate can never be re-confirmed; rule confirmation demands rule ID + version + exact
//  evidence; month/year/unknown precision cannot be promoted (explicit reviewed correction first,
//  never a silent month-boundary snap); overdue is calculated, never a stored autonomous status;
//  every candidate/Deadline lifecycle change is audited atomically (failed audit → full rollback).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("OPS-002 — deadline repository")
struct DeadlineRepositoryTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let due = Date(timeIntervalSince1970: 1_700_600_000)

    private struct Rig {
        let db: Database
        let url: URL
        let tasks: ProfessionalTaskRepository
        let repo: DeadlineRepository
        let workspaceID: UUID
        let taskID: UUID
        let claimID: UUID
        let sourceVersionID: UUID
        let evidenceBlockID: UUID
    }

    /// Latest-schema DB + workspace + one open task + one workspace-bound claim (KO-only
    /// evidence refs — NOT exact) + a resolvable source version and evidence block for
    /// upgrading evidence to exact.
    private func rig() async throws -> Rig {
        let url = MigrationFixtureBuilder.newTemporaryURL()
        let db = try await MigrationFixtureBuilder.database(atVersion: 0, at: url)
        try await SchemaMigrations.migrate(db)
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, template_type, created_at, updated_at) VALUES (?,?,?,?,?);",
                          [.uuid(ws), .text("WS"), .text("general"), .real(0), .real(0)])
        let f = UUID(), ko = UUID(), claim = UUID(), doc = UUID(), sv = UUID(), block = UUID()
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
        """, [.uuid(sv), .uuid(f), .uuid(doc), .text(String(repeating: "ab", count: 32)), .real(0), .real(0)])
        try await db.exec("""
        INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text, extraction_method, extraction_confidence)
        VALUES (?,?,?,?,?,?,?,?,?);
        """, [.uuid(block), .uuid(doc), .uuid(sv), .integer(0), .text("paragraph"),
              .text("respond within 30 days"), .text("respond within 30 days"), .text("native"), .real(1.0)])
        try await db.exec("INSERT INTO evidence_block_objects (evidence_block_id, knowledge_object_id, linked_at) VALUES (?,?,?);",
                          [.uuid(block), .uuid(ko), .real(0)])
        try await db.exec("""
        INSERT INTO claims (id, subject_id, subject_label, statement, confidence, created_at,
                            evidence_basis, review_disposition, proposal_origin, availability_status, conflict_status)
        VALUES (?,?,?,?,?,?,?,?,?,?,?);
        """, [.uuid(claim), .uuid(UUID()), .text("S"), .text("due 30 days after notice"), .real(0.9), .real(1000),
              .text("directlyObserved"), .text("unreviewed"), .text("sourceExtraction"),
              .text("available"), .text("none")])
        try await db.exec("""
        INSERT INTO claim_evidence_ref (claim_id, ordinal, knowledge_object_id, evidence_role) VALUES (?,?,?,?);
        """, [.uuid(claim), .integer(0), .uuid(ko), .text("supports")])
        let tasks = ProfessionalTaskRepository(database: db)
        let task = try await tasks.createConfirmed(workspaceID: ws, primaryIssueID: nil,
                                                   title: "File response", detail: nil, type: .action,
                                                   priority: .high, owner: nil,
                                                   authority: .user(actor: "u"), at: t0)
        return Rig(db: db, url: url, tasks: tasks, repo: DeadlineRepository(database: db),
                   workspaceID: ws, taskID: task.id, claimID: claim,
                   sourceVersionID: sv, evidenceBlockID: block)
    }

    private func dayValue(_ tz: String = "UTC") -> DeadlineValue {
        DeadlineValue(date: due, precision: .day, timeZoneIdentifier: tz)
    }

    private func extractedCandidate(_ r: Rig, value: DeadlineValue? = nil,
                                    at date: Date? = nil) async throws -> DeadlineCandidate {
        try await r.repo.createCandidate(taskID: r.taskID, value: value ?? dayValue(), kind: .due,
                                         origin: .sourceExtraction, confidence: 0.85,
                                         proposedBy: "date-extractor", ruleID: nil, ruleVersion: nil,
                                         at: date ?? t0)
    }

    private func userConfirmation(at date: Date) -> DeadlineConfirmation {
        DeadlineConfirmation(kind: .user, confirmedBy: "u", confirmedAt: date,
                             reason: "verified against filing", ruleID: nil, ruleVersion: nil)
    }

    // MARK: - Cases 11 + 12: extraction produces ONLY a candidate

    @Test("An extracted date creates only a DeadlineCandidate — never a confirmed Deadline")
    func extractedDateCreatesOnlyCandidate() async throws {
        let r = try await rig()
        let c = try await extractedCandidate(r)
        #expect(c.status == .pending)
        #expect(c.origin == .sourceExtraction)
        #expect(c.confidence == 0.85)
        // The candidate is queryable in the proposal layer…
        #expect(try await r.repo.candidates(taskID: r.taskID).map(\.id) == [c.id])
        // …and NEVER appears in confirmed-Deadline queries.
        #expect(try await r.repo.deadlines(taskID: r.taskID).isEmpty)
        #expect(Int(try await r.db.query("SELECT COUNT(*) FROM deadlines;", []).first?.int(0) ?? -1) == 0)
        #expect(try await r.repo.candidateReviews(candidateID: c.id).map(\.action) == [.created])
        // Ghost task and blank proposer are rejected.
        let ghost = UUID()
        await #expect(throws: DeadlineError.taskNotFound(ghost)) {
            _ = try await r.repo.createCandidate(taskID: ghost, value: self.dayValue(), kind: .due,
                                                 origin: .sourceExtraction, confidence: nil, proposedBy: "x",
                                                 ruleID: nil, ruleVersion: nil, at: self.t0)
        }
        await #expect(throws: DeadlineError.blankProposer) {
            _ = try await r.repo.createCandidate(taskID: r.taskID, value: self.dayValue(), kind: .due,
                                                 origin: .sourceExtraction, confidence: nil, proposedBy: "  ",
                                                 ruleID: nil, ruleVersion: nil, at: self.t0)
        }
    }

    // MARK: - Cases 13 + 19: user confirmation → SEPARATE row, candidate preserved

    @Test("User confirmation creates a separate Deadline and preserves the candidate intact")
    func userConfirmationCreatesSeparateDeadline() async throws {
        let r = try await rig()
        let value = DeadlineValue(date: due, precision: .minute, timeZoneIdentifier: "Asia/Kolkata")
        let c = try await extractedCandidate(r, value: value)
        let d = try await r.repo.confirmCandidate(id: c.id, confirmation: userConfirmation(at: t0.addingTimeInterval(60)),
                                                  at: t0.addingTimeInterval(60))
        // A NEW row — never the candidate's id reused.
        #expect(d.id != c.id)
        #expect(d.sourceCandidateID == c.id)
        #expect(d.status == .active)
        #expect(d.confirmation.kind == .user)
        // Case 19: precision + time zone travel intact into the confirmed Deadline.
        #expect(d.value == value)
        let loaded = try #require(try await r.repo.deadline(id: d.id))
        #expect(loaded.value.precision == .minute)
        #expect(loaded.value.timeZoneIdentifier == "Asia/Kolkata")
        #expect(loaded.value.date == due)
        // The candidate is PRESERVED: promoted status, original origin/confidence/proposer.
        let preserved = try #require(try await r.repo.candidate(id: c.id))
        #expect(preserved.status == .promoted)
        #expect(preserved.origin == .sourceExtraction)
        #expect(preserved.confidence == 0.85)
        #expect(preserved.proposedBy == "date-extractor")
        // Both audit ledgers recorded the promotion.
        #expect(try await r.repo.candidateReviews(candidateID: c.id).map(\.action) == [.created, .promoted])
        #expect(try await r.repo.deadlineReviews(deadlineID: d.id).map(\.action) == [.confirmed])
        // Blank confirmer is rejected.
        let c2 = try await extractedCandidate(r, at: t0.addingTimeInterval(1))
        await #expect(throws: DeadlineError.blankConfirmer) {
            _ = try await r.repo.confirmCandidate(
                id: c2.id,
                confirmation: DeadlineConfirmation(kind: .user, confirmedBy: " ", confirmedAt: self.t0,
                                                   reason: nil, ruleID: nil, ruleVersion: nil),
                at: self.t0)
        }
    }

    // MARK: - Case 14: rule confirmation requires rule identity + exact evidence

    @Test("Rule confirmation requires nonblank rule ID/version and at least one EXACT evidence link")
    func ruleConfirmationRequiresEvidence() async throws {
        let r = try await rig()
        let c = try await extractedCandidate(r)
        // Missing rule identity.
        await #expect(throws: DeadlineError.blankRule) {
            _ = try await r.repo.confirmCandidate(
                id: c.id,
                confirmation: DeadlineConfirmation(kind: .deterministicRule, confirmedBy: "engine",
                                                   confirmedAt: self.t0, reason: nil, ruleID: "", ruleVersion: "1"),
                at: self.t0)
        }
        // Rule identity present, but NO evidence link on the candidate → refused.
        let ruleConfirmation = DeadlineConfirmation(kind: .deterministicRule, confirmedBy: "engine",
                                                    confirmedAt: t0.addingTimeInterval(5),
                                                    reason: "30-day response rule",
                                                    ruleID: "resp-30d", ruleVersion: "2")
        await #expect(throws: DeadlineError.ruleEvidenceRequired) {
            _ = try await r.repo.confirmCandidate(id: c.id, confirmation: ruleConfirmation, at: self.t0.addingTimeInterval(5))
        }
        // A candidate-scoped deadlineBasis link to a Claim whose evidence refs are KO-ONLY (no
        // exact EvidenceBlock + source version) is NOT exact evidence → still refused.
        _ = try await r.tasks.addEvidenceLink(taskID: r.taskID, scope: .deadlineCandidate(c.id),
                                              target: .claim(r.claimID), role: .deadlineBasis, at: t0)
        await #expect(throws: DeadlineError.ruleEvidenceRequired) {
            _ = try await r.repo.confirmCandidate(id: c.id, confirmation: ruleConfirmation, at: self.t0.addingTimeInterval(5))
        }
        // The candidate is untouched by the refusals.
        #expect(try #require(try await r.repo.candidate(id: c.id)).status == .pending)
        #expect(try await r.repo.deadlines(taskID: r.taskID).isEmpty)
        // Upgrade the Claim's evidence reference to EXACT (cites the block + source version) —
        // now the same link satisfies rule confirmation.
        try await r.db.exec("""
        UPDATE claim_evidence_ref SET evidence_block_id = ?, source_version_id = ? WHERE claim_id = ?;
        """, [.uuid(r.evidenceBlockID), .uuid(r.sourceVersionID), .uuid(r.claimID)])
        let d = try await r.repo.confirmCandidate(id: c.id, confirmation: ruleConfirmation, at: t0.addingTimeInterval(6))
        #expect(d.confirmation.kind == .deterministicRule)
        #expect(d.confirmation.ruleID == "resp-30d")
        #expect(d.confirmation.ruleVersion == "2")
        #expect(d.sourceCandidateID == c.id)
    }

    // MARK: - Case 15: model/source can never directly create a Deadline

    @Test("Model/source origins can never confirm: the only confirmation kinds are user and rule")
    func modelAndSourceNeverConfirm() async throws {
        // The type system is the first gate: exactly two confirmation kinds exist.
        #expect(Set(DeadlineConfirmationKind.allCases) == [.user, .deterministicRule])
        // And a rule cannot bypass the candidate layer via direct creation — user only.
        let r = try await rig()
        await #expect(throws: DeadlineError.ruleConfirmationRequiresCandidate) {
            _ = try await r.repo.createConfirmedDeadline(
                taskID: r.taskID, value: self.dayValue(), kind: .due,
                confirmation: DeadlineConfirmation(kind: .deterministicRule, confirmedBy: "engine",
                                                   confirmedAt: self.t0, reason: nil,
                                                   ruleID: "r", ruleVersion: "1"),
                at: self.t0)
        }
        // Direct USER creation is legitimate (no candidate) and audited.
        let d = try await r.repo.createConfirmedDeadline(taskID: r.taskID, value: dayValue(), kind: .filing,
                                                         confirmation: userConfirmation(at: t0), at: t0)
        #expect(d.sourceCandidateID == nil)
        #expect(try await r.repo.deadlineReviews(deadlineID: d.id).map(\.action) == [.confirmed])
    }

    // MARK: - Case 16: precision gate (no silent month→day conversion)

    @Test("Month/year/unknown precision cannot be promoted; explicit reviewed correction unlocks it")
    func precisionGate() async throws {
        let r = try await rig()
        // Coarser than .month cannot even be proposed.
        for precision in [DatePrecision.unknown, .decade, .year, .quarter] {
            await #expect(throws: DeadlineError.invalidCandidatePrecision(precision)) {
                _ = try await r.repo.createCandidate(
                    taskID: r.taskID,
                    value: DeadlineValue(date: self.due, precision: precision, timeZoneIdentifier: "UTC"),
                    kind: .due, origin: .sourceExtraction, confidence: nil, proposedBy: "x",
                    ruleID: nil, ruleVersion: nil, at: self.t0)
            }
        }
        // A .month candidate is proposable but NOT promotable.
        let monthValue = DeadlineValue(date: due, precision: .month, timeZoneIdentifier: "UTC")
        let c = try await extractedCandidate(r, value: monthValue)
        await #expect(throws: DeadlineError.unpromotablePrecision(.month)) {
            _ = try await r.repo.confirmCandidate(id: c.id, confirmation: self.userConfirmation(at: self.t0), at: self.t0)
        }
        #expect(try await r.repo.deadlines(taskID: r.taskID).isEmpty)
        // The refinement is an EXPLICIT reviewed correction with a reviewer-supplied value —
        // the repository performs no month-boundary snapping of its own.
        let refined = try await r.repo.correctCandidate(
            id: c.id, to: DeadlineValue(date: due, precision: .day, timeZoneIdentifier: "UTC"),
            reviewer: "u", reason: "checked the order: due on the 17th", at: t0.addingTimeInterval(10))
        #expect(refined.value.precision == .day)
        #expect(refined.status == .pending)
        #expect(try await r.repo.candidateReviews(candidateID: c.id).map(\.action) == [.created, .corrected])
        let d = try await r.repo.confirmCandidate(id: c.id, confirmation: userConfirmation(at: t0.addingTimeInterval(20)),
                                                  at: t0.addingTimeInterval(20))
        #expect(d.value.precision == .day)
    }

    // MARK: - Case 17: rejection creates no Deadline

    @Test("Rejecting a candidate creates no Deadline and closes its confirmability")
    func rejectionCreatesNoDeadline() async throws {
        let r = try await rig()
        let c = try await extractedCandidate(r)
        try await r.repo.rejectCandidate(id: c.id, reviewer: "u", reason: "not a real deadline", at: t0.addingTimeInterval(1))
        #expect(try #require(try await r.repo.candidate(id: c.id)).status == .rejected)
        #expect(try await r.repo.deadlines(taskID: r.taskID).isEmpty)
        #expect(try await r.repo.candidateReviews(candidateID: c.id).map(\.action) == [.created, .rejected])
        // A rejected candidate cannot be confirmed afterwards.
        await #expect(throws: DeadlineError.candidateNotPending(.rejected)) {
            _ = try await r.repo.confirmCandidate(id: c.id, confirmation: self.userConfirmation(at: self.t0), at: self.t0)
        }
        // Supersede + archive paths are also audited; pending→archived and rejected→archived legal.
        let c2 = try await extractedCandidate(r, at: t0.addingTimeInterval(2))
        try await r.repo.supersedeCandidate(id: c2.id, reviewer: "u", reason: "newer extraction", at: t0.addingTimeInterval(3))
        try await r.repo.archiveCandidate(id: c2.id, reviewer: "u", reason: nil, at: t0.addingTimeInterval(4))
        #expect(try await r.repo.candidateReviews(candidateID: c2.id).map(\.action) == [.created, .superseded, .archived])
    }

    // MARK: - Case 18: one candidate → at most one Deadline

    @Test("Re-confirming a promoted candidate fails at the repository AND the database layer")
    func duplicateConfirmationFails() async throws {
        let r = try await rig()
        let c = try await extractedCandidate(r)
        let d = try await r.repo.confirmCandidate(id: c.id, confirmation: userConfirmation(at: t0.addingTimeInterval(1)),
                                                  at: t0.addingTimeInterval(1))
        // Repository gate.
        await #expect(throws: DeadlineError.candidateNotPending(.promoted)) {
            _ = try await r.repo.confirmCandidate(id: c.id, confirmation: self.userConfirmation(at: self.t0), at: self.t0)
        }
        // Database gate: UNIQUE(source_candidate_id) — even a direct insert cannot double-promote.
        await #expect(throws: (any Error).self) {
            try await r.db.exec("""
            INSERT INTO deadlines (id, task_id, source_candidate_id, due_date, precision, time_zone,
                                   deadline_kind, status, confirmation_kind, confirmed_by, confirmed_at,
                                   created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(r.taskID), .uuid(c.id), .real(0), .integer(5), .text("UTC"),
                  .text("due"), .text("active"), .text("user"), .text("u"), .real(0), .real(0), .real(0)])
        }
        #expect(try await r.repo.deadlines(taskID: r.taskID).map(\.id) == [d.id])
    }

    // MARK: - Case 20: overdue is a calculation, never a stored mutation

    @Test("Overdue is calculated from the comparison time without changing the stored status")
    func overdueIsCalculatedNotStored() async throws {
        let r = try await rig()
        let d = try await r.repo.createConfirmedDeadline(taskID: r.taskID, value: dayValue(), kind: .due,
                                                         confirmation: userConfirmation(at: t0), at: t0)
        #expect(d.isOverdue(at: due.addingTimeInterval(-1)) == false)
        #expect(d.isOverdue(at: due.addingTimeInterval(1)) == true)
        // The stored row is untouched by the calculation — status is still 'active', and there is
        // no 'overdue' status anywhere in the vocabulary.
        let stored = try await r.db.query("SELECT status FROM deadlines WHERE id = ?;", [.uuid(d.id)]).first?.string(0)
        #expect(stored == "active")
        #expect(!DeadlineStatus.allCases.map(\.rawValue).contains("overdue"))
        // A satisfied deadline is never overdue, however late the comparison time.
        try await r.repo.satisfy(id: d.id, reviewer: "u", reason: "filed", at: due.addingTimeInterval(10))
        let satisfied = try #require(try await r.repo.deadline(id: d.id))
        #expect(satisfied.isOverdue(at: due.addingTimeInterval(100)) == false)
    }

    // MARK: - Case 21: lifecycle audits

    @Test("Satisfying, cancelling, superseding and archiving a Deadline record audit rows")
    func lifecycleAudits() async throws {
        let r = try await rig()
        func newDeadline(_ offset: TimeInterval) async throws -> Deadline {
            try await r.repo.createConfirmedDeadline(taskID: r.taskID, value: dayValue(), kind: .due,
                                                     confirmation: userConfirmation(at: t0.addingTimeInterval(offset)),
                                                     at: t0.addingTimeInterval(offset))
        }
        let s = try await newDeadline(0)
        try await r.repo.satisfy(id: s.id, reviewer: "u", reason: "done", at: t0.addingTimeInterval(1))
        let satisfied = try #require(try await r.repo.deadline(id: s.id))
        #expect(satisfied.status == .satisfied)
        #expect(satisfied.satisfiedAt == t0.addingTimeInterval(1))
        #expect(try await r.repo.deadlineReviews(deadlineID: s.id).map(\.action) == [.confirmed, .satisfied])

        let c = try await newDeadline(2)
        try await r.repo.cancel(id: c.id, reviewer: "u", reason: "matter settled", at: t0.addingTimeInterval(3))
        #expect(try await r.repo.deadlineReviews(deadlineID: c.id).map(\.action) == [.confirmed, .cancelled])

        let sup = try await newDeadline(4)
        try await r.repo.supersede(id: sup.id, reviewer: "u", reason: "extended by court", at: t0.addingTimeInterval(5))
        #expect(try await r.repo.deadlineReviews(deadlineID: sup.id).map(\.action) == [.confirmed, .superseded])

        try await r.repo.archive(id: s.id, reviewer: "u", reason: nil, at: t0.addingTimeInterval(6))
        #expect(try await r.repo.deadlineReviews(deadlineID: s.id).map(\.action) == [.confirmed, .satisfied, .archived])
        // Terminal rules: a satisfied deadline cannot be cancelled; archived is terminal.
        await #expect(throws: DeadlineError.invalidStatusChange(from: .cancelled, to: .satisfied)) {
            try await r.repo.satisfy(id: c.id, reviewer: "u", reason: nil, at: self.t0)
        }
        await #expect(throws: DeadlineError.invalidStatusChange(from: .archived, to: .cancelled)) {
            try await r.repo.cancel(id: s.id, reviewer: "u", reason: nil, at: self.t0)
        }
    }

    // MARK: - Case 22: failed audit rolls back promotion / status change

    @Test("A failed audit write rolls back the entire promotion and any status change")
    func failedAuditRollsBackPromotion() async throws {
        let r = try await rig()
        let c = try await extractedCandidate(r)
        await r.repo.setInjectFailure(.beforeDeadlineReview)
        await #expect(throws: (any Error).self) {
            _ = try await r.repo.confirmCandidate(id: c.id, confirmation: self.userConfirmation(at: self.t0), at: self.t0)
        }
        await r.repo.setInjectFailure(nil)
        // NOTHING of the promotion survived: no Deadline row, candidate still pending, no
        // promoted review.
        #expect(try await r.repo.deadlines(taskID: r.taskID).isEmpty)
        #expect(try #require(try await r.repo.candidate(id: c.id)).status == .pending)
        #expect(try await r.repo.candidateReviews(candidateID: c.id).map(\.action) == [.created])
        // Same guarantee for a plain status change.
        let d = try await r.repo.confirmCandidate(id: c.id, confirmation: userConfirmation(at: t0.addingTimeInterval(1)),
                                                  at: t0.addingTimeInterval(1))
        await r.repo.setInjectFailure(.beforeDeadlineReview)
        await #expect(throws: (any Error).self) {
            try await r.repo.satisfy(id: d.id, reviewer: "u", reason: nil, at: self.t0.addingTimeInterval(2))
        }
        await r.repo.setInjectFailure(nil)
        let loaded = try #require(try await r.repo.deadline(id: d.id))
        #expect(loaded.status == .active, "status changed despite the failed ledger write")
        #expect(loaded.satisfiedAt == nil)
        #expect(try await MigrationFaultHarness.integrityOK(r.db))
    }

    // MARK: - Durability (case 25, deadline side)

    @Test("Reopening the database restores candidates and Deadlines exactly")
    func reopenRecoversState() async throws {
        let r = try await rig()
        let value = DeadlineValue(date: due, precision: .minute, timeZoneIdentifier: "Asia/Kolkata")
        let c = try await extractedCandidate(r, value: value)
        let d = try await r.repo.confirmCandidate(id: c.id, confirmation: userConfirmation(at: t0.addingTimeInterval(1)),
                                                  at: t0.addingTimeInterval(1))
        let pending = try await extractedCandidate(r, at: t0.addingTimeInterval(2))

        let reopened = try MigrationFixtureBuilder.reopen(at: r.url)
        let repo2 = DeadlineRepository(database: reopened)
        let loadedD = try #require(try await repo2.deadline(id: d.id))
        #expect(loadedD.sourceCandidateID == c.id)
        #expect(loadedD.value == value)
        #expect(loadedD.confirmation.confirmedBy == "u")
        let loadedC = try #require(try await repo2.candidate(id: c.id))
        #expect(loadedC.status == .promoted)
        #expect(try #require(try await repo2.candidate(id: pending.id)).status == .pending)
        #expect(try await repo2.candidateReviews(candidateID: c.id).map(\.action) == [.created, .promoted])
        #expect(try await repo2.deadlineReviews(deadlineID: d.id).map(\.action) == [.confirmed])
    }
}
