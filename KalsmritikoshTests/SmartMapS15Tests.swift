//
//  SmartMapS15Tests.swift
//  KalsmritikoshTests
//
//  Smart-map slice S15 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md §02 ARCH, §03 DATA; schema v190):
//  - DATA-02: the v171–v176 tables and v183 history references refuse rows of a missing case and endpoints of another case,
//    inside the statement; the one permitted cross-case route is case_cross_references; a refused write leaves nothing;
//  - ARCH-09: automation work that crosses the engine run is re-checked inside the applying write — a case closed or erased,
//    an input gone stale or the policy changed meanwhile refuses it and the engine's action never joins the case;
//  - DATA-03: assignments keep before/after copies of the task's owner and of the assignment rows;
//  - DATA-10: date precision, wording, range and exact amounts survive a recorded state and the map export; missing stays missing;
//  - ARCH-01 / DATA-09: identities through rename, re-layout, export, exchange import, restart and backup/restore;
//  - ARCH-04: semantic roles; a source's presence, verified words, accepted reviews and completed work never conclude;
//  - ARCH-05: typed references with explicit availability in the map export;
//  - ARCH-10: the map, the tools list, the report and the AI money tool show the same canonical figures.
//  Synthetic data only; AI replies are scripted closures (no network, no model). Dates carry explicit time zones.
//

import Foundation
import Testing
@testable import Kalsmritikosh

private let s15Kolkata = TimeZone(identifier: "Asia/Kolkata")!

private func s15Count(_ db: Database, _ sql: String, _ b: [SQLValue] = []) async throws -> Int {
    Int(try await db.query(sql, b).first?.int(0) ?? -1)
}

