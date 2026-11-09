//
//  CaseActionWork.swift
//  Kalsmritikosh
//
//  Smart-map S8 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md §17 ACTION; plan §17.1–§17.3; schema v184).
//  The mother case and its child actions over the ONE task engine (professional_tasks) and the M1 child-action contract
//  (case_action_contracts), through the case file repository's one savepoint. Nothing here calls a model or the network.
//
//  • Contract (ACTION-01): type, trigger provenance (the records and source revisions that started it), helpers, the
//    capability it needs, whether the parent needs it and the parent's closure criteria — beside the M1 purpose,
//    deliverable, responsible person, reviewer, parent and links. `actionDossier` reads one action whole; `untraceable`
//    lists case tasks that have no contract.
//  • Templates (ACTION-02): editable drafts per action type (a contradiction check, an interview, a reconciliation …);
//    a template proposes a target date, never a legal deadline. Case templates apply once per item, however often applied.
//  • Lifecycle (ACTION-03): proposed → assigned → in progress → waiting / blocked (with reason and remedy) → completed,
//    cancelled or superseded; review (submitted / returned / accepted) and outcome stay separate values. Completing work
//    never closes the question it serves.
//  • Assignment (ACTION-05 / ACTION-06): a rule names the owner and why — a designated owner, else the eligible person with
//    the least open work (alphabetical on ties), else the one investigator of a solo case — or leaves the action in the
//    unassigned queue with the remedy. A deliberate assignment is an override the router keeps until the person changes
//    it or a stated invalidation (membership ended, a conflict recorded, declared unavailable) occurs. Edits, delegation,
//    reassignment, deferral and cancellation are recorded; bulk changes report a result per action.
//  • Dates (ACTION-07): every date says what it is — the investigator's target, an external deadline with the authority
//    that sets it, or a reminder — with its time zone.
//  • Results (ACTION-08 / ACTION-09): append-only revisions naming the inputs examined and an explicit outcome kind
//    (successful, partial, unsuccessful, inconclusive); each is returned to every branch the action serves and to its
//    parent. A review names the exact revision; a new revision after acceptance needs review again.
//  • Parent rollup (ACTION-10): counts of blocked, waiting, unassigned, unresolved and review-needed children and every
//    outcome as recorded (nothing averaged); an optional child never holds the parent; closure needs every required child
//    finished or a recorded exception.
//  • Solo work (ACTION-11): with no team recorded, every role is bound to the one investigator and their review of their
//    own work is recorded and labelled as self-review — unless the case's policy requires independent review, which is
//    then shown as an unmet requirement, never fabricated.
//  • Reopen / supersede (ACTION-12): finished work whose examined source changed gets ONE proposal per issue and revision;
//    the person reopens, supersedes (a new action naming the old) or dismisses it, with a reason.
//

import Foundation
import os

// MARK: - Types

/// What kind of work an action is (ACTION-01 / ACTION-02).
public nonisolated enum CaseActionType: String, Sendable, CaseIterable, Codable, Identifiable {
    case contradictionCheck, missingEvidence, interview, identityCheck, forensicExamination, reconciliation, changedEvidenceReview, outputPreparation, other
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .contradictionCheck: return "Check an apparent contradiction"
        case .missingEvidence: return "Obtain missing evidence"
        case .interview: return "Interview"
        case .identityCheck: return "Check an identity"
        case .forensicExamination: return "Forensic examination"
        case .reconciliation: return "Reconcile records"
        case .changedEvidenceReview: return "Review changed evidence"
        case .outputPreparation: return "Prepare an output"
        case .other: return "Other work"
        }
    }
}

/// Where an action came from: the records and source revisions that started it (ACTION-01).
public nonisolated struct CaseActionTrigger: Codable, Sendable, Equatable, Hashable {
    /// S10 (AI-06): `assistant` — created from an AI proposal (accepted by a person, or applied under configured execution).
    public enum Kind: String, Codable, Sendable { case manual, template, automation, reopen, changedEvidence, assistant }
    public var kind: Kind
    /// Map keys ("allegation:…", "reportPoint:…") or "kind:id" of the records that started it.
    public var records: [String]
    /// The exact source versions it was raised against.
    public var sourceRevisions: [UUID]
    public var note: String?
    /// The automation outbox row that created it, when an automation did.
    public var outboxID: UUID?
    public init(kind: Kind, records: [String] = [], sourceRevisions: [UUID] = [], note: String? = nil, outboxID: UUID? = nil) {
        self.kind = kind; self.records = records; self.sourceRevisions = sourceRevisions; self.note = note; self.outboxID = outboxID
    }
}

/// The ACTION-01 fields beside the M1 contract.
public nonisolated struct CaseActionDetails: Sendable, Equatable {
    public var type: CaseActionType
    public var trigger: CaseActionTrigger
    public var helpers: [String]
    public var requiredCapability: String?
    /// False: the parent may close without it (an optional child).
    public var requiredForParent: Bool
    /// What closing this action (as a parent) needs, in words.
    public var closureCriteria: String?
    public init(type: CaseActionType, trigger: CaseActionTrigger = CaseActionTrigger(kind: .manual), helpers: [String] = [], requiredCapability: String? = nil,
                requiredForParent: Bool = true, closureCriteria: String? = nil) {
        self.type = type; self.trigger = trigger; self.helpers = helpers; self.requiredCapability = requiredCapability
        self.requiredForParent = requiredForParent; self.closureCriteria = closureCriteria
    }
}

/// The v184 columns of one action's contract.
public nonisolated struct CaseActionState: Sendable, Equatable {
    public let taskID: UUID
    public let details: CaseActionDetails?
    public let assignmentOverride: Bool
    public let overrideBy: String?
    public let overrideReason: String?
    public let stateReason: String?
    public let stateRemedy: String?
    public let waitingUntil: Date?
    public let supersededBy: UUID?
    public let supersedeReason: String?
}

/// An editable action template (ACTION-02). Applying it gives a draft the investigator changes before creating the action.
public nonisolated struct CaseActionTemplate: Identifiable, Sendable, Equatable {
    public let type: CaseActionType
    public let title: String
    public let purpose: String
    public let deliverable: String
    /// What the work needs as input, in words.
    public let inputs: String
    public let capability: String?
    /// A proposed TARGET (days from today), never a legal deadline.
    public let targetDays: Int?
    public var id: String { type.rawValue }

    public static let all: [CaseActionTemplate] = [
        CaseActionTemplate(type: .contradictionCheck, title: "Check the apparent contradiction",
                           purpose: "Find out whether the two accounts really differ, and why.",
                           deliverable: "Both passages compared (identity, time, units, context, later corrections) and an outcome: explained, remains, or cannot be decided.",
                           inputs: "The two passages and their sources", capability: nil, targetDays: 7),
        CaseActionTemplate(type: .missingEvidence, title: "Obtain the missing records",
                           purpose: "Get the material the question needs that the case does not hold.",
                           deliverable: "The records received and added to the case, or the custodian's refusal or a statement that they do not exist.",
                           inputs: "What is missing, for which period, and who holds it", capability: nil, targetDays: 14),
        CaseActionTemplate(type: .interview, title: "Interview the witness",
                           purpose: "Hear the person's account of the points the question turns on.",
                           deliverable: "A confirmed statement with the questions put and the answers given, or a record that the interview did not take place and why.",
                           inputs: "The points to put and the material to show", capability: "Interviewing", targetDays: 14),
        CaseActionTemplate(type: .identityCheck, title: "Check whether the records name the same person",
                           purpose: "Decide whether two records refer to one person or to different people.",
                           deliverable: "The attributes compared with their sources and a decision with reasons — or a statement that the records cannot settle it.",
                           inputs: "The two records and their identifiers", capability: nil, targetDays: 7),
        CaseActionTemplate(type: .forensicExamination, title: "Examine the item",
                           purpose: "Establish what the item shows using a stated method.",
                           deliverable: "An examination report naming the item, the method, the findings and their limits.",
                           inputs: "The item, its custody record and the question put", capability: "Forensic examination", targetDays: 21),
        CaseActionTemplate(type: .reconciliation, title: "Reconcile the payments",
                           purpose: "Work out how the recorded payments relate (separate, reversal, duplicate record).",
                           deliverable: "A schedule of the records with references and a reconciliation, or the records still needed.",
                           inputs: "The statements and the period", capability: "Financial analysis", targetDays: 10),
        CaseActionTemplate(type: .changedEvidenceReview, title: "Review the changed evidence",
                           purpose: "See whether a changed source alters work already done.",
                           deliverable: "The earlier result checked against the new version: still holds, needs redoing, or superseded.",
                           inputs: "The earlier and the new version of the source", capability: nil, targetDays: 7),
        CaseActionTemplate(type: .outputPreparation, title: "Prepare the output",
                           purpose: "Produce the report or briefing from the reviewed record.",
                           deliverable: "A draft output whose every point opens its source, ready for review.",
                           inputs: "The accepted points and decisions", capability: nil, targetDays: 10),
    ]
    public static func template(_ type: CaseActionType) -> CaseActionTemplate? { all.first { $0.type == type } }

    /// The editable draft (title, purpose, deliverable) for `subject` ("the payments of 5 and 9 March").
    public func draft(subject: String? = nil, parentTaskID: UUID? = nil, servesQuestions: [UUID] = [], fromPoint: UUID? = nil) -> CaseFileService.ChildAction {
        let t = subject.map { "\(title): \($0)" } ?? title
        return CaseFileService.ChildAction(title: t, purpose: purpose, deliverable: deliverable, parentTaskID: parentTaskID, fromPoint: fromPoint,
                                           servesQuestions: servesQuestions)
    }
}

/// What a date on an action is (ACTION-07).
public nonisolated enum CaseDateBasis: String, Sendable, CaseIterable, Codable {
    case target, external, reminder
    public var label: String {
        switch self {
        case .target: return "Investigator's target (not a legal deadline)"
        case .external: return "External deadline (confirmed, with its authority)"
        case .reminder: return "Reminder"
        }
    }
}

public nonisolated struct CaseActionDate: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let taskID: UUID
    public let date: Date
    public let precision: DatePrecision
    public let timeZone: String
    public let basis: CaseDateBasis?
    public let authority: String?
    /// True: only proposed (a template's suggested target) — nobody has set it.
    public let isProposal: Bool
    public var label: String { (basis?.label ?? "Date (basis not recorded)") + (isProposal ? " — proposed, not set" : "") }
}

