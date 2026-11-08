//
//  SmartMapS8Tests.swift
//  KalsmritikoshTests
//
//  Smart-map S8 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md: ACTION and AUTO of milestone M3; schema v184).
//  Throwaway ledgers; expected results written by hand. AI off: nothing here calls a model or the network.
//

import Foundation
import Testing
@testable import Kalsmritikosh

/// A new current version of the document behind `object`, included in the case.
private func s8Revise(_ db: Database, object: UUID, cases: InvestigationCaseRepository, caseID: UUID, text: String) async throws -> UUID {
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
    try await db.exec("""
        INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text, extraction_method, extraction_confidence)
        VALUES (?,?,?,?,?,?,?,?,?);
        """, [.uuid(UUID()), .uuid(doc), .uuid(version), .integer(0), .text("paragraph"), .text(text), .text(text.lowercased()), .text("native"), .real(1.0)])
    let header = try await cases.fetch(caseID: caseID)?.caseHeader
    _ = try await cases.includeSource(caseID: caseID, expectedRevision: header?.revision ?? 1, sourceRef: version.uuidString,
                                      sourceKind: .sourceVersion, actor: "Ada", at: Date())
    return version
}

private func s8Count(_ db: Database, _ sql: String, _ binds: [SQLValue] = []) async throws -> Int {
    Int(try await db.query(sql, binds).first?.int(0) ?? -1)
}

/// A case with a bank statement, a question ("paid twice?"), and an action that examined the statement and is done.
@MainActor
private struct S8Rig {
    let f: CaseFileTests.Fixture
    let doc: (version: UUID, object: UUID, blocks: [UUID])
    let question: UUID
    var svc: CaseFileService { f.svc }
    var file: CaseFileRepository { f.file }
    static func make() async throws -> S8Rig {
        let f = try await CaseFileTests.fixture(title: "Supplier payments")
        let doc = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "bank-statement.txt",
                                                            text: "Transfer to Dalmia Traders on 5 March 2026 for ₹10,000. A second transfer of ₹10,000 followed on 9 March 2026.")
        let q = try await f.file.addAllegation(caseID: f.caseID, text: "Was the supplier paid twice?", actor: "Ada")
        return S8Rig(f: f, doc: doc, question: q)
    }
    func action(_ title: String = "Reconcile the two transfers", type: CaseActionType = .reconciliation, responsible: String? = "Ada", parent: UUID? = nil,
                required: Bool = true, capability: String? = nil) async throws -> UUID {
        try await svc.createTypedAction(caseID: f.caseID,
                                        CaseFileService.ChildAction(title: title, purpose: "Find out whether the second transfer is a separate payment",
                                                                    deliverable: "A reconciliation of both transfers with references", responsible: responsible,
                                                                    parentTaskID: parent, servesQuestions: [question]),
                                        details: CaseActionDetails(type: type, trigger: CaseActionTrigger(kind: .manual, records: ["allegation:\(question.uuidString.lowercased())"],
                                                                                                          sourceRevisions: [doc.version]),
                                                                   requiredCapability: capability, requiredForParent: required),
                                        actor: "Ada")
    }
    /// An action that examined the statement (v1), with an accepted result, completed.
    func finishedAction() async throws -> UUID {
        let t = try await action()
        _ = try await file.recordActionResult(caseID: f.caseID, taskID: t, kind: .report, outcome: .successful, summary: "Two separate settlements",
                                              inputs: [.source(doc.version, "bank statement")], actor: "Ada")
        try await file.completeAction(caseID: f.caseID, taskID: t, actor: "Ada")
        return t
    }
    func revise() async throws -> UUID { try await s8Revise(f.db, object: doc.object, cases: f.cases, caseID: f.caseID, text: "Only one transfer of ₹10,000 was made.") }
    func status(_ t: UUID) async throws -> ProfessionalTaskStatus? {
        try await f.db.query("SELECT status FROM professional_tasks WHERE upper(id) = ?;", [.text(t.uuidString)]).first?.string(0).flatMap(ProfessionalTaskStatus.init(rawValue:))
    }
    func automation(recipes: [CaseAutomationRecipe] = CaseAutomationRecipe.builtIn, ai: @escaping @Sendable (UUID) -> Bool = { _ in false },
                    lease: TimeInterval = 300) -> CaseAutomationService {
        CaseAutomationService(database: f.db, caseFiles: svc, recipes: recipes, aiPermitted: ai, lease: lease)
    }
    func trigger(_ recipe: CaseAutomationRecipe = .changedEvidenceReview, event: String, title: String = "Review changed evidence",
                 inputs: [CaseExaminedInput], causation: UUID? = nil, by: String = "Ada") -> CaseAutomationTrigger {
        CaseAutomationTrigger(recipeID: recipe.id, causeAction: recipe.triggers[0], eventKey: event, title: title, purpose: "Check the earlier work against the new version",
                              inputs: inputs, causationID: causation, requestedBy: by)
    }
}

// MARK: - ACTION

@MainActor
@Suite("Smart map S8 — mother case, child actions and results (ACTION)", .serialized)
struct SmartMapS8ActionTests {

