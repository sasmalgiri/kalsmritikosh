//
//  CaseFileTests.swift
//  KalsmritikoshTests
//
//  Investigations Made Easy — the case file (v151): intake, triage, stages, allegations and
//  findings, people and interviews, exhibits, holds, batches, conflict checks, tasks over the one
//  task engine, templates, caseload, documents and the action log. Throwaway ledgers only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Case file (v151)")
struct CaseFileTests {

    struct Fixture {
        let db: Database
        let cases: InvestigationCaseRepository
        let workspaces: WorkspaceRepository
        let svc: CaseFileService
        let workspaceID: UUID
        let caseID: UUID
        var file: CaseFileRepository { svc.file }
    }

    static func fixture(title: String = "Complaint about the night shift") async throws -> Fixture {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let workspaces = WorkspaceRepository(database: db)
        let ws = Workspace(title: "WS")
        try await workspaces.upsert(ws)
        let cases = InvestigationCaseRepository(database: db)
        let c = try await cases.createCase(workspaceID: ws.id, title: title, actor: "Ada", at: Date())
        let svc = CaseFileService(database: db, cases: cases, workspaces: workspaces)
        return Fixture(db: db, cases: cases, workspaces: workspaces, svc: svc, workspaceID: ws.id, caseID: c.id)
    }

    @Test("Anonymous intake stores no identity")
    func anonymousIntake() async throws {
        let f = try await Self.fixture()
        var p = try await f.file.profile(caseID: f.caseID)
        p.intake = CaseIntake(channel: .hotline, anonymous: true, complainant: "Jane Roe", complainantContact: "jane@example.com",
                              allegationSummary: "Shouting at staff")
        try await f.file.saveProfile(p, actor: "Ada")
        let rows = try await f.db.query("SELECT complainant, complainant_contact, anonymous FROM case_profiles WHERE case_id = ?;", [.uuid(f.caseID)])
        #expect(rows.first?.isNull(0) == true)
        #expect(rows.first?.isNull(1) == true)
        #expect(rows.first?.int(2) == 1)
        #expect(try await f.file.profile(caseID: f.caseID).intake.allegationSummary == "Shouting at staff")
    }