/// One input a result examined (ACTION-08).
public nonisolated struct CaseExaminedInput: Codable, Sendable, Hashable {
    /// "sourceVersion", or a case record kind: "allegation", "point", "report", "task", "request".
    public let kind: String
    public let id: String
    public let label: String?
    public init(kind: String, id: String, label: String? = nil) { self.kind = kind; self.id = id; self.label = label }
    public static func source(_ v: UUID, _ label: String? = nil) -> CaseExaminedInput { CaseExaminedInput(kind: "sourceVersion", id: v.uuidString, label: label) }
}

public nonisolated enum CaseResultKind: String, Sendable, CaseIterable, Codable {
    case report, record, observation, noResult
    public var label: String {
        switch self {
        case .report: return "Report"
        case .record: return "Record obtained"
        case .observation: return "Observation"
        case .noResult: return "No result"
        }
    }
}

public nonisolated enum CaseResultOutcomeKind: String, Sendable, CaseIterable, Codable {
    case successful, partial, unsuccessful, inconclusive
    public var label: String {
        switch self {
        case .successful: return "Done as asked"
        case .partial: return "Partly done"
        case .unsuccessful: return "Unsuccessful"
        case .inconclusive: return "Inconclusive"
        }
    }
}

public nonisolated struct CaseActionResult: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    public let taskID: UUID
    public let revision: Int
    public let kind: CaseResultKind
    public let outcome: CaseResultOutcomeKind
    public let summary: String
    public let reportID: UUID?
    public let inputs: [CaseExaminedInput]
    public let recordedBy: String
    public let recordedAt: Date
}

public nonisolated struct CaseActionResultReview: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let taskID: UUID
    public let resultID: UUID
    public let revision: Int
    public let accepted: Bool
    public let kind: CaseReviewKind
    public let reviewer: String
    public let rationale: String
    public let reviewedAt: Date
}

public nonisolated struct CaseResultBranch: Sendable, Equatable, Hashable {
    public let resultID: UUID
    public let taskID: UUID
    public let targetKind: String
    public let targetID: String
    public let via: String
}

/// An action whose newest result revision has not been reviewed since an earlier revision was accepted.
public nonisolated struct CaseReReviewNeed: Sendable, Equatable {
    public let taskID: UUID
    public let latestRevision: Int
    public let acceptedRevision: Int
    public var explanation: String { "Revision \(latestRevision) was recorded after revision \(acceptedRevision) was accepted — it needs review." }
}

/// A routing decision (ACTION-05).
public nonisolated struct CaseRoutingDecision: Sendable, Equatable {
    public enum Outcome: String, Sendable { case assigned, unassigned, keptOverride, overrideInvalidated, alreadyAssigned }
    public let taskID: UUID
    public let outcome: Outcome
    public let assignee: String?
    public let reason: String
    public let remedy: String?
    public static let ruleVersion = 1
}

public nonisolated struct CaseUnassignedItem: Identifiable, Sendable, Equatable {
    public let taskID: UUID
    public let title: String
    public let reason: String
    public let remedy: String?
    public var id: UUID { taskID }
}

public nonisolated enum CaseBulkActionOperation: Sendable, Equatable {
    case reassign(to: String, reason: String)
    case deferUntil(Date, reason: String)
    case cancel(reason: String)
    case setPriority(ProfessionalTaskPriority)
    case route
}

public nonisolated struct CaseBulkItemResult: Sendable, Equatable {
    public let taskID: UUID
    public let succeeded: Bool
    public let message: String
}

/// The parent's view of its children (ACTION-10). Nothing is averaged: each child's outcome is listed as recorded.
public nonisolated struct CaseActionRollup: Sendable, Equatable {
    public struct Child: Sendable, Equatable {
        public let taskID: UUID
        public let title: String
        public let status: ProfessionalTaskStatus
        public let review: CaseActionReview
        public let outcome: CaseActionOutcome
        public let required: Bool
        public let assigned: Bool
        public let exception: String?
        public var finished: Bool { ProfessionalTaskStatus.finished.contains(status) }
    }
    public let parentTaskID: UUID?
    public let children: [Child]
    public let closureCriteria: String?
    public var blocked: Int { children.filter { $0.status == .blocked }.count }
    public var waiting: Int { children.filter { $0.status == .waiting }.count }
    public var unassigned: Int { children.filter { !$0.finished && !$0.assigned }.count }
    /// Children whose recorded outcome does not answer what they were for (or that record none).
    public var unresolved: Int { children.filter { $0.status != .cancelled && $0.status != .superseded && Self.unresolvedOutcomes.contains($0.outcome) }.count }
    public var reviewNeeded: Int { children.filter { $0.review == .submitted }.count }
    public var optional: Int { children.filter { !$0.required }.count }
    /// Each outcome as recorded, with how many children record it.
    public var outcomes: [(CaseActionOutcome, Int)] {
        CaseActionOutcome.allCases.compactMap { o in let n = children.filter { $0.outcome == o }.count; return n > 0 ? (o, n) : nil }
    }
    /// Required children that are neither finished nor excepted: what holds the parent open.
    public var holdingClosure: [Child] { children.filter { $0.required && !$0.finished && $0.exception == nil } }
    static let unresolvedOutcomes: Set<CaseActionOutcome> = [.notRecorded, .contradictionRemains, .evidenceUnavailable, .furtherWorkNeeded, .hypothesisChallenged]
    public static func == (a: CaseActionRollup, b: CaseActionRollup) -> Bool { a.parentTaskID == b.parentTaskID && a.children == b.children && a.closureCriteria == b.closureCriteria }
}

/// Who holds which role in a case with no team recorded (ACTION-11).
public nonisolated struct CaseSoloBinding: Sendable, Equatable {
    public let person: String
    public let roles: [String]
    public let note: String
}

public nonisolated struct CaseReopenProposal: Identifiable, Sendable, Equatable {
    public enum State: String, Sendable { case pending, reopened, superseded, dismissed }
    public enum Decision: String, Sendable { case reopen, supersede, dismiss }
    public let id: UUID
    public let caseID: UUID
    public let taskID: UUID
    public let issueKey: String
    public let revisionKey: String
    public let explanation: String
    public let state: State
    public let decisionReason: String?
    public let newTaskID: UUID?
    public let createdAt: Date
}

/// Everything about one action, read together (ACTION-01).
public nonisolated struct CaseActionDossier: Sendable {
    public let task: ProfessionalTask
    public let caseID: UUID
    public let contract: CaseActionContract
    public let state: CaseActionState
    public let servesQuestions: [UUID]
    public let raisedFrom: [CaseWorkLink]
    public let children: [UUID]
    public let waitsFor: [UUID]
    public let assignments: [CaseWorkAssignment]
    public let routing: [(outcome: String, assignee: String?, reason: String, at: Date)]
    public let results: [CaseActionResult]
    public let reviews: [CaseActionResultReview]
    public let history: [ProfessionalTaskReview]
    public let dates: [CaseActionDate]
    /// The mother case, the parent, the purpose, the deliverable and the trigger are all recorded.
    public var isTraceable: Bool { state.details != nil && !contract.purpose.isEmpty && !contract.deliverable.isEmpty }
}

public nonisolated enum CaseActionWorkError: Error, Equatable, LocalizedError {
    case reasonRequired(String)
    case notAllowed(String)
    case lateResult(String)
    case staleRevision(latest: Int)
    case independentReviewRequired
    case noInputs
    case holdsClosure([String])
    case alreadyDecided

    public var errorDescription: String? {
        switch self {
        case .reasonRequired(let what): return "Say why: \(what) needs a reason."
        case .notAllowed(let why): return why
        case .lateResult(let state): return "This action is \(state); a result can no longer be submitted to it. Record it on the action that replaced it, or reopen this one first."
        case .staleRevision(let latest): return "That is not the newest result. Review revision \(latest)."
        case .independentReviewRequired: return "This case's policy requires review by someone other than the person who did the work, and no other reviewer is recorded. The requirement stays unmet until one is."
        case .noInputs: return "Name what was examined. A result says which material it rests on (a record that nothing could be examined is recorded as 'No result')."
        case .holdsClosure(let titles): return "Still open and required: \(titles.joined(separator: "; ")). Finish them, cancel them, or record an exception for each."
        case .alreadyDecided: return "That proposal has already been decided."
        }
    }
}

nonisolated private final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

// MARK: - Persistence (the case file repository's one savepoint)

extension CaseFileRepository {

    static let actionStateColumns = """
        task_id, action_type, trigger_json, helpers_json, required_capability, required_for_parent, closure_criteria,
        assignment_override, override_by, override_reason, state_reason, state_remedy, waiting_until, superseded_by_task_id, supersede_reason
        """

    static func decodeActionState(_ r: SQLRow) -> CaseActionState? {
        guard let tid = r.uuid(0) else { return nil }
        var details: CaseActionDetails?
        if let t = r.string(1).flatMap(CaseActionType.init(rawValue:)) {
            let trig = (r.string(2)?.data(using: .utf8)).flatMap { try? JSONDecoder().decode(CaseActionTrigger.self, from: $0) } ?? CaseActionTrigger(kind: .manual)
            let helpers = (r.string(3)?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
            details = CaseActionDetails(type: t, trigger: trig, helpers: helpers, requiredCapability: r.string(4), requiredForParent: (r.int(5) ?? 1) == 1,
                                        closureCriteria: r.string(6))
        }
        return CaseActionState(taskID: tid, details: details, assignmentOverride: (r.int(7) ?? 0) == 1, overrideBy: r.string(8), overrideReason: r.string(9),
                               stateReason: r.string(10), stateRemedy: r.string(11), waitingUntil: r.date(12), supersededBy: r.uuid(13), supersedeReason: r.string(14))
    }

    public func actionStates(caseID: UUID) async throws -> [UUID: CaseActionState] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        let rows = try await database.query("SELECT \(Self.actionStateColumns) FROM case_action_contracts WHERE case_id = ?;", [.uuid(caseID)])
        var out: [UUID: CaseActionState] = [:]
        for r in rows { if let s = Self.decodeActionState(r) { out[s.taskID] = s } }
        return out
    }