    @Test("ACTION-01/02: an action from an edited template carries its whole contract; a template proposes a target, never a deadline; applying a case template twice adds nothing")
    func contractTemplatesAndIdempotence() async throws {
        let r = try await S8Rig.make()
        let parent = try await r.action("Establish the payment history", type: .other)
        let tpl = try #require(CaseActionTemplate.template(.interview))
        var draft = tpl.draft(subject: "the accounts clerk", parentTaskID: parent, servesQuestions: [r.question])
        draft.title = "Interview the accounts clerk about the 9 March transfer"     // edited before creating
        draft.responsible = "Ada"; draft.reviewer = "Bina"
        let t = try await r.svc.createTypedAction(caseID: r.f.caseID, draft,
                                                  details: CaseActionDetails(type: .interview, trigger: CaseActionTrigger(kind: .template, sourceRevisions: [r.doc.version]),
                                                                             helpers: ["Chen"], requiredCapability: tpl.capability),
                                                  proposedTargetDays: tpl.targetDays, actor: "Ada")
        let other = try await r.action("Obtain the supplier's ledger", type: .missingEvidence, parent: parent)
        _ = try await r.file.addDependency(caseID: r.f.caseID, taskID: t, dependsOn: other, reason: "Put the ledger to the clerk", actor: "Ada")
        let d = try await r.svc.actionDossier(caseID: r.f.caseID, taskID: t)
        #expect(d.isTraceable)
        #expect(d.caseID == r.f.caseID && d.contract.parentTaskID == parent && d.servesQuestions == [r.question])
        #expect(d.task.title == "Interview the accounts clerk about the 9 March transfer")
        #expect(d.state.details?.type == .interview && d.state.details?.helpers == ["Chen"] && d.state.details?.requiredCapability == "Interviewing")
        #expect(d.state.details?.trigger.sourceRevisions == [r.doc.version])
        #expect(d.contract.responsible == "Ada" && d.contract.reviewer == "Bina" && d.waitsFor == [other])
        #expect(d.history.contains { $0.action == .created })
        // The template's "14 days" is a PROPOSED target: no active deadline exists.
        #expect(d.dates.count == 1 && d.dates[0].isProposal && d.dates[0].basis == .target)
        #expect(try await s8Count(r.f.db, "SELECT COUNT(*) FROM deadlines WHERE upper(task_id) = ?;", [.text(t.uuidString)]) == 0)
        // A plain task without a contract is listed as untraceable.
        let plain = try await r.svc.addTask(caseID: r.f.caseID, workspaceID: r.f.workspaceID, title: "Misc", assignee: nil, due: nil, actor: "Ada")
        #expect(try await r.file.untraceableTasks(caseID: r.f.caseID) == [plain])
        // Every type has a template with a concrete deliverable.
        #expect(Set(CaseActionTemplate.all.map(\.type)).count == 8 && CaseActionTemplate.all.allSatisfy { !$0.deliverable.isEmpty })
        // Case templates: applied twice → one task per item, targets proposed (candidates), no confirmed deadline.
        let ct = try #require(CaseTemplate.template(id: "workplace"))
        let before = try await r.svc.caseTasks(caseID: r.f.caseID).count
        try await r.svc.applyTemplate(ct, caseID: r.f.caseID, workspaceID: r.f.workspaceID, actor: "Ada")
        try await r.svc.applyTemplate(ct, caseID: r.f.caseID, workspaceID: r.f.workspaceID, actor: "Ada")
        #expect(try await r.svc.caseTasks(caseID: r.f.caseID).count == before + ct.tasks.count)
        #expect(try await s8Count(r.f.db, "SELECT COUNT(*) FROM deadlines d JOIN case_task_links l ON upper(l.task_id) = upper(d.task_id) WHERE l.case_id = ?;", [.uuid(r.f.caseID)]) == 0)
        #expect(try await s8Count(r.f.db, "SELECT COUNT(*) FROM case_deadline_bases WHERE case_id = ? AND ref_kind = 'candidate' AND basis = 'target';", [.uuid(r.f.caseID)])
                == ct.tasks.filter { $0.dueInDays != nil }.count + 1)
    }

    @Test("ACTION-03/04: lifecycle states keep their reasons; waiting-for work blocks completion; completing never closes the question; superseded work takes no late result")
    func lifecycleAndOutcome() async throws {
        let r = try await S8Rig.make()
        let t = try await r.action()
        let pre = try await r.action("Get the bank's transfer advice", type: .missingEvidence)
        _ = try await r.file.addDependency(caseID: r.f.caseID, taskID: t, dependsOn: pre, reason: nil, actor: "Ada")
        try await r.file.setActionState(caseID: r.f.caseID, taskID: t, to: .assigned, reason: nil, actor: "Ada")
        try await r.file.setActionState(caseID: r.f.caseID, taskID: t, to: .inProgress, reason: nil, actor: "Ada")
        await #expect(throws: CaseActionWorkError.reasonRequired("waiting")) {
            try await r.file.setActionState(caseID: r.f.caseID, taskID: t, to: .waiting, reason: " ", actor: "Ada")
        }
        try await r.file.setActionState(caseID: r.f.caseID, taskID: t, to: .waiting, reason: "Bank reply awaited", remedy: "Chase on Friday", actor: "Ada")
        var st = try #require(try await r.file.actionStates(caseID: r.f.caseID)[t])
        #expect(st.stateReason == "Bank reply awaited" && st.stateRemedy == "Chase on Friday")
        #expect(try await r.status(t) == .waiting)
        try await r.file.setActionState(caseID: r.f.caseID, taskID: t, to: .blocked, reason: "Bank refuses without a court order", actor: "Ada")
        try await r.file.setActionState(caseID: r.f.caseID, taskID: t, to: .inProgress, reason: nil, actor: "Ada")
        st = try #require(try await r.file.actionStates(caseID: r.f.caseID)[t])
        #expect(st.stateReason == nil)
        await #expect(throws: CaseActionWorkError.self) { try await r.file.completeAction(caseID: r.f.caseID, taskID: t, actor: "Ada") }
        try await r.file.completeAction(caseID: r.f.caseID, taskID: pre, actor: "Ada")
        try await r.file.completeAction(caseID: r.f.caseID, taskID: t, actor: "Ada")
        #expect(try await r.status(t) == .completed)
        // The question it served keeps its own disposition.
        #expect(try await r.file.allegations(caseID: r.f.caseID).first { $0.id == r.question }?.disposition == .pending)
        // Supersede (with a named replacement); a reply to the superseded action is refused as late.
        let replacement = try await r.action("Reconcile again with the corrected statement")
        try await r.file.supersedeAction(caseID: r.f.caseID, taskID: t, by: replacement, reason: "Statement corrected", actor: "Ada")
        #expect(try await r.status(t) == .superseded)
        #expect(try await r.file.actionStates(caseID: r.f.caseID)[t]?.supersededBy == replacement)
        await #expect(throws: CaseActionWorkError.lateResult("superseded")) {
            _ = try await r.file.recordActionResult(caseID: r.f.caseID, taskID: t, kind: .report, outcome: .successful, summary: "late",
                                                    inputs: [.source(r.doc.version)], actor: "Ada")
        }
        let reviews = try await ProfessionalTaskRepository(database: r.f.db).reviews(taskID: t).map(\.action)
        #expect(reviews.contains(.superseded) && reviews.contains(.completed) && reviews.filter { $0 == .statusChanged }.count >= 4)
    }

    @Test("ACTION-05/06: routing names the owner and why (least open work, then alphabetical), queues what nobody can take, keeps a deliberate assignment until a stated invalidation; edits, deferral and bulk changes report per action")
    func routingOverridesAndBulk() async throws {
        let r = try await S8Rig.make()
        let c = r.f.caseID
        for (m, role) in [("Ada", CaseTeamMembership.Role.lead), ("Bina", .investigator), ("Chen", .investigator)] {
            _ = try await r.file.addTeamMember(caseID: c, member: m, role: role, actor: "Ada")
        }
        _ = try await r.file.declareCapability(investigator: "Bina", capability: "Financial analysis", basis: "Chartered accountant", actor: "Ada")
        _ = try await r.file.declareCapability(investigator: "Chen", capability: "Financial analysis", basis: "Bank examiner", actor: "Ada")
        let busy = try await r.action("Earlier work", responsible: nil)
        _ = try await r.file.assignWork(caseID: c, kind: .task, workID: busy.uuidString, to: "Bina", actor: "Ada")
        let t = try await r.action(responsible: nil, capability: "Financial analysis")
        let d = try await r.svc.routeAction(caseID: c, taskID: t, actor: "Ada")
        #expect(d.outcome == .assigned && d.assignee == "Chen", "Chen and Bina are eligible; Bina already has one open action")
        #expect(d.reason.contains("Bank examiner") && d.reason.contains("least open work"))
        #expect(try await r.status(t) == .assigned)
        // Nobody declared interviewing → the unassigned queue, with the remedy.
        let i = try await r.action("Interview the clerk", type: .interview, responsible: nil, capability: "Interviewing")
        let u = try await r.svc.routeAction(caseID: c, taskID: i, actor: "Ada")
        #expect(u.outcome == .unassigned && u.remedy?.contains("Interviewing") == true)
        #expect(try await r.svc.unassignedQueue(caseID: c).contains { $0.taskID == i && $0.reason.contains("Has not declared") })
        // A deliberate assignment is kept by the router…
        _ = try await r.svc.assignActionDeliberately(caseID: c, taskID: i, to: "Bina", reason: "She knows the clerk", actor: "Ada")
        #expect(try await r.svc.routeAction(caseID: c, taskID: i, actor: "Ada").outcome == .keptOverride)
        // …until a stated invalidation: Bina declared unavailable today.
        _ = try await r.file.declareUnavailable(investigator: "Bina", from: Date().addingTimeInterval(-3600), to: Date().addingTimeInterval(86_400), note: "Leave", actor: "Bina")
        let inv = try await r.svc.routeAction(caseID: c, taskID: i, actor: "Ada")
        #expect(inv.reason.contains("no longer holds") && inv.outcome == .unassigned, "nobody else declared interviewing")
        #expect(try await r.file.actionStates(caseID: c)[i]?.assignmentOverride == false)
        // Edit, defer, bulk with a per-item result.
        try await r.svc.editAction(caseID: c, taskID: t, title: "Reconcile the 5 and 9 March transfers", priority: .high, reason: "clearer", actor: "Ada")
        #expect(try await ProfessionalTaskRepository(database: r.f.db).task(id: t)?.title == "Reconcile the 5 and 9 March transfers")
        let results = await r.svc.bulkActions(caseID: c, taskIDs: [t, UUID()], .deferUntil(Date().addingTimeInterval(7 * 86_400), reason: "Bank closed for audit"), actor: "Ada")
        #expect(results.map(\.succeeded) == [true, false] && !results[1].message.isEmpty)
        #expect(try await r.status(t) == .waiting)
        #expect(try await r.file.actionStates(caseID: c)[t]?.waitingUntil != nil)
        // An ended member cannot make bulk changes (checked at the moment of acting).
        let ada = try #require(try await r.file.teamMemberships(caseID: c).first { $0.member == "Chen" })
        try await r.file.endTeamMembership(caseID: c, membershipID: ada.id, reason: "Moved to another unit", transferTo: "Ada", actor: "Ada")
        let refused = await r.svc.bulkActions(caseID: c, taskIDs: [busy], .setPriority(.low), actor: "Chen")
        #expect(refused.map(\.succeeded) == [false])
    }

    @Test("ACTION-07/08/09: dates say what they are; results name their inputs, return to every branch and the parent; reviews name the exact revision and a new revision needs review again")
    func datesResultsAndReviews() async throws {
        let r = try await S8Rig.make()
        let c = r.f.caseID
        let parent = try await r.action("Establish the payment history", type: .other)
        let t = try await r.action(parent: parent)
        await #expect(throws: CaseActionWorkError.self) {
            _ = try await r.file.setActionDate(caseID: c, taskID: t, date: Date(), timeZone: TimeZone(identifier: "Asia/Kolkata")!, basis: .external, actor: "Ada")
        }
        let tz = TimeZone(identifier: "Asia/Kolkata")!
        _ = try await r.file.setActionDate(caseID: c, taskID: t, date: Date(timeIntervalSince1970: 1_800_000_000), timeZone: tz, basis: .external,
                                           authority: "Bank's notice of 2 Nov 2026: records destroyed after 30 days", actor: "Ada")
        _ = try await r.file.setActionDate(caseID: c, taskID: t, date: Date(timeIntervalSince1970: 1_799_000_000), timeZone: tz, basis: .target, actor: "Ada")
        let dates = try await r.file.actionDates(caseID: c, taskID: t)
        #expect(Set(dates.compactMap(\.basis)) == [.external, .target] && dates.allSatisfy { $0.timeZone == "Asia/Kolkata" && !$0.isProposal })
        #expect(dates.first { $0.basis == .external }?.authority?.contains("notice") == true)
        // Results.
        await #expect(throws: CaseActionWorkError.noInputs) {
            _ = try await r.file.recordActionResult(caseID: c, taskID: t, kind: .report, outcome: .successful, summary: "x", inputs: [], actor: "Ada")
        }
        let r1 = try await r.file.recordActionResult(caseID: c, taskID: t, kind: .report, outcome: .inconclusive, summary: "The statement alone cannot tell",
                                                     inputs: [.source(r.doc.version)], actor: "Ada")
        #expect(r1.revision == 1)
        let branches = try await r.file.resultBranches(caseID: c).filter { $0.resultID == r1.id }
        #expect(Set(branches.map(\.via)) == ["serves", "parent"])
        #expect(branches.contains { $0.targetKind == "allegation" && $0.targetID == r.question.uuidString.lowercased() })
        #expect(branches.contains { $0.targetKind == "task" && $0.targetID == parent.uuidString.lowercased() })
        let kind = try await r.file.reviewActionResult(caseID: c, taskID: t, revision: 1, accept: true, rationale: "Inconclusive is the honest outcome", actor: "Ada")
        #expect(kind == .selfReview)
        _ = try await r.file.recordActionResult(caseID: c, taskID: t, kind: .record, outcome: .successful, summary: "Bank advice: two settlements",
                                                inputs: [.source(r.doc.version), CaseExaminedInput(kind: "allegation", id: r.question.uuidString)], actor: "Ada")
        #expect(try await r.file.reReviewNeeded(caseID: c) == [CaseReReviewNeed(taskID: t, latestRevision: 2, acceptedRevision: 1)])
        #expect(try await r.file.reportLedger(caseID: c).contract(t)?.review == .submitted)
        await #expect(throws: CaseActionWorkError.staleRevision(latest: 2)) {
            _ = try await r.file.reviewActionResult(caseID: c, taskID: t, revision: 1, accept: true, rationale: "again", actor: "Bina")
        }
        #expect(try await r.file.reviewActionResult(caseID: c, taskID: t, revision: 2, accept: true, rationale: "Advice matches", actor: "Bina") == .independent)
        #expect(try await r.file.reReviewNeeded(caseID: c).isEmpty)
        #expect(try await r.file.actionResults(caseID: c, taskID: t).map(\.revision) == [1, 2], "revisions are kept, never edited")
        await #expect(throws: (any Error).self) {
            try await r.f.db.exec("UPDATE case_action_results SET summary = 'changed' WHERE id = ?;", [.uuid(r1.id)])
        }
        #expect(try await r.file.allegations(caseID: c).first { $0.id == r.question }?.disposition == .pending)
    }

    @Test("ACTION-10: the parent rollup lists outcomes as recorded; optional children never hold it; closure needs required children finished or an exception")
    func rollupAndClosure() async throws {
        let r = try await S8Rig.make()
        let c = r.f.caseID
        let parent = try await r.svc.createTypedAction(caseID: c, CaseFileService.ChildAction(title: "Payment history", purpose: "Establish the history",
                                                                                            deliverable: "A schedule", responsible: "Ada"),
                                                       details: CaseActionDetails(type: .other, closureCriteria: "Every required child finished or excepted"), actor: "Ada")
        let done = try await r.action("Statement check", parent: parent)
        let optional = try await r.action("Nice-to-have: supplier's own ledger", parent: parent, required: false)
        let blocked = try await r.action("Bank advice", parent: parent)
        try await r.file.recordOutcome(caseID: c, taskID: done, outcome: .discrepancyExplained, note: nil, actor: "Ada")
        try await r.file.completeAction(caseID: c, taskID: done, actor: "Ada")
        try await r.file.recordOutcome(caseID: c, taskID: blocked, outcome: .evidenceUnavailable, note: nil, actor: "Ada")
        try await r.file.setActionState(caseID: c, taskID: blocked, to: .blocked, reason: "Bank refuses", actor: "Ada")
        _ = try await r.svc.routeAction(caseID: c, taskID: done, actor: "Ada")
        let roll = try await r.svc.actionRollup(caseID: c, parentTaskID: parent)
        #expect(roll.children.count == 3 && roll.blocked == 1 && roll.optional == 1 && roll.closureCriteria == "Every required child finished or excepted")
        #expect(roll.unresolved == 2, "evidence unavailable + no outcome recorded")
        #expect(roll.outcomes.map(\.0).contains(.discrepancyExplained) && roll.outcomes.map(\.0).contains(.evidenceUnavailable))
        #expect(roll.holdingClosure.map(\.taskID) == [blocked], "the optional child does not hold the parent")
        await #expect(throws: CaseActionWorkError.holdsClosure(["Bank advice"])) {
            try await r.file.closeParentAction(caseID: c, parentTaskID: parent, exceptions: [:], actor: "Ada")
        }
        try await r.file.closeParentAction(caseID: c, parentTaskID: parent, exceptions: [blocked: "Bank will not release without an order; schedule built from statements"], actor: "Ada")
        #expect(try await r.status(parent) == .completed)
        #expect(try await r.status(optional) == .open)
        #expect(try await r.status(blocked) == .blocked)
        #expect(try await r.svc.actionRollup(caseID: c, parentTaskID: parent).holdingClosure.isEmpty)
    }

    @Test("ACTION-11: a solo investigator holds every role and self-review is recorded and labelled; a team still needs a second QC person; an independent-review policy shows as unmet")
    func soloAndSelfReview() async throws {
        let r = try await S8Rig.make()
        let c = r.f.caseID
        let binding = try #require(try await r.svc.soloBinding(caseID: c, actor: "Ada"))
        #expect(binding.person == "Ada" && binding.roles.count == 4 && binding.note.contains("self-review"))
        _ = try await r.file.createBatches(caseID: c, sourceRefs: [r.doc.version.uuidString], size: 10, reviewer: "Ada", actor: "Ada")
        let batch = try #require(try await r.file.reviewBatches(caseID: c).first)
        try await r.file.advanceBatch(caseID: c, id: batch.id, to: .qcDone, qcNote: "Checked", actor: "Ada")
        #expect(try await r.file.batchQCKind(caseID: c, id: batch.id) == "self")
        // Policy requires independent review → a self-review is refused, never fabricated.
        let auto = r.automation()
        var p = CaseAutomationPolicy.standard; p.requireIndependentReview = true
        _ = try await auto.setPolicy(caseID: c, p, actor: "Ada")
        let t = try await r.action()
        _ = try await r.file.recordActionResult(caseID: c, taskID: t, kind: .report, outcome: .successful, summary: "done", inputs: [.source(r.doc.version)], actor: "Ada")
        await #expect(throws: CaseActionWorkError.independentReviewRequired) {
            _ = try await r.file.reviewActionResult(caseID: c, taskID: t, revision: 1, accept: true, rationale: "mine", actor: "Ada")
        }
        #expect(try await r.svc.soloBinding(caseID: c, actor: "Ada")?.note.contains("requires independent review") == true)
        // With a team, the first-pass reviewer cannot QC their own batch.
        let r2 = try await S8Rig.make()
        _ = try await r2.file.addTeamMember(caseID: r2.f.caseID, member: "Ada", role: .lead, actor: "Ada")
        #expect(try await r2.svc.soloBinding(caseID: r2.f.caseID, actor: "Ada") == nil)
        _ = try await r2.file.createBatches(caseID: r2.f.caseID, sourceRefs: [r2.doc.version.uuidString], size: 10, reviewer: "Ada", actor: "Ada")
        let b2 = try #require(try await r2.file.reviewBatches(caseID: r2.f.caseID).first)
        await #expect(throws: CaseFileError.self) { try await r2.file.advanceBatch(caseID: r2.f.caseID, id: b2.id, to: .qcDone, qcNote: nil, actor: "Ada") }
    }

    @Test("ACTION-12: a changed source gives one reopen proposal per issue and revision; supersede creates linked new work; the same unchanged issue never repeats")
    func reopenAndSupersede() async throws {
        let r = try await S8Rig.make()
        let c = r.f.caseID
        let t = try await r.finishedAction()
        #expect(try await r.file.proposeReopenings(caseID: c).isEmpty, "nothing changed yet")
        let v2 = try await r.revise()
        let first = try await r.file.proposeReopenings(caseID: c)
        #expect(first.count == 1 && first[0].taskID == t && first[0].revisionKey == v2.uuidString.lowercased())
        #expect(try await r.file.proposeReopenings(caseID: c).isEmpty, "the same unchanged issue is not proposed again")
        let new = try #require(try await r.svc.decideReopening(caseID: c, proposalID: first[0].id, .supersede, reason: "Statement corrected by the bank", actor: "Ada"))
        #expect(try await r.status(t) == .superseded)
        #expect(try await r.file.actionStates(caseID: c)[t]?.supersededBy == new)
        let d = try await r.svc.actionDossier(caseID: c, taskID: new)
        #expect(d.state.details?.trigger.kind == .reopen && d.state.details?.trigger.sourceRevisions == [v2] && d.servesQuestions == [r.question])
        await #expect(throws: CaseActionWorkError.alreadyDecided) {
            _ = try await r.svc.decideReopening(caseID: c, proposalID: first[0].id, .dismiss, reason: "x", actor: "Ada")
        }
        // Reopen path on another finished action.
        let t2 = try await r.finishedAction()
        _ = try await r.revise()
        let p2 = try await r.file.proposeReopenings(caseID: c).filter { $0.taskID == t2 }
        #expect(p2.count == 1)
        _ = try await r.svc.decideReopening(caseID: c, proposalID: p2[0].id, .reopen, reason: "Redo with the corrected statement", actor: "Ada")
        #expect(try await r.status(t2) == .open)
    }
}

