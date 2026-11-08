//
//  SmartMapContractsTests.swift
//  KalsmritikoshTests
//
//  Smart-map M0 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md: ARCH-01/02/04/06/07, DATA-01–DATA-10,
//  BASE-04; schema v177). Throwaway ledgers, AI off, no network:
//  • frame membership: one record placed in two branches is one record (one edit shows in both), duplicates and
//    cross-case or closed-case placements are refused without a partial write, withdrawal keeps history;
//  • action dependencies over the one task engine: cycle and cross-case refused, shown as "depends on";
//  • actors: legacy names backfilled with stable ids and never authenticated; reported external performers recorded;
//  • times: event, receipt, entry and review kept apart, unrecorded shown as not recorded;
//  • integrity, indexes and failures: a row without its case refused by the database; endpoint reads use indexes;
//    a full disk mid-write leaves the case as it was; unreadable saved filters say so;
//  • lifecycle: the registered inventory matches the schema and catches a new store; case erasure now takes the case's
//    tasks; restart and backup/restore keep every v177 id;
//  • v176 → v177 upgrade and an interrupted upgrade.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Smart map M0 — record and relationship contracts (v177)", .serialized)
struct SmartMapContractsTests {

    static func scratch(_ tag: String) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("s1-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func count(_ db: Database, _ sql: String, _ b: [SQLValue] = []) async throws -> Int {
        Int(try await db.query(sql, b).first?.int(0) ?? -1)
    }

    // MARK: ARCH-02 / DATA-01–03 — frame membership

    @Test("One witness placed in two branches is one record: one edit shows in both; duplicates, other cases and closed cases are refused without a partial write")
    func frameMembership() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        let witness = try await f.file.addPerson(caseID: c, name: "Meera Shah", role: .witness, entityID: nil, contact: nil, notes: nil, actor: "Priya")
        let q = try await f.svc.raiseQuestion(caseID: c, fromPoint: try await f.svc.addPoint(caseID: c, reportID: rig.report, kind: .finding,
                                              statement: "Seal intact", quote: "The seal on bag 7 was intact on arrival.", actor: "Priya"),
                                              text: "Was the seal intact?", actor: "Priya")
        let w = rig.node(.person, witness), qn = rig.node(.allegation, q), rn = rig.node(.report, rig.report)
        let m1 = try await f.file.placeInFrame(caseID: c, frame: qn, member: w, purpose: "her account bears on it", actor: "Priya")
        _ = try await f.file.placeInFrame(caseID: c, frame: rn, member: w, purpose: nil, actor: "Priya")