    static func jsonText<T: Encodable>(_ v: T) -> String {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(v)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    /// ACTION-01 — record the action's type, trigger, helpers, capability, parent requirement and closure criteria.
    public func saveActionDetails(caseID: UUID, taskID: UUID, _ d: CaseActionDetails, actor: String, at date: Date = Date()) async throws {
        let who = try Self.clean(actor, "Actor")
        try await write("cf_acd", caseID: caseID, actor: who, action: "actionDetails", detail: d.type.rawValue, at: date, capture: .actionContract(taskID)) { db in
            try CaseMembershipGate.require(db, caseID: caseID, name: who)
            guard try !db.query("SELECT 1 FROM case_action_contracts WHERE task_id = ? AND case_id = ?;", [.uuid(taskID), .uuid(caseID)]).isEmpty else {
                throw CaseWorkError.noContract
            }
            for v in d.trigger.sourceRevisions where !(try Self.versionInCase(db, v, caseID: caseID)) { throw CaseWorkError.sourceNotInCase }
            let helpers = d.helpers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            try db.exec("""
                UPDATE case_action_contracts SET action_type = ?, trigger_json = ?, helpers_json = ?, required_capability = ?, required_for_parent = ?,
                    closure_criteria = ?, updated_at = ? WHERE task_id = ?;
                """, [.text(d.type.rawValue), .text(Self.jsonText(d.trigger)), .text(Self.jsonText(helpers)), .optionalText(Self.blankToNil(d.requiredCapability)),
                      .bool(d.requiredForParent), .optionalText(Self.blankToNil(d.closureCriteria)), .date(date), .uuid(taskID)])
        }
    }

    /// Case tasks with no contract: generic rows nobody can trace to a purpose (ACTION-01).
    public func untraceableTasks(caseID: UUID) async throws -> [UUID] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT l.task_id FROM case_task_links l
            WHERE l.case_id = ? AND NOT EXISTS (SELECT 1 FROM case_action_contracts c WHERE c.case_id = l.case_id AND upper(c.task_id) = upper(l.task_id))
            ORDER BY l.created_at;
            """, [.uuid(caseID)]).compactMap { $0.uuid(0) }
    }

    // MARK: ACTION-03 lifecycle

    /// Move an action to assigned / in progress / waiting / blocked / open, or cancel it. Waiting, blocked and cancelled
    /// need a reason; waiting and blocked keep it (and the remedy) on the action until the next change.
    public func setActionState(caseID: UUID, taskID: UUID, to status: ProfessionalTaskStatus, reason: String?, remedy: String? = nil,
                               waitingUntil: Date? = nil, actor: String, at date: Date = Date()) async throws {
        let who = try Self.clean(actor, "Actor")
        let why = Self.blankToNil(reason)
        if [.waiting, .blocked, .cancelled].contains(status), why == nil { throw CaseActionWorkError.reasonRequired("\(status.rawValue)") }
        guard ProfessionalTaskStatus.activeWork.contains(status) || status == .cancelled else {
            throw CaseActionWorkError.notAllowed("Use complete, supersede or reopen for that change.")
        }
        try await write("cf_acst", caseID: caseID, actor: who, action: "actionState", detail: status.rawValue + (why.map { ": \($0)" } ?? ""), at: date,
                        capture: .actionContract(taskID)) { db in
            try CaseMembershipGate.require(db, caseID: caseID, name: who)
            guard try Self.taskInCase(db, taskID, caseID: caseID) else { throw CaseWorkError.notInCase("action") }
            try ProfessionalTaskRepository.applyStatusInWrite(db, taskID: taskID, to: status, reviewer: who, reason: why, at: date)
            let keep = status == .waiting || status == .blocked
            try db.exec("UPDATE case_action_contracts SET state_reason = ?, state_remedy = ?, waiting_until = ?, updated_at = ? WHERE task_id = ? AND case_id = ?;",
                        [keep ? .optionalText(why) : .null, keep ? .optionalText(Self.blankToNil(remedy)) : .null,
                         status == .waiting ? .optionalDate(waitingUntil) : .null, .date(date), .uuid(taskID), .uuid(caseID)])
        }
    }

    /// Complete an action (workflow completion). Refused while an action it waits for is unfinished, with the names;
    /// its result's review and the question it serves are untouched.
    public func completeAction(caseID: UUID, taskID: UUID, actor: String, at date: Date = Date()) async throws {
        let who = try Self.clean(actor, "Actor")
        try await write("cf_accm", caseID: caseID, actor: who, action: "taskCompleted", detail: nil, at: date, capture: .actionContract(taskID)) { db in
            try CaseMembershipGate.require(db, caseID: caseID, name: who)
            guard try Self.taskInCase(db, taskID, caseID: caseID) else { throw CaseWorkError.notInCase("action") }
            let pending = try db.query("""
                SELECT p.title FROM professional_task_dependencies d JOIN professional_tasks p ON upper(p.id) = upper(d.depends_on_task_id)
                WHERE upper(d.task_id) = ? AND p.status NOT IN ('completed','cancelled','superseded','archived');
                """, [.text(taskID.uuidString)]).compactMap { $0.string(0) }
            if !pending.isEmpty { throw CaseActionWorkError.notAllowed("It waits for unfinished work: \(pending.joined(separator: "; ")).") }
            try ProfessionalTaskRepository.applyStatusInWrite(db, taskID: taskID, to: .completed, reviewer: who, reason: nil, at: date)
            try db.exec("UPDATE case_action_contracts SET state_reason = NULL, state_remedy = NULL, waiting_until = NULL, updated_at = ? WHERE task_id = ?;",
                        [.date(date), .uuid(taskID)])
            try db.exec("UPDATE deadlines SET status = 'satisfied', satisfied_at = ?, updated_at = ? WHERE upper(task_id) = ? AND status = 'active';",
                        [.date(date), .date(date), .text(taskID.uuidString)])
        }
    }

    /// ACTION-03 / ACTION-12 — the action is replaced by `replacement` (another action of this case), with the reason.
    public func supersedeAction(caseID: UUID, taskID: UUID, by replacement: UUID, reason: String, actor: String, at date: Date = Date()) async throws {
        let who = try Self.clean(actor, "Actor"), why = try Self.clean(reason, "The reason")
        guard taskID != replacement else { throw CaseActionWorkError.notAllowed("An action cannot replace itself.") }
        try await write("cf_acsup", caseID: caseID, actor: who, action: "actionSuperseded", detail: why, at: date, capture: .actionContract(taskID)) { db in
            try CaseMembershipGate.require(db, caseID: caseID, name: who)
            guard try Self.taskInCase(db, taskID, caseID: caseID) else { throw CaseWorkError.notInCase("action") }
            guard try Self.taskInCase(db, replacement, caseID: caseID) else { throw CaseWorkError.notInCase("replacement action") }
            try ProfessionalTaskRepository.applyStatusInWrite(db, taskID: taskID, to: .superseded, reviewer: who, reason: why, at: date)
            try db.exec("UPDATE case_action_contracts SET superseded_by_task_id = ?, supersede_reason = ?, state_reason = NULL, state_remedy = NULL, updated_at = ? WHERE task_id = ? AND case_id = ?;",
                        [.uuid(replacement), .text(why), .date(date), .uuid(taskID), .uuid(caseID)])
            // Open assignments on the replaced action end; the people keep the history.
            try db.exec("UPDATE case_work_assignments SET ended_at = ?, ended_by = ?, end_reason = 'released' WHERE case_id = ? AND work_kind = 'task' AND work_id = ? AND ended_at IS NULL;",
                        [.date(date), .text(who), .uuid(caseID), .text(taskID.uuidString.lowercased())])
        }
    }

    // MARK: ACTION-05 / ACTION-06 assignment

    /// Record a routing decision and, when it assigns, the assignment, the engine's owner and the assigned state — one unit.
    func writeRouting(caseID: UUID, taskID: UUID, decision: CaseRoutingDecision, policyVersion: Int?, override: (by: String, reason: String)?,
                      clearOverride: Bool, actor: String, at date: Date) async throws {
        let who = try Self.clean(actor, "Actor")
        let action = decision.outcome == .assigned ? "taskAssigned" : "actionRouted"
        try await write("cf_route", caseID: caseID, actor: who, action: action, detail: "\(decision.outcome.rawValue): \(decision.reason)", at: date,
                        capture: .actionContract(taskID)) { db in
            try CaseMembershipGate.require(db, caseID: caseID, name: who)
            guard try Self.taskInCase(db, taskID, caseID: caseID) else { throw CaseWorkError.notInCase("action") }
            if decision.outcome == .assigned, let to = decision.assignee {
                // A deliberate reassignment ends the current assignment first ("reassigned to …").
                try db.exec("UPDATE case_work_assignments SET ended_at = ?, ended_by = ?, end_reason = 'reassigned', reassigned_to = ? WHERE case_id = ? AND work_kind = 'task' AND work_id = ? AND ended_at IS NULL;",
                            [.date(date), .text(who), .text(to), .uuid(caseID), .text(taskID.uuidString.lowercased())])
                let cap = try db.query("SELECT required_capability FROM case_action_contracts WHERE task_id = ?;", [.uuid(taskID)]).first?.string(0)
                try Self.checkAssignable(db, caseID: caseID, kind: .task, workID: taskID.uuidString, assignee: to, capability: override == nil ? cap : nil, actor: who, at: date)
                try db.exec("INSERT INTO case_work_assignments (id, case_id, work_kind, work_id, assignee, capability, assigned_by, assigned_at, note) VALUES (?,?,?,?,?,?,?,?,?);",
                            [.uuid(UUID()), .uuid(caseID), .text("task"), .text(taskID.uuidString.lowercased()), .text(to), .optionalText(override == nil ? cap : nil),
                             .text(who), .date(date), .text(decision.reason)])
                try ProfessionalTaskRepository.setOwnerInWrite(db, taskID: taskID, owner: to, reviewer: who, reason: decision.reason, at: date)
                let status = try db.query("SELECT status FROM professional_tasks WHERE upper(id) = ?;", [.text(taskID.uuidString)]).first?.string(0)
                if status == ProfessionalTaskStatus.open.rawValue {
                    try ProfessionalTaskRepository.applyStatusInWrite(db, taskID: taskID, to: .assigned, reviewer: who, reason: decision.reason, at: date)
                }
            }
            if let override {
                try db.exec("UPDATE case_action_contracts SET assignment_override = 1, override_by = ?, override_reason = ?, updated_at = ? WHERE task_id = ?;",
                            [.text(override.by), .text(override.reason), .date(date), .uuid(taskID)])
            } else if clearOverride {
                try db.exec("UPDATE case_action_contracts SET assignment_override = 0, override_by = NULL, override_reason = NULL, updated_at = ? WHERE task_id = ?;",
                            [.date(date), .uuid(taskID)])
            }
            let stored: String
            switch decision.outcome {
            case .assigned: stored = "assigned"
            case .unassigned: stored = "unassigned"
            case .keptOverride, .alreadyAssigned: stored = "keptOverride"
            case .overrideInvalidated: stored = "overrideInvalidated"
            }
            try db.exec("""
                INSERT INTO case_action_routing (id, case_id, task_id, outcome, assignee, reason, remedy, rule_version, policy_version, decided_by, decided_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(caseID), .uuid(taskID), .text(stored), .optionalText(decision.assignee), .text(decision.reason),
                      .optionalText(decision.remedy), .integer(Int64(CaseRoutingDecision.ruleVersion)), policyVersion.map { .integer(Int64($0)) } ?? .null,
                      .text(who), .date(date)])
        }
    }

    public func routingHistory(caseID: UUID, taskID: UUID? = nil) async throws -> [(taskID: UUID, outcome: String, assignee: String?, reason: String, remedy: String?, at: Date)] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT task_id, outcome, assignee, reason, remedy, decided_at FROM case_action_routing WHERE case_id = ? AND (? IS NULL OR upper(task_id) = upper(?))
            ORDER BY decided_at, rowid;
            """, [.uuid(caseID), .optionalText(taskID?.uuidString), .optionalText(taskID?.uuidString)]).compactMap { r in
            guard let t = r.uuid(0), let o = r.string(1), let why = r.string(3), let at = r.date(5) else { return nil }
            return (t, o, r.string(2), why, r.string(4), at)
        }
    }

    // MARK: ACTION-07 dates

    /// Set a date on an action with what it is. A target or a reminder is the investigator's own date; an external
    /// deadline needs the authority that sets it (a notice, a rule, a court order) — none is ever inferred. A day-precision
    /// date means the end of that day in the stated time zone.
    @discardableResult
    public func setActionDate(caseID: UUID, taskID: UUID, date due: Date, precision: DatePrecision = .day, timeZone: TimeZone,
                              basis: CaseDateBasis, authority: String? = nil, actor: String, at date: Date = Date()) async throws -> UUID {
        let who = try Self.clean(actor, "Actor")
        let auth = Self.blankToNil(authority)
        if basis == .external, auth == nil { throw CaseActionWorkError.reasonRequired("An external deadline (the notice, rule or order that sets it)") }
        guard DeadlineValue.confirmablePrecisions.contains(precision) else { throw CaseActionWorkError.notAllowed("A date set on an action needs at least a day.") }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let stored = precision == .day ? cal.date(byAdding: DateComponents(day: 1, second: -1), to: cal.startOfDay(for: due)) ?? due : due
        let id = UUID()
        let kind: DeadlineKind = basis == .reminder ? .followUp : (basis == .external ? .response : .due)
        try await write("cf_acdate", caseID: caseID, actor: who, action: "dueSet", detail: "\(basis.rawValue): \(ISO8601DateFormatter().string(from: stored))", at: date,
                        capture: .actionContract(taskID)) { db in
            try CaseMembershipGate.require(db, caseID: caseID, name: who)
            guard try Self.taskInCase(db, taskID, caseID: caseID) else { throw CaseWorkError.notInCase("action") }
            guard let st = try db.query("SELECT status FROM professional_tasks WHERE upper(id) = ?;", [.text(taskID.uuidString)]).first?.string(0)
                    .flatMap(ProfessionalTaskStatus.init(rawValue:)), ProfessionalTaskStatus.activeWork.contains(st) else {
                throw CaseActionWorkError.notAllowed("Dates are set on open work.")
            }
            // A new date of the same basis replaces the earlier one (kept, superseded).
            try db.exec("""
                UPDATE deadlines SET status = 'superseded', updated_at = ? WHERE upper(task_id) = ? AND status = 'active'
                  AND id IN (SELECT ref_id FROM case_deadline_bases WHERE case_id = ? AND upper(task_id) = ? AND basis = ? AND ref_kind = 'deadline');
                """, [.date(date), .text(taskID.uuidString), .uuid(caseID), .text(taskID.uuidString), .text(basis.rawValue)])
            try db.exec("""
                INSERT INTO deadlines (id, task_id, source_candidate_id, due_date, precision, time_zone, deadline_kind, status, confirmation_kind, confirmed_by,
                    confirmed_at, confirm_reason, rule_id, rule_version, created_at, updated_at)
                VALUES (?,?,NULL,?,?,?,?, 'active', 'user', ?, ?, ?, NULL, NULL, ?, ?);
                """, [.uuid(id), .uuid(taskID), .date(stored), .integer(Int64(precision.rawValue)), .text(timeZone.identifier), .text(kind.rawValue), .text(who),
                      .date(date), .text(basis.label + (auth.map { " — \($0)" } ?? "")), .date(date), .date(date)])
            try db.exec("INSERT INTO deadline_reviews (id, deadline_id, action, reviewer, reason, reviewed_at) VALUES (?,?,?,?,?,?);",
                        [.uuid(UUID()), .uuid(id), .text(DeadlineReviewAction.confirmed.rawValue), .text(who), .text(basis.label), .date(date)])
            try db.exec("""
                INSERT INTO case_deadline_bases (ref_id, case_id, task_id, ref_kind, basis, authority, time_zone, recorded_by, recorded_at) VALUES (?,?,?, 'deadline', ?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .uuid(taskID), .text(basis.rawValue), .optionalText(auth), .text(timeZone.identifier), .text(who), .date(date)])
        }
        return id
    }

    /// Record the basis of a date set elsewhere (a target proposed by a template, or a due date from the older path).
    func recordDateBasis(caseID: UUID, refID: UUID, taskID: UUID, refKind: String, basis: CaseDateBasis, timeZone: String, actor: String, at date: Date) async throws {
        try await CaseAccessPolicy.requireChange(database, caseID: caseID, actor: actor, .work)
        try await database.exec("""
            INSERT OR IGNORE INTO case_deadline_bases (ref_id, case_id, task_id, ref_kind, basis, authority, time_zone, recorded_by, recorded_at) VALUES (?,?,?,?,?,NULL,?,?,?);
            """, [.uuid(refID), .uuid(caseID), .uuid(taskID), .text(refKind), .text(basis.rawValue), .text(timeZone), .text(actor), .date(date)])
    }

    /// Every date on the action — set dates and proposals — with its basis.
    public func actionDates(caseID: UUID, taskID: UUID) async throws -> [CaseActionDate] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        let bases = Dictionary(uniqueKeysWithValues: try await database.query(
            "SELECT ref_id, basis, authority FROM case_deadline_bases WHERE case_id = ? AND upper(task_id) = ?;", [.uuid(caseID), .text(taskID.uuidString)])
            .compactMap { r -> (UUID, (CaseDateBasis?, String?))? in r.uuid(0).map { ($0, (r.string(1).flatMap(CaseDateBasis.init(rawValue:)), r.string(2))) } })
        var out: [CaseActionDate] = []
        for r in try await database.query("SELECT id, due_date, precision, time_zone FROM deadlines WHERE upper(task_id) = ? AND status = 'active' ORDER BY due_date;",
                                          [.text(taskID.uuidString)]) {
            guard let id = r.uuid(0), let d = r.date(1), let p = r.int(2).flatMap({ DatePrecision(rawValue: Int($0)) }) else { continue }
            out.append(CaseActionDate(id: id, taskID: taskID, date: d, precision: p, timeZone: r.string(3) ?? "", basis: bases[id]?.0, authority: bases[id]?.1, isProposal: false))
        }
        for r in try await database.query("SELECT id, due_date, precision, time_zone FROM deadline_candidates WHERE upper(task_id) = ? AND status = 'pending' ORDER BY due_date;",
                                          [.text(taskID.uuidString)]) {
            guard let id = r.uuid(0), let d = r.date(1), let p = r.int(2).flatMap({ DatePrecision(rawValue: Int($0)) }) else { continue }
            out.append(CaseActionDate(id: id, taskID: taskID, date: d, precision: p, timeZone: r.string(3) ?? "", basis: bases[id]?.0 ?? .target, authority: nil, isProposal: true))
        }
        return out
    }

    // MARK: ACTION-08 / ACTION-09 results and review

    /// Record a result revision. It names what was examined (source versions of the case, or case records) and an explicit
    /// outcome kind; it is returned to every branch the action serves or came from, and to its parent action. The action's
    /// status, the questions it serves and their dispositions are left as they are. A revision recorded after an accepted
    /// one sends the action back to review.
    @discardableResult
    public func recordActionResult(caseID: UUID, taskID: UUID, kind: CaseResultKind, outcome: CaseResultOutcomeKind, summary: String, reportID: UUID? = nil,
                                   inputs: [CaseExaminedInput], actor: String, at date: Date = Date()) async throws -> CaseActionResult {
        let who = try Self.clean(actor, "Actor"), text = try Self.clean(summary, "The result")
        if inputs.isEmpty && kind != .noResult { throw CaseActionWorkError.noInputs }
        let id = UUID()
        let rev = Box(1)
        try await write("cf_acres", caseID: caseID, actor: who, action: "actionResultRecorded", detail: "\(kind.rawValue)/\(outcome.rawValue)", at: date,
                        capture: .actionContract(taskID)) { db in
            try CaseMembershipGate.require(db, caseID: caseID, name: who)
            guard let c = try db.query("SELECT review_state FROM case_action_contracts WHERE task_id = ? AND case_id = ?;", [.uuid(taskID), .uuid(caseID)]).first else {
                throw CaseWorkError.noContract
            }
            // AUTO-12 late replies: a superseded or cancelled action takes no new result.
            let status = try db.query("SELECT status FROM professional_tasks WHERE upper(id) = ?;", [.text(taskID.uuidString)]).first?.string(0) ?? ""
            if status == ProfessionalTaskStatus.superseded.rawValue || status == ProfessionalTaskStatus.cancelled.rawValue || status == ProfessionalTaskStatus.archived.rawValue {
                throw CaseActionWorkError.lateResult(status)
            }
            for i in inputs {
                if i.kind == "sourceVersion" {
                    guard let v = UUID(uuidString: i.id), try Self.versionInCase(db, v, caseID: caseID) else { throw CaseWorkError.sourceNotInCase }
                } else {
                    guard let rid = UUID(uuidString: i.id), try Self.workEnd(db, i.kind, rid, caseID: caseID) else { throw CaseWorkError.notInCase(i.kind) }
                }
            }
            if let reportID, try db.query("SELECT 1 FROM case_reports WHERE id = ? AND case_id = ?;", [.uuid(reportID), .uuid(caseID)]).isEmpty {
                throw CaseWorkError.notInCase("report")
            }
            let next = Int(try db.query("SELECT coalesce(MAX(revision), 0) + 1 FROM case_action_results WHERE upper(task_id) = ?;", [.text(taskID.uuidString)]).first?.int(0) ?? 1)
            rev.value = next
            try db.exec("""
                INSERT INTO case_action_results (id, case_id, task_id, revision, result_kind, outcome_kind, summary, report_id, inputs_json, recorded_by, recorded_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .uuid(taskID), .integer(Int64(next)), .text(kind.rawValue), .text(outcome.rawValue), .text(text),
                      reportID.map { .uuid($0) } ?? .null, .text(Self.jsonText(inputs)), .text(who), .date(date)])
            // Returned to every branch: the work links of the action, then its parent.
            var targets: [(String, String, String)] = try db.query("""
                SELECT target_kind, target_id, role FROM case_work_links WHERE case_id = ? AND work_kind = 'task' AND upper(work_id) = ? AND withdrawn_at IS NULL;
                """, [.uuid(caseID), .text(taskID.uuidString)]).compactMap { r in
                guard let k = r.string(0), let t = r.string(1), let role = r.string(2) else { return nil }
                return (k, t.lowercased(), role)
            }
            if let parent = try db.query("SELECT parent_task_id FROM case_action_contracts WHERE task_id = ?;", [.uuid(taskID)]).first?.string(0) {
                targets.append(("task", parent.lowercased(), "parent"))
            }
            for (k, t, via) in targets {
                try db.exec("INSERT OR IGNORE INTO case_action_result_branches (id, case_id, result_id, task_id, target_kind, target_id, via, returned_at) VALUES (?,?,?,?,?,?,?,?);",
                            [.uuid(UUID()), .uuid(caseID), .uuid(id), .uuid(taskID), .text(k), .text(t), .text(via), .date(date)])
            }
            // The newest revision is what is under review (a new one after acceptance needs review again).
            _ = c
            try db.exec("""
                UPDATE case_action_contracts SET review_state = 'submitted', review_kind = NULL, reviewed_by = NULL, reviewed_at = NULL, review_note = NULL,
                    submitted_by = ?, submitted_at = ?, updated_at = ? WHERE task_id = ?;
                """, [.text(who), .date(date), .date(date), .uuid(taskID)])
        }
        return CaseActionResult(id: id, caseID: caseID, taskID: taskID, revision: rev.value, kind: kind, outcome: outcome, summary: text, reportID: reportID,
                                inputs: inputs, recordedBy: who, recordedAt: date)
    }

    /// Accept or return the newest result revision, naming it. Self-review is labelled as such, and refused when the
    /// case's policy requires independent review.
    @discardableResult
    public func reviewActionResult(caseID: UUID, taskID: UUID, revision: Int, accept: Bool, rationale: String, actor: String,
                                   at date: Date = Date()) async throws -> CaseReviewKind {
        let who = try Self.clean(actor, "Actor"), why = try Self.clean(rationale, "The rationale")
        let box = Box(CaseReviewKind.independent)
        try await write("cf_acrr", caseID: caseID, actor: who, action: accept ? "actionAccepted" : "actionReturned", detail: "revision \(revision): \(why)", at: date,
                        capture: .actionContract(taskID)) { db in
            try CaseMembershipGate.require(db, caseID: caseID, name: who)
            guard let c = try db.query("SELECT review_state, responsible, created_by FROM case_action_contracts WHERE task_id = ? AND case_id = ?;",
                                       [.uuid(taskID), .uuid(caseID)]).first else { throw CaseWorkError.noContract }
            guard let latest = try db.query("SELECT id, revision, recorded_by FROM case_action_results WHERE upper(task_id) = ? ORDER BY revision DESC LIMIT 1;",
                                            [.text(taskID.uuidString)]).first, let resultID = latest.uuid(0) else { throw CaseWorkError.notSubmitted }
            let latestRev = Int(latest.int(1) ?? 0)
            guard latestRev == revision else { throw CaseActionWorkError.staleRevision(latest: latestRev) }
            guard c.string(0) == CaseActionReview.submitted.rawValue else { throw CaseWorkError.notSubmitted }
            let doers = [Self.blankToNil(c.string(1)), latest.string(2), c.string(2)].compactMap { $0 }.map(CaseConflictMatcher.normalise)
            let kind: CaseReviewKind = doers.contains(CaseConflictMatcher.normalise(who)) ? .selfReview : .independent
            if kind == .selfReview, try CaseAutomationPolicyStore.requiresIndependentReview(db, caseID: caseID) {
                throw CaseActionWorkError.independentReviewRequired
            }
            box.value = kind
            try db.exec("""
                INSERT INTO case_action_result_reviews (id, case_id, task_id, result_id, revision, decision, review_kind, reviewer, rationale, reviewed_at)
                VALUES (?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(caseID), .uuid(taskID), .uuid(resultID), .integer(Int64(revision)), .text(accept ? "accepted" : "returned"),
                      .text(kind.rawValue), .text(who), .text(why), .date(date)])
            try db.exec("UPDATE case_action_contracts SET review_state = ?, review_kind = ?, reviewed_by = ?, reviewed_at = ?, review_note = ?, updated_at = ? WHERE task_id = ?;",
                        [.text(accept ? CaseActionReview.accepted.rawValue : CaseActionReview.returned.rawValue), .text(kind.rawValue), .text(who), .date(date),
                         .text("revision \(revision): \(why)"), .date(date), .uuid(taskID)])
        }
        return box.value
    }

    public func actionResults(caseID: UUID, taskID: UUID? = nil) async throws -> [CaseActionResult] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT id, case_id, task_id, revision, result_kind, outcome_kind, summary, report_id, inputs_json, recorded_by, recorded_at
            FROM case_action_results WHERE case_id = ? AND (? IS NULL OR upper(task_id) = upper(?)) ORDER BY task_id, revision;
            """, [.uuid(caseID), .optionalText(taskID?.uuidString), .optionalText(taskID?.uuidString)]).compactMap { r in
            guard let id = r.uuid(0), let c = r.uuid(1), let t = r.uuid(2), let k = r.string(4).flatMap(CaseResultKind.init(rawValue:)),
                  let o = r.string(5).flatMap(CaseResultOutcomeKind.init(rawValue:)), let s = r.string(6), let by = r.string(9), let at = r.date(10) else { return nil }
            let inputs = (r.string(8)?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([CaseExaminedInput].self, from: $0) } ?? []
            return CaseActionResult(id: id, caseID: c, taskID: t, revision: Int(r.int(3) ?? 1), kind: k, outcome: o, summary: s, reportID: r.uuid(7), inputs: inputs,
                                    recordedBy: by, recordedAt: at)
        }
    }

    public func actionResultReviews(caseID: UUID, taskID: UUID? = nil) async throws -> [CaseActionResultReview] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT id, task_id, result_id, revision, decision, review_kind, reviewer, rationale, reviewed_at FROM case_action_result_reviews
            WHERE case_id = ? AND (? IS NULL OR upper(task_id) = upper(?)) ORDER BY reviewed_at, rowid;
            """, [.uuid(caseID), .optionalText(taskID?.uuidString), .optionalText(taskID?.uuidString)]).compactMap { r in
            guard let id = r.uuid(0), let t = r.uuid(1), let res = r.uuid(2), let d = r.string(4), let k = r.string(5).flatMap(CaseReviewKind.init(rawValue:)),
                  let by = r.string(6), let why = r.string(7), let at = r.date(8) else { return nil }
            return CaseActionResultReview(id: id, taskID: t, resultID: res, revision: Int(r.int(3) ?? 0), accepted: d == "accepted", kind: k, reviewer: by, rationale: why, reviewedAt: at)
        }
    }

    /// Results returned to a branch (a question, a point, a parent action…).
    public func resultBranches(caseID: UUID) async throws -> [CaseResultBranch] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("SELECT result_id, task_id, target_kind, target_id, via FROM case_action_result_branches WHERE case_id = ? ORDER BY returned_at, rowid;",
                                 [.uuid(caseID)]).compactMap { r in
            guard let res = r.uuid(0), let t = r.uuid(1), let k = r.string(2), let id = r.string(3), let via = r.string(4) else { return nil }
            return CaseResultBranch(resultID: res, taskID: t, targetKind: k, targetID: id, via: via)
        }
    }

    /// Actions whose newest revision came after an accepted one and is not yet reviewed.
    public func reReviewNeeded(caseID: UUID) async throws -> [CaseReReviewNeed] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        let results = try await actionResults(caseID: caseID)
        let reviews = try await actionResultReviews(caseID: caseID)
        var out: [CaseReReviewNeed] = []
        for (task, rs) in Dictionary(grouping: results, by: \.taskID) {
            guard let latest = rs.map(\.revision).max() else { continue }
            let mine = reviews.filter { $0.taskID == task }
            guard let accepted = mine.filter(\.accepted).map(\.revision).max(), accepted < latest,
                  !mine.contains(where: { $0.revision == latest }) else { continue }
            out.append(CaseReReviewNeed(taskID: task, latestRevision: latest, acceptedRevision: accepted))
        }
        return out.sorted { $0.taskID.uuidString < $1.taskID.uuidString }
    }

    // MARK: ACTION-10 closure

    /// Record exceptions (one per required child that will not be finished), then complete the parent — refused, naming
    /// them, while any required child is neither finished nor excepted. Optional children never hold the parent.
    public func closeParentAction(caseID: UUID, parentTaskID: UUID, exceptions: [UUID: String], actor: String, at date: Date = Date()) async throws {
        let who = try Self.clean(actor, "Actor")
        for (_, why) in exceptions where Self.blankToNil(why) == nil { throw CaseActionWorkError.reasonRequired("An exception") }
        try await write("cf_acclose", caseID: caseID, actor: who, action: "taskCompleted", detail: "parent closed with \(exceptions.count) exception(s)", at: date,
                        capture: .actionContract(parentTaskID)) { db in
            try CaseMembershipGate.require(db, caseID: caseID, name: who)
            guard try Self.taskInCase(db, parentTaskID, caseID: caseID) else { throw CaseWorkError.notInCase("action") }
            for (child, why) in exceptions {
                guard try !db.query("SELECT 1 FROM case_action_contracts WHERE task_id = ? AND case_id = ? AND upper(parent_task_id) = ?;",
                                    [.uuid(child), .uuid(caseID), .text(parentTaskID.uuidString)]).isEmpty else { throw CaseWorkError.notInCase("child action") }
                try db.exec("INSERT OR IGNORE INTO case_action_closure_exceptions (id, case_id, parent_task_id, child_task_id, reason, recorded_by, recorded_at) VALUES (?,?,?,?,?,?,?);",
                            [.uuid(UUID()), .uuid(caseID), .uuid(parentTaskID), .uuid(child), .text(why.trimmingCharacters(in: .whitespacesAndNewlines)), .text(who), .date(date)])
            }
            let holding = try db.query("""
                SELECT t.title FROM case_action_contracts c JOIN professional_tasks t ON upper(t.id) = upper(c.task_id)
                WHERE c.case_id = ? AND upper(c.parent_task_id) = ? AND c.required_for_parent = 1
                  AND t.status NOT IN ('completed','cancelled','superseded','archived')
                  AND NOT EXISTS (SELECT 1 FROM case_action_closure_exceptions e WHERE e.case_id = c.case_id AND upper(e.parent_task_id) = ? AND upper(e.child_task_id) = upper(c.task_id));
                """, [.uuid(caseID), .text(parentTaskID.uuidString), .text(parentTaskID.uuidString)]).compactMap { $0.string(0) }
            if !holding.isEmpty { throw CaseActionWorkError.holdsClosure(holding) }
            try ProfessionalTaskRepository.applyStatusInWrite(db, taskID: parentTaskID, to: .completed, reviewer: who, reason: "Closed under its criteria", at: date)
        }
    }

    public func closureExceptions(caseID: UUID) async throws -> [(parent: UUID, child: UUID, reason: String)] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("SELECT parent_task_id, child_task_id, reason FROM case_action_closure_exceptions WHERE case_id = ?;", [.uuid(caseID)]).compactMap { r in
            guard let p = r.uuid(0), let c = r.uuid(1), let why = r.string(2) else { return nil }
            return (p, c, why)
        }
    }

    // MARK: ACTION-02 template applications

    /// True when the template item had not been applied to the case yet (and records it); false: already applied.
    func claimTemplateItem(caseID: UUID, templateID: String, itemKey: String, taskID: UUID, actor: String, at date: Date) async throws -> Bool {
        try await CaseAccessPolicy.requireChange(database, caseID: caseID, actor: actor, .work)
        try await database.exec("""
            INSERT OR IGNORE INTO case_template_applications (case_id, template_id, item_key, task_id, applied_by, applied_at) VALUES (?,?,?,?,?,?);
            """, [.uuid(caseID), .text(templateID), .text(itemKey), .uuid(taskID), .text(actor), .date(date)])
        let owner = try await database.query("SELECT task_id FROM case_template_applications WHERE case_id = ? AND template_id = ? AND item_key = ?;",
                                             [.uuid(caseID), .text(templateID), .text(itemKey)]).first?.uuid(0)
        return owner == taskID
    }

    func templateItemApplied(caseID: UUID, templateID: String, itemKey: String) async throws -> Bool {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await !database.query("SELECT 1 FROM case_template_applications WHERE case_id = ? AND template_id = ? AND item_key = ?;",
                                  [.uuid(caseID), .text(templateID), .text(itemKey)]).isEmpty
    }

    // MARK: ACTION-12 reopen proposals

    /// For finished work whose examined source (or the source it was raised against) now has a newer version, record ONE
    /// proposal per issue (action + logical source) and revision (the new version). An unchanged issue never produces a
    /// second proposal; a later new version does.
    @discardableResult
    public func proposeReopenings(caseID: UUID, at date: Date = Date()) async throws -> [CaseReopenProposal] {
        try await CaseAccessPolicy.requireChange(database, caseID: caseID, actor: nil, .read)
        var created: [UUID] = []
        let finished = try await database.query("""
            SELECT c.task_id, t.title, c.trigger_json FROM case_action_contracts c JOIN professional_tasks t ON upper(t.id) = upper(c.task_id)
            WHERE c.case_id = ? AND t.status = 'completed';
            """, [.uuid(caseID)])
        let results = try await actionResults(caseID: caseID)
        for r in finished {
            guard let task = r.uuid(0) else { continue }
            let title = r.string(1) ?? "the action"
            var versions = Set(results.filter { $0.taskID == task }.flatMap(\.inputs).filter { $0.kind == "sourceVersion" }.compactMap { UUID(uuidString: $0.id) })
            if let t = (r.string(2)?.data(using: .utf8)).flatMap({ try? JSONDecoder().decode(CaseActionTrigger.self, from: $0) }) { versions.formUnion(t.sourceRevisions) }
            for v in versions {
                guard let row = try await database.query("""
                    SELECT o.logical_source_id, (SELECT n.id FROM source_versions n WHERE n.logical_source_id = o.logical_source_id AND n.is_current = 1 LIMIT 1),
                           coalesce(o.filename, '')
                    FROM source_versions o WHERE o.id IN (?, ?);
                    """, [.text(v.uuidString), .text(v.uuidString.lowercased())]).first,
                      let logical = row.string(0), let current = row.uuid(1), current != v else { continue }
                let id = UUID()
                let name = (row.string(2) ?? "").isEmpty ? "a source" : "“\(row.string(2) ?? "")”"
                let explanation = "The work “\(title)” examined \(name) at an earlier version; a newer version is now current. Reopen it, supersede it with new work, or dismiss with a reason."
                try await database.exec("""
                    INSERT OR IGNORE INTO case_action_reopen_proposals (id, case_id, task_id, issue_key, revision_key, explanation, created_at) VALUES (?,?,?,?,?,?,?);
                    """, [.uuid(id), .uuid(caseID), .uuid(task), .text("source:\(logical.lowercased())"), .text(current.uuidString.lowercased()), .text(explanation), .date(date)])
                if try await !database.query("SELECT 1 FROM case_action_reopen_proposals WHERE id = ?;", [.uuid(id)]).isEmpty { created.append(id) }
            }
        }
        return try await reopenProposals(caseID: caseID).filter { created.contains($0.id) }
    }

    public func reopenProposals(caseID: UUID) async throws -> [CaseReopenProposal] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT id, case_id, task_id, issue_key, revision_key, explanation, state, decision_reason, new_task_id, created_at
            FROM case_action_reopen_proposals WHERE case_id = ? ORDER BY created_at, rowid;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let c = r.uuid(1), let t = r.uuid(2), let ik = r.string(3), let rk = r.string(4), let ex = r.string(5),
                  let st = r.string(6).flatMap(CaseReopenProposal.State.init(rawValue:)), let at = r.date(9) else { return nil }
            return CaseReopenProposal(id: id, caseID: c, taskID: t, issueKey: ik, revisionKey: rk, explanation: ex, state: st, decisionReason: r.string(7),
                                      newTaskID: r.uuid(8), createdAt: at)
        }
    }

    func markReopenProposal(caseID: UUID, id: UUID, state: CaseReopenProposal.State, reason: String, newTaskID: UUID?, reopenTask: UUID?,
                            actor: String, at date: Date) async throws {
        let who = try Self.clean(actor, "Actor"), why = try Self.clean(reason, "The reason")
        try await write("cf_reopen", caseID: caseID, actor: who, action: state == .reopened ? "taskReopened" : "reopenProposalDecided", detail: "\(state.rawValue): \(why)", at: date) { db in
            try CaseMembershipGate.require(db, caseID: caseID, name: who)
            guard let r = try db.query("SELECT state FROM case_action_reopen_proposals WHERE id = ? AND case_id = ?;", [.uuid(id), .uuid(caseID)]).first else {
                throw CaseWorkError.notInCase("proposal")
            }
            guard r.string(0) == CaseReopenProposal.State.pending.rawValue else { throw CaseActionWorkError.alreadyDecided }
            if let reopenTask {
                try ProfessionalTaskRepository.applyStatusInWrite(db, taskID: reopenTask, to: .open, reviewer: who, reason: why, at: date)
            }
            try db.exec("UPDATE case_action_reopen_proposals SET state = ?, decided_by = ?, decided_at = ?, decision_reason = ?, new_task_id = ? WHERE id = ?;",
                        [.text(state.rawValue), .text(who), .date(date), .text(why), newTaskID.map { .uuid($0) } ?? .null, .uuid(id)])
        }
    }

    /// The acting gate (PEOPLE-09) read from the ledger now — for changes made through another repository.
    public func requireActing(caseID: UUID, name: String) async throws {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        try await database.withSavepoint("cf_gate_\(UUID().uuidString.prefix(8))") { db in try CaseMembershipGate.require(db, caseID: caseID, name: name) }
    }

    // MARK: ACTION-11 solo

    /// Whether the case has any team recorded (a solo case has none).
    public func hasTeam(caseID: UUID) async throws -> Bool {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await !database.query("SELECT 1 FROM case_team_memberships WHERE case_id = ? LIMIT 1;", [.uuid(caseID)]).isEmpty
    }
}