// MARK: - AUTO

@MainActor
@Suite("Smart map S8 — durable, bounded case-work orchestration (AUTO)", .serialized)
struct SmartMapS8AutomationTests {

    @Test("AUTO-01/02: policies are versioned with typed recipes; the mode and the AI permission never change each other")
    func policiesAndModes() async throws {
        let r = try await S8Rig.make()
        let c = r.f.caseID
        let consent = CaseReadPermissionStore.inMemory()
        let auto = r.automation(ai: { consent.permission(caseID: $0) != nil })
        let p0 = try await auto.policy(caseID: c)
        #expect(p0.version == 0 && p0.policy.mode == .suggest)
        let recipe = CaseAutomationRecipe.changedEvidenceReview
        #expect(recipe.stages.map(\.count) == [2, 1, 1] && recipe.stages.last?.first?.kind == .reviewCheckpoint && !recipe.inputs.isEmpty && !recipe.outputs.isEmpty)
        #expect(try await auto.setMode(caseID: c, .execute, actor: "Ada") == 1)
        #expect(consent.permission(caseID: c) == nil, "execute mode grants no AI permission")
        consent.grant(caseID: c, fingerprint: "docs-v1", documentCount: 1)
        #expect(try await auto.policy(caseID: c).policy.mode == .execute)
        #expect(try await auto.policy(caseID: c).version == 1, "AI permission changes no policy")
        consent.withdraw(caseID: c)
        #expect(try await auto.setMode(caseID: c, .manual, actor: "Ada") == 2 && consent.permission(caseID: c) == nil)
        await #expect(throws: (any Error).self) { try await r.f.db.exec("UPDATE case_automation_policies SET mode = 'execute' WHERE case_id = ?;", [.uuid(c)]) }
    }

