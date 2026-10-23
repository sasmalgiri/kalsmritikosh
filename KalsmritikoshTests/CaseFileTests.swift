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
        try await f.file.addAllegationEvidence(caseID: f.caseID, allegationID: a, evidenceRef: "src-1", label: "Email 4 March",
                                               stance: .supports, note: "Names the date", actor: "Ada")
        try await f.file.decide(allegationID: a, caseID: f.caseID, disposition: .substantiated, rationale: "Two witnesses and the email agree", actor: "Ada")
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
        let n = try await f.file.createBatches(caseID: f.caseID, sourceRefs: (1...25).map { "s\($0)" }, size: 10, reviewer: "Ada", actor: "Ada")
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