// MARK: - The work flows over the existing services

extension CaseFileService {

    /// ACTION-01 / ACTION-02 — create an action with its contract and its details in one go (an action from a template is
    /// an edited draft). A template's target becomes a PROPOSED target date, never a set or legal deadline.
    @discardableResult
    public func createTypedAction(caseID: UUID, _ a: ChildAction, details: CaseActionDetails, proposedTargetDays: Int? = nil, actor: String,
                                  at date: Date = Date()) async throws -> UUID {
        try await CaseAccessPolicy.requireChange(file.database, caseID: caseID, actor: actor, .work)
        let task = try await createAction(caseID: caseID, a, actor: actor, at: date)
        do {
            try await file.saveActionDetails(caseID: caseID, taskID: task, details, actor: actor, at: date)
        } catch {
            KalsmritikoshLog.app.error("Action details not recorded; cancelling the new action: \(error.localizedDescription, privacy: .public)")
            do { try await setTaskStatus(caseID: caseID, taskID: task, to: .cancelled, actor: actor, at: date) } catch {
                KalsmritikoshLog.app.error("The new action could not be cancelled: \(error.localizedDescription, privacy: .public)")
            }
            throw error
        }
        if let days = proposedTargetDays, let due = Calendar.current.date(byAdding: .day, value: days, to: date) {
            try await proposeTarget(caseID: caseID, taskID: task, due: due, ruleID: "action-template:\(details.type.rawValue)", actor: actor, at: date)
        }
        return task
    }