    @Test("AUTO-03/04/07 + app path: a changed source triggers one review through the outbox and the engine; repeats, re-delivery and policy changes do not recreate it; cosmetic actions never enqueue")
    func outboxEndToEnd() async throws {
        let r = try await S8Rig.make()
        let c = r.f.caseID
        let auto = r.automation()
        var prof = try await r.file.profile(caseID: c); prof.owner = "Ada"
        try await r.file.saveProfile(prof, actor: "Ada")
        let done = try await r.finishedAction()
        let v2 = try await r.revise()
        let outcomes = await auto.observeSourceVersion(v2)
        guard case .queued(let id) = try #require(outcomes.first) else { Issue.record("not queued: \(outcomes)"); return }
        let row = try #require(try await auto.queue(caseID: c).first { $0.id == id })
        #expect(row.state == .done && row.recipeID == "changed-evidence-review" && row.recipeVersion == 1 && row.policyVersion == 0 && row.executedPolicyVersion == 0)
        #expect(row.inputs.contains(.source(v2)) && row.effects.contains { $0.contains("proposal only") } && row.executionID != nil)
        let out = try #require(row.outputTaskID)
        #expect(try await r.status(out) == .candidate, "suggestion mode: a proposal")
        let dossier = try await r.svc.actionDossier(caseID: c, taskID: out)
        #expect(dossier.state.details?.trigger.outboxID == id && dossier.state.details?.type == .changedEvidenceReview)
        #expect(dossier.raisedFrom.contains { $0.targetKind == .task && $0.targetID == done })
        // The engine's receipt (the app now builds the engine).
        #expect(try await s8Count(r.f.db, "SELECT COUNT(*) FROM workflow_automation_executions WHERE id = ? AND status = 'succeeded';", [.uuid(try #require(row.executionID))]) == 1)
        // Repeat delivery, a new policy version and a re-read of the same version: no second piece of work.
        let again = await auto.observeSourceVersion(v2)
        #expect(again == [.alreadyDone(id)])
        _ = try await auto.setMode(caseID: c, .execute, actor: "Ada")
        #expect(await auto.observeSourceVersion(v2) == [.alreadyDone(id)])
        #expect(try await s8Count(r.f.db, "SELECT COUNT(*) FROM case_automation_outbox WHERE case_id = ?;", [.uuid(c)]) == 1)
        // Cosmetic actions never enqueue; related triggers coalesce while waiting.
        var cosmetic = r.trigger(event: "layout", inputs: [.source(v2)]); cosmetic.causeAction = "layoutSaved"
        #expect(try await auto.observe(caseID: c, cosmetic) == .ignoredCosmetic)
        let other = try await r.action("Second piece of earlier work")
        let a1 = try await auto.observe(caseID: c, r.trigger(event: "e1", inputs: [.source(v2), CaseExaminedInput(kind: "task", id: other.uuidString)]))
        let a2 = try await auto.observe(caseID: c, r.trigger(event: "e2", inputs: [.source(v2), CaseExaminedInput(kind: "task", id: other.uuidString)]))
        guard case .queued(let q) = a1 else { Issue.record("\(a1)"); return }
        #expect(a2 == .coalesced(q))
        #expect(try await auto.queue(caseID: c).first { $0.id == q }?.coalescedCount == 1)
        // The trigger and its case-log row committed together.
        #expect(try await s8Count(r.f.db, "SELECT COUNT(*) FROM case_actions WHERE case_id = ? AND action = 'sourceRevisionObserved';", [.uuid(c)]) == 5)
        // Execute mode: the policy opens it and routes it (solo: bound to the one investigator).
        let rep = try await auto.dispatch(caseID: c, actor: "Ada")
        #expect(rep.done == [q])
        let o2 = try #require(try await auto.queue(caseID: c).first { $0.id == q }?.outputTaskID)
        #expect(try await r.status(o2) == .assigned)
        #expect(try await ProfessionalTaskRepository(database: r.f.db).reviews(taskID: o2).contains { $0.action == .candidateConfirmed && $0.authorityKind == .deterministicRule })
    }

