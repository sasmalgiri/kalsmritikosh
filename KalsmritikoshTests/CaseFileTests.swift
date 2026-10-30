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
        let source = try #require(try await CaseFileTestSources.inScope(f.db, cases: f.cases, caseID: f.caseID).first)
        try await f.file.addAllegationEvidence(caseID: f.caseID, allegationID: a, evidenceRef: source, label: "Email 4 March",
                                               stance: .supports, note: "Names the date", actor: "Ada")
        // I4 — an adverse finding needs the response put to the respondent (or an explicit exception).
        await #expect(throws: CaseFileError.adverseFindingUnsupported("record the response put to the respondent, or state the exception that justifies deciding without one")) {
            try await f.file.decide(allegationID: a, caseID: f.caseID, disposition: .substantiated, rationale: "Two witnesses and the email agree", actor: "Ada")
        }
        try await f.file.recordResponse(allegationID: a, caseID: f.caseID, response: "Denies shouting; says voices were raised by both.", actor: "Ada")
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

    @Test("I4: an evidence link carries the exact passage; an adverse finding needs a documentary passage that supports it and the response (or an explicit exception); the report tells a reviewed documentary finding from a typed disposition")
    func passageLevelEvidenceAndAdverseFindingGate() async throws {
        let f = try await Self.fixture()
        let a = try await f.file.addAllegation(caseID: f.caseID, text: "The supplier was paid twice", actor: "Ada")
        // Notes alone cannot substantiate.
        try await f.file.addAllegationEvidence(caseID: f.caseID, allegationID: a, evidenceRef: "note:Two invoices in the folder", label: nil, stance: .supports, note: nil, actor: "Ada")
        await #expect(throws: CaseFileError.adverseFindingUnsupported("link at least one source passage or exhibit that supports it — a typed note is your own entry, not evidence")) {
            try await f.file.decide(allegationID: a, caseID: f.caseID, disposition: .substantiated, rationale: "Obvious", actor: "Ada")
        }
        // A passage: version + block + quote, opened from the allegation without searching again.
        let source = try #require(try await CaseFileTestSources.inScope(f.db, cases: f.cases, caseID: f.caseID).first)
        let block = UUID(), object = UUID()
        try await f.file.addAllegationEvidence(caseID: f.caseID, allegationID: a, evidenceRef: source, label: "Bank statement, 3 March", stance: .supports,
                                               note: "The debit", passage: StudioEvidenceRef(sourceVersionID: UUID(uuidString: source), objectID: object, blockID: block, quote: "Debit 10,000.00 Dalmia Traders"),
                                               actor: "Ada")
        let grid = try await f.file.allegationEvidence(caseID: f.caseID)
        let link = try #require(grid.first { $0.evidenceRef == source })
        #expect(link.quote == "Debit 10,000.00 Dalmia Traders" && link.blockID == block && link.objectID == object && link.isDocumentary && link.opensPassage)
        #expect(grid.first { $0.evidenceRef.hasPrefix("note:") }?.isDocumentary == false)
        // Documentary support, but no response yet.
        await #expect(throws: CaseFileError.adverseFindingUnsupported("record the response put to the respondent, or state the exception that justifies deciding without one")) {
            try await f.file.decide(allegationID: a, caseID: f.caseID, disposition: .substantiated, rationale: "Two payments, one invoice", actor: "Ada")
        }
        // An explicit exception is recorded with the finding.
        try await f.file.decide(allegationID: a, caseID: f.caseID, disposition: .substantiated, rationale: "Two payments, one invoice",
                                exception: "Respondent left the organisation; two written requests unanswered", actor: "Ada")
        var al = try #require(try await f.file.allegations(caseID: f.caseID).first)
        #expect(al.disposition == .substantiated && al.exceptionNote == "Respondent left the organisation; two written requests unanswered" && al.response == nil)
        // A response recorded later shows in the report; a non-adverse finding needs none.
        try await f.file.recordResponse(allegationID: a, caseID: f.caseID, response: "The second payment was a refund reversal.", actor: "Ada")
        al = try #require(try await f.file.allegations(caseID: f.caseID).first)
        #expect(al.response == "The second payment was a refund reversal.")
        let b = try await f.file.addAllegation(caseID: f.caseID, text: "The approval was forged", actor: "Ada")
        try await f.file.decide(allegationID: b, caseID: f.caseID, disposition: .unsubstantiated, rationale: "No document shows it", actor: "Ada")
        let s = try #require(try await f.svc.snapshot(caseID: f.caseID, custody: []))
        let report = CaseFileDocuments.caseFileReport(s, by: "Ada")
        #expect(report.contains("— “Debit 10,000.00 Dalmia Traders” — The debit [\(source); block \(block.uuidString.prefix(8))]"))
        #expect(report.contains("(investigator's note)"))
        #expect(report.contains("Response: “The second payment was a refund reversal.”"))
        #expect(report.contains("**Unsubstantiated** — decided by Ada on") && report.contains("typed disposition: no documentary evidence supports it"))
        #expect(report.contains("## Unresolved questions and limitations"))
        #expect(!report.contains("A1 was decided without a recorded response"), "the response was recorded after the decision")
    }

    @Test("I5: a reviewed result row is carried to an allegation, the chronology and the report with the same passage and revision identity — no retyping; excluded material keeps its reason")
    func reviewedRowHandsOffIntoTheCase() async throws {
        let f = try await Self.fixture()
        let a = try await f.file.addAllegation(caseID: f.caseID, text: "The approval was given on 3 March", actor: "Ada")
        let source = try #require(try await CaseFileTestSources.inScope(f.db, cases: f.cases, caseID: f.caseID).first)
        let version = try #require(UUID(uuidString: source))
        let results = JobResultRepository(database: f.db)
        let quote = "Vikram Rao said the meeting about the payment was held on March 2, 2026."
        let row1 = JobResultRow(title: "Point 1: meeting · payment — Vikram Rao", detail: "“\(quote)”", date: "2026-03-02",
                                flags: ["verbatim", "differs from Asha Rao on date: 2026-03-02 vs 2026-03-03"],
                                refs: [StudioEvidenceRef(sourceVersionID: version, objectID: UUID(), quote: quote)],
                                fields: ["point": "Point 1", "witness": "Vikram Rao", "comparison": "differs"])
        var row2 = JobResultRow(title: "Point 1: meeting · payment — Asha Rao", detail: "“Asha Rao said the meeting was held on March 3, 2026.”", refs: [])
        row2.note = "Duplicate of the attested statement already in the case"
        let id = try await results.save(caseID: f.caseID, jobID: "hr.statements", family: .interviewsQuotes, state: .draft,
                                        content: JobResultContent(rows: [row1, row2]), actor: "Ada")
        let record = try #require(try await results.latest(caseID: f.caseID, jobID: "hr.statements"))
        #expect(record.id == id)
        // To the allegation, as a contradicting passage; to the chronology; into the report.
        try await JobResultHandoff.addToAllegation(record, row: 0, allegationID: a, stance: .contradicts, note: "Vikram's date differs", file: f.file, actor: "Ada")
        try await JobResultHandoff.addToChronology(record, row: 0, file: f.file, actor: "Ada")
        try await JobResultHandoff.addToReport(record, row: 0, include: true, allegationID: a, file: f.file, actor: "Ada")
        // Excluding needs the reason (the row's note); a row with no source cannot be evidence.
        try await JobResultHandoff.addToReport(record, row: 1, include: false, file: f.file, actor: "Ada")
        await #expect(throws: JobResultHandoffError.noSource) {
            try await JobResultHandoff.addToAllegation(record, row: 1, allegationID: a, stance: .supports, note: nil, file: f.file, actor: "Ada")
        }
        var noNote = record.content.rows[1]; noNote.note = nil
        let bare = JobResultRecord(id: record.id, caseID: record.caseID, jobID: record.jobID, family: record.family, state: record.state,
                                   content: JobResultContent(rows: [row1, noNote]), createdBy: record.createdBy, createdAt: record.createdAt)
        await #expect(throws: JobResultHandoffError.reasonRequired) {
            try await JobResultHandoff.addToReport(bare, row: 1, include: false, file: f.file, actor: "Ada")
        }
        // The respondent's explanation, then the report: the same text, passage and origin everywhere.
        try await f.file.recordResponse(allegationID: a, caseID: f.caseID, response: "Asha says the diary shows the 3rd; Vikram was reading an earlier draft.", actor: "Ada")
        let origin = JobResultHandoff.origin(jobID: "hr.statements", resultID: record.id, row: 0)
        let s = try #require(try await f.svc.snapshot(caseID: f.caseID, custody: []))
        let link = try #require(s.grid.first { $0.allegationID == a })
        #expect(link.stance == .contradicts && link.quote == quote && link.origin == origin && link.evidenceRef == source && link.label == JobResultHandoff.text(of: row1))
        let chron = try #require(s.journal.first { $0.kind == .chronology })
        #expect(chron.quote == quote && chron.origin == origin && chron.evidenceRef == source && chron.text == JobResultHandoff.text(of: row1))
        #expect(chron.eventDate == JobResultHandoff.date(of: row1) && JobResultHandoff.date(of: row1) != nil)
        #expect(JobResultHandoff.text(of: row1) == row1.title, "a detail that only repeats the quote is not carried twice")
        let included = s.reportItems.filter(\.included), excluded = s.reportItems.filter { !$0.included }
        #expect(included.count == 1 && included[0].quote == quote && included[0].origin == origin && included[0].allegationID == a)
        #expect(excluded.count == 1 && excluded[0].exclusionReason == "Duplicate of the attested statement already in the case")
        let report = CaseFileDocuments.caseFileReport(s, by: "Ada")
        #expect(report.contains("Contradicts:\n- \(JobResultHandoff.text(of: row1)) — “\(quote)” — Vikram's date differs [\(source)] (from \(origin))"))
        #expect(report.contains("## Reviewed results included in this report\n- \(JobResultHandoff.text(of: row1)) — “\(quote)” [\(source)] (from \(origin)) · A1"))
        #expect(report.contains("## Material excluded from this report\n- \(JobResultHandoff.text(of: row2)) — excluded: Duplicate of the attested statement already in the case"))
        #expect(report.contains("Response: “Asha says the diary shows the 3rd"))
        #expect(report.contains("- \(CaseFileDocuments.d(chron.eventDate)): \(JobResultHandoff.text(of: row1)) — “\(quote)” [\(source)] (from \(origin))"))
        // Excluding an included item later keeps it, with the reason, and is in the log.
        try await f.file.setReportItem(caseID: f.caseID, id: included[0].id, included: false, reason: "Superseded by the attested statement", actor: "Ada")
        let after = try await f.file.reportItems(caseID: f.caseID)
        #expect(after.filter(\.included).isEmpty && after.first { $0.id == included[0].id }?.exclusionReason == "Superseded by the attested statement")
        #expect(try await f.file.actions(caseID: f.caseID).filter { $0.action == "reportItemExcluded" }.count == 2)
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