    /// A proposed target date (a candidate the investigator may set or ignore) — the template's suggestion, labelled as such.
    func proposeTarget(caseID: UUID, taskID: UUID, due: Date, ruleID: String, actor: String, at date: Date) async throws {
        try await CaseAccessPolicy.requireChange(file.database, caseID: caseID, actor: actor, .work)
        let tz = TimeZone.current
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let value = DeadlineValue(date: cal.date(byAdding: DateComponents(day: 1, second: -1), to: cal.startOfDay(for: due)) ?? due, precision: .day,
                                  timeZoneIdentifier: tz.identifier)
        let c = try await deadlinesRepo.createCandidate(taskID: taskID, value: value, kind: .due, origin: .deterministicRule, confidence: nil, proposedBy: actor,
                                                        ruleID: ruleID, ruleVersion: "1", at: date)
        try await file.recordDateBasis(caseID: caseID, refID: c.id, taskID: taskID, refKind: "candidate", basis: .target, timeZone: tz.identifier, actor: actor, at: date)
    }

    /// Everything about one action (ACTION-01).
    public func actionDossier(caseID: UUID, taskID: UUID) async throws -> CaseActionDossier {
        try await CaseAccessPolicy.requireRead(file.database, caseID: caseID)
        guard let task = try await tasksRepo.task(id: taskID) else { throw CaseWorkError.notInCase("action") }
        let ledger = try await file.reportLedger(caseID: caseID)
        guard let contract = ledger.contract(taskID) else { throw CaseWorkError.noContract }
        let state = try await file.actionStates(caseID: caseID)[taskID]
            ?? CaseActionState(taskID: taskID, details: nil, assignmentOverride: false, overrideBy: nil, overrideReason: nil, stateReason: nil, stateRemedy: nil,
                               waitingUntil: nil, supersededBy: nil, supersedeReason: nil)
        let links = ledger.workLinks.filter { $0.isActive && $0.workKind == .task && $0.workID == taskID }
        let routing = try await file.routingHistory(caseID: caseID, taskID: taskID).map { (outcome: $0.outcome, assignee: $0.assignee, reason: $0.reason, at: $0.at) }
        return CaseActionDossier(
            task: task, caseID: caseID, contract: contract, state: state,
            servesQuestions: links.filter { $0.targetKind == .allegation && $0.role == .serves }.map(\.targetID),
            raisedFrom: links.filter { $0.role == .raisedFrom },
            children: ledger.contracts.filter { $0.parentTaskID == taskID }.map(\.taskID),
            waitsFor: ledger.dependencies(of: taskID).map(\.dependsOnTaskID),
            assignments: try await file.assignments(caseID: caseID).filter { $0.workKind == .task && $0.workID.lowercased() == taskID.uuidString.lowercased() },
            routing: routing,
            results: try await file.actionResults(caseID: caseID, taskID: taskID),
            reviews: try await file.actionResultReviews(caseID: caseID, taskID: taskID),
            history: try await tasksRepo.reviews(taskID: taskID),
            dates: try await file.actionDates(caseID: caseID, taskID: taskID))
    }