    @Test("AUTO-08: queued work is refused at execution when its input went stale, the requester left, the policy changed, AI permission is missing or the case closed")
    func authorityAtExecution() async throws {
        let r = try await S8Rig.make()
        let c = r.f.caseID
        let v2 = try await r.revise()
        let task = try await r.action()
        let ai = CaseAutomationRecipe(id: "ai-summary", version: 1, label: "AI summary refresh", triggers: ["actionResultRecorded"], inputs: [], outputs: [],
                                      steps: [.init(id: "s", label: "s", kind: .propose, group: 0)], action: .createCandidateTask, actionType: .other,
                                      deliverable: "d", sendsContent: true, estimatedSpendCents: 0, externalRequests: 0)
        let auto = r.automation(recipes: CaseAutomationRecipe.builtIn + [ai])
        var p = CaseAutomationPolicy.standard; p.allowedRecipes.append("ai-summary"); p.allowedTriggers.append("actionResultRecorded")
        _ = try await auto.setPolicy(caseID: c, p, actor: "Ada")
        func q(_ t: CaseAutomationTrigger) async throws -> UUID {
            guard case .queued(let id) = try await auto.observe(caseID: c, t) else { throw CaseAutomationError.wrongState("not queued") }
            return id
        }
        let stale = try await q(r.trigger(event: "s", inputs: [.source(v2), CaseExaminedInput(kind: "task", id: task.uuidString)]))
        let aiRow = try await q(r.trigger(ai, event: "a", inputs: [CaseExaminedInput(kind: "task", id: task.uuidString)]))
        _ = try await r.revise()                                         // v2 is no longer current
        let rep = try await auto.dispatch(caseID: c, actor: "Ada")
        #expect(Set(rep.refused) == [stale, aiRow] && rep.done.isEmpty)
        let rows = try await auto.queue(caseID: c)
        #expect(rows.first { $0.id == stale }?.stateReason?.contains("stale") == true)
        #expect(rows.first { $0.id == aiRow }?.stateReason?.contains("no AI permission") == true)
        // Requester left the team; then a policy change.
        _ = try await r.file.addTeamMember(caseID: c, member: "Ada", role: .lead, actor: "Ada")
        let bina = try await r.file.addTeamMember(caseID: c, member: "Bina", role: .investigator, actor: "Ada")
        let v3 = try #require(try await r.f.db.query("SELECT id FROM source_versions WHERE is_current = 1 AND filename = 'revised.txt';").first?.uuid(0))
        let left = try await q(r.trigger(event: "b", inputs: [.source(v3)], by: "Bina"))
        try await r.file.endTeamMembership(caseID: c, membershipID: bina, reason: "Left", transferTo: nil, actor: "Ada")
        let pol = try await q(r.trigger(event: "p", inputs: [.source(v3), CaseExaminedInput(kind: "task", id: task.uuidString)]))
        p.allowedRecipes = ["missing-records-request"]
        _ = try await auto.setPolicy(caseID: c, p, actor: "Ada")
        _ = try await auto.dispatch(caseID: c, actor: "Ada")
        let rows2 = try await auto.queue(caseID: c)
        #expect(rows2.first { $0.id == left }?.stateReason?.contains("can no longer act") == true)
        #expect(rows2.first { $0.id == pol }?.stateReason?.contains("no longer allows") == true)
        #expect(try await s8Count(r.f.db, "SELECT COUNT(*) FROM case_automation_outbox WHERE case_id = ? AND output_task_id IS NOT NULL;", [.uuid(c)]) == 0)
        // A closed case: queued work does not change it.
        _ = try await auto.setPolicy(caseID: c, .standard, actor: "Ada")
        let closed = try await q(r.trigger(event: "c", inputs: [.source(v3), CaseExaminedInput(kind: "allegation", id: r.question.uuidString)]))
        // The closure decision's own effect on the profile (the closure flow itself is tested elsewhere).
        try await r.file.saveProfile(try await r.file.profile(caseID: c), actor: "Ada")
        try await r.f.db.exec("UPDATE case_profiles SET stage = 'closed' WHERE case_id = ?;", [.uuid(c)])
        #expect(try await s8Count(r.f.db, "SELECT COUNT(*) FROM case_profiles WHERE case_id = ? AND stage = 'closed';", [.uuid(c)]) == 1)
        _ = try await auto.dispatch(caseID: c, actor: "Ada")
        #expect(try await auto.queue(caseID: c).first { $0.id == closed }?.stateReason?.contains("closed") == true)
    }