        // Refusals: duplicate, a member from another case, a non-placeable kind — and none of them writes anything.
        let actionsBefore = try await Self.count(f.db, "SELECT COUNT(*) FROM case_actions WHERE case_id = ?;", [.uuid(c)])
        await #expect(throws: CaseContractError.alreadyPlaced) { _ = try await f.file.placeInFrame(caseID: c, frame: qn, member: w, purpose: nil, actor: "Priya") }
        let other = try await f.cases.createCase(workspaceID: f.workspaceID, title: "Other", actor: "Priya", at: Date())
        let foreign = try await f.file.addPerson(caseID: other.id, name: "Someone", role: .witness, entityID: nil, contact: nil, notes: nil, actor: "Priya")
        await #expect(throws: CaseWorkError.self) {
            _ = try await f.file.placeInFrame(caseID: c, frame: qn, member: CaseMapNodeID(caseID: c, kind: .person, id: foreign), purpose: nil, actor: "Priya")
        }
        await #expect(throws: CaseContractError.self) {
            _ = try await f.file.placeInFrame(caseID: c, frame: qn, member: CaseMapNodeID(caseID: c, kind: .qualification, id: UUID()), purpose: nil, actor: "Priya")
        }
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM case_actions WHERE case_id = ?;", [.uuid(c)]) == actionsBefore)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM case_frame_members WHERE case_id = ?;", [.uuid(c)]) == 2)
        // The database itself refuses a membership whose case does not exist.
        await #expect(throws: (any Error).self) {
            try await f.db.exec("INSERT INTO case_frame_members (id, case_id, frame_kind, frame_id, member_kind, member_id, added_by, added_at) VALUES (?,?,?,?,?,?,?,?);",
                                [.uuid(UUID()), .uuid(UUID()), .text("allegation"), .text("a"), .text("person"), .text("b"), .text("x"), .real(1)])
        }
        // A placement is not a drawable link.
        await #expect(throws: CaseMapError.self) {
            _ = try await CaseMapRepository(database: f.db).addLink(caseID: c, type: .placedIn, from: qn, to: w, rationale: "r", actor: "Priya")
        }

        // One record, two appearances: the frames both hold it; one edit shows in both.
        var p = try await rig.projection()
        let inQ = try #require(CaseMapFrames.frame(of: qn, in: p)).contains(w), inR = try #require(CaseMapFrames.frame(of: rn, in: p)).contains(w)
        #expect(inQ && inR)
        #expect(p.nodes.filter { $0.id == w }.count == 1)
        var person = try #require(try await f.file.people(caseID: c).first { $0.id == witness })
        person.name = "Meera R. Shah"
        try await f.file.updatePerson(person, actor: "Priya")
        p = try await rig.projection()
        for anchor in [qn, rn] {
            let fr = try #require(CaseMapFrames.frame(of: anchor, in: p))
            #expect(fr.members.first { $0.node == w }?.relation.contains(CaseMapLinkType.placedIn.label) == true)
            #expect(p.node(w)?.title.contains("Meera R. Shah") == true)
        }
        // Withdrawn with a reason: it leaves that branch only; the membership, its revision copies and the other branch stay.
        try await f.file.withdrawFromFrame(caseID: c, membershipID: m1, reason: "not relevant to the seal", actor: "Priya")
        p = try await rig.projection()
        let stillQ = try #require(CaseMapFrames.frame(of: qn, in: p)).contains(w), stillR = try #require(CaseMapFrames.frame(of: rn, in: p)).contains(w)
        #expect(!stillQ && stillR)
        let ledger = try await f.file.reportLedger(caseID: c)
        #expect(ledger.frameMembers.count == 2 && ledger.frameMembers.first { $0.id == m1 }?.withdrawnReason == "not relevant to the seal")
        let revs = try await CaseRecordRevisions.revisions(f.db, caseID: c, kind: "frameMember", recordID: m1)
        #expect(revs.map(\.change) == ["placedInFrame", "removedFromFrame"] && revs.last?.changedFields.contains("withdrawn_at") == true)
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_frame_members SET purpose = 'x' WHERE id = ?;", [.uuid(m1)]) }
        // A closed case takes no placement.
        try await f.file.markClosed(caseID: c, reopened: false, actor: "Priya")
        await #expect(throws: CaseFileError.caseClosed) { _ = try await f.file.placeInFrame(caseID: c, frame: qn, member: w, purpose: nil, actor: "Priya") }
    }

    // MARK: ARCH-07 / ARCH-04 — dependencies over the one task engine; completed work does not decide the question

    @Test("Action dependencies use the task engine's own table; cycles and other cases are refused; completed and accepted work leaves the question open")
    func dependencies() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        let q = try await f.file.addAllegation(caseID: c, text: "Was the seal broken in transit?", actor: "Priya")
        let parent = try await f.svc.createAction(caseID: c, .init(title: "Resolve", purpose: "p", deliverable: "a note", servesQuestions: [q]), actor: "Priya")
        let money = try await f.svc.createAction(caseID: c, .init(title: "Trace", purpose: "p", deliverable: "the PO", parentTaskID: parent), actor: "Priya")
        let talk = try await f.svc.createAction(caseID: c, .init(title: "Interview", purpose: "p", deliverable: "her account", parentTaskID: parent), actor: "Priya")
        let dep = try await f.file.addDependency(caseID: c, taskID: talk, dependsOn: money, reason: "ask her about the PO", actor: "Priya")
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM professional_task_dependencies WHERE id = ?;", [.uuid(dep)]) == 1)
        await #expect(throws: CaseContractError.dependencyCycle) { _ = try await f.file.addDependency(caseID: c, taskID: money, dependsOn: talk, reason: nil, actor: "Priya") }
        await #expect(throws: CaseContractError.alreadyDepends) { _ = try await f.file.addDependency(caseID: c, taskID: talk, dependsOn: money, reason: nil, actor: "Priya") }
        let other = try await f.cases.createCase(workspaceID: f.workspaceID, title: "Other", actor: "Priya", at: Date())
        let foreign = try await f.svc.addTask(caseID: other.id, workspaceID: f.workspaceID, title: "Elsewhere", assignee: nil, due: nil, actor: "Priya")
        await #expect(throws: CaseWorkError.self) { _ = try await f.file.addDependency(caseID: c, taskID: talk, dependsOn: foreign, reason: nil, actor: "Priya") }
        let p = try await rig.projection()
        #expect(p.links(of: rig.node(.task, talk)).contains { $0.type == .dependsOn && $0.to == rig.node(.task, money) })
        #expect(try await f.file.reportLedger(caseID: c).dependencies(of: talk).map(\.dependsOnTaskID) == [money])

        // The work is done and accepted; the question keeps its own disposition (a completed action is not a finding).
        for t in [money, talk, parent] {
            try await f.svc.completeTask(caseID: c, taskID: t, actor: "Priya")
            try await f.file.submitAction(caseID: c, taskID: t, note: nil, actor: "Priya")
            _ = try await f.file.reviewAction(caseID: c, taskID: t, accept: true, note: nil, actor: "Ben")
        }
        #expect(try await f.file.allegations(caseID: c).first { $0.id == q }?.disposition == .pending)
        // The activity log is not an action: nothing in case_actions became a task.
        #expect(try await f.svc.caseTasks(caseID: c).count == 3)

        try await f.file.removeDependency(caseID: c, dependencyID: dep, reason: "PO already found", actor: "Priya")
        #expect(try await f.file.reportLedger(caseID: c).dependencies.isEmpty)
        let revs = try await CaseRecordRevisions.revisions(f.db, caseID: c, kind: "actionDependency", recordID: dep)
        #expect(revs.map(\.change) == ["dependencyAdded", "dependencyRemoved"] && revs.last?.after == nil && revs.last?.before != nil)
    }

    // MARK: ARCH-06 / DATA-05 — actors and times

    @Test("Legacy names get stable ids and are never authenticated; external performers are recorded as reported; event, receipt, entry and review stay apart")
    func actorsAndTimes() async throws {
        // Upgrade: a v176 ledger with names in a case's history.
        let db = try await MigrationFixtureBuilder.database(atVersion: 176)
        let ws = UUID(), c = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);", [.uuid(ws), .text("W"), .real(1), .real(1)])
        try await db.exec("INSERT INTO investigation_cases (id, workspace_id, title, status, revision, actor, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?);",
                          [.uuid(c), .uuid(ws), .text("C"), .text("open"), .integer(1), .text("u"), .real(1), .real(1)])
        for (n, who) in [(1, "Ada"), (2, "Ada "), (3, "Ben")] {
            try await db.exec("INSERT INTO case_actions (id, case_id, sequence, actor, action, detail, at) VALUES (?,?,?,?,?,?,?);",
                              [.uuid(UUID()), .uuid(c), .integer(Int64(n)), .text(who), .text("note"), .null, .real(Double(n))])
        }
        try await SchemaMigrations.migrate(db)
        let actors = try await CaseFileRepository(database: db).reportLedger(caseID: c).actors
        #expect(Set(actors.map(\.displayName)) == ["Ada", "Ben"], "one stable id per name: \(actors.map(\.displayName))")
        #expect(actors.allSatisfy { $0.isLegacyName && !$0.isAuthenticated && $0.kind == .localUser })
        #expect(actors.first { $0.displayName == "Ada" }?.attribution.contains("not a signed-in account") == true)
        let ada = try #require(actors.first { $0.displayName == "Ada" })
        await #expect(throws: (any Error).self) {
            try await db.exec("UPDATE case_actors SET authentication = 'authenticated', actor_kind = 'authenticatedUser', identity_ref = 'x' WHERE id = ?;", [.uuid(ada.id)])
        }
        let again = try await CaseFileRepository(database: db).reportLedger(caseID: c).actors
        let idsAgain = Set(again.map(\.id)), idsFirst = Set(actors.map(\.id))
        #expect(idsAgain == idsFirst, "the ids are stable across reads")

        // On a live case: a new acting name is registered once; external performers are recorded as reported.
        let rig = try await CaseFramesRig.make()
        let f = rig.f
        _ = try await f.file.addAllegation(caseID: f.caseID, text: "Q1", actor: "Chandra")
        _ = try await f.file.addAllegation(caseID: f.caseID, text: "Q2", actor: "Chandra")
        let ext = try await f.file.recordActor(caseID: f.caseID, kind: .reportedExternal, displayName: "Questioned Document Examiner, Delhi", actor: "Chandra")
        await #expect(throws: CaseContractError.identityServiceUnavailable) {
            _ = try await f.file.recordActor(caseID: f.caseID, kind: .authenticatedUser, displayName: "chandra@example.com", actor: "Chandra")
        }
        let live = try await f.file.reportLedger(caseID: f.caseID)
        #expect(live.actors.filter { $0.displayName == "Chandra" }.count == 1)
        #expect(live.actors.first { $0.id == ext }?.kind == .reportedExternal && live.actors.first { $0.id == ext }?.isLegacyName == false)

        // Times: the report's own date, its receipt and its entry; an action's entry, hand-in and review.
        let received = Date(timeIntervalSince1970: 1_774_000_000)
        let r = try await f.file.addReport(caseID: f.caseID, CaseReportDetails(title: "Amendment", kind: .amendment, amendsReportID: rig.report,
                                                                                reportDateText: "2 April 2026"), actor: "Chandra")
        let lr = try await f.file.reportLedger(caseID: f.caseID)
        #expect(lr.report(r)?.times.map(\.display) == ["Date of the record itself: 2 April 2026", "Received: not recorded",
                                                      "Recorded in the case: \(try #require(lr.report(r)?.recordedAt).formatted(date: .abbreviated, time: .shortened))"])
        var d = CaseReportDetails(title: "Supplement", kind: .supplement, amendsReportID: rig.report)
        d.receivedAt = received; d.receivedText = "by courier, 3 April 2026"
        let s = try await f.file.addReport(caseID: f.caseID, d, actor: "Chandra")
        let sr = try #require(try await f.file.reportLedger(caseID: f.caseID).report(s))
        #expect(sr.receivedAt == received && sr.receivedText == "by courier, 3 April 2026" && sr.recordedAt != received && sr.reportDate == nil)
        let a = try await f.svc.createAction(caseID: f.caseID, .init(title: "Check", purpose: "p", deliverable: "d"), actor: "Chandra")
        let t0 = Date(timeIntervalSince1970: 1_775_000_000), t1 = t0.addingTimeInterval(3600)
        try await f.file.submitAction(caseID: f.caseID, taskID: a, note: nil, actor: "Dev", at: t0)
        _ = try await f.file.reviewAction(caseID: f.caseID, taskID: a, accept: true, note: nil, actor: "Chandra", at: t1)
        let k = try #require(try await f.file.reportLedger(caseID: f.caseID).contract(a))
        #expect(k.submittedBy == "Dev" && k.submittedAt == t0 && k.reviewedAt == t1 && k.reviewedBy == "Chandra")
        #expect(k.times.map(\.kind) == [.entry, .receipt, .review] && k.times.allSatisfy(\.isRecorded))
    }

    // MARK: DATA-04 — indexed branch reads

    @Test("Link, work-link and membership endpoint reads use their indexes, not a scan of the case")
    func indexes() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        func plan(_ sql: String) async throws -> String {
            try await db.query("EXPLAIN QUERY PLAN " + sql, [.text("c"), .text("k"), .text("i")]).compactMap { $0.string(3) }.joined(separator: " | ")
        }
        #expect(try await plan("SELECT id FROM case_map_links WHERE case_id = ? AND from_kind = ? AND from_id = ?;").contains("idx_case_map_links_from"))
        #expect(try await plan("SELECT id FROM case_map_links WHERE case_id = ? AND to_kind = ? AND to_id = ?;").contains("idx_case_map_links_to"))
        #expect(try await plan("SELECT id FROM case_work_links WHERE case_id = ? AND target_kind = ? AND target_id = ?;").contains("idx_case_work_links_target"))
        #expect(try await plan("SELECT id FROM case_frame_members WHERE case_id = ? AND member_kind = ? AND member_id = ?;").contains("idx_case_frame_members_member"))
        #expect(try await plan("SELECT id FROM case_frame_members WHERE case_id = ? AND frame_kind = ? AND frame_id = ? AND withdrawn_at IS NULL;").contains("idx_case_frame_members_active"))
    }

    // MARK: DATA-07 — failures

    @Test("A full disk mid-write leaves the case as it was; unreadable saved filters are reported precisely, not passed off as a filter")
    func failures() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        let q = try await f.file.addAllegation(caseID: c, text: "Kept question", actor: "Priya")
        let actions = try await Self.count(f.db, "SELECT COUNT(*) FROM case_actions WHERE case_id = ?;", [.uuid(c)])
        let pages = try await Self.count(f.db, "PRAGMA page_count;")
        try await f.db.exec("PRAGMA max_page_count = \(pages);", [])
        let big = String(repeating: "x", count: 400_000)
        await #expect(throws: (any Error).self) { _ = try await f.file.addAllegation(caseID: c, text: big, actor: "Priya") }
        try await f.db.exec("PRAGMA max_page_count = 1073741823;", [])
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM case_actions WHERE case_id = ?;", [.uuid(c)]) == actions, "nothing half-written")
        #expect(try await f.file.allegations(caseID: c).map(\.id) == [q], "the case reads as before")
        _ = try await f.file.addAllegation(caseID: c, text: "After space returned", actor: "Priya")

        // A saved view whose stored filters cannot be read says so; it is not passed off as the person's filter.
        let repo = CaseMapRepository(database: f.db)
        let v = try await repo.saveView(caseID: c, name: "Witnesses", base: .people, filter: CaseMapFilter(), actor: "Priya")
        try await f.db.exec("UPDATE case_map_views SET filters_json = '{\"kinds\": 7, \"future\": true' WHERE id = ?;", [.uuid(v)])
        let views = try await repo.views(caseID: c)
        #expect(views.first { $0.id == v }?.filterProblem?.contains("could not be read") == true)
        let good = try await repo.saveView(caseID: c, name: "All", base: .overview, filter: CaseMapFilter(), actor: "Priya")
        #expect(try await repo.views(caseID: c).first { $0.id == good }?.filterProblem == nil)
    }

    // MARK: DATA-08 / BASE-04 — the registered inventory

    @Test("Every case store in the migrated ledger is registered with its lifecycle, and a new unregistered store is caught")
    func inventory() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let missing = try await db.withSavepoint("inv") { d in try CaseDataInventory.unregistered(d) }
        #expect(missing.isEmpty, "unregistered case stores: \(missing)")
        let tables = Set(try await db.query("SELECT name FROM sqlite_master WHERE type = 'table';", []).compactMap { $0.string(0) })
        for e in CaseDataInventory.entries {
            #expect(tables.contains(e.table), "\(e.table) is registered but not in the schema")
            #expect(CaseDataInventory.families.contains(e.family), "\(e.table): \(e.family)")
            let cols = try await db.query("PRAGMA table_info(\"\(e.table)\");", []).compactMap { $0.string(1) }
            let fks = try await db.query("PRAGMA foreign_key_list(\"\(e.table)\");", []).map { ($0.string(2) ?? "", $0.string(6) ?? "") }
            switch e.lifecycle {
            case .caseID: #expect(cols.contains("case_id") || e.table == "investigation_cases", "\(e.table) has no case_id")
            case .undeclaredChild(let col, let parent):
                #expect(CaseEraser.undeclaredChildren.contains { $0.0 == e.table && $0.1 == col && $0.2 == parent }, "\(e.table) is not in CaseEraser.undeclaredChildren")
            case .cascade(let parent): #expect(fks.contains { $0.0 == parent && $0.1 == "CASCADE" }, "\(e.table) does not cascade from \(parent)")
            case .erasureRecord: #expect(CaseEraser.keptTables.contains(e.table))
            case .taskEngine, .notCaseData: break
            }
        }
        // The detector works: a store added without lifecycle handling is reported.
        try await db.exec("CREATE TABLE case_zz_unhandled (id TEXT PRIMARY KEY, case_id TEXT);", [])
        try await db.exec("CREATE TABLE zz_child_of_people (id TEXT PRIMARY KEY, person_id TEXT REFERENCES case_people(id));", [])
        let caught = try await db.withSavepoint("inv2") { d in try CaseDataInventory.unregistered(d) }
        #expect(caught == ["case_zz_unhandled", "zz_child_of_people"])
    }

    @Test("Case erasure takes the case's own tasks (and their dependencies and contracts); a task another case links to stays; v177 rows go with the case")
    func erasureCoversTasksAndV177() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let svc = try #require(await f.state.caseFiles)
        let ws = try #require(try await f.db.query("SELECT workspace_id FROM investigation_cases WHERE id = ?;", [.uuid(f.caseA)]).first?.uuid(0))
        let own = try await svc.createAction(caseID: f.caseA, .init(title: "Secret task of A", purpose: "p", deliverable: "d"), actor: "Tester")
        let own2 = try await svc.createAction(caseID: f.caseA, .init(title: "Second", purpose: "p", deliverable: "d"), actor: "Tester")
        _ = try await svc.file.addDependency(caseID: f.caseA, taskID: own2, dependsOn: own, reason: nil, actor: "Tester")
        let shared = try await svc.addTask(caseID: f.caseA, workspaceID: ws, title: "Shared task", assignee: nil, due: nil, actor: "Tester")
        try await f.db.exec("INSERT INTO case_task_links (case_id, task_id, created_at) VALUES (?,?,?);", [.uuid(f.caseB), .uuid(shared), .real(1)])
        _ = try await svc.file.addAllegation(caseID: f.caseB, text: "B's own question", actor: "Tester")
        let person = try await svc.file.addPerson(caseID: f.caseA, name: "Witness", role: .witness, entityID: nil, contact: nil, notes: nil, actor: "Tester")
        _ = try await svc.file.placeInFrame(caseID: f.caseA, frame: CaseMapNodeID(caseID: f.caseA, kind: .caseFile, id: f.caseA),
                                            member: CaseMapNodeID(caseID: f.caseA, kind: .person, id: person), purpose: "secret purpose", actor: "Tester")
        let out = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: false, reason: "Client request", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil, "\(out.report.refused ?? "")")
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM professional_tasks WHERE id IN (?, ?);", [.uuid(own), .uuid(own2)]) == 0)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM professional_task_dependencies WHERE task_id IN (?, ?) OR depends_on_task_id IN (?, ?);",
                                     [.uuid(own), .uuid(own2), .uuid(own), .uuid(own2)]) == 0)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM professional_tasks WHERE id = ?;", [.uuid(shared)]) == 1, "case B still uses it")
        #expect(out.report.rowsErased["professional_tasks"] == 2)
        for t in ["case_frame_members", "case_actors", "case_action_contracts"] {
            #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM \(t) WHERE case_id = ?;", [.uuid(f.caseA)]) == 0, "\(t) left")
        }
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM case_actors WHERE case_id = ?;", [.uuid(f.caseB)]) >= 1, "case B's actors stay")
    }

    @Test("A person erasure removes branch placements and actor ids that stand for their case-person rows")
    func personErasureCoversV177() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let svc = try #require(await f.state.caseFiles)
        let row = try #require(try await f.db.query("SELECT id, value FROM entities WHERE kind = 'person' AND value LIKE '%Roberts%' LIMIT 1;", []).first)
        let entity = try #require(row.string(0).flatMap(UUID.init(uuidString:)))
        let person = try await svc.file.addPerson(caseID: f.caseA, name: row.string(1) ?? "Roberts", role: .witness, entityID: entity, contact: nil, notes: nil, actor: "Tester")
        let caseNode = CaseMapNodeID(caseID: f.caseA, kind: .caseFile, id: f.caseA), pn = CaseMapNodeID(caseID: f.caseA, kind: .person, id: person)
        _ = try await svc.file.placeInFrame(caseID: f.caseA, frame: caseNode, member: pn, purpose: nil, actor: "Tester")
        // S3 (GRAPH-05): the person's own branch holds another record (a case placed inside a person it holds is a containment cycle).
        let q = try await svc.file.addAllegation(caseID: f.caseA, text: "Was the account accurate?", actor: "Tester")
        _ = try await svc.file.placeInFrame(caseID: f.caseA, frame: pn, member: CaseMapNodeID(caseID: f.caseA, kind: .allegation, id: q), purpose: nil, actor: "Tester")
        await #expect(throws: CaseContractError.containmentCycle) { _ = try await svc.file.placeInFrame(caseID: f.caseA, frame: pn, member: caseNode, purpose: nil, actor: "Tester") }
        _ = try await svc.file.recordActor(caseID: f.caseA, kind: .caseParticipant, displayName: "The witness", casePersonID: person, actor: "Tester")
        // v179 — an identity decision, a brief set-aside and a briefing step that name the person's row.
        let twin = try await svc.file.addPerson(caseID: f.caseA, name: "Another name", role: .witness, entityID: nil, contact: nil, notes: nil, actor: "Tester")
        _ = try await svc.file.recordIdentityDecision(caseID: f.caseA, personA: person, personB: twin, decision: .differentPeople, rationale: "Different dates of birth", actor: "Tester")
        _ = try await svc.file.setBriefRelevance(caseID: f.caseA, record: pn, decision: .setAside, reason: "Peripheral", actor: "Tester")
        let briefing = try await svc.file.createBriefing(caseID: f.caseA, title: "Handover", purpose: nil, actor: "Tester")
        _ = try await svc.file.addBriefingItem(caseID: f.caseA, briefingID: briefing, kind: .record, record: pn, actor: "Tester")
        let out = try await f.state.erasePerson(entity, reason: "Subject request", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil)
        for t in ["case_person_identity_decisions", "case_brief_relevance", "case_briefing_items"] {
            #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM \(t) WHERE case_id = ?;", [.uuid(f.caseA)]) == 0, "\(t) still names the erased person's row")
        }
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM case_briefings WHERE case_id = ?;", [.uuid(f.caseA)]) == 1, "the briefing itself stays")
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM case_frame_members WHERE case_id = ?;", [.uuid(f.caseA)]) == 0)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM case_actors WHERE case_person_id IS NOT NULL;") == 0)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM case_actors WHERE case_id = ? AND display_name = 'Tester';", [.uuid(f.caseA)]) == 1, "the investigator's id stays")
    }

    // MARK: DATA-09 — identity round trips

    @Test("Restart and a complete backup/restore keep every frame membership, dependency, actor and time with the same ids")
    func identityRoundTrip() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        let a = try await f.svc.createAction(caseID: c, .init(title: "A", purpose: "p", deliverable: "d"), actor: "Priya")
        let b = try await f.svc.createAction(caseID: c, .init(title: "B", purpose: "p", deliverable: "d"), actor: "Priya")
        _ = try await f.file.addDependency(caseID: c, taskID: b, dependsOn: a, reason: nil, actor: "Priya")
        _ = try await f.file.placeInFrame(caseID: c, frame: rig.node(.report, rig.report), member: rig.node(.task, a), purpose: "check", actor: "Priya")
        _ = try await f.file.recordActor(caseID: c, kind: .reportedExternal, displayName: "External lab", actor: "Priya")
        try await f.file.submitAction(caseID: c, taskID: a, note: nil, actor: "Priya")
        let before = try await f.file.reportLedger(caseID: c)
        #expect(!before.frameMembers.isEmpty && !before.dependencies.isEmpty && before.actors.count >= 3)

        let snap = try Self.scratch("v177snap").appendingPathComponent("knowledge.sqlite")
        try await f.db.backupSnapshot(to: snap)
        // Restart: a fresh connection to the same file reads the same records.
        let reopened = try Database(url: snap)
        #expect(try await CaseFileRepository(database: reopened).reportLedger(caseID: c) == before)
        let backup = try Self.scratch("v177backup")
        _ = try BackupService().createCompleteBackup(databaseSnapshot: snap, originals: [], notIncluded: [], destination: backup,
                                                     schemaVersion: SchemaMigrations.latestVersion, nowEpoch: 1)
        let newMac = try Self.scratch("v177new")
        _ = try await BackupService().restoreComplete(backupFolder: backup, into: newMac, ledgerKey: nil)
        let restored = try Database(url: newMac.appendingPathComponent("knowledge.sqlite"))
        #expect(try await CaseFileRepository(database: restored).reportLedger(caseID: c) == before)
    }

    // MARK: DATA-06 — upgrade and interrupted upgrade

    @Test("v176 → v177 keeps every case; a fault before the stamp rolls v177 back and the restart completes it")
    func migrationV177() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 176)
        let ws = UUID(), c = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);", [.uuid(ws), .text("W"), .real(1), .real(1)])
        try await db.exec("INSERT INTO investigation_cases (id, workspace_id, title, status, revision, actor, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?);",
                          [.uuid(c), .uuid(ws), .text("Kept"), .text("open"), .integer(1), .text("u"), .real(1), .real(1)])
        try await db.exec("INSERT INTO case_actions (id, case_id, sequence, actor, action, detail, at) VALUES (?,?,?,?,?,?,?);",
                          [.uuid(UUID()), .uuid(c), .integer(1), .text("Ada"), .text("note"), .null, .real(1)])
        try await db.exec("INSERT INTO case_reports (id, case_id, title, report_kind, recorded_by, recorded_at) VALUES (?,?,?,?,?,?);",
                          [.uuid(UUID()), .uuid(c), .text("R"), .text("original"), .text("Ada"), .real(1)])
        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.migrate(db, through: 177, fault: MigrationFaultHarness.hook(throwingAt: .afterSQLBeforeVersionStamp(version: 177)))
        }
        #expect(try await db.currentUserVersion() == 176)
        let fmExists = try await MigrationFixtureBuilder.tableExists(db, "case_frame_members")
        let actorsExists = try await MigrationFixtureBuilder.tableExists(db, "case_actors")
        #expect(!fmExists && !actorsExists)
        let cols = try await db.query("PRAGMA table_info(case_reports);", []).compactMap { $0.string(1) }
        #expect(!cols.contains("received_at"), "the added column rolled back too")
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
        #expect(try await Self.count(db, "SELECT COUNT(*) FROM investigation_cases WHERE id = ?;", [.uuid(c)]) == 1)
        #expect(try await Self.count(db, "SELECT COUNT(*) FROM case_reports WHERE case_id = ?;", [.uuid(c)]) == 1)
        #expect(try await Self.count(db, "SELECT COUNT(*) FROM case_actors WHERE case_id = ? AND origin = 'legacyName';", [.uuid(c)]) == 1)
        #expect(try await MigrationFaultHarness.integrityOK(db))
        #expect(!SchemaMigrations.isIdempotent(try #require(SchemaMigrations.migrationSQL(for: 177))), "v177 adds columns: not re-run by the repair pass")
    }

    // MARK: DATA-10 — missing is not zero

    @Test("A missing amount is unreadable, not zero; an unrecorded time is 'not recorded', not the entry time")
    func explicitUnknowns() {
        var e = ForensicEngagement(title: "Unknowns", now: Date())
        var paid = FATransaction(); paid.date = "2026-03-06"; paid.amount = "INR 50,000"; paid.kind = .payment; paid.reference = "UTR A"
        var blank = FATransaction(); blank.date = "2026-03-07"; blank.amount = ""; blank.kind = .payment; blank.reference = "UTR B"
        e.schedule = [paid, blank]
        let s = e.summary
        #expect(s.unreadable == [blank.id] && s.byCurrency["INR"]?.gross == 50_000)
        #expect(CaseTimeAssertion(kind: .receipt, date: nil, text: nil).display == "Received: not recorded")
        #expect(!CaseTimeAssertion(kind: .review, date: nil, text: "  ").isRecorded)
    }
}