    // MARK: ACTION-05 / ACTION-06

    /// Choose the owner of an action by rule and record why — or leave it in the unassigned queue with the remedy.
    @discardableResult
    public func routeAction(caseID: UUID, taskID: UUID, policyVersion: Int? = nil, actor: String, at date: Date = Date()) async throws -> CaseRoutingDecision {
        try await CaseAccessPolicy.requireChange(file.database, caseID: caseID, actor: actor, .work)
        let ledger = try await file.reportLedger(caseID: caseID)
        guard let contract = ledger.contract(taskID) else { throw CaseWorkError.noContract }
        let state = try await file.actionStates(caseID: caseID)[taskID]
        let capability = state?.details?.requiredCapability
        let assignments = try await file.assignments(caseID: caseID)
        let open = assignments.first { $0.isOpen && $0.workKind == .task && $0.workID.lowercased() == taskID.uuidString.lowercased() }
        let candidates = try await file.routingCandidates(caseID: caseID, capability: capability, on: date)
        let team = try await file.teamMemberships(caseID: caseID)
        var clearOverride = false
        var prefix = ""
        if let open {
            let now = candidates.first { $0.name == open.assignee }
            let invalid: String? = {
                if let now, !now.eligible { return now.reasons.filter { r in ["ended", "Conflict recorded", "unavailable"].contains { r.contains($0) } }.joined(separator: "; ") }
                if now == nil, !team.isEmpty { return "\(open.assignee) is not on the case team" }
                return nil
            }()
            if let invalid, !invalid.isEmpty {
                if state?.assignmentOverride == true {
                    clearOverride = true
                    prefix = "The deliberate assignment to \(open.assignee) no longer holds (\(invalid)). "
                } else {
                    prefix = "\(open.assignee) can no longer take it (\(invalid)). "
                }
                try await file.endAssignment(caseID: caseID, assignmentID: open.id, reason: .released, actor: actor, at: date)
            } else if state?.assignmentOverride == true {
                let d = CaseRoutingDecision(taskID: taskID, outcome: .keptOverride, assignee: open.assignee,
                                            reason: "Kept: \(state?.overrideBy ?? "someone") assigned it deliberately to \(open.assignee)" + (state?.overrideReason.map { " (\($0))" } ?? "") + ".",
                                            remedy: nil)
                try await file.writeRouting(caseID: caseID, taskID: taskID, decision: d, policyVersion: policyVersion, override: nil, clearOverride: false, actor: actor, at: date)
                return d
            } else {
                return CaseRoutingDecision(taskID: taskID, outcome: .alreadyAssigned, assignee: open.assignee, reason: "Already assigned to \(open.assignee).", remedy: nil)
            }
        }
        let workload = Dictionary(grouping: assignments.filter(\.isOpen), by: \.assignee).mapValues(\.count)
        var decision: CaseRoutingDecision
        let eligible = candidates.filter(\.eligible)
        if let designated = CaseFileRepository.blankToNil(contract.responsible),
           eligible.contains(where: { $0.name == designated }) || (capability == nil && (team.isEmpty || candidates.isEmpty)) {
            let reasons = candidates.first { $0.name == designated }?.reasons ?? []
            decision = CaseRoutingDecision(taskID: taskID, outcome: .assigned, assignee: designated,
                                           reason: prefix + "Designated owner on the action (\(designated))" + (reasons.isEmpty ? "." : ": " + reasons.joined(separator: "; ") + "."), remedy: nil)
        } else if let pick = eligible.min(by: { (workload[$0.name] ?? 0, $0.name) < (workload[$1.name] ?? 0, $1.name) }) {
            decision = CaseRoutingDecision(taskID: taskID, outcome: .assigned, assignee: pick.name,
                                           reason: prefix + "Eligible (\(pick.reasons.joined(separator: "; "))) with the least open work (\(workload[pick.name] ?? 0)); ties go alphabetically.",
                                           remedy: nil)
        } else if team.isEmpty, capability == nil,
                  let owner = CaseFileRepository.blankToNil(try await file.profile(caseID: caseID).owner) ?? (actor == CaseAutomationService.actorName ? nil : actor) {
            decision = CaseRoutingDecision(taskID: taskID, outcome: .assigned, assignee: owner,
                                           reason: prefix + "Solo case: every role is bound to \(owner).", remedy: nil)
        } else if team.isEmpty, capability == nil {
            decision = CaseRoutingDecision(taskID: taskID, outcome: .unassigned, assignee: nil,
                                           reason: prefix + "Solo case with no recorded owner, and software is never made the owner.",
                                           remedy: "Record the case owner (or assign someone deliberately).")
        } else {
            let why = candidates.isEmpty ? "Nobody is recorded who could take it" : candidates.map { "\($0.name): \($0.reasons.joined(separator: "; "))" }.joined(separator: " · ")
            let remedy = capability.map { "Record “\($0)” for a team member who has it, assign someone deliberately, or remove the requirement." }
                ?? "Add an available team member, or assign someone deliberately."
            decision = CaseRoutingDecision(taskID: taskID, outcome: .unassigned, assignee: nil, reason: prefix + why, remedy: remedy)
        }
        try await file.writeRouting(caseID: caseID, taskID: taskID, decision: decision, policyVersion: policyVersion, override: nil, clearOverride: clearOverride,
                                    actor: actor, at: date)
        return decision
    }