    @Test("AUTO-05/06: automated feedback without a new condition is suppressed once (bounded); budgets hold work with a reason and resume it; manual work is never budgeted")
    func stormsAndBudgets() async throws {
        let r = try await S8Rig.make()
        let c = r.f.caseID
        let auto = r.automation()
        let v1 = r.doc.version
        let t = try await r.action()
        guard case .queued(let first) = try await auto.observe(caseID: c, r.trigger(event: "1", inputs: [.source(v1), CaseExaminedInput(kind: "task", id: t.uuidString)])) else {
            Issue.record("not queued"); return
        }
        _ = try await auto.dispatch(caseID: c, actor: "Ada")
        // summary → action → summary: the follow-up of the automated action's result carries the same inputs.
        var outcomes: [CaseEnqueueOutcome] = []
        for i in 0..<20 {
            outcomes.append(try await auto.observe(caseID: c, r.trigger(.resultFollowUp, event: "loop-\(i)", title: "Follow up",
                                                                         inputs: [.source(v1), CaseExaminedInput(kind: "task", id: t.uuidString)], causation: first)))
        }
        guard case .suppressed(let s, let why) = outcomes[0] else { Issue.record("\(outcomes[0])"); return }
        #expect(why.contains("No material new condition") && outcomes.allSatisfy { $0 == .suppressed(s, why) })
        #expect(try await s8Count(r.f.db, "SELECT COUNT(*) FROM case_automation_outbox WHERE case_id = ?;", [.uuid(c)]) == 2, "bounded: the run and one suppressed record")
        // A new condition (a newer version) is material.
        let v2 = try await r.revise()
        guard case .queued = try await auto.observe(caseID: c, r.trigger(.resultFollowUp, event: "new", title: "Follow up", inputs: [.source(v2)], causation: first)) else {
            Issue.record("a changed input should queue"); return
        }
        // Budgets: one new action per run.
        var p = CaseAutomationPolicy.standard; p.budgets.newActionsPerRun = 1
        _ = try await auto.setPolicy(caseID: c, p, actor: "Ada")
        for i in 0..<2 { _ = try await auto.observe(caseID: c, r.trigger(event: "b\(i)", inputs: [.source(v2), CaseExaminedInput(kind: "allegation", id: UUID().uuidString)])) }
        let rep = try await auto.dispatch(caseID: c, actor: "Ada")
        #expect(rep.done.count == 1 && rep.held.count == 2)
        let held = try await auto.queue(caseID: c).filter { $0.state == .held }
        #expect(held.allSatisfy { $0.stateReason?.contains("new actions per run") == true && $0.stateReason?.contains("resume") == true })
        let status = try await auto.budgetStatus(caseID: c)
        #expect(status.held == 2 && status.newActionsUsed == 1 && status.lines.contains { $0.contains("held by a budget") })
        // Manual work is not budgeted.
        for i in 0..<3 { _ = try await r.action("Manual \(i)") }
        #expect(try await auto.resumeHeld(caseID: c, actor: "Ada") == 2)
        let rep2 = try await auto.dispatch(caseID: c, actor: "Ada")
        #expect(rep2.done.count == 1 && rep2.held.count == 1)
    }