private func s15Date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, zone: TimeZone = s15Kolkata) -> Date {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
    return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

private func s15Scratch(_ tag: String) throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("s15-\(tag)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// A new current version of the document behind `object`, included in the case (as SmartMapS8Tests does).
private func s15Revise(_ db: Database, object: UUID, cases: InvestigationCaseRepository, caseID: UUID) async throws {
    let fileID = try #require(try await db.query("SELECT file_id FROM knowledge_objects WHERE id = ?;", [.uuid(object)]).first?.uuid(0))
    try await db.exec("UPDATE source_versions SET is_current = 0 WHERE logical_source_id = ?;", [.uuid(fileID)])
    let version = UUID(), doc = UUID(), t = Date().timeIntervalSince1970
    let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    try await db.exec("""
        INSERT INTO source_versions (id, logical_source_id, document_id, content_hash, valid_from, is_current, created_at,
            filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        """, [.uuid(version), .uuid(fileID), .uuid(doc), .text(hex + hex), .real(t), .integer(1), .real(t),
              .text("revised.txt"), .text("txt"), .text("magicBytes"), .integer(1), .text("referenced"), .text("referenceRecorded"), .real(t)])
    let header = try await cases.fetch(caseID: caseID)?.caseHeader
    _ = try await cases.includeSource(caseID: caseID, expectedRevision: header?.revision ?? 1, sourceRef: version.uuidString,
                                      sourceKind: .sourceVersion, actor: "Ada", at: Date())
}

/// A case with a statement, a question and one action.
private struct S15Rig {
    let f: CaseFileTests.Fixture
    let doc: (version: UUID, object: UUID, blocks: [UUID])
    let question: UUID
    let task: UUID
    var c: UUID { f.caseID }

    static func make(title: String = "Supplier payments") async throws -> S15Rig {
        let f = try await CaseFileTests.fixture(title: title)
        let doc = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "bank-statement.txt",
                                                            text: "Transfer to Dalmia Traders on 5 March 2026 for ₹10,000. A second transfer of ₹10,000 followed on 9 March 2026.")
        let q = try await f.file.addAllegation(caseID: f.caseID, text: "Was the supplier paid twice?", actor: "Ada")
        let t = try await f.svc.createTypedAction(caseID: f.caseID,
                                                  CaseFileService.ChildAction(title: "Reconcile the two transfers", purpose: "Find out whether the second transfer is separate",
                                                                              deliverable: "A reconciliation", responsible: "Ada", servesQuestions: [q]),
                                                  details: CaseActionDetails(type: .reconciliation, trigger: CaseActionTrigger(kind: .manual, records: [], sourceRevisions: [doc.version])),
                                                  actor: "Ada")
        return S15Rig(f: f, doc: doc, question: q, task: t)
    }

    func trigger(_ event: String, inputs: [CaseExaminedInput]) -> CaseAutomationTrigger {
        let r = CaseAutomationRecipe.changedEvidenceReview
        return CaseAutomationTrigger(recipeID: r.id, causeAction: r.triggers[0], eventKey: event, title: "Review changed evidence",
                                     purpose: "Check the earlier work against the new version", inputs: inputs, causationID: nil, requestedBy: "Ada")
    }
}

// MARK: - DATA-02

@Suite("Smart map S15 — ownership, references and apply-time checks (M0 ARCH/DATA)", .serialized)
struct SmartMapS15Tests {

    @Test("DATA-02: rows of a missing case and endpoints of another case are refused by the database; a refused write leaves no partial row")
    func referencesEnforced() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        let other = try await f.cases.createCase(workspaceID: f.workspaceID, title: "Other case", actor: "Ada", at: Date())
        let foreignReport = try await f.file.addReport(caseID: other.id, CaseReportDetails(title: "Other report"), actor: "Ada")
        let foreignQ = try await f.file.addAllegation(caseID: other.id, text: "Other question", actor: "Ada")
        let myQ = try await f.file.addAllegation(caseID: c, text: "Was the seal intact?", actor: "Ada")
        let ghost = UUID()

        // 1. Every smart-map table refuses a row whose case does not exist.
        var missingCase: [(String, String, [SQLValue])] = []
        missingCase.append(("case_map_views", "INSERT INTO case_map_views (id, case_id, name, base_view, created_by, created_at, updated_at) VALUES (?,?,'v','overview','x',1,1);", [.uuid(UUID()), .uuid(ghost)]))
        missingCase.append(("case_map_layout", "INSERT INTO case_map_layout (case_id, frame_key, record_kind, record_id, x, y, updated_at) VALUES (?, '', 'person', 'p', 0, 0, 1);", [.uuid(ghost)]))
        missingCase.append(("case_map_links", "INSERT INTO case_map_links (id, case_id, link_type, from_kind, from_id, to_kind, to_id, rationale, created_by, created_at) VALUES (?,?,'supports','person','a','allegation','b','r','x',1);", [.uuid(UUID()), .uuid(ghost)]))
        missingCase.append(("case_record_revisions", "INSERT INTO case_record_revisions (id, case_id, record_kind, record_id, change, after_json, actor, recorded_at) VALUES (?,?,'person','p','c','{}','x',1);", [.uuid(UUID()), .uuid(ghost)]))
        missingCase.append(("case_change_seen", "INSERT INTO case_change_seen (case_id, seen_through, seen_by, seen_at) VALUES (?,1,'x',1);", [.uuid(ghost)]))
        missingCase.append(("case_reports", "INSERT INTO case_reports (id, case_id, title, report_kind, recorded_by, recorded_at) VALUES (?,?,'R','original','x',1);", [.uuid(UUID()), .uuid(ghost)]))
        for (table, sql, binds) in missingCase {
            await #expect(throws: (any Error).self, "\(table) accepted a row of a missing case") { try await f.db.exec(sql, binds) }
        }

        // 2. Endpoints of another case: a point on another case's report, a work link to another case's question,
        //    an amendment of another case's report, a contract for a task that is not this case's.
        await #expect(throws: (any Error).self) {
            try await f.db.exec("INSERT INTO case_report_points (id, case_id, report_id, point_kind, statement, recorded_by, recorded_at) VALUES (?,?,?,'claim','s','x',1);",
                                [.uuid(UUID()), .uuid(c), .uuid(foreignReport)])
        }
        await #expect(throws: (any Error).self) {
            try await f.db.exec("INSERT INTO case_work_links (id, case_id, work_kind, work_id, target_kind, target_id, role, created_by, created_at) VALUES (?,?,'allegation',?,'report',?,'serves','x',1);",
                                [.uuid(UUID()), .uuid(c), .uuid(foreignQ), .uuid(rig.report)])
        }
        await #expect(throws: (any Error).self) {
            try await f.db.exec("INSERT INTO case_reports (id, case_id, title, report_kind, amends_report_id, recorded_by, recorded_at) VALUES (?,?,'A','amendment',?,'x',1);",
                                [.uuid(UUID()), .uuid(c), .uuid(foreignReport)])
        }
        await #expect(throws: (any Error).self) {
            try await f.db.exec("INSERT INTO case_action_contracts (task_id, case_id, purpose, deliverable, created_by, created_at, updated_at) VALUES (?,?,'p','d','x',1,1);",
                                [.uuid(UUID()), .uuid(c)])
        }
        // The same-case forms are accepted (the triggers are not over-broad).
        try await f.db.exec("INSERT INTO case_work_links (id, case_id, work_kind, work_id, target_kind, target_id, role, created_by, created_at) VALUES (?,?,'allegation',?,'report',?,'serves','x',1);",
                            [.uuid(UUID()), .uuid(c), .uuid(myQ), .uuid(rig.report)])

        // 3. No partial write: a valid statement followed by an invalid one in the same savepoint leaves neither.
        let pointsBefore = try await s15Count(f.db, "SELECT COUNT(*) FROM case_report_points WHERE case_id = ?;", [.uuid(c)])
        let good = UUID()
        await #expect(throws: (any Error).self) {
            try await f.db.withSavepoint("s15_partial") { db in
                try db.exec("INSERT INTO case_report_points (id, case_id, report_id, point_kind, statement, recorded_by, recorded_at) VALUES (?,?,?,'claim','ok','x',1);",
                            [.uuid(good), .uuid(c), .uuid(rig.report)])
                try db.exec("INSERT INTO case_report_qualifications (id, case_id, point_id, qualification_kind, text, recorded_by, recorded_at) VALUES (?,?,?,'limitation','t','x',1);",
                            [.uuid(UUID()), .uuid(c), .uuid(UUID())])
            }
        }
        #expect(try await s15Count(f.db, "SELECT COUNT(*) FROM case_report_points WHERE case_id = ?;", [.uuid(c)]) == pointsBefore)
        #expect(try await s15Count(f.db, "SELECT COUNT(*) FROM case_report_points WHERE id = ?;", [.uuid(good)]) == 0)
        // Through the repository: a point on another case's report is refused and the case's log is unchanged.
        let actions = try await s15Count(f.db, "SELECT COUNT(*) FROM case_actions WHERE case_id = ?;", [.uuid(c)])
        await #expect(throws: (any Error).self) {
            _ = try await f.file.addPoint(caseID: c, reportID: foreignReport, kind: .claim, statement: "x", passage: nil, support: .note, locatorNote: nil, actor: "Ada")
        }
        #expect(try await s15Count(f.db, "SELECT COUNT(*) FROM case_actions WHERE case_id = ?;", [.uuid(c)]) == actions)

        // 4. The permitted cross-case route: a cross-reference through this case's own history source.
        let src = try await f.file.addHistorySource(caseID: c, kind: .case, originCaseID: other.id, purpose: "Earlier dispute", scope: .records, actor: "Ada")
        let ref = try await f.file.addCrossReference(caseID: c, historySourceID: src, origin: CaseMapNodeID(caseID: other.id, kind: .allegation, id: foreignQ),
                                                     mode: .live, purpose: "Compare", actor: "Ada")
        #expect(try await s15Count(f.db, "SELECT COUNT(*) FROM case_cross_references WHERE id = ?;", [.uuid(ref)]) == 1)
        // …but not through another case's history source.
        let theirs = try await f.file.addHistorySource(caseID: other.id, kind: .case, originCaseID: c, purpose: "Back", scope: .records, actor: "Ada")
        await #expect(throws: (any Error).self) {
            try await f.db.exec("""
                INSERT INTO case_cross_references (id, case_id, history_source_id, origin_case_id, origin_kind, origin_record_id, mode, purpose, created_by, created_at)
                VALUES (?,?,?,?,'allegation',?,'live','p','x',1);
                """, [.uuid(UUID()), .uuid(c), .uuid(theirs), .uuid(other.id), .uuid(foreignQ)])
        }
    }

    @Test("DATA-02: an action's parent must be an action of the same case, on insert and when it changes")
    func contractParentChecked() async throws {
        let r = try await S15Rig.make()
        let other = try await S15Rig.make(title: "Other")
        await #expect(throws: (any Error).self) {
            try await r.f.db.exec("UPDATE case_action_contracts SET parent_task_id = ? WHERE task_id = ?;", [.uuid(other.task), .uuid(r.task)])
        }
        let child = try await r.f.svc.createAction(caseID: r.c, .init(title: "Child", purpose: "p", deliverable: "d", parentTaskID: r.task), actor: "Ada")
        #expect(try await s15Count(r.f.db, "SELECT COUNT(*) FROM case_action_contracts WHERE task_id = ? AND parent_task_id IS NOT NULL;", [.uuid(child)]) == 1)
    }

    @Test("DATA-01/DATA-06: v189 → v190 keeps every case row; the newest migration leaves the sentinel a column; a fault rolls v190 back")
    func migrationV190() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 189)
        let ws = UUID(), c = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);", [.uuid(ws), .text("W"), .real(1), .real(1)])
        try await db.exec("INSERT INTO investigation_cases (id, workspace_id, title, status, revision, actor, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?);",
                          [.uuid(c), .uuid(ws), .text("Kept"), .text("open"), .integer(1), .text("u"), .real(1), .real(1)])
        try await db.exec("INSERT INTO case_reports (id, case_id, title, report_kind, recorded_by, recorded_at) VALUES (?,?,?,?,?,?);",
                          [.uuid(UUID()), .uuid(c), .text("R"), .text("original"), .text("Ada"), .real(1)])
        // A legacy orphan row (case gone before v190) is kept: the new keys check new writes, they do not delete history.
        try await db.exec("INSERT INTO case_map_layout (case_id, frame_key, record_kind, record_id, x, y, updated_at) VALUES (?, '', 'person', 'p', 0, 0, 1);", [.uuid(UUID())])
        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.migrate(db, through: 190, fault: MigrationFaultHarness.hook(throwingAt: .afterSQLBeforeVersionStamp(version: 190)))
        }
        #expect(try await db.currentUserVersion() == 189)
        #expect(try await s15Count(db, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name LIKE '%_v190';") == 0)
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
        #expect(try await s15Count(db, "SELECT COUNT(*) FROM case_reports WHERE case_id = ?;", [.uuid(c)]) == 1)
        #expect(try await s15Count(db, "SELECT COUNT(*) FROM case_map_layout;") == 1)
        #expect(try await s15Count(db, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name LIKE '%_v190';") >= 20)
        #expect(SchemaMigrations.addedColumns(inMigration: 190).contains { $0.table == "case_automation_outbox" && $0.column == "unapplied_task_id" })
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    // MARK: - ARCH-09

    private func queued(_ r: S15Rig, _ auto: CaseAutomationService, _ event: String) async throws -> UUID {
        guard case .queued(let id) = try await auto.observe(caseID: r.c, r.trigger(event, inputs: [.source(r.doc.version), CaseExaminedInput(kind: "task", id: r.task.uuidString)])) else {
            throw CaseAutomationError.wrongState("not queued")
        }
        return id
    }

    private func linkedTasks(_ r: S15Rig) async throws -> Int {
        try await s15Count(r.f.db, "SELECT COUNT(*) FROM case_task_links WHERE case_id = ?;", [.uuid(r.c)])
    }

    @Test("ARCH-09: work allowed when it started is applied only if still allowed — a stale input, a closed case or a manual policy during the run refuses it; the engine's action is archived, never joins the case")
    func applyTimeRecheck() async throws {
        // Control: nothing changes during the run → applied.
        let ok = try await S15Rig.make()
        let autoOK = CaseAutomationService(database: ok.f.db, caseFiles: ok.f.svc, aiPermitted: { _ in false })
        let q0 = try await queued(ok, autoOK, "e0")
        #expect(try await autoOK.dispatch(caseID: ok.c, actor: "Ada").done == [q0])

        // The input goes stale while the engine runs.
        let r = try await S15Rig.make()
        let auto = CaseAutomationService(database: r.f.db, caseFiles: r.f.svc, aiPermitted: { _ in false })
        let q1 = try await queued(r, auto, "e1")
        let db = r.f.db, cases = r.f.cases, object = r.doc.object, c = r.c
        await auto.setBeforeApply { try? await s15Revise(db, object: object, cases: cases, caseID: c) }
        let before = try await linkedTasks(r)
        let rep = try await auto.dispatch(caseID: r.c, actor: "Ada")
        #expect(rep.refused == [q1] && rep.done.isEmpty, "\(rep)")
        let row = try #require(try await r.f.db.query("SELECT state, state_reason, unapplied_task_id, output_task_id FROM case_automation_outbox WHERE id = ?;", [.uuid(q1)]).first)
        #expect(row.string(0) == "refused" && row.string(1)?.contains("stale") == true && row.isNull(3))
        let made = try #require(row.uuid(2))
        #expect(try await linkedTasks(r) == before, "the engine's action is not linked to the case")
        #expect(try await s15Count(r.f.db, "SELECT COUNT(*) FROM case_action_contracts WHERE upper(task_id) = ?;", [.text(made.uuidString)]) == 0)
        #expect(try await s15Count(r.f.db, "SELECT COUNT(*) FROM professional_tasks WHERE upper(id) = ? AND archived_at IS NOT NULL;", [.text(made.uuidString)]) == 1)
        #expect(try await s15Count(r.f.db, "SELECT COUNT(*) FROM case_actions WHERE case_id = ? AND action = 'automationApplied';", [.uuid(r.c)]) == 0)

        // The case is closed while the engine runs.
        let r2 = try await S15Rig.make()
        let auto2 = CaseAutomationService(database: r2.f.db, caseFiles: r2.f.svc, aiPermitted: { _ in false })
        let q2 = try await queued(r2, auto2, "e2")
        let file2 = r2.f.file, c2 = r2.c
        await auto2.setBeforeApply { try? await file2.markClosed(caseID: c2, reopened: false, actor: "Ada") }
        let before2 = try await linkedTasks(r2)
        #expect(try await auto2.dispatch(caseID: r2.c, actor: "Ada").refused == [q2])
        #expect(try await r2.f.db.query("SELECT state_reason FROM case_automation_outbox WHERE id = ?;", [.uuid(q2)]).first?.string(0)?.contains("closed") == true)
        #expect(try await linkedTasks(r2) == before2)

        // The policy is switched to manual while the engine runs.
        let r3 = try await S15Rig.make()
        let auto3 = CaseAutomationService(database: r3.f.db, caseFiles: r3.f.svc, aiPermitted: { _ in false })
        let q3 = try await queued(r3, auto3, "e3")
        let c3 = r3.c
        let other = CaseAutomationService(database: r3.f.db, caseFiles: r3.f.svc, aiPermitted: { _ in false })
        await auto3.setBeforeApply { _ = try? await other.setMode(caseID: c3, .manual, actor: "Ada") }
        #expect(try await auto3.dispatch(caseID: r3.c, actor: "Ada").refused == [q3])
        #expect(try await r3.f.db.query("SELECT state_reason FROM case_automation_outbox WHERE id = ?;", [.uuid(q3)]).first?.string(0)?.contains("manual") == true)
    }

    @Test("ARCH-09: a case erased while the engine runs takes nothing from the late result")
    func erasedDuringRun() async throws {
        let r = try await S15Rig.make()
        let auto = CaseAutomationService(database: r.f.db, caseFiles: r.f.svc, aiPermitted: { _ in false })
        _ = try await queued(r, auto, "x1")
        let db = r.f.db, c = r.c
        await auto.setBeforeApply {
            _ = try? await CaseEraser(database: db).erase(caseID: c, sourceVersionIDs: [], eraseExclusiveSources: false, reason: "Opened in error", legalBasis: nil, actor: "Ada")
        }
        let rep = try await auto.dispatch(caseID: r.c, actor: "Ada")
        #expect(rep.done.isEmpty && rep.refused.count == 1, "\(rep)")
        #expect(try await s15Count(db, "SELECT COUNT(*) FROM investigation_cases WHERE id = ?;", [.uuid(c)]) == 0)
        for t in ["case_task_links", "case_action_contracts", "case_actions", "case_work_links", "case_automation_usage"] {
            #expect(try await s15Count(db, "SELECT COUNT(*) FROM \(t) WHERE case_id = ?;", [.uuid(c)]) == 0, "\(t) has rows of the erased case")
        }
    }

    // MARK: - DATA-03

    @Test("DATA-03: an assignment keeps before/after copies of the task's owner and of the assignment rows, with the actor, in the same unit")
    func assignmentRevisions() async throws {
        let r = try await S15Rig.make()
        _ = try await r.f.svc.assignActionDeliberately(caseID: r.c, taskID: r.task, to: "Ben", reason: "Knows the ledger", actor: "Ada")
        let taskRevs = try await CaseRecordRevisions.revisions(r.f.db, caseID: r.c, kind: "task", recordID: r.task)
        let owner = try #require(taskRevs.last { $0.changedFields.contains("owner") })
        #expect(owner.value("owner").before == "Ada" && owner.value("owner").after == "Ben" && owner.actor == "Ada")
        let assignRevs = try await CaseRecordRevisions.revisions(r.f.db, caseID: r.c, kind: "workAssignment")
        #expect(assignRevs.count == 1 && assignRevs[0].before == nil && assignRevs[0].value("assignee").after == "Ben")
        #expect(owner.actionID != nil && owner.actionID == assignRevs[0].actionID, "both copies belong to the one case action")

        // v182 assignments of other work: created, reassigned (old ended + new started) and ended — each inspectable.
        let a = try await r.f.file.assignWork(caseID: r.c, kind: .allegation, workID: r.question.uuidString, to: "Ada", actor: "Ada")
        let b = try await r.f.file.reassignWork(caseID: r.c, assignmentID: a, to: "Ben", reason: "Handover", actor: "Ada")
        try await r.f.file.endAssignment(caseID: r.c, assignmentID: b, reason: .completed, actor: "Ben")
        let ra = try await CaseRecordRevisions.revisions(r.f.db, caseID: r.c, kind: "workAssignment", recordID: a)
        #expect(ra.count == 2 && ra[1].value("end_reason").after == "reassigned" && ra[1].value("reassigned_to").after == "Ben")
        let rb = try await CaseRecordRevisions.revisions(r.f.db, caseID: r.c, kind: "workAssignment", recordID: b)
        #expect(rb.count == 2 && rb[0].before == nil && rb[1].value("end_reason").after == "completed" && rb[1].actor == "Ben")
    }

    // MARK: - DATA-10

    @Test("DATA-10: precision, wording and exact amounts survive a recorded state and the export; missing stays missing (not midnight, 1970, zero or 'day')")
    func explicitUnknownsAcrossSerialization() async throws {
        let f = try await CaseFileTests.fixture(title: "Dates and money")
        let month = try await f.file.addJournal(caseID: f.caseID, kind: .chronology, text: "Contract signed", eventDate: s15Date(2026, 3, 1), evidenceRef: nil,
                                                datePrecision: .month, dateText: "March 2026", actor: "Ada")
        let minute = try await f.file.addJournal(caseID: f.caseID, kind: .chronology, text: "Call", eventDate: s15Date(2026, 3, 14, 9, 12), evidenceRef: nil,
                                                 datePrecision: .minute, actor: "Ada")
        let undated = try await f.file.addJournal(caseID: f.caseID, kind: .chronology, text: "Meeting, date not known", eventDate: nil, evidenceRef: nil, actor: "Ada")
        var paid = CaseMoneyRecordInput(kind: .payment, amountText: "INR 50,000.10"); paid.date = "2026-03-06"
        let exact = try await f.file.recordMoney(caseID: f.caseID, paid, actor: "Ada")
        let vague = try await f.file.recordMoney(caseID: f.caseID, CaseMoneyRecordInput(kind: .payment, amountText: "about fifty thousand"), actor: "Ada")
        func nid(_ k: CaseMapRecordKind, _ id: UUID) -> CaseMapNodeID { CaseMapNodeID(caseID: f.caseID, kind: k, id: id) }

        let live = try #require(await caseMapLoad(f).projection)
        #expect(live.node(nid(.moneyRecord, vague))?.money == nil, "an unreadable amount is not zero")
        #expect(live.node(nid(.journal, undated))?.eventDate == nil)

        // A recorded state keeps precision, wording and exact amounts; nothing missing is filled in.
        let history = CaseHistoryService(database: f.db, map: CaseMapService(sources: caseMapSources(f)))
        let cp = try await history.record(caseID: f.caseID, kind: .manual, actor: "Ada")
        let view = try await history.open(id: cp.id, caseID: f.caseID)
        let p = view.projection
        #expect(p.node(nid(.journal, month))?.datePrecision == .month && p.node(nid(.journal, month))?.dateText == "March 2026")
        #expect(p.node(nid(.journal, minute))?.datePrecision == .minute)
        #expect(p.node(nid(.journal, undated))?.eventDate == nil && p.node(nid(.journal, undated))?.datePrecision == nil)
        #expect(p.node(nid(.moneyRecord, exact))?.money?.amount == Decimal(string: "50000.10") && p.node(nid(.moneyRecord, exact))?.money?.currency == "INR")
        #expect(p.node(nid(.moneyRecord, vague))?.money == nil)
        // A payload recorded before S15 (no precision keys) reads back as "not recorded", never as day precision.
        var legacy = view.payload
        for i in legacy.nodes.indices { legacy.nodes[i].datePrecision = nil }
        let json = try legacy.encoded()
        #expect(!json.contains("datePrecision"))
        let reread = try CaseCheckpointPayload.decode(json).rebuild(unavailable: []).0
        #expect(reread.node(nid(.journal, month))?.datePrecision == nil)

        // The export writes each date at its own precision in the reader's zone; missing is an empty cell.
        let shown = live.nodes.map(\.id)
        let frozen = CaseMapExportRenderer.freeze(CaseMapExportRequest(projection: live, placements: [:], shown: shown, links: [], selection: nil,
                                                                       viewTitle: "All", state: .current(Date()), scopeFingerprint: nil),
                                                  restrictions: [], timeZone: s15Kolkata)
        func event(_ k: CaseMapRecordKind, _ id: UUID) -> String? { frozen.items.first { $0.ref == nid(k, id).key }?.event }
        #expect(event(.journal, month) == "2026-03 — as written: March 2026")
        #expect(event(.journal, minute) == "2026-03-14T09:12+05:30")
        #expect(event(.journal, undated) == "")
        #expect(event(.moneyRecord, exact) == "2026-03-06")
        #expect(frozen.items.allSatisfy { !$0.event.hasPrefix("1970") })

        // Bug fixed: a local (IST) day was exported in GMT as the previous day.
        let istDay = s15Date(2026, 3, 14)
        #expect(CaseMapExportRenderer.day(istDay) == "2026-03-13", "the old GMT rendering")
        var n = try #require(live.node(nid(.journal, minute)))
        n = CaseMapNode(id: n.id, revision: nil, kind: .event, title: "t", wording: nil, status: n.status, review: n.review, sources: [], author: nil,
                        recordedAt: nil, eventDate: istDay, history: [], changedSourceWarning: nil, isDocumentary: false)
        n.datePrecision = .day
        #expect(CaseMapExportRenderer.eventText(n, zone: s15Kolkata) == "2026-03-14")
        n.datePrecision = nil
        #expect(CaseMapExportRenderer.eventText(n, zone: s15Kolkata) == "2026-03-14 (precision not recorded)")
    }

    // MARK: - ARCH-01 / DATA-09

    @Test("ARCH-01: renaming people and accounts and moving every item leaves export references, links and history keyed to the same identities")
    func identityThroughRenameAndLayout() async throws {
        let f = try await CaseFileTests.fixture(title: "Identity")
        let c = f.caseID
        let person = try await f.file.addPerson(caseID: c, name: "Meera Shah", role: .witness, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        let q = try await f.file.addAllegation(caseID: c, text: "Was the supplier paid twice?", actor: "Ada")
        let acct = try await f.file.addMoneyAccount(caseID: c, identifier: "3391", institution: "Western Coast Bank", currency: "INR", actor: "Ada")
        var i = CaseMoneyRecordInput(kind: .payment, amountText: "INR 10,000"); i.date = "2026-03-05"; i.payerAccountID = acct
        let rec = try await f.file.recordMoney(caseID: c, i, actor: "Ada")
        let pn = CaseMapNodeID(caseID: c, kind: .person, id: person), qn = CaseMapNodeID(caseID: c, kind: .allegation, id: q)
        let mn = CaseMapNodeID(caseID: c, kind: .moneyRecord, id: rec)
        _ = try await CaseMapRepository(database: f.db).addLink(caseID: c, type: .mentions, from: pn, to: qn, rationale: "Her account bears on it", actor: "Ada")
        _ = try await CaseMapRepository(database: f.db).addLink(caseID: c, type: .mentions, from: mn, to: qn, rationale: "The payment in question", actor: "Ada")

        func refs() async throws -> (items: [String], links: [String], titles: [String: String]) {
            let p = try #require(await caseMapLoad(f).projection)
            let fr = CaseMapExportRenderer.freeze(CaseMapExportRequest(projection: p, placements: [:], shown: p.nodes.map(\.id), links: p.links.map(\.id),
                                                                       selection: nil, viewTitle: "All", state: .current(Date()), scopeFingerprint: nil),
                                                  restrictions: [], timeZone: s15Kolkata)
            let titles = Dictionary(fr.items.map { ($0.ref, $0.title) }, uniquingKeysWith: { a, _ in a })
            return (fr.items.map(\.ref).sorted(), fr.relations.map { "\($0.fromRef)>\($0.toRef)" }.sorted(), titles)
        }
        let before = try await refs()
        let exchangeBefore = try await f.file.exchangeDocument(caseID: c, sourceSystem: "office-a").records.map(\.id).sorted()

        var p = try #require(try await f.file.people(caseID: c).first { $0.id == person })
        p.name = "Meera R. Shah"
        try await f.file.updatePerson(p, actor: "Ada")
        let layout = CaseMapRepository(database: f.db)
        try await layout.savePlacements(caseID: c, [pn: CaseMapPlacement(point: CaseMapPoint(x: 900, y: -40), pinned: true),
                                                    qn: CaseMapPlacement(point: CaseMapPoint(x: -10, y: 300)), mn: CaseMapPlacement(point: CaseMapPoint(x: 5, y: 5))])
        try await layout.savePlacements(caseID: c, frame: qn.key, [pn: CaseMapPlacement(point: CaseMapPoint(x: 1, y: 2))])

        let after = try await refs()
        #expect(after.items == before.items && after.links == before.links, "export references unchanged")
        #expect(after.titles[pn.key]?.contains("Meera R. Shah") == true && before.titles[pn.key]?.contains("Meera R. Shah") == false)
        #expect(try await f.file.exchangeDocument(caseID: c, sourceSystem: "office-a").records.map(\.id).sorted() == exchangeBefore)
        let revs = try await CaseRecordRevisions.revisions(f.db, caseID: c, kind: "person", recordID: person)
        #expect(revs.contains { $0.value("name").before == "Meera Shah" && $0.value("name").after == "Meera R. Shah" })
        #expect(CaseMapRecordKind.linkable.contains(.moneyRecord) && CaseMapRecordKind.linkable.contains(.moneyAccount))
    }

    @Test("DATA-09: exchange export → import → restart → backup/restore keeps ids, memberships and reviewed points; re-import matches everything")
    func identityRoundTrips() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, a = f.caseID
        let person = try await f.file.addPerson(caseID: a, name: "Ravi Kumar", role: .witness, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        let q = try await f.file.addAllegation(caseID: a, text: "Was the seal intact?", actor: "Ada")
        _ = try await f.file.addJournal(caseID: a, kind: .chronology, text: "Bag 7 received", eventDate: s15Date(2026, 3, 14), evidenceRef: nil, datePrecision: .day, actor: "Ada")
        _ = try await CaseMapRepository(database: f.db).addLink(caseID: a, type: .mentions, from: CaseMapNodeID(caseID: a, kind: .person, id: person),
                                                                to: CaseMapNodeID(caseID: a, kind: .allegation, id: q), rationale: "He received the bag", actor: "Ada")
        let exported = try await f.file.exchangeDocument(caseID: a, sourceSystem: "office-a")
        let data = try CaseExchange.encode(exported)
        let b = try await f.cases.createCase(workspaceID: f.workspaceID, title: "Receiving case", actor: "Ada", at: Date()).id
        let r1 = try await f.file.importExchange(caseID: b, data: data, actor: "Ada")
        #expect(r1.skipped.isEmpty && r1.matched.isEmpty && !r1.created.isEmpty)
        // A membership and a reviewed point in the receiving case.
        let importedQ = try #require(try await f.file.allegations(caseID: b).first?.id)
        let importedP = try #require(try await f.file.people(caseID: b).first?.id)
        let member = try await f.file.placeInFrame(caseID: b, frame: CaseMapNodeID(caseID: b, kind: .allegation, id: importedQ),
                                                   member: CaseMapNodeID(caseID: b, kind: .person, id: importedP), purpose: "witness", actor: "Ada")
        let rep = try await f.file.addReport(caseID: b, CaseReportDetails(title: "Note of receipt"), actor: "Ada")
        let pt = try await f.file.addPoint(caseID: b, reportID: rep, kind: .claim, statement: "Bag 7 received sealed", passage: nil, support: .note, locatorNote: nil, actor: "Ada")
        try await f.file.reviewPoint(caseID: b, pointID: pt, to: .accepted, actor: "Ada")
        func meaning(_ d: CaseExchange.Document) -> [String] { d.records.map { "\($0.id)|\($0.kind)|\($0.text)|\($0.date ?? "")" }.sorted() }
        let backB = try await f.file.exchangeDocument(caseID: b, sourceSystem: "office-a")
        #expect(meaning(backB) == meaning(exported), "the receiving case exports the same identities")
        let ledgerB = try await f.file.reportLedger(caseID: b)

        // Restart and backup/restore.
        let snap = try s15Scratch("snap").appendingPathComponent("knowledge.sqlite")
        try await f.db.backupSnapshot(to: snap)
        let reopened = try Database(url: snap)
        #expect(meaning(try await CaseFileRepository(database: reopened).exchangeDocument(caseID: b, sourceSystem: "office-a")) == meaning(exported))
        let backup = try s15Scratch("backup")
        _ = try BackupService().createCompleteBackup(databaseSnapshot: snap, originals: [], notIncluded: [], destination: backup,
                                                     schemaVersion: SchemaMigrations.latestVersion, nowEpoch: 1)
        let newMac = try s15Scratch("new")
        _ = try await BackupService().restoreComplete(backupFolder: backup, into: newMac, ledgerKey: nil)
        let restored = try Database(url: newMac.appendingPathComponent("knowledge.sqlite"))
        let rf = CaseFileRepository(database: restored)
        #expect(meaning(try await rf.exchangeDocument(caseID: b, sourceSystem: "office-a")) == meaning(exported))
        let ledgerR = try await rf.reportLedger(caseID: b)
        #expect(ledgerR == ledgerB)
        #expect(ledgerR.frameMembers.contains { $0.id == member })
        #expect(ledgerR.points.first { $0.id == pt }?.review == .accepted)
        // Importing the same file into the restored ledger matches everything; nothing is duplicated.
        let r2 = try await rf.importExchange(caseID: b, data: data, actor: "Ada")
        #expect(r2.created.isEmpty && r2.matched.count == r1.created.count, "\(r2)")
    }

    // MARK: - ARCH-04

    @Test("ARCH-04: every record kind has a semantic role; only a finding concludes; a source, verified words, an accepted review and completed work leave the question pending")
    func semanticRoles() async throws {
        #expect(CaseMapRecordKind.allCases.filter { $0.semanticRole.mayConclude } == [.allegation])
        #expect(CaseMapRecordKind.reportPoint.semanticRole == .assertion, "a report's own 'finding' is its author's assertion")
        #expect(CaseMapRecordKind.moneyTransaction.semanticRole == .extractedText && CaseMapRecordKind.document.semanticRole == .source)
        #expect(CaseMapRecordKind.investigatorLink.semanticRole == .interpretation && CaseMapRecordKind.reviewDecision.semanticRole == .review)

        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        let q = try await f.file.addAllegation(caseID: c, text: "Was the seal intact?", actor: "Ada")
        // A verified passage as a "finding" point of the report, accepted on review.
        let pt = try await f.svc.addPoint(caseID: c, reportID: rig.report, kind: .finding, statement: "The seal was intact",
                                          quote: "The seal on bag 7 was intact on arrival.", actor: "Ada")
        try await f.file.reviewPoint(caseID: c, pointID: pt, to: .accepted, actor: "Ada")
        // More material arrives; an action serving the question is completed.
        _ = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: c, name: "photo-log.txt", text: "Photograph 3 shows bag 7 sealed.")
        let t = try await f.svc.createAction(caseID: c, .init(title: "Check the photographs", purpose: "p", deliverable: "d", servesQuestions: [q]), actor: "Ada")
        try await f.file.completeAction(caseID: c, taskID: t, actor: "Ada")
        let allegation = try #require(try await f.file.allegations(caseID: c).first { $0.id == q })
        #expect(allegation.disposition == .pending, "nothing but the investigator's decision concludes the question")
        let point = try #require(try await f.file.reportLedger(caseID: c).points.first { $0.id == pt })
        #expect(point.review == .accepted && point.kind == .finding)
    }

    // MARK: - ARCH-05

    @Test("ARCH-05: the map export carries typed references — object, version, locator, availability now, scope and who asserted it; a superseded or erased source is stated")
    func typedReferencesInExport() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        let pt = try await f.svc.addPoint(caseID: c, reportID: rig.report, kind: .claim, statement: "Seal intact", quote: "The seal on bag 7 was intact on arrival.", actor: "Ada")
        let p0 = try #require(await caseMapLoad(f).projection)
        let ptNode = CaseMapNodeID(caseID: c, kind: .reportPoint, id: pt)
        let output = CaseOutputService(database: f.db, caseFiles: f.svc, custody: { _ in [] }, pendingDirectory: try s15Scratch("pending"))
        func refs(_ p: CaseMapProjection) async throws -> [CaseTypedReference] {
            try await output.typedReferences(CaseMapExportRequest(projection: p, placements: [:], shown: [ptNode], links: [], selection: nil, viewTitle: "v",
                                                                  state: .current(Date()), scopeFingerprint: "fp-1"))
        }
        let live = try await refs(p0)
        let r0 = try #require(live.first { $0.sourceVersionID == rig.doc.version })
        #expect(r0.holder == ptNode.key && r0.availability == .available && r0.scopeFingerprint == "fp-1" && r0.provenance.contains("Ada"))
        #expect(r0.locator.blockID != nil && r0.objectID == rig.doc.object)
        // The same projection after the document was revised: the cited version is superseded and the row says so.
        try await s15Revise(f.db, object: rig.doc.object, cases: f.cases, caseID: c)
        #expect(try await refs(p0).first { $0.sourceVersionID == rig.doc.version }?.availability == .superseded)
        // A version no longer in the ledger is erased; the CSV row states it.
        let ghost = CaseMapSourceRef(sourceVersionID: UUID(), objectID: nil, blockID: nil, documentName: "gone", quote: nil)
        let erased = try await f.db.withSavepoint("s15_ref") { db in
            try CaseTypedReferences.resolve(db, caseID: c, holder: ptNode.key, source: ghost, provenance: "x", scopeFingerprint: nil)
        }
        #expect(erased.availability == .erased)
        var frozen = CaseMapExportFrozen(header: [], legend: [], items: [], relations: [], citations: [])
        frozen.references = [erased]
        #expect(CaseMapExportRenderer.csv(frozen).contains("reference,\(ptNode.key)") && CaseMapExportRenderer.csv(frozen).contains("was erased"))
        // A file-level outcome is carried explicitly (a missing original is never shown as present).
        #expect(CaseTypedReference.Availability(.missingOriginal) == .missingOriginal)
        #expect(CaseTypedReference.Availability.missingOriginal.label.contains("missing"))
    }
}