    /// A deliberate assignment (or delegation/reassignment): the router keeps it until the person changes it or a stated
    /// invalidation occurs.
    @discardableResult
    public func assignActionDeliberately(caseID: UUID, taskID: UUID, to person: String, reason: String, delegatedBy: String? = nil, actor: String,
                                         at date: Date = Date()) async throws -> CaseRoutingDecision {
        try await CaseAccessPolicy.requireChange(file.database, caseID: caseID, actor: actor, .work)
        let to = try CaseFileRepository.clean(person, "Who it is assigned to"), why = try CaseFileRepository.clean(reason, "The reason")
        let label = delegatedBy.map { "Delegated by \($0)" } ?? "Assigned deliberately by \(actor)"
        let d = CaseRoutingDecision(taskID: taskID, outcome: .assigned, assignee: to, reason: "\(label): \(why).", remedy: nil)
        try await file.writeRouting(caseID: caseID, taskID: taskID, decision: d, policyVersion: nil, override: (actor, why), clearOverride: false, actor: actor, at: date)
        return d
    }

    /// The person lets the router choose again.
    public func releaseOverride(caseID: UUID, taskID: UUID, actor: String, at date: Date = Date()) async throws {
        try await CaseAccessPolicy.requireChange(file.database, caseID: caseID, actor: actor, .work)
        let d = CaseRoutingDecision(taskID: taskID, outcome: .keptOverride, assignee: nil, reason: "The deliberate assignment was released by \(actor); routing may choose again.", remedy: nil)
        try await file.writeRouting(caseID: caseID, taskID: taskID, decision: d, policyVersion: nil, override: nil, clearOverride: true, actor: actor, at: date)
    }