    @Test("Stages move only along the allowed path; triage decides open, decline or refer")
    func stagesAndTriage() async throws {
        let f = try await Self.fixture()
        #expect(try await f.file.profile(caseID: f.caseID).stage == .intake)
        await #expect(throws: CaseFileError.self) {
            try await f.file.moveStage(caseID: f.caseID, to: .findings, reason: nil, actor: "Ada")
        }
        try await f.file.recordTriage(caseID: f.caseID, CaseTriage(severity: .high), actor: "Ada")
        #expect(try await f.file.profile(caseID: f.caseID).stage == .triage)
        await #expect(throws: CaseFileError.self) {   // decline needs a reason
            try await f.file.recordTriage(caseID: f.caseID, CaseTriage(decision: .decline), actor: "Ada")
        }
        try await f.file.recordTriage(caseID: f.caseID, CaseTriage(severity: .high, decision: .accept), actor: "Ada")
        let p = try await f.file.profile(caseID: f.caseID)
        #expect(p.stage == .open)
        #expect(p.triage.decidedBy == "Ada")
        try await f.file.moveStage(caseID: f.caseID, to: .inProgress, reason: nil, actor: "Ada")
        try await f.file.moveStage(caseID: f.caseID, to: .onHold, reason: "Waiting for HR records", actor: "Ada")
        #expect(try await f.file.profile(caseID: f.caseID).stage == .onHold)
    }

    @Test("A finding needs a rationale; the grid links evidence by stance and retracts without deleting")
    func allegationsAndGrid() async throws {
        let f = try await Self.fixture()
        let a = try await f.file.addAllegation(caseID: f.caseID, text: "Shouted at staff on 3 March", actor: "Ada")
        await #expect(throws: CaseFileError.self) {
            try await f.file.decide(allegationID: a, caseID: f.caseID, disposition: .substantiated, rationale: " ", actor: "Ada")
        }
        // §2 — support is a VERIFIED passage of an ingested document, linked through the service.
        let email = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "email-4-march.txt",
                                                              text: "On 3 March the manager shouted at staff in the open office. Two people left the floor.")
        let source = email.version.uuidString
        _ = try await f.svc.linkEvidence(caseID: f.caseID, allegationID: a, evidenceRef: source, label: "Email 4 March", stance: .supports, note: "Names the date",
                                         passage: StudioEvidenceRef(sourceVersionID: email.version, quote: "On 3 March the manager shouted at staff"), actor: "Ada")
        // I4 — an adverse finding needs the response put to the respondent (or an explicit exception).
        await #expect(throws: CaseFileError.adverseFindingUnsupported("record the response put to the respondent, or state the exception that justifies deciding without one")) {
            try await f.svc.decide(allegationID: a, caseID: f.caseID, disposition: .substantiated, rationale: "Two witnesses and the email agree", actor: "Ada")
        }
        try await f.file.recordResponse(allegationID: a, caseID: f.caseID, response: "Denies shouting; says voices were raised by both.", actor: "Ada")
        try await f.svc.decide(allegationID: a, caseID: f.caseID, disposition: .substantiated, rationale: "Two witnesses and the email agree", actor: "Ada")
        let list = try await f.file.allegations(caseID: f.caseID)
        #expect(list.first?.label == "A1")
        #expect(list.first?.disposition == .substantiated)
        let grid = try await f.file.allegationEvidence(caseID: f.caseID)
        #expect(grid.count == 1)
        try await f.file.retractAllegationEvidence(caseID: f.caseID, id: grid[0].id, actor: "Ada")
        #expect(try await f.file.allegationEvidence(caseID: f.caseID).isEmpty)
        let kept = try await f.db.query("SELECT COUNT(*) FROM case_allegation_evidence;", [])
        #expect(kept.first?.int(0) == 1)   // retracted, not deleted
    }

    @Test("An attested statement is fingerprinted and can't be changed")
    func interviewsAttest() async throws {
        let f = try await Self.fixture()
        let pid = try await f.file.addPerson(caseID: f.caseID, name: "Sam Witness", role: .witness, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        let iv = try await f.file.addInterview(caseID: f.caseID, personID: pid, questions: "What did you see?", actor: "Ada")
        await #expect(throws: CaseFileError.self) {   // nothing to attest yet
            try await f.file.attest(interviewID: iv, caseID: f.caseID, attestedBy: "Sam Witness", actor: "Ada")
        }
        var record = try #require(try await f.file.interview(id: iv))
        record.statementText = "I saw the supervisor shout at two staff."
        record.status = .summarised
        try await f.file.updateInterview(record, actor: "Ada")
        try await f.file.attest(interviewID: iv, caseID: f.caseID, attestedBy: "Sam Witness", actor: "Ada")
        var attested = try #require(try await f.file.interview(id: iv))
        #expect(attested.status == .attested)
        #expect(attested.statementIntact)
        attested.statementText = "Changed later."
        await #expect(throws: CaseFileError.statementAlreadyAttested) {
            try await f.file.updateInterview(attested, actor: "Ada")
        }
        try await f.file.addCredibility(caseID: f.caseID, interviewID: iv, factor: .corroboration, assessment: .supports,
                                        note: "Matches the email", evidenceRef: nil, actor: "Ada")
        #expect(try await f.file.credibility(caseID: f.caseID).count == 1)
    }

    @Test("Exhibits number themselves and refuse duplicates")
    func exhibits() async throws {
        let f = try await Self.fixture()
        let n1 = try await f.file.addExhibit(caseID: f.caseID, number: nil, description: "Laptop", sourceRef: nil, sha256: nil,
                                              collectedBy: nil, collectedAt: nil, collectedWhere: "Desk 4", actor: "Ada")
        let n2 = try await f.file.addExhibit(caseID: f.caseID, number: nil, description: "USB stick", sourceRef: nil, sha256: nil,
                                              collectedBy: nil, collectedAt: nil, collectedWhere: nil, actor: "Ada")
        #expect(n1 == "EX-001" && n2 == "EX-002")
        await #expect(throws: CaseFileError.duplicateExhibitNumber("EX-001")) {
            _ = try await f.file.addExhibit(caseID: f.caseID, number: "EX-001", description: "Dup", sourceRef: nil, sha256: nil,
                                            collectedBy: nil, collectedAt: nil, collectedWhere: nil, actor: "Ada")
        }
        let ex = try await f.file.exhibits(caseID: f.caseID)
        try await f.file.withdrawExhibit(caseID: f.caseID, id: ex[0].id, actor: "Ada")
        #expect(try await f.file.exhibits(caseID: f.caseID).count == 1)
        #expect(try await f.file.exhibits(caseID: f.caseID, includeWithdrawn: true).count == 2)
    }

    @Test("Holds are issued, acknowledged and released")
    func holds() async throws {
        let f = try await Self.fixture()
        let text = CaseFileDocuments.holdNoticeTemplate(caseTitle: "Case", custodian: "Pat", organisation: "Acme", issuer: "Ada")
        #expect(text.contains("To: Pat") && text.contains("Ada, Acme"))
        try await f.file.issueHold(caseID: f.caseID, custodian: "Pat", personID: nil, noticeText: text, reminderDue: nil, actor: "Ada")
        var h = try #require(try await f.file.holdNotices(caseID: f.caseID).first)
        #expect(h.isOutstanding)
        try await f.file.acknowledgeHold(caseID: f.caseID, id: h.id, acknowledgedAt: Date(), actor: "Ada")
        try await f.file.releaseHold(caseID: f.caseID, id: h.id, reason: "Matter concluded", actor: "Ada")
        h = try #require(try await f.file.holdNotices(caseID: f.caseID).first)
        #expect(!h.isOutstanding && h.releasedAt != nil)
    }

    @Test("Review batches split documents and need a second person for QC")
    func batches() async throws {
        let f = try await Self.fixture()
        let sources = try await CaseFileTestSources.inScope(f.db, cases: f.cases, caseID: f.caseID, count: 25)
        let n = try await f.file.createBatches(caseID: f.caseID, sourceRefs: sources, size: 10, reviewer: "Ada", actor: "Ada")
        #expect(n == 3)
        let b = try #require(try await f.file.reviewBatches(caseID: f.caseID).first)
        #expect(b.sourceRefs.count == 10)
        try await f.file.advanceBatch(caseID: f.caseID, id: b.id, to: .firstPassDone, qcNote: nil, actor: "Ada")
        await #expect(throws: CaseFileError.self) {
            try await f.file.advanceBatch(caseID: f.caseID, id: b.id, to: .qcDone, qcNote: nil, actor: "Ada")
        }
        try await f.file.advanceBatch(caseID: f.caseID, id: b.id, to: .qcDone, qcNote: "Checked 10 of 10", actor: "Ben")
        #expect(try await f.file.reviewBatches(caseID: f.caseID).first?.qcReviewer == "Ben")
    }

    @Test("The conflict check records matches and waivers")
    func conflicts() async throws {
        let f = try await Self.fixture()
        _ = try await f.file.addPerson(caseID: f.caseID, name: "John Smith", role: .subject, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        let clear = try await f.file.runConflictCheck(caseID: f.caseID, investigator: "Ada Lovelace", declaredRelationships: [], waiveNote: nil, actor: "Ada")
        #expect(clear.result == .clear)
        let hit = try await f.file.runConflictCheck(caseID: f.caseID, investigator: "Ada Lovelace", declaredRelationships: ["john  SMITH"], waiveNote: nil, actor: "Ada")
        #expect(hit.result == .conflict && hit.matched == "John Smith")
        let waived = try await f.file.runConflictCheck(caseID: f.caseID, investigator: "Ada Lovelace", declaredRelationships: ["John Smith"],
                                                       waiveNote: "Former colleague, no contact since 2019; approved by the reviewer", actor: "Ada")
        #expect(waived.result == .waived)
        #expect(CaseConflictMatcher.matches(investigator: "Smith", declared: [], people: ["John Smith"]).isEmpty)  // surname alone is not a match
    }

    @Test("Tasks go through the task engine with confirmed deadlines; overdue is calculated")
    func tasksAndDeadlines() async throws {
        let f = try await Self.fixture()
        let past = Date().addingTimeInterval(-3 * 86_400)
        let t = try await f.svc.addTask(caseID: f.caseID, workspaceID: f.workspaceID, title: "Collect rota", assignee: "Ada", due: past, actor: "Ada")
        var items = try await f.svc.caseTasks(caseID: f.caseID)
        #expect(items.count == 1)
        #expect(items[0].isOverdue(at: Date()))
        #expect(items[0].deadline?.confirmation.kind == .user)
        try await f.svc.setDue(caseID: f.caseID, taskID: t, due: Date().addingTimeInterval(5 * 86_400), actor: "Ada")
        items = try await f.svc.caseTasks(caseID: f.caseID)
        #expect(!items[0].isOverdue(at: Date()))
        try await f.svc.completeTask(caseID: f.caseID, taskID: t, actor: "Ada")
        items = try await f.svc.caseTasks(caseID: f.caseID)
        #expect(items[0].task.status == .completed)
        #expect(items[0].deadline?.status == .satisfied)
    }

    @Test("Every template applies: plan, tasks with due dates, starter allegations, retention")
    func templates() async throws {
        #expect(Set(CaseTemplate.all.map(\.id)).count == CaseTemplate.all.count)
        for choice in InvestigationKindChoice.all { #expect(CaseTemplate.template(id: choice.id) != nil, "no template for \(choice.id)") }
        let f = try await Self.fixture()
        let t = try #require(CaseTemplate.template(id: "workplace"))
        try await f.svc.applyTemplate(t, caseID: f.caseID, workspaceID: f.workspaceID, actor: "Ada")
        let p = try await f.file.profile(caseID: f.caseID)
        #expect(p.kind == "workplace" && !p.plan.isEmpty && p.retentionPolicy != nil && p.owner == "Ada")
        #expect(try await f.svc.caseTasks(caseID: f.caseID).count == t.tasks.count)
        #expect(try await f.file.allegations(caseID: f.caseID).count == t.allegationPrompts.count)
    }

    @Test("The caseload puts overdue, severe, active cases first")
    func caseload() async throws {
        let f = try await Self.fixture(title: "Quiet case")
        let loud = try await f.cases.createCase(workspaceID: f.workspaceID, title: "Urgent case", actor: "Ada", at: Date())
        try await f.file.recordTriage(caseID: loud.id, CaseTriage(severity: .critical, decision: .accept), actor: "Ada")
        try await f.svc.addTask(caseID: loud.id, workspaceID: f.workspaceID, title: "Late", assignee: nil,
                                due: Date().addingTimeInterval(-86_400), actor: "Ada")
        let rows = try await f.svc.caseload()
        #expect(rows.count == 2)
        #expect(rows.first?.title == "Urgent case")
        #expect(rows.first?.overdueTasks == 1 && rows.first?.severity == .critical)
    }

    // MARK: Investigator workflow review 2026-10-30, I4 + I5

    @Test("§2: documentary support means a VERIFIED passage — a real quote in a real block verifies; a fabricated quote, an absent block, a wrong version, an out-of-case source, a withdrawn exhibit and a legacy identifier-only link all fail; an exception waives only the response; a scope change after linking is caught at the decision")
    func verifiedPassagesGateAdverseFindings() async throws {
        let f = try await Self.fixture()
        let a = try await f.file.addAllegation(caseID: f.caseID, text: "The supplier was paid twice", actor: "Ada")
        let bank = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "bank-statement.txt",
                                                             text: "Transfer to Dalmia Traders on 5 March 2026 for ₹10,000. The debit of ₹10,000 is the only payment to that supplier in the period. Closing balance ₹2,42,000.")
        let other = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "memo.txt",
                                                              text: "The staff picnic moves to the riverside park. Asha Rao booked the hall.")
        let outside = try await CaseFileTestSources.seed(f.db)   // in the archive, not in this case
        // Notes alone cannot substantiate.
        _ = try await f.svc.linkEvidence(caseID: f.caseID, allegationID: a, evidenceRef: "note:Two invoices in the folder", label: nil, stance: .supports, note: nil, actor: "Ada")
        await #expect(throws: CaseFileError.adverseFindingUnsupported("link at least one source passage or exhibit that supports it — a typed note is your own entry, not evidence")) {
            try await f.svc.decide(allegationID: a, caseID: f.caseID, disposition: .substantiated, rationale: "Obvious", actor: "Ada")
        }
        // A fabricated quote against a real source: unverified, and refused as support with the reason.
        let fake = try await f.svc.linkEvidence(caseID: f.caseID, allegationID: a, evidenceRef: bank.version.uuidString, label: "Bank statement", stance: .supports, note: nil,
                                                passage: StudioEvidenceRef(sourceVersionID: bank.version, quote: "Debit 20,000 Dalmia Traders twice"), actor: "Ada")
        #expect(fake.verification.support == .unverified("the quoted words are not in the cited source"))
        await #expect(throws: CaseFileError.self) { try await f.svc.decide(allegationID: a, caseID: f.caseID, disposition: .substantiated, rationale: "x", exception: "no respondent", actor: "Ada") }
        // An absent block, a block of another version, an out-of-case source, a bare identifier.
        let absent = try await f.svc.linkEvidence(caseID: f.caseID, allegationID: a, evidenceRef: bank.version.uuidString, label: nil, stance: .supports, note: nil,
                                                  passage: StudioEvidenceRef(sourceVersionID: bank.version, blockID: UUID(), quote: "only payment to that supplier"), actor: "Ada")
        #expect(absent.verification.support == .unverified("the cited passage no longer exists"))
        let wrongVersion = try await f.svc.linkEvidence(caseID: f.caseID, allegationID: a, evidenceRef: bank.version.uuidString, label: nil, stance: .supports, note: nil,
                                                        passage: StudioEvidenceRef(sourceVersionID: bank.version, blockID: other.blocks[0], quote: "staff picnic"), actor: "Ada")
        #expect(wrongVersion.verification.support == .unverified("the cited passage belongs to a different version of the source"))
        await #expect(throws: CaseFileError.self, "a source outside the case cannot even be linked") {
            _ = try await f.svc.linkEvidence(caseID: f.caseID, allegationID: a, evidenceRef: outside.uuidString, label: nil, stance: .supports, note: nil,
                                             passage: StudioEvidenceRef(sourceVersionID: outside, quote: "anything"), actor: "Ada")
        }
        let bare = try await f.svc.linkEvidence(caseID: f.caseID, allegationID: a, evidenceRef: bank.version.uuidString, label: nil, stance: .supports, note: nil, passage: nil, actor: "Ada")
        #expect(bare.verification.support.stored == "unverified" && bare.verification.support.detail?.contains("quotes no passage") == true)
        // The legacy path (identifiers only, no verification) stores an unverified link that never counts.
        let legacyID = try await f.file.addAllegationEvidence(caseID: f.caseID, allegationID: a, evidenceRef: bank.version.uuidString, label: "old fixture", stance: .supports, note: nil,
                                                              passage: StudioEvidenceRef(sourceVersionID: bank.version, objectID: UUID(), blockID: UUID(), quote: "Debit 10,000.00 Dalmia Traders"), actor: "Ada")
        #expect(try await f.file.allegationEvidence(caseID: f.caseID).first { $0.id == legacyID }?.isDocumentary == false)
        await #expect(throws: CaseFileError.self) { try await f.svc.decide(allegationID: a, caseID: f.caseID, disposition: .substantiated, rationale: "x", exception: "no respondent", actor: "Ada") }
        // A withdrawn exhibit is not support either.
        let ex = try await f.file.addExhibit(caseID: f.caseID, number: nil, description: "The paper invoice", sourceRef: nil, sha256: nil, collectedBy: "Ada", collectedAt: Date(), collectedWhere: nil, actor: "Ada")
        let exhibit = try await f.svc.linkEvidence(caseID: f.caseID, allegationID: a, evidenceRef: "exhibit:\(ex)", label: nil, stance: .supports, note: nil, actor: "Ada")
        #expect(exhibit.verification.support == .exhibit(ex))
        let exID = try #require(try await f.file.exhibits(caseID: f.caseID).first { $0.number == ex }?.id)
        try await f.file.withdrawExhibit(caseID: f.caseID, id: exID, actor: "Ada")
        let afterWithdraw = try await f.svc.reverifyLinks(caseID: f.caseID)
        #expect(afterWithdraw.first { $0.link.id == exhibit.id }?.verification.support.stored == "unverified")
        await #expect(throws: CaseFileError.self) { try await f.svc.decide(allegationID: a, caseID: f.caseID, disposition: .substantiated, rationale: "x", exception: "no respondent", actor: "Ada") }
        // A REAL quote with no locator resolves to the one block that holds it and verifies.
        let real = try await f.svc.linkEvidence(caseID: f.caseID, allegationID: a, evidenceRef: bank.version.uuidString, label: "Bank statement, 5 March", stance: .supports,
                                                note: "The debit", passage: StudioEvidenceRef(sourceVersionID: bank.version, quote: "is the only payment to that supplier in the period"), actor: "Ada")
        guard case .documentary(let v, let o, let b) = real.verification.support else { Issue.record("expected documentary, got \(real.verification.support)"); return }
        #expect(v == bank.version && o == bank.object && b == bank.blocks[1], "the quote is pinned to the block it is in")
        let stored = try #require(try await f.file.allegationEvidence(caseID: f.caseID).first { $0.id == real.id })
        #expect(stored.isDocumentary && stored.blockID == bank.blocks[1] && stored.objectID == bank.object && stored.opensPassage && stored.verification == "verified")
        // Documentary support, but no response: refused; the exception waives only that.
        await #expect(throws: CaseFileError.adverseFindingUnsupported("record the response put to the respondent, or state the exception that justifies deciding without one")) {
            try await f.svc.decide(allegationID: a, caseID: f.caseID, disposition: .substantiated, rationale: "Two payments, one invoice", actor: "Ada")
        }
        try await f.svc.decide(allegationID: a, caseID: f.caseID, disposition: .substantiated, rationale: "Two payments, one invoice",
                               exception: "Respondent left the organisation; two written requests unanswered", actor: "Ada")
        var al = try #require(try await f.file.allegations(caseID: f.caseID).first)
        #expect(al.disposition == .substantiated && al.exceptionNote == "Respondent left the organisation; two written requests unanswered" && al.response == nil)
        try await f.file.recordResponse(allegationID: a, caseID: f.caseID, response: "The second payment was a refund reversal.", actor: "Ada")
        al = try #require(try await f.file.allegations(caseID: f.caseID).first)
        #expect(al.response == "The second payment was a refund reversal.")
        // The report labels every link by its verification and tells a typed disposition apart.
        let b2 = try await f.file.addAllegation(caseID: f.caseID, text: "The approval was forged", actor: "Ada")
        try await f.svc.decide(allegationID: b2, caseID: f.caseID, disposition: .unsubstantiated, rationale: "No document shows it", actor: "Ada")
        var s = try #require(try await f.svc.snapshot(caseID: f.caseID, custody: []))
        var report = CaseFileDocuments.caseFileReport(s, by: "Ada")
        #expect(report.contains("- Bank statement, 5 March (verified passage) — “is the only payment to that supplier in the period” — The debit [\(bank.version.uuidString); block \(bank.blocks[1].uuidString.prefix(8))]"))
        #expect(report.contains("(unverified — the quoted words are not in the cited source)"))
        #expect(report.contains("(investigator's note)"))
        #expect(report.contains("Response: “The second payment was a refund reversal.”"))
        #expect(report.contains("**Unsubstantiated** — decided by Ada on") && report.contains("typed disposition: no documentary evidence supports it"))
        #expect(report.contains("evidence link(s) name a source but did not verify"))
        // A scope change after linking: the source leaves the case → re-verification at the next decision refuses.
        try await f.file.decide(allegationID: a, caseID: f.caseID, disposition: .pending, rationale: nil, actor: "Ada")
        let header = try #require(try await f.cases.fetch(caseID: f.caseID)).caseHeader
        _ = try await f.cases.excludeSource(caseID: f.caseID, expectedRevision: header.revision, sourceRef: bank.version.uuidString, sourceKind: .sourceVersion, note: "out of period", actor: "Ada", at: Date())
        await #expect(throws: CaseFileError.self, "the only verified passage left the case") {
            try await f.svc.decide(allegationID: a, caseID: f.caseID, disposition: .substantiated, rationale: "x", actor: "Ada")
        }
        s = try #require(try await f.svc.snapshot(caseID: f.caseID, custody: []))
        report = CaseFileDocuments.caseFileReport(s, by: "Ada")
        #expect(s.grid.first { $0.id == real.id }?.verification == "unverified" && report.contains("(unverified — the cited source is not in this case or is not accessible under the current policy)"))
    }

    @Test("§3: a carried row keeps EVERY citation, its saved revision's ledger digest and its review state; a rejected row is refused as evidence; an undecided row prints as provisional; a superseded origin is flagged; the same row is not carried twice by accident")
    func reviewedRowHandsOffIntoTheCase() async throws {
        let f = try await Self.fixture()
        let a = try await f.file.addAllegation(caseID: f.caseID, text: "The approval was given on 3 March", actor: "Ada")
        let vikram = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "vikram.txt",
                                                               text: "Vikram Rao said the meeting about the payment was held on March 2, 2026. Vikram Rao denied approving it before 5 March.")
        let asha = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "asha.txt",
                                                             text: "Asha Rao said the meeting was held on March 3, 2026. Asha Rao said she approved the payment.")
        let results = JobResultRepository(database: f.db)
        let q1 = "Vikram Rao said the meeting about the payment was held on March 2, 2026.", q2 = "Vikram Rao denied approving it before 5 March."
        var row1 = JobResultRow(title: "Point 1: meeting · payment — Vikram Rao", detail: "“\(q1)” “\(q2)”", date: "2026-03-02",
                                refs: [StudioEvidenceRef(sourceVersionID: vikram.version, objectID: vikram.object, blockID: vikram.blocks[0], quote: q1),
                                       StudioEvidenceRef(sourceVersionID: vikram.version, objectID: vikram.object, blockID: vikram.blocks[1], quote: q2)],
                                fields: ["point": "Point 1", "witness": "Vikram Rao", "comparison": "differs"])
        row1.decision = .accepted
        let q3 = "Asha Rao said the meeting was held on March 3, 2026."
        let row2 = JobResultRow(title: "Point 1: meeting · payment — Asha Rao", detail: "“\(q3)”", refs: [StudioEvidenceRef(sourceVersionID: asha.version, objectID: asha.object, quote: q3)])
        var row3 = JobResultRow(title: "Point 2 — Asha Rao", detail: "“Asha Rao said she approved the payment.”", refs: [StudioEvidenceRef(sourceVersionID: asha.version, quote: "Asha Rao said she approved the payment.")])
        row3.decision = .rejected; row3.note = "Duplicate of the attested statement already in the case"
        let id = try await results.save(caseID: f.caseID, jobID: "hr.statements", family: .interviewsQuotes, state: .draft,
                                        content: JobResultContent(rows: [row1, row2, row3]), actor: "Ada")
        let record = try #require(try await results.latest(caseID: f.caseID, jobID: "hr.statements"))
        #expect(record.id == id)
        let digest = try #require(try await results.payloadSHA256(id: id))
        // Both passages of the accepted row travel, each verified; the undecided row is provisional; the rejected row is refused.
        let linkIDs = try await JobResultHandoff.addToAllegation(record, row: 0, allegationID: a, stance: .contradicts, note: "Vikram's date differs", results: results, caseFiles: f.svc, actor: "Ada")
        #expect(linkIDs.count == 2)
        _ = try await JobResultHandoff.addToAllegation(record, row: 1, allegationID: a, stance: .supports, note: nil, results: results, caseFiles: f.svc, actor: "Ada")
        await #expect(throws: CaseFileError.rejectedRowNotEvidence) {
            _ = try await JobResultHandoff.addToAllegation(record, row: 2, allegationID: a, stance: .supports, note: nil, results: results, caseFiles: f.svc, actor: "Ada")
        }
        await #expect(throws: CaseFileError.alreadyCarried("That passage"), "the same row to the same allegation twice is refused") {
            _ = try await JobResultHandoff.addToAllegation(record, row: 0, allegationID: a, stance: .contradicts, note: nil, results: results, caseFiles: f.svc, actor: "Ada")
        }
        try await JobResultHandoff.addToChronology(record, row: 0, results: results, caseFiles: f.svc, actor: "Ada")
        try await JobResultHandoff.addToReport(record, row: 0, include: true, allegationID: a, results: results, caseFiles: f.svc, actor: "Ada")
        try await JobResultHandoff.addToReport(record, row: 1, include: true, allegationID: a, results: results, caseFiles: f.svc, actor: "Ada")
        try await JobResultHandoff.addToReport(record, row: 2, include: false, results: results, caseFiles: f.svc, actor: "Ada")
        await #expect(throws: CaseFileError.rejectedRowNotEvidence) {
            _ = try await JobResultHandoff.addToReport(record, row: 2, include: true, results: results, caseFiles: f.svc, actor: "Ada")
        }
        // A caller-supplied record that is not the saved current revision is refused before anything is written.
        let forged = JobResultRecord(id: UUID(), caseID: record.caseID, jobID: record.jobID, family: record.family, state: record.state,
                                     content: record.content, createdBy: record.createdBy, createdAt: record.createdAt)
        await #expect(throws: CaseFileError.staleResultRevision) {
            _ = try await JobResultHandoff.addToChronology(forged, row: 0, results: results, caseFiles: f.svc, actor: "Ada")
        }
        try await f.file.recordResponse(allegationID: a, caseID: f.caseID, response: "Asha says the diary shows the 3rd; Vikram was reading an earlier draft.", actor: "Ada")
        let origin0 = JobResultHandoff.origin(jobID: "hr.statements", resultID: record.id, row: 0)
        let origin1 = JobResultHandoff.origin(jobID: "hr.statements", resultID: record.id, row: 1)
        var s = try #require(try await f.svc.snapshot(caseID: f.caseID, custody: []))
        let links = s.grid.filter { $0.origin == origin0 }
        #expect(links.count == 2 && Set(links.compactMap(\.quote)) == [q1, q2] && links.allSatisfy { $0.isDocumentary && $0.reviewState == "accepted" && $0.originDigest == digest && $0.stance == .contradicts })
        let ashaLink = try #require(s.grid.first { $0.origin == origin1 })
        #expect(ashaLink.reviewState == "undecided" && ashaLink.isDocumentary, "the undecided row's passage still verifies — it is the REVIEW that is provisional")
        let chron = try #require(s.journal.first { $0.kind == .chronology })
        #expect(chron.citations.count == 2 && chron.quote == q1 && chron.origin == origin0 && chron.reviewState == "accepted" && chron.originDigest == digest && chron.support.isDocumentary)
        let included = s.reportItems.filter(\.included), excluded = s.reportItems.filter { !$0.included }
        #expect(included.count == 2 && included.first { $0.origin == origin0 }?.citations.count == 2 && included.first { $0.origin == origin0 }?.isAcceptedReview == true)
        #expect(included.first { $0.origin == origin1 }?.isAcceptedReview == false)
        #expect(excluded.count == 1 && excluded[0].exclusionReason == "Duplicate of the attested statement already in the case" && excluded[0].reviewState == "rejected")
        var report = CaseFileDocuments.caseFileReport(s, by: "Ada")
        #expect(report.contains("## Reviewed results included in this report") && report.contains("## Provisional material included in this report"))
        #expect(report.contains("(from \(origin0); accepted on review; revision \(digest.prefix(12)))"))
        #expect(report.contains("(from \(origin1); provisional — not yet decided on review; revision \(digest.prefix(12)))"))
        #expect(report.contains("+ 1 more citation(s)"), "the second passage is not lost in the report")
        #expect(report.contains("## Material excluded from this report\n- \(JobResultHandoff.text(of: row3)) [\(asha.version.uuidString)] — excluded: Duplicate of the attested statement already in the case"))
        // A newer saved run supersedes the origin: the report says so instead of showing the old revision as current.
        _ = try await results.save(caseID: f.caseID, jobID: "hr.statements", family: .interviewsQuotes, state: .draft, content: JobResultContent(rows: [row1]), actor: "Ada")
        s = try #require(try await f.svc.snapshot(caseID: f.caseID, custody: []))
        #expect(s.supersededOrigins.contains(origin0) && s.supersededOrigins.contains(origin1))
        report = CaseFileDocuments.caseFileReport(s, by: "Ada")
        #expect(report.contains("SUPERSEDED by a later result revision — re-review") && report.contains("carried item(s) come from a result revision that has since been superseded"))
        // Excluding an included item later keeps it, with the reason, and is in the log.
        try await f.file.setReportItem(caseID: f.caseID, id: included[0].id, included: false, reason: "Superseded by the attested statement", actor: "Ada")
        let after = try await f.file.reportItems(caseID: f.caseID)
        #expect(after.first { $0.id == included[0].id }?.exclusionReason == "Superseded by the attested statement")
        #expect(try await f.file.actions(caseID: f.caseID).filter { $0.action == "reportItemExcluded" }.count == 2)
    }

    @Test("A name the tagger labels both as a person and as an organisation in one document reads as a PERSON whichever row comes first (the acceptance case's Asha Rao lost her speaker attribution when the organisation row won)")
    func doublyTaggedNameIsAPerson() async throws {
        let f = try await Self.fixture()
        let doc = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "statement.txt",
                                                            text: "Asha Rao said she approved the payment to Dalmia Traders on 3 March 2026. Asha Rao said the invoice was received once.")
        let entities = EntitiesRepository(database: f.db)
        for order in [[Entity.Kind.organization, .person], [.person, .organization]] {
            // Both orders of arrival: the organisation row first, then the person row, and the reverse.
            try await f.db.exec("DELETE FROM entity_mentions WHERE source_object_id = ?;", [.uuid(doc.object)])
            try await f.db.exec("DELETE FROM entities WHERE source_object_id = ?;", [.uuid(doc.object)])
            try await entities.insertBatch(order.map { Entity(kind: $0, value: "Asha Rao", sourceObjectID: doc.object) }
                                           + [Entity(kind: .organization, value: "Dalmia Traders", sourceObjectID: doc.object)])
            let reader = StudioCaseFactsReader(facts: GenericFactRepository(database: f.db), events: EventsRepository(database: f.db),
                                               objects: KnowledgeObjectRepository(database: f.db), entities: entities)
            let facts = try await reader.read(caseTitle: "x", sourceVersionIDs: [doc.version])
            let asha = facts.named.filter { $0.value == "Asha Rao" }
            #expect(asha.count == 1 && asha.first?.label == "person", "\(order): \(facts.named.map { "\($0.value)=\($0.label)" })")
            #expect(facts.named.first { $0.value == "Dalmia Traders" }?.label == "organisation")
            let names = JobText.names(in: "Asha Rao said she approved the payment to Dalmia Traders on 3 March 2026.", facts.named, persons: true)
            #expect(SpeakerAttribution.resolve("Asha Rao said she approved the payment to Dalmia Traders on 3 March 2026.", named: names).speaker == "Asha Rao")
        }
    }

    @Test("Documents carry what was recorded; every change is in the action log")
    func documentsAndLog() async throws {
        let f = try await Self.fixture()
        let pid = try await f.file.addPerson(caseID: f.caseID, name: "Sam Witness", role: .witness, entityID: nil, contact: "x123", notes: nil, actor: "Ada")
        try await f.file.addContact(caseID: f.caseID, personID: pid, at: Date(), mode: "Phone", note: "Left message", actor: "Ada")
        _ = try await f.file.addJournal(caseID: f.caseID, kind: .chronology, text: "Sam Witness saw the incident", eventDate: Date(), evidenceRef: nil, actor: "Ada")
        try await f.file.logRedaction(caseID: f.caseID, sourceRef: "src-9", location: "p. 2", reason: "Personal data", actor: "Ada")
        let s = try #require(try await f.svc.snapshot(caseID: f.caseID, custody: []))
        let report = CaseFileDocuments.caseFileReport(s, by: "Ada")
        #expect(report.contains("# Complaint about the night shift") && report.contains("Sam Witness — Witness"))
        #expect(report.contains("judgement stays with the investigator"))
        let personal = CaseFileDocuments.personDataExport(s, name: "Sam Witness", by: "Ada")
        #expect(personal.contains("Left message") && personal.contains("saw the incident"))
        #expect(CaseFileDocuments.redactionLogCSV(s).contains("\"Personal data\""))
        let log = try await f.file.actions(caseID: f.caseID)
        #expect(log.map(\.action) == ["personAdded", "contactLogged", "chronologyAdded", "redactionLogged"])
        #expect(log.map(\.sequence) == [1, 2, 3, 4])
    }

    @Test("Writes to a case that doesn't exist are refused")
    func unknownCase() async throws {
        let f = try await Self.fixture()
        let missing = UUID()
        await #expect(throws: CaseFileError.caseNotFound(missing)) {
            _ = try await f.file.addAllegation(caseID: missing, text: "x", actor: "Ada")
        }
    }
}