// MARK: - ARCH-10 (AI money tool parity)

private nonisolated final class S15Script: @unchecked Sendable {
    private let lock = NSLock()
    private var _sends: [CaseReadSend] = []
    func record(_ s: CaseReadSend) -> Int { lock.withLock { _sends.append(s); return _sends.count - 1 } }
    var sends: [CaseReadSend] { lock.withLock { _sends } }
}

private func s15Reply(calls: [[String: Any]] = [], proposals: [[String: Any]] = []) -> CaseReader.Reply {
    let root: [String: Any] = ["calls": calls, "proposals": proposals, "complete": true]
    let text = String(decoding: (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    var u = CloudCallUsage(inputTokens: 50, cacheWriteTokens: 0, cacheReadTokens: 0, outputTokens: 20, purpose: "case.assist", provider: "test")
    u.model = "answering-model-7"; u.stopReason = "end_turn"
    return CaseReader.Reply(text: text, usage: u)
}

@MainActor
@Suite("Smart map S15 — one canonical money result (ARCH-10)", .serialized)
struct SmartMapS15ParityTests {

    private func assistant(_ f: CaseFileTests.Fixture, privileged: Set<UUID>, script: S15Script) -> CaseAIAssistService {
        let objects = KnowledgeObjectRepository(database: f.db)
        let plan = CaseWholeReading(
            documents: { versions in
                let byObject = try await objects.sourceVersionsByObject(inSourceVersionIDs: versions)
                var out: [CaseReader.Document] = []
                for id in byObject.keys {
                    guard let text = try await objects.fetchContent(id: id), !text.isEmpty else { continue }
                    out.append(CaseReader.Document(objectID: id, sourceVersionID: byObject[id]?.sorted { $0.uuidString < $1.uuidString }.first, fileName: nil, text: text))
                }
                return out
            },
            gate: { CloudSourceGate(resolve: { id in .resolved(ProtectionLabel(sensitivity: .internalLevel, privileged: privileged.contains(id))) }, legacyPrivileged: { [] }) },
            reader: {
                CaseReader { send in
                    let i = script.record(send)
                    return i == 0 ? s15Reply(calls: [["tool": "money"]]) : s15Reply(proposals: [["kind": "claim", "statement": "Two payments are recorded"]])
                }
            },
            permissions: CaseReadPermissionStore.inMemory(account: { nil }),
            askConsent: { _ in true })
        return CaseAIAssistService(database: f.db, caseFiles: f.svc, plan: plan, search: nil,
                                   identity: { .init(provider: "test-provider", model: "configured-model-3") })
    }

    @Test("The map, the tools list, the report and the AI money tool show the same figures, from the one money service")
    func moneyParity() async throws {
        let f = try await CaseFileTests.fixture(title: "Paid twice?")
        _ = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "statement.txt", text: "Two transfers of INR 50,000.")
        let a = try await f.file.addMoneyAccount(caseID: f.caseID, identifier: "3391", institution: "Western Coast Bank", currency: "INR", actor: "Ada")
        let b = try await f.file.addMoneyAccount(caseID: f.caseID, identifier: "8804", institution: "Western Coast Bank", currency: "INR", actor: "Ada")
        for (day, ref) in [("2026-03-06", "KS-1"), ("2026-03-09", "KS-2")] {
            var i = CaseMoneyRecordInput(kind: .payment, amountText: "INR 50,000"); i.date = day; i.reference = ref; i.payerAccountID = a; i.payeeAccountID = b
            _ = try await f.file.recordMoney(caseID: f.caseID, i, actor: "Ada")
        }
        var refund = CaseMoneyRecordInput(kind: .refund, amountText: "INR 50,000"); refund.date = "2026-03-19"; refund.reference = "KS-3"
        refund.payerAccountID = b; refund.payeeAccountID = a
        _ = try await f.file.recordMoney(caseID: f.caseID, refund, actor: "Ada")

        let ledger = try await f.file.moneyLedger(caseID: f.caseID)
        let canonical = ledger.figures()
        #expect(canonical.first { $0.figure == .grossPaid }?.amount == 100_000)
        #expect(canonical.first { $0.figure == .returned }?.amount == 50_000)
        #expect(canonical.first { $0.figure == .net }?.amount == 50_000)
        // Map.
        let map = try #require(await caseMapLoad(f).projection)
        #expect(map.moneyFigures == canonical)
        // Report (the exported money report renders this text).
        let report = CaseMoneyReport.markdown(ledger)
        for line in canonical { #expect(report.contains("\(line.figure.label)") && report.contains(line.text)) }
        // AI tool: the app computes the figures; the model receives exactly the canonical lines.
        let script = S15Script()
        let ai = assistant(f, privileged: [], script: script)
        let run = try await ai.run(caseID: f.caseID, task: CaseAIAssistTask(kind: .review), actor: "Ada")
        #expect(run.tools.first?.tool == "money" && run.tools.first?.outcome == "ran", "\(run.tools)")
        #expect(script.sends.count == 2)
        #expect(script.sends[1].suffix.contains(CaseMoneyReport.toolText(canonical)))
    }

    @Test("The AI money tool shows no figure when a money record rests on a document the AI was not sent")
    func moneyToolRespectsScope() async throws {
        let f = try await CaseFileTests.fixture(title: "Privileged money")
        _ = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "statement.txt", text: "Transfer of INR 10,000.")
        let memo = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "counsel.txt", text: "Counsel notes a payment of INR 70,000.")
        var i = CaseMoneyRecordInput(kind: .payment, amountText: "INR 70,000"); i.date = "2026-03-06"; i.sourceVersionID = memo.version
        _ = try await f.file.recordMoney(caseID: f.caseID, i, actor: "Ada")
        let script = S15Script()
        let ai = assistant(f, privileged: [memo.object], script: script)
        let run = try await ai.run(caseID: f.caseID, task: CaseAIAssistTask(kind: .review), actor: "Ada")
        #expect(run.tools.first?.tool == "money" && run.tools.first?.outcome == "rejected", "\(run.tools)")
        #expect(script.sends.allSatisfy { !$0.suffix.contains("70,000") })
    }
}