    /// Open actions with a contract and nobody assigned, with the latest reason and remedy.
    public func unassignedQueue(caseID: UUID) async throws -> [CaseUnassignedItem] {
        try await CaseAccessPolicy.requireRead(file.database, caseID: caseID)
        let ledger = try await file.reportLedger(caseID: caseID)
        let open = Set(try await file.assignments(caseID: caseID).filter { $0.isOpen && $0.workKind == .task }.map { $0.workID.lowercased() })
        let routing = try await file.routingHistory(caseID: caseID)
        var out: [CaseUnassignedItem] = []
        for c in ledger.contracts {
            guard let t = try await tasksRepo.task(id: c.taskID), ProfessionalTaskStatus.activeWork.contains(t.status) || t.status == .candidate,
                  !open.contains(c.taskID.uuidString.lowercased()) else { continue }
            let last = routing.last { $0.taskID == c.taskID && $0.outcome == "unassigned" }
            out.append(CaseUnassignedItem(taskID: c.taskID, title: t.title, reason: last?.reason ?? "Not routed yet.", remedy: last?.remedy ?? "Route it, or assign someone."))
        }
        return out
    }

    /// Edit an action's title, detail or priority (recorded with the reason in the engine's history and the case log).
    public func editAction(caseID: UUID, taskID: UUID, title: String? = nil, detail: String?? = nil, priority: ProfessionalTaskPriority? = nil,
                           reason: String?, actor: String, at date: Date = Date()) async throws {
        try await CaseAccessPolicy.requireChange(file.database, caseID: caseID, actor: actor, .work)
        guard try await file.linkedTaskIDs(caseID: caseID).contains(taskID) else { throw CaseWorkError.notInCase("action") }
        try await file.requireActing(caseID: caseID, name: actor)
        _ = try await tasksRepo.edit(taskID: taskID, title: title, detail: detail, priority: priority, reviewer: actor, reason: reason, at: date)
        try await file.logAction(caseID: caseID, action: "actionEdited", detail: reason, actor: actor, at: date)
    }

    /// Defer: the action waits until a date, with the reason.
    public func deferAction(caseID: UUID, taskID: UUID, until: Date, reason: String, actor: String, at date: Date = Date()) async throws {
        try await CaseAccessPolicy.requireChange(file.database, caseID: caseID, actor: actor, .work)
        try await file.setActionState(caseID: caseID, taskID: taskID, to: .waiting, reason: reason, remedy: "Resume on \(until.formatted(date: .abbreviated, time: .omitted))",
                                      waitingUntil: until, actor: actor, at: date)
    }

    /// Apply one change to several actions; each action reports its own result (one failing does not stop the others).
    public func bulkActions(caseID: UUID, taskIDs: [UUID], _ op: CaseBulkActionOperation, actor: String, at date: Date = Date()) async -> [CaseBulkItemResult] {
        var out: [CaseBulkItemResult] = []
        for id in taskIDs {
            do {
                switch op {
                case .reassign(let to, let reason): _ = try await assignActionDeliberately(caseID: caseID, taskID: id, to: to, reason: reason, actor: actor, at: date)
                case .deferUntil(let until, let reason): try await deferAction(caseID: caseID, taskID: id, until: until, reason: reason, actor: actor, at: date)
                case .cancel(let reason): try await file.setActionState(caseID: caseID, taskID: id, to: .cancelled, reason: reason, actor: actor, at: date)
                case .setPriority(let p): try await editAction(caseID: caseID, taskID: id, priority: p, reason: "bulk priority change", actor: actor, at: date)
                case .route: _ = try await routeAction(caseID: caseID, taskID: id, actor: actor, at: date)
                }
                out.append(CaseBulkItemResult(taskID: id, succeeded: true, message: "Done"))
            } catch {
                KalsmritikoshLog.app.error("Bulk action change failed for one action: \(error.localizedDescription, privacy: .public)")
                out.append(CaseBulkItemResult(taskID: id, succeeded: false, message: error.localizedDescription))
            }
        }
        return out
    }

    // MARK: ACTION-10 rollup

    /// The parent's children (nil: the mother case's top-level actions), each as recorded.
    public func actionRollup(caseID: UUID, parentTaskID: UUID?) async throws -> CaseActionRollup {
        try await CaseAccessPolicy.requireRead(file.database, caseID: caseID)
        let ledger = try await file.reportLedger(caseID: caseID)
        let states = try await file.actionStates(caseID: caseID)
        let open = Set(try await file.assignments(caseID: caseID).filter { $0.isOpen && $0.workKind == .task }.map { $0.workID.lowercased() })
        let exceptions = try await file.closureExceptions(caseID: caseID).filter { $0.parent == parentTaskID }
        var children: [CaseActionRollup.Child] = []
        for c in ledger.contracts where c.parentTaskID == parentTaskID {
            guard let t = try await tasksRepo.task(id: c.taskID), t.status != .candidate else { continue }
            children.append(.init(taskID: c.taskID, title: t.title, status: t.status, review: c.review, outcome: c.outcome,
                                  required: states[c.taskID]?.details?.requiredForParent ?? true, assigned: open.contains(c.taskID.uuidString.lowercased()),
                                  exception: exceptions.first { $0.child == c.taskID }?.reason))
        }
        let criteria = parentTaskID.flatMap { states[$0]?.details?.closureCriteria }
        return CaseActionRollup(parentTaskID: parentTaskID, children: children, closureCriteria: criteria)
    }

    // MARK: ACTION-11

    /// In a case with no team, the one investigator holds every role; nil when a team is recorded.
    public func soloBinding(caseID: UUID, actor: String) async throws -> CaseSoloBinding? {
        try await CaseAccessPolicy.requireRead(file.database, caseID: caseID)
        guard try await !file.hasTeam(caseID: caseID) else { return nil }
        let person = CaseFileRepository.blankToNil(try await file.profile(caseID: caseID).owner) ?? actor
        let independent = try await file.requiresIndependentReview(caseID: caseID)
        return CaseSoloBinding(person: person, roles: ["Case lead", "Investigator / action owner", "Evidence coordinator", "Reviewer"],
                               note: independent
                               ? "This case's policy requires independent review: results of \(person)'s own work stay unreviewed until another reviewer is recorded."
                               : "No team is recorded, so \(person) holds every role. Reviews of their own work are recorded as self-review and labelled so — no second account is needed or invented.")
    }

    // MARK: ACTION-12

    /// Decide a reopen proposal: reopen the finished action, supersede it with new work (same purpose, deliverable, parent
    /// and questions; the new source as its trigger), or dismiss it — each with the reason.
    @discardableResult
    public func decideReopening(caseID: UUID, proposalID: UUID, _ decision: CaseReopenProposal.Decision, reason: String, actor: String,
                                at date: Date = Date()) async throws -> UUID? {
        try await CaseAccessPolicy.requireChange(file.database, caseID: caseID, actor: actor, .review)
        guard let p = try await file.reopenProposals(caseID: caseID).first(where: { $0.id == proposalID }) else { throw CaseWorkError.notInCase("proposal") }
        guard p.state == .pending else { throw CaseActionWorkError.alreadyDecided }
        switch decision {
        case .dismiss:
            try await file.markReopenProposal(caseID: caseID, id: proposalID, state: .dismissed, reason: reason, newTaskID: nil, reopenTask: nil, actor: actor, at: date)
            return nil
        case .reopen:
            try await file.markReopenProposal(caseID: caseID, id: proposalID, state: .reopened, reason: reason, newTaskID: nil, reopenTask: p.taskID, actor: actor, at: date)
            return p.taskID
        case .supersede:
            let ledger = try await file.reportLedger(caseID: caseID)
            guard let c = ledger.contract(p.taskID), let old = try await tasksRepo.task(id: p.taskID) else { throw CaseWorkError.noContract }
            let questions = ledger.workLinks.filter { $0.isActive && $0.workKind == .task && $0.workID == p.taskID && $0.targetKind == .allegation && $0.role == .serves }.map(\.targetID)
            let newVersion = UUID(uuidString: p.revisionKey)
            let prior = try await file.actionStates(caseID: caseID)[p.taskID]?.details
            let new = try await createTypedAction(
                caseID: caseID,
                ChildAction(title: old.title, purpose: c.purpose, deliverable: c.deliverable, responsible: c.responsible, reviewer: c.reviewer,
                            parentTaskID: c.parentTaskID, servesQuestions: questions),
                details: CaseActionDetails(type: prior?.type ?? .changedEvidenceReview,
                                           trigger: CaseActionTrigger(kind: .reopen, records: ["task:\(p.taskID.uuidString.lowercased())"],
                                                                      sourceRevisions: newVersion.map { [$0] } ?? [], note: reason),
                                           helpers: prior?.helpers ?? [], requiredCapability: prior?.requiredCapability, requiredForParent: prior?.requiredForParent ?? true),
                actor: actor, at: date)
            try await file.supersedeAction(caseID: caseID, taskID: p.taskID, by: new, reason: reason, actor: actor, at: date)
            try await file.markReopenProposal(caseID: caseID, id: proposalID, state: .superseded, reason: reason, newTaskID: new, reopenTask: nil, actor: actor, at: date)
            return new
        }
    }
}