    @Test("AUTO-09/12: crashes at each write boundary recover to one logical effect; failures are classed, retried and cancelled; manual mode pauses the queue; replay after restore repeats nothing")
    func failureRecoveryAndReplay() async throws {
        let r = try await S8Rig.make()
        let c = r.f.caseID
        let auto = r.automation(lease: 0)
        let v1 = r.doc.version
        func q(_ e: String, title: String = "Review changed evidence") async throws -> UUID {
            guard case .queued(let id) = try await auto.observe(caseID: c, r.trigger(event: e, title: title, inputs: [.source(v1), CaseExaminedInput(kind: "allegation", id: UUID().uuidString)])) else {
                throw CaseAutomationError.wrongState("not queued")
            }
            return id
        }
        // Crash after the engine made the output, before the row finished.
        let a = try await q("a")
        await auto.setFault(.afterEffect)
        await #expect(throws: (any Error).self) { _ = try await auto.dispatch(caseID: c, actor: "Ada") }
        await auto.setFault(nil)
        #expect(try await auto.queue(caseID: c).first { $0.id == a }?.state == .running)
        let rep = try await auto.dispatch(caseID: c, actor: "Ada", now: Date().addingTimeInterval(1))
        #expect(rep.recovered == [a] && rep.done == [a])
        let tasksA = try await s8Count(r.f.db, "SELECT COUNT(*) FROM professional_tasks WHERE origin = 'automationProposed';")
        #expect(tasksA == 1, "the resumed run found its output instead of making a second")
        // Crash inside the engine: the receipt left 'started' with its output already made.
        let b = try await q("b")
        _ = try await auto.dispatch(caseID: c, actor: "Ada")
        let rowB = try #require(try await auto.queue(caseID: c).first { $0.id == b })
        try await r.f.db.exec("UPDATE workflow_automation_executions SET status = 'started', output_id = NULL, output_kind = NULL, result_json = NULL, result_sha256 = NULL, completed_at = NULL WHERE id = ?;",
                              [.uuid(try #require(rowB.executionID))])
        try await r.f.db.exec("UPDATE case_automation_outbox SET state = 'retrying', output_task_id = NULL WHERE id = ?;", [.uuid(b)])
        _ = try await auto.dispatch(caseID: c, actor: "Ada")
        #expect(try await auto.queue(caseID: c).first { $0.id == b }?.outputTaskID == rowB.outputTaskID)
        #expect(try await s8Count(r.f.db, "SELECT COUNT(*) FROM professional_tasks WHERE origin = 'automationProposed';") == 2)
        // Crash right after the claim.
        let d = try await q("d")
        await auto.setFault(.afterClaim)
        await #expect(throws: (any Error).self) { _ = try await auto.dispatch(caseID: c, actor: "Ada") }
        await auto.setFault(nil)
        #expect(try await auto.dispatch(caseID: c, actor: "Ada", now: Date().addingTimeInterval(1)).done == [d])
        // An impossible prerequisite (blank title) fails visibly, is retried (attempts recorded) and cancelled.
        let bad = try await q("bad", title: "   ")
        _ = try await auto.dispatch(caseID: c, actor: "Ada")
        var row = try #require(try await auto.queue(caseID: c).first { $0.id == bad })
        #expect(row.state == .failed && row.failureClass == "impossible" && row.outputTaskID == nil)
        try await auto.retry(caseID: c, id: bad, actor: "Ada")
        _ = try await auto.dispatch(caseID: c, actor: "Ada")
        row = try #require(try await auto.queue(caseID: c).first { $0.id == bad })
        #expect(row.state == .failed && row.attempts == 2)
        #expect(try await WorkflowAutomationExecutionRepository(database: r.f.db).attempts(id: try #require(try await r.f.db.query(
            "SELECT id FROM workflow_automation_executions WHERE status = 'failed';").first?.uuid(0))) == 2)
        try await auto.cancel(caseID: c, id: bad, reason: "Not needed", actor: "Ada")
        #expect(try await auto.queue(caseID: c).first { $0.id == bad }?.state == .cancelled)
        // Manual mode pauses: queued work waits.
        let e = try await q("e")
        _ = try await auto.setMode(caseID: c, .manual, actor: "Ada")
        #expect(try await auto.dispatch(caseID: c, actor: "Ada").paused)
        #expect(try await auto.queue(caseID: c).first { $0.id == e }?.state == .queued)
        // Restore: a copy of the ledger replays nothing that was done.
        _ = try await auto.setMode(caseID: c, .suggest, actor: "Ada")
        _ = try await auto.dispatch(caseID: c, actor: "Ada")
        let before = try await s8Count(r.f.db, "SELECT COUNT(*) FROM professional_tasks;")
        let restored = r.automation()
        let again = try await restored.dispatch(caseID: c, actor: "Ada")
        #expect(again.done.isEmpty)
        #expect(try await s8Count(r.f.db, "SELECT COUNT(*) FROM professional_tasks;") == before)
    }

    @Test("AUTO-10/11: external effects go only to configured recipients, once, and are reconciled before another hand-over; assignment contacts nobody; undo keeps performed and external work")
    func externalEffectsAndCompensation() async throws {
        let r = try await S8Rig.make()
        let c = r.f.caseID
        let auto = r.automation()
        await #expect(throws: CaseAutomationError.recipientNotAuthorized) {
            _ = try await auto.prepareExternalEffect(caseID: c, recipientID: UUID(), purpose: "Request", content: "Please send", actor: "Ada")
        }
        let bank = try await auto.authorizeRecipient(caseID: c, recipient: "Bank records desk", channel: "letter", contentScope: "Request for March statements", actor: "Ada")
        let e1 = try await auto.prepareExternalEffect(caseID: c, recipientID: bank, purpose: "Request March statements", content: "Dear …", actor: "Ada")
        let e2 = try await auto.prepareExternalEffect(caseID: c, recipientID: bank, purpose: "Request March statements", content: "Dear …", actor: "Ada")
        #expect(e1.id == e2.id && e1.state == .prepared)
        try await auto.markHandedOver(caseID: c, effectID: e1.id, providerRef: "Post 123", actor: "Ada")
        await #expect(throws: CaseAutomationError.outcomeUnknown) { try await auto.markHandedOver(caseID: c, effectID: e1.id, providerRef: nil, actor: "Ada") }
        try await auto.reconcileExternalEffect(caseID: c, effectID: e1.id, sent: false, note: "Returned by the post office", actor: "Ada")
        try await auto.markHandedOver(caseID: c, effectID: e1.id, providerRef: "Post 124", actor: "Ada")
        try await auto.reconcileExternalEffect(caseID: c, effectID: e1.id, sent: true, note: "Bank acknowledged", actor: "Ada")
        await #expect(throws: CaseAutomationError.alreadySent) { try await auto.markHandedOver(caseID: c, effectID: e1.id, providerRef: nil, actor: "Ada") }
        #expect(try await auto.externalEffects(caseID: c).first?.handovers == 2)
        // Assigning an interview of a witness contacts nobody.
        let interview = try await r.action("Interview the witness", type: .interview)
        _ = try await r.svc.assignActionDeliberately(caseID: c, taskID: interview, to: "Ada", reason: "Lead", actor: "Ada")
        #expect(try await auto.externalEffects(caseID: c).count == 1)
        // Compensation: an untouched proposal is cancelled (kept); performed work and a hand-over are kept.
        func run(_ e: String) async throws -> (UUID, UUID) {
            guard case .queued(let id) = try await auto.observe(caseID: c, r.trigger(event: e, inputs: [.source(r.doc.version), CaseExaminedInput(kind: "allegation", id: UUID().uuidString)])) else {
                throw CaseAutomationError.wrongState("not queued")
            }
            _ = try await auto.dispatch(caseID: c, actor: "Ada")
            return (id, try #require(try await auto.queue(caseID: c).first { $0.id == id }?.outputTaskID))
        }
        let (run1, out1) = try await run("x1")
        let undo = try await auto.compensate(caseID: c, outboxID: run1, reason: "Raised by mistake", actor: "Ada")
        #expect(undo.map(\.outcome) == ["compensated"])
        #expect(try await r.status(out1) == .cancelled)
        #expect(try await ProfessionalTaskRepository(database: r.f.db).task(id: out1) != nil, "kept, not deleted")
        let (run2, out2) = try await run("x2")
        _ = try await ProfessionalTaskRepository(database: r.f.db).confirmCandidate(taskID: out2, authority: .user(actor: "Ada"), reason: nil, at: Date())
        _ = try await r.file.recordActionResult(caseID: c, taskID: out2, kind: .observation, outcome: .partial, summary: "Looked", inputs: [.source(r.doc.version)], actor: "Ada")
        let sent = try await auto.prepareExternalEffect(caseID: c, recipientID: bank, purpose: "Follow-up", content: "Further to …", outboxID: run2, actor: "Ada")
        try await auto.markHandedOver(caseID: c, effectID: sent.id, providerRef: nil, actor: "Ada")
        let kept = try await auto.compensate(caseID: c, outboxID: run2, reason: "Change of plan", actor: "Ada")
        #expect(kept.map(\.outcome) == ["kept", "kept"] && kept.allSatisfy { !$0.explanation.isEmpty })
        #expect(kept.contains { $0.effectKind == "externalEffect" && $0.explanation.contains("cannot be unsent") })
        #expect(try await r.status(out2) == .open)
        #expect(try await auto.compensations(caseID: c).count == 3)
    }

    @Test("Erasure: a case's automation, action records and the engine receipts naming its work go with the case")
    func erasureRemovesAutomation() async throws {
        let r = try await S8Rig.make()
        let c = r.f.caseID
        let auto = r.automation()
        _ = try await r.finishedAction()
        guard case .queued = try await auto.observe(caseID: c, r.trigger(event: "z", inputs: [.source(r.doc.version), CaseExaminedInput(kind: "allegation", id: r.question.uuidString)])) else {
            Issue.record("not queued"); return
        }
        _ = try await auto.dispatch(caseID: c, actor: "Ada")
        #expect(try await s8Count(r.f.db, "SELECT COUNT(*) FROM workflow_automation_executions;") == 1)
        _ = try await CaseEraser(database: r.f.db).erase(caseID: c, sourceVersionIDs: [], eraseExclusiveSources: false, reason: "Retention ended", legalBasis: nil, actor: "Ada")
        for t in ["case_automation_outbox", "case_action_results", "case_action_result_branches", "case_automation_usage", "case_automation_policies", "workflow_automation_executions"] {
            #expect(try await s8Count(r.f.db, "SELECT COUNT(*) FROM \(t);") == 0, "\(t) left rows")
        }
        #expect(try await r.f.db.withSavepoint("s8inv") { db in try CaseDataInventory.unregistered(db) }.isEmpty)
    }
}
