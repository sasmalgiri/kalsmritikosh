//
//  CaseReports.swift
//  Kalsmritikosh
//
//  Smart-map M1 (docs/IME_Recursive_Case_Map_Feasibility_and_Implementation_Plan_2026-11-08.md §5.1, §6, §17.3;
//  schema v176): supplied reports as canonical case records, their addressable points and qualifications, the
//  links that say where work came from and what it serves, and the child-action contract over the ONE task engine.
//
//  • A report names the exact source version it was read from. An amendment or supplement is a new report naming
//    the one it amends — the first report is never overwritten. A result is a report that answers a child action.
//  • A point is the investigator's statement of what the report says, with its kind, the exact quoted words and
//    their locator (version, block, character span, page/section note) verified through the case's ONE verifier.
//    Storing a point does not make it true; accepting it on review records the investigator's decision, and an
//    accepted point is never changed automatically (the v176 trigger refuses it).
//  • Qualifications (uncertainty, limitation, exclusion, condition) are attached to a point, append-only, and travel
//    with it into every summary of it.
//  • A question raised from a point is an allegation of the case (the case's questions); an action is a case task
//    (ProfessionalTask, user authority) with its contract: parent action (or the mother case), purpose, deliverable,
//    responsible person and reviewer (free text), the review state and the outcome — both separate from the task's
//    status. A completed task leaves its question open. Self-review is recorded as self-review (solo work needs no
//    invented second name). Parent ownership is acyclic.
//  Every write goes through CaseFileRepository's one savepoint with its case_actions row. Nothing here calls a model.
//

import Foundation
import os

// MARK: - Records

public nonisolated enum CaseReportKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case original, amendment, supplement, result
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .original: return "Report"
        case .amendment: return "Amendment"
        case .supplement: return "Supplement"
        case .result: return "Result"
        }
    }
}

/// A supplied report (or a recorded result) — its identity, source and what it says about itself.
public nonisolated struct CaseReport: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let caseID: UUID
    public let title: String
    public let kind: CaseReportKind
    /// The report this one amends or supplements (nil for an original or a result).
    public let amendsReportID: UUID?
    /// The exact source version the report was read from (nil: a result recorded without a document yet).
    public let sourceVersionID: UUID?
    public let producer: String?
    public let author: String?
    public let examinedMaterial: String?
    public let reportDate: Date?
    /// The report's own wording of its date ("14 March 2026", "spring 2026").
    public let reportDateText: String?
    public let methods: String?
    public let limitations: String?
    /// For a result: the child action it answers, and the point that action was raised from.
    public let originTaskID: UUID?
    public let originPointID: UUID?
    public let recordedBy: String
    public let recordedAt: Date
    public let withdrawnBy: String?
    public let withdrawnAt: Date?
    public let withdrawnReason: String?
    /// v177 (ARCH-06): when the report reached the case (receipt), kept apart from its own date and from when it was
    /// entered (`recordedAt`); nil: not recorded — never assumed to be the entry time.
    public var receivedAt: Date? = nil
    public var receivedText: String? = nil
    public var isActive: Bool { withdrawnAt == nil }
}

/// What a supplied report is asked to record when it is added.
public nonisolated struct CaseReportDetails: Sendable, Equatable {
    public var title: String
    public var kind: CaseReportKind = .original
    public var amendsReportID: UUID?
    public var sourceVersionID: UUID?
    public var producer: String?
    public var author: String?
    public var examinedMaterial: String?
    public var reportDate: Date?
    public var reportDateText: String?
    public var methods: String?
    public var limitations: String?
    public var originTaskID: UUID?
    public var originPointID: UUID?
    /// v177 (ARCH-06): when the report was received, and the source's own wording of it.
    public var receivedAt: Date?
    public var receivedText: String?
    public init(title: String, kind: CaseReportKind = .original, amendsReportID: UUID? = nil, sourceVersionID: UUID? = nil, producer: String? = nil,
                author: String? = nil, examinedMaterial: String? = nil, reportDate: Date? = nil, reportDateText: String? = nil, methods: String? = nil,
                limitations: String? = nil, originTaskID: UUID? = nil, originPointID: UUID? = nil) {
        self.title = title; self.kind = kind; self.amendsReportID = amendsReportID; self.sourceVersionID = sourceVersionID; self.producer = producer
        self.author = author; self.examinedMaterial = examinedMaterial; self.reportDate = reportDate; self.reportDateText = reportDateText
        self.methods = methods; self.limitations = limitations; self.originTaskID = originTaskID; self.originPointID = originPointID
    }
}

public nonisolated enum CaseReportPointKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case claim, finding, recommendation, allegation
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .claim: return "Claim"
        case .finding: return "Finding"
        case .recommendation: return "Recommendation"
        case .allegation: return "Allegation"
        }
    }
}

public nonisolated enum CaseReportPointReview: String, Codable, Sendable, CaseIterable {
    case unreviewed, accepted, rejected
    public var label: String {
        switch self {
        case .unreviewed: return "Not reviewed yet"
        case .accepted: return "Accepted on review"
        case .rejected: return "Rejected on review"
        }
    }
}

/// One addressable point of a report.
public nonisolated struct CaseReportPoint: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let caseID: UUID
    public let reportID: UUID
    public let ordinal: Int
    public let kind: CaseReportPointKind
    /// The investigator's statement of the point (what the report says — not that it is true).
    public let statement: String
    /// The exact quoted words, as selected from the source.
    public let quote: String?
    public let sourceVersionID: UUID?
    public let objectID: UUID?
    public let blockID: UUID?
    /// The quoted words' character span inside the block's text (when the block is known).
    public let charStart: Int?
    public let charEnd: Int?
    /// The person's page / section note ("p. 4, §2.1").
    public let locatorNote: String?
    /// "verified", "unverified" or "note" with the reason (the case's one verifier decided it).
    public let supportState: String
    public let supportDetail: String?
    public let review: CaseReportPointReview
    public let reviewedBy: String?
    public let reviewedAt: Date?
    public let recordedBy: String
    public let recordedAt: Date
    public let withdrawnBy: String?
    public let withdrawnAt: Date?
    public let withdrawnReason: String?
    public var isActive: Bool { withdrawnAt == nil }
    public var isVerified: Bool { supportState == "verified" }
    /// v178 (SRC-03) — the qualifiers of the source sentence the quoted words were cut from, what the cut left out, and
    /// how the statement is not supported by the words; nil when no words were quoted (or before v178).
    public var sourceCheck: CasePointSourceCheck? = nil
    /// v178 — the full source sentence when the quoted words are a shorter part of it.
    public var quoteContext: String? = nil
    public var passage: StudioEvidenceRef? {
        guard sourceVersionID != nil || objectID != nil || quote != nil else { return nil }
        return StudioEvidenceRef(sourceVersionID: sourceVersionID, objectID: objectID, blockID: blockID, quote: quote)
    }
    /// "version 1a2b3c4d · passage 5e6f7a8b · characters 12–48 · p. 4" — what locates the words.
    public var locatorText: String {
        var parts: [String] = []
        parts.append(sourceVersionID.map { "version \($0.uuidString.prefix(8))" } ?? "no source version")
        if let blockID { parts.append("passage \(blockID.uuidString.prefix(8))") } else if quote?.isEmpty == false { parts.append("quoted words") } else { parts.append("Position unavailable") }
        if let charStart, let charEnd { parts.append("characters \(charStart)–\(charEnd)") }
        if let n = locatorNote, !n.isEmpty { parts.append(n) }
        return parts.joined(separator: " · ")
    }
}

public nonisolated enum CaseQualificationKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case uncertainty, limitation, exclusion, condition
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .uncertainty: return "Uncertainty"
        case .limitation: return "Limitation"
        case .exclusion: return "Exclusion"
        case .condition: return "Condition"
        }
    }
}

public nonisolated struct CaseReportQualification: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let caseID: UUID
    public let pointID: UUID
    public let kind: CaseQualificationKind
    public let text: String
    public let quote: String?
    public let recordedBy: String
    public let recordedAt: Date
    /// "Condition: only if the seal was intact" — the line that travels with every summary of the point.
    public var line: String { "\(kind.label): \(text)" + (quote.map { " (\u{201C}\($0)\u{201D})" } ?? "") }
}

/// Where work came from and what it serves (v176 case_work_links).
public nonisolated struct CaseWorkLink: Identifiable, Sendable, Equatable, Hashable {
    public enum WorkKind: String, Sendable, CaseIterable { case allegation, task, report }
    public enum TargetKind: String, Sendable, CaseIterable { case point, allegation, hypothesis, report, task }
    public enum Role: String, Sendable, CaseIterable {
        /// The work was raised from the target (a question or action from a point).
        case raisedFrom
        /// The work serves the target (an action for a question or point; one action can serve several).
        case serves
    }
    public let id: UUID
    public let caseID: UUID
    public let workKind: WorkKind
    public let workID: UUID
    public let targetKind: TargetKind
    public let targetID: UUID
    public let role: Role
    public let purpose: String?
    public let createdBy: String
    public let createdAt: Date
    public let withdrawnAt: Date?
    public var isActive: Bool { withdrawnAt == nil }
}

/// The review of a child action's result — separate from the task's status and from its outcome.
public nonisolated enum CaseActionReview: String, Codable, Sendable, CaseIterable {
    case notSubmitted, submitted, returned, accepted
    public var label: String {
        switch self {
        case .notSubmitted: return "Result not submitted"
        case .submitted: return "Result submitted — awaiting review"
        case .returned: return "Returned for more work"
        case .accepted: return "Result accepted"
        }
    }
}

/// What the work found, recorded by a person — completing a task does not answer its question.
public nonisolated enum CaseActionOutcome: String, Codable, Sendable, CaseIterable, Identifiable {
    case notRecorded, answered, discrepancyExplained, contradictionRemains, evidenceUnavailable, noRelevantResult, hypothesisChallenged, furtherWorkNeeded
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .notRecorded: return "No outcome recorded"
        case .answered: return "Question answered"
        case .discrepancyExplained: return "Discrepancy explained"
        case .contradictionRemains: return "Contradiction remains"
        case .evidenceUnavailable: return "Evidence unavailable"
        case .noRelevantResult: return "No relevant result"
        case .hypothesisChallenged: return "Hypothesis challenged"
        case .furtherWorkNeeded: return "Further work needed"
        }
    }
}

/// How a result was reviewed: by someone else, or by the person who did the work (solo — labelled, not refused).
public nonisolated enum CaseReviewKind: String, Codable, Sendable {
    case independent
    case selfReview = "self"
    public var label: String { self == .selfReview ? "Self-review (solo) — reviewed by the person who did the work" : "Independent review" }
}

/// The child-action contract over a case task (v176 case_action_contracts).
public nonisolated struct CaseActionContract: Identifiable, Sendable, Equatable, Hashable {
    public let taskID: UUID
    public let caseID: UUID
    /// The parent action; nil: the mother case itself.
    public let parentTaskID: UUID?
    public let purpose: String
    public let deliverable: String
    public let responsible: String?
    public let reviewer: String?
    public let review: CaseActionReview
    public let reviewKind: CaseReviewKind?
    public let reviewedBy: String?
    public let reviewedAt: Date?
    public let reviewNote: String?
    public let outcome: CaseActionOutcome
    public let outcomeNote: String?
    public let createdBy: String
    public let createdAt: Date
    public let updatedAt: Date
    /// v177 (ARCH-06): who handed the result in and when (receipt of the work), kept apart from its review time.
    public var submittedBy: String? = nil
    public var submittedAt: Date? = nil
    public var id: UUID { taskID }
}

/// Everything v176 holds for one case, read together.
public nonisolated struct CaseReportLedger: Sendable, Equatable {
    public var reports: [CaseReport] = []
    public var points: [CaseReportPoint] = []
    public var qualifications: [CaseReportQualification] = []
    public var workLinks: [CaseWorkLink] = []
    public var contracts: [CaseActionContract] = []
    /// v177 — investigator-placed frame memberships, action dependencies and the case's actor identities.
    public var frameMembers: [CaseFrameMembership] = []
    public var dependencies: [CaseActionDependency] = []
    public var actors: [CaseActor] = []
    /// v179 (GRAPH-09) — recorded same-person / different-people decisions about pairs of case-person rows.
    public var identityDecisions: [CasePersonIdentityDecision] = []
    public init(reports: [CaseReport] = [], points: [CaseReportPoint] = [], qualifications: [CaseReportQualification] = [],
                workLinks: [CaseWorkLink] = [], contracts: [CaseActionContract] = []) {
        self.reports = reports; self.points = points; self.qualifications = qualifications; self.workLinks = workLinks; self.contracts = contracts
    }
    public func report(_ id: UUID) -> CaseReport? { reports.first { $0.id == id } }
    public func point(_ id: UUID) -> CaseReportPoint? { points.first { $0.id == id } }
    public func contract(_ taskID: UUID) -> CaseActionContract? { contracts.first { $0.taskID == taskID } }
    public func qualifications(of point: UUID) -> [CaseReportQualification] { qualifications.filter { $0.pointID == point } }
}

public nonisolated enum CaseWorkError: Error, Equatable, LocalizedError {
    case notInCase(String)
    case sourceNotInCase
    case parentCycle
    case acceptedPointLocked
    case notSubmitted
    case noContract
    case withdrawn(String)

    public var errorDescription: String? {
        switch self {
        case .notInCase(let what): return "That \(what) is not part of this case."
        case .sourceNotInCase: return "The report's document is not in this case's scope. Add it to the case first; the scope is never widened here."
        case .parentCycle: return "That parent would make the action its own ancestor. Choose another parent action."
        case .acceptedPointLocked: return "This point was accepted on review and is not changed. Record a new point, or reopen its review first."
        case .notSubmitted: return "Submit the result before it is reviewed."
        case .noContract: return "This task has no action contract (purpose and deliverable). Record them first."
        case .withdrawn(let what): return "That \(what) was withdrawn."
        }
    }
}

// MARK: - Persistence (the case file repository's one savepoint)

nonisolated extension CaseRecordCapture {
    public static func report(_ id: UUID) -> CaseRecordCapture { CaseRecordCapture(kind: "report", table: "case_reports", recordID: id) }
    public static func reportPoint(_ id: UUID) -> CaseRecordCapture { CaseRecordCapture(kind: "reportPoint", table: "case_report_points", recordID: id) }
    public static func actionContract(_ id: UUID) -> CaseRecordCapture { CaseRecordCapture(kind: "actionContract", table: "case_action_contracts", keyColumn: "task_id", recordID: id) }
}

extension CaseFileRepository {

    /// Everything v176 holds for the case.
    public func reportLedger(caseID: UUID) async throws -> CaseReportLedger {
        let c: [SQLValue] = [.uuid(caseID)]
        var ledger = CaseReportLedger()
        ledger.reports = try await database.query("""
            SELECT id, case_id, title, report_kind, amends_report_id, source_version_id, producer, author, examined_material, report_date,
                   report_date_text, methods, limitations, origin_task_id, origin_point_id, recorded_by, recorded_at, withdrawn_by, withdrawn_at, withdrawn_reason,
                   received_at, received_text
            FROM case_reports WHERE case_id = ? ORDER BY recorded_at ASC, rowid ASC;
            """, c).compactMap { r in
            guard let id = r.uuid(0), let cid = r.uuid(1), let title = r.string(2), let kind = r.string(3).flatMap(CaseReportKind.init(rawValue:)),
                  let by = r.string(15), let at = r.date(16) else { return nil }
            return CaseReport(id: id, caseID: cid, title: title, kind: kind, amendsReportID: r.uuid(4), sourceVersionID: r.uuid(5), producer: r.string(6),
                              author: r.string(7), examinedMaterial: r.string(8), reportDate: r.date(9), reportDateText: r.string(10), methods: r.string(11),
                              limitations: r.string(12), originTaskID: r.uuid(13), originPointID: r.uuid(14), recordedBy: by, recordedAt: at,
                              withdrawnBy: r.string(17), withdrawnAt: r.date(18), withdrawnReason: r.string(19), receivedAt: r.date(20), receivedText: r.string(21))
        }
        ledger.points = try await database.query("""
            SELECT id, case_id, report_id, ordinal, point_kind, statement, quote, source_version_id, object_id, block_id, char_start, char_end,
                   locator_note, support_state, support_detail, review_state, reviewed_by, reviewed_at, recorded_by, recorded_at,
                   withdrawn_by, withdrawn_at, withdrawn_reason, qualifiers_json, quote_context
            FROM case_report_points WHERE case_id = ? ORDER BY report_id ASC, ordinal ASC, recorded_at ASC, rowid ASC;
            """, c).compactMap { r in
            guard let id = r.uuid(0), let cid = r.uuid(1), let rid = r.uuid(2), let kind = r.string(4).flatMap(CaseReportPointKind.init(rawValue:)),
                  let statement = r.string(5), let support = r.string(13), let review = r.string(15).flatMap(CaseReportPointReview.init(rawValue:)),
                  let by = r.string(18), let at = r.date(19) else { return nil }
            return CaseReportPoint(id: id, caseID: cid, reportID: rid, ordinal: Int(r.int(3) ?? 0), kind: kind, statement: statement, quote: r.string(6),
                                   sourceVersionID: r.uuid(7), objectID: r.uuid(8), blockID: r.uuid(9), charStart: r.int(10).map(Int.init),
                                   charEnd: r.int(11).map(Int.init), locatorNote: r.string(12), supportState: support, supportDetail: r.string(14),
                                   review: review, reviewedBy: r.string(16), reviewedAt: r.date(17), recordedBy: by, recordedAt: at,
                                   withdrawnBy: r.string(20), withdrawnAt: r.date(21), withdrawnReason: r.string(22),
                                   sourceCheck: CasePointSourceCheck.decode(r.string(23)), quoteContext: r.string(24))
        }
        ledger.qualifications = try await database.query("""
            SELECT id, case_id, point_id, qualification_kind, text, quote, recorded_by, recorded_at
            FROM case_report_qualifications WHERE case_id = ? ORDER BY recorded_at ASC, rowid ASC;
            """, c).compactMap { r in
            guard let id = r.uuid(0), let cid = r.uuid(1), let pid = r.uuid(2), let kind = r.string(3).flatMap(CaseQualificationKind.init(rawValue:)),
                  let text = r.string(4), let by = r.string(6), let at = r.date(7) else { return nil }
            return CaseReportQualification(id: id, caseID: cid, pointID: pid, kind: kind, text: text, quote: r.string(5), recordedBy: by, recordedAt: at)
        }
        ledger.workLinks = try await database.query("""
            SELECT id, case_id, work_kind, work_id, target_kind, target_id, role, purpose, created_by, created_at, withdrawn_at
            FROM case_work_links WHERE case_id = ? ORDER BY created_at ASC, rowid ASC;
            """, c).compactMap { r in
            guard let id = r.uuid(0), let cid = r.uuid(1), let wk = r.string(2).flatMap(CaseWorkLink.WorkKind.init(rawValue:)), let wid = r.uuid(3),
                  let tk = r.string(4).flatMap(CaseWorkLink.TargetKind.init(rawValue:)), let tid = r.uuid(5),
                  let role = r.string(6).flatMap(CaseWorkLink.Role.init(rawValue:)), let by = r.string(8), let at = r.date(9) else { return nil }
            return CaseWorkLink(id: id, caseID: cid, workKind: wk, workID: wid, targetKind: tk, targetID: tid, role: role, purpose: r.string(7),
                                createdBy: by, createdAt: at, withdrawnAt: r.date(10))
        }
        ledger.contracts = try await database.query("""
            SELECT task_id, case_id, parent_task_id, purpose, deliverable, responsible, reviewer, review_state, review_kind, reviewed_by, reviewed_at,
                   review_note, outcome, outcome_note, created_by, created_at, updated_at, submitted_by, submitted_at
            FROM case_action_contracts WHERE case_id = ? ORDER BY created_at ASC, rowid ASC;
            """, c).compactMap { r in
            guard let tid = r.uuid(0), let cid = r.uuid(1), let purpose = r.string(3), let deliverable = r.string(4),
                  let review = r.string(7).flatMap(CaseActionReview.init(rawValue:)), let outcome = r.string(12).flatMap(CaseActionOutcome.init(rawValue:)),
                  let by = r.string(14), let at = r.date(15), let up = r.date(16) else { return nil }
            return CaseActionContract(taskID: tid, caseID: cid, parentTaskID: r.uuid(2), purpose: purpose, deliverable: deliverable, responsible: r.string(5),
                                      reviewer: r.string(6), review: review, reviewKind: r.string(8).flatMap(CaseReviewKind.init(rawValue:)),
                                      reviewedBy: r.string(9), reviewedAt: r.date(10), reviewNote: r.string(11), outcome: outcome, outcomeNote: r.string(13),
                                      createdBy: by, createdAt: at, updatedAt: up, submittedBy: r.string(17), submittedAt: r.date(18))
        }
        try await readContracts(caseID: caseID, into: &ledger)
        return ledger
    }

    // MARK: Reports

    /// Record a supplied report (or a result). The source version must be in the case's scope; an amendment or
    /// supplement names a report of this case; a result names a task of this case.
    @discardableResult
    public func addReport(caseID: UUID, _ d: CaseReportDetails, actor: String, at date: Date = Date()) async throws -> UUID {
        let title = try Self.clean(d.title, "The report's title")
        let who = try Self.clean(actor, "Actor")
        let id = UUID()
        try await write("cf_rep", caseID: caseID, actor: who, action: d.kind == .result ? "resultRecorded" : "reportAdded", detail: title, at: date,
                        capture: .report(id)) { db in
            if let v = d.sourceVersionID, !(try Self.versionInCase(db, v, caseID: caseID)) { throw CaseWorkError.sourceNotInCase }
            if let a = d.amendsReportID, try db.query("SELECT 1 FROM case_reports WHERE id = ? AND case_id = ?;", [.uuid(a), .uuid(caseID)]).isEmpty {
                throw CaseWorkError.notInCase("report")
            }
            if let t = d.originTaskID, !(try Self.taskInCase(db, t, caseID: caseID)) { throw CaseWorkError.notInCase("action") }
            if let p = d.originPointID, try db.query("SELECT 1 FROM case_report_points WHERE id = ? AND case_id = ?;", [.uuid(p), .uuid(caseID)]).isEmpty {
                throw CaseWorkError.notInCase("point")
            }
            try db.exec("""
                INSERT INTO case_reports (id, case_id, title, report_kind, amends_report_id, source_version_id, producer, author, examined_material,
                    report_date, report_date_text, methods, limitations, origin_task_id, origin_point_id, recorded_by, recorded_at, received_at, received_text)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .text(title), .text(d.kind.rawValue), d.amendsReportID.map { .uuid($0) } ?? .null,
                      d.sourceVersionID.map { .uuid($0) } ?? .null, .optionalText(Self.blankToNil(d.producer)), .optionalText(Self.blankToNil(d.author)),
                      .optionalText(Self.blankToNil(d.examinedMaterial)), .optionalDate(d.reportDate), .optionalText(Self.blankToNil(d.reportDateText)),
                      .optionalText(Self.blankToNil(d.methods)), .optionalText(Self.blankToNil(d.limitations)), d.originTaskID.map { .uuid($0) } ?? .null,
                      d.originPointID.map { .uuid($0) } ?? .null, .text(who), .date(date), .optionalDate(d.receivedAt),
                      .optionalText(Self.blankToNil(d.receivedText))])
        }
        return id
    }

    public func withdrawReport(caseID: UUID, id: UUID, reason: String, actor: String, at date: Date = Date()) async throws {
        let why = try Self.clean(reason, "The reason")
        let who = try Self.clean(actor, "Actor")
        try await write("cf_repwd", caseID: caseID, actor: who, action: "reportWithdrawn", detail: why, at: date, capture: .report(id)) { db in
            guard try !db.query("SELECT 1 FROM case_reports WHERE id = ? AND case_id = ? AND withdrawn_at IS NULL;", [.uuid(id), .uuid(caseID)]).isEmpty else {
                throw CaseWorkError.notInCase("report")
            }
            try db.exec("UPDATE case_reports SET withdrawn_by = ?, withdrawn_at = ?, withdrawn_reason = ? WHERE id = ?;", [.text(who), .date(date), .text(why), .uuid(id)])
        }
    }

    // MARK: Points and qualifications

    /// Store a point with its passage as the case's verifier resolved it (`support`). The character span is read
    /// from the pinned block's text inside the write.
    @discardableResult
    public func addPoint(caseID: UUID, reportID: UUID, kind: CaseReportPointKind, statement: String, passage: StudioEvidenceRef?,
                         support: CaseEvidenceSupport, locatorNote: String?, actor: String, at date: Date = Date()) async throws -> UUID {
        let text = try Self.clean(statement, "The point")
        let who = try Self.clean(actor, "Actor")
        let id = UUID()
        let quote = Self.blankToNil(passage?.quote)
        try await write("cf_pt", caseID: caseID, actor: who, action: "pointAdded", detail: text, at: date, capture: .reportPoint(id)) { db in
            guard try !db.query("SELECT 1 FROM case_reports WHERE id = ? AND case_id = ? AND withdrawn_at IS NULL;", [.uuid(reportID), .uuid(caseID)]).isEmpty else {
                throw CaseWorkError.notInCase("report")
            }
            var start: Int?, end: Int?
            var sourceText: String?
            if let block = passage?.blockID, let quote,
               let raw = try db.query("SELECT raw_text FROM evidence_blocks WHERE id = ? LIMIT 1;", [.uuid(block)]).first?.string(0) {
                sourceText = raw
                if let r = raw.range(of: quote) {
                    start = raw.distance(from: raw.startIndex, to: r.lowerBound)
                    end = raw.distance(from: raw.startIndex, to: r.upperBound)
                }
            } else if quote != nil, let version = passage?.sourceVersionID {
                // Words across several passages of the version: their sentence is read from the version's text in order.
                let rows = try db.query("""
                    SELECT raw_text FROM evidence_blocks WHERE source_version_id = ? AND superseded_by_run IS NULL ORDER BY ordinal LIMIT 20000;
                    """, [.uuid(version)])
                if !rows.isEmpty { sourceText = rows.compactMap { $0.string(0) }.joined(separator: "\n") }
            }
            // SRC-03 — what the quoted words keep of their source sentence (negation, attribution, uncertainty, plans,
            // conditions, date) and whether the statement is supported by them; stored once, never changed.
            let check = CasePointSourceCheck.make(statement: text, quote: quote, sourceText: sourceText)
            let ordinal = (try db.query("SELECT COALESCE(MAX(ordinal), 0) + 1 FROM case_report_points WHERE report_id = ?;", [.uuid(reportID)]).first?.int(0)) ?? 1
            try db.exec("""
                INSERT INTO case_report_points (id, case_id, report_id, ordinal, point_kind, statement, quote, source_version_id, object_id, block_id,
                    char_start, char_end, locator_note, support_state, support_detail, review_state, recorded_by, recorded_at, qualifiers_json, quote_context)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?, 'unreviewed', ?, ?, ?, ?);
                """, [.uuid(id), .uuid(caseID), .uuid(reportID), .integer(ordinal), .text(kind.rawValue), .text(text), .optionalText(quote),
                      passage?.sourceVersionID.map { .uuid($0) } ?? .null, passage?.objectID.map { .uuid($0) } ?? .null, passage?.blockID.map { .uuid($0) } ?? .null,
                      start.map { .integer(Int64($0)) } ?? .null, end.map { .integer(Int64($0)) } ?? .null, .optionalText(Self.blankToNil(locatorNote)),
                      .text(support.stored), .optionalText(support.detail), .text(who), .date(date),
                      .optionalText(check?.json), .optionalText(check?.context.sentence)])
        }
        return id
    }

    /// Accept, reject or reopen the review of a point — the investigator's decision, kept with before/after copies.
    public func reviewPoint(caseID: UUID, pointID: UUID, to state: CaseReportPointReview, actor: String, at date: Date = Date()) async throws {
        let who = try Self.clean(actor, "Actor")
        try await write("cf_ptrv", caseID: caseID, actor: who, action: "pointReviewed", detail: state.rawValue, at: date, capture: .reportPoint(pointID)) { db in
            guard try !db.query("SELECT 1 FROM case_report_points WHERE id = ? AND case_id = ?;", [.uuid(pointID), .uuid(caseID)]).isEmpty else {
                throw CaseWorkError.notInCase("point")
            }
            try db.exec("UPDATE case_report_points SET review_state = ?, reviewed_by = ?, reviewed_at = ? WHERE id = ?;",
                        state == .unreviewed ? [.text(state.rawValue), .null, .null, .uuid(pointID)] : [.text(state.rawValue), .text(who), .date(date), .uuid(pointID)])
        }
    }

    /// Change a point's wording. An accepted point is refused (its review must be reopened first).
    public func restatePoint(caseID: UUID, pointID: UUID, statement: String, actor: String, at date: Date = Date()) async throws {
        let text = try Self.clean(statement, "The point")
        let who = try Self.clean(actor, "Actor")
        try await write("cf_ptre", caseID: caseID, actor: who, action: "pointRestated", detail: text, at: date, capture: .reportPoint(pointID)) { db in
            guard let state = try db.query("SELECT review_state FROM case_report_points WHERE id = ? AND case_id = ?;", [.uuid(pointID), .uuid(caseID)]).first?.string(0) else {
                throw CaseWorkError.notInCase("point")
            }
            guard state != CaseReportPointReview.accepted.rawValue else { throw CaseWorkError.acceptedPointLocked }
            try db.exec("UPDATE case_report_points SET statement = ? WHERE id = ?;", [.text(text), .uuid(pointID)])
        }
    }

    @discardableResult
    public func addQualification(caseID: UUID, pointID: UUID, kind: CaseQualificationKind, text: String, quote: String?,
                                 actor: String, at date: Date = Date()) async throws -> UUID {
        let clean = try Self.clean(text, "The qualification")
        let who = try Self.clean(actor, "Actor")
        let id = UUID()
        try await write("cf_ptq", caseID: caseID, actor: who, action: "qualificationAdded", detail: clean, at: date) { db in
            guard try !db.query("SELECT 1 FROM case_report_points WHERE id = ? AND case_id = ?;", [.uuid(pointID), .uuid(caseID)]).isEmpty else {
                throw CaseWorkError.notInCase("point")
            }
            try db.exec("""
                INSERT INTO case_report_qualifications (id, case_id, point_id, qualification_kind, text, quote, recorded_by, recorded_at) VALUES (?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .uuid(pointID), .text(kind.rawValue), .text(clean), .optionalText(Self.blankToNil(quote)), .text(who), .date(date)])
        }
        return id
    }

    // MARK: Work links

    /// Link work to what it came from or serves. Both ends must be records of this case.
    @discardableResult
    public func addWorkLink(caseID: UUID, work: CaseWorkLink.WorkKind, workID: UUID, target: CaseWorkLink.TargetKind, targetID: UUID,
                            role: CaseWorkLink.Role, purpose: String?, actor: String, at date: Date = Date()) async throws -> UUID {
        let who = try Self.clean(actor, "Actor")
        let id = UUID()
        try await write("cf_wl", caseID: caseID, actor: who, action: "workLinked", detail: "\(work.rawValue) \(role.rawValue) \(target.rawValue)", at: date) { db in
            guard try Self.workEnd(db, work.rawValue, workID, caseID: caseID) else { throw CaseWorkError.notInCase(work.rawValue) }
            guard try Self.workEnd(db, target.rawValue, targetID, caseID: caseID) else { throw CaseWorkError.notInCase(target.rawValue) }
            // The same active link is not recorded twice (one action serving a question once).
            guard try db.query("""
                SELECT 1 FROM case_work_links WHERE case_id = ? AND work_kind = ? AND work_id = ? AND target_kind = ? AND target_id = ? AND role = ? AND withdrawn_at IS NULL;
                """, [.uuid(caseID), .text(work.rawValue), .uuid(workID), .text(target.rawValue), .uuid(targetID), .text(role.rawValue)]).isEmpty else { return }
            try db.exec("""
                INSERT INTO case_work_links (id, case_id, work_kind, work_id, target_kind, target_id, role, purpose, created_by, created_at) VALUES (?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .text(work.rawValue), .uuid(workID), .text(target.rawValue), .uuid(targetID), .text(role.rawValue),
                      .optionalText(Self.blankToNil(purpose)), .text(who), .date(date)])
        }
        return id
    }

    // MARK: Action contracts

    /// Record the contract of a case task. The parent (another action of this case) must not make it its own ancestor.
    public func saveContract(caseID: UUID, taskID: UUID, parentTaskID: UUID?, purpose: String, deliverable: String, responsible: String?,
                             reviewer: String?, actor: String, at date: Date = Date()) async throws {
        let p = try Self.clean(purpose, "The purpose")
        let d = try Self.clean(deliverable, "The expected result")
        let who = try Self.clean(actor, "Actor")
        try await write("cf_ac", caseID: caseID, actor: who, action: "actionContract", detail: p, at: date, capture: .actionContract(taskID)) { db in
            guard try Self.taskInCase(db, taskID, caseID: caseID) else { throw CaseWorkError.notInCase("action") }
            if let parentTaskID {
                guard try Self.taskInCase(db, parentTaskID, caseID: caseID) else { throw CaseWorkError.notInCase("parent action") }
                if try Self.wouldCycle(db, taskID: taskID, parent: parentTaskID) { throw CaseWorkError.parentCycle }
            }
            try db.exec("""
                INSERT INTO case_action_contracts (task_id, case_id, parent_task_id, purpose, deliverable, responsible, reviewer, created_by, created_at, updated_at)
                VALUES (?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(task_id) DO UPDATE SET parent_task_id = excluded.parent_task_id, purpose = excluded.purpose, deliverable = excluded.deliverable,
                    responsible = excluded.responsible, reviewer = excluded.reviewer, updated_at = excluded.updated_at;
                """, [.uuid(taskID), .uuid(caseID), parentTaskID.map { .uuid($0) } ?? .null, .text(p), .text(d), .optionalText(Self.blankToNil(responsible)),
                      .optionalText(Self.blankToNil(reviewer)), .text(who), .date(date), .date(date)])
        }
    }

    /// Submit the result of an action for review (its task status is not changed).
    public func submitAction(caseID: UUID, taskID: UUID, note: String?, actor: String, at date: Date = Date()) async throws {
        let who = try Self.clean(actor, "Actor")
        try await write("cf_acs", caseID: caseID, actor: who, action: "actionSubmitted", detail: note, at: date, capture: .actionContract(taskID)) { db in
            guard try !db.query("SELECT 1 FROM case_action_contracts WHERE task_id = ? AND case_id = ?;", [.uuid(taskID), .uuid(caseID)]).isEmpty else {
                throw CaseWorkError.noContract
            }
            try db.exec("UPDATE case_action_contracts SET review_state = 'submitted', review_kind = NULL, reviewed_by = NULL, reviewed_at = NULL, review_note = ?, updated_at = ?, submitted_by = ?, submitted_at = ? WHERE task_id = ?;",
                        [.optionalText(Self.blankToNil(note)), .date(date), .text(who), .date(date), .uuid(taskID)])
        }
    }

    /// Accept or return a submitted result. When the reviewer is the person who did the work (the responsible
    /// person, else who created the action), it is recorded as self-review — never refused, never disguised.
    @discardableResult
    public func reviewAction(caseID: UUID, taskID: UUID, accept: Bool, note: String?, actor: String, at date: Date = Date()) async throws -> CaseReviewKind {
        let who = try Self.clean(actor, "Actor")
        let box = ReviewKindBox()
        try await write("cf_acr", caseID: caseID, actor: who, action: accept ? "actionAccepted" : "actionReturned", detail: note, at: date,
                        capture: .actionContract(taskID)) { db in
            guard let r = try db.query("SELECT review_state, responsible, created_by FROM case_action_contracts WHERE task_id = ? AND case_id = ?;",
                                       [.uuid(taskID), .uuid(caseID)]).first else { throw CaseWorkError.noContract }
            guard r.string(0) == CaseActionReview.submitted.rawValue else { throw CaseWorkError.notSubmitted }
            let doer = Self.blankToNil(r.string(1)) ?? r.string(2) ?? ""
            let kind: CaseReviewKind = CaseConflictMatcher.normalise(doer) == CaseConflictMatcher.normalise(who) ? .selfReview : .independent
            box.kind = kind
            try db.exec("UPDATE case_action_contracts SET review_state = ?, review_kind = ?, reviewed_by = ?, reviewed_at = ?, review_note = ?, updated_at = ? WHERE task_id = ?;",
                        [.text(accept ? CaseActionReview.accepted.rawValue : CaseActionReview.returned.rawValue), .text(kind.rawValue), .text(who), .date(date),
                         .optionalText(Self.blankToNil(note)), .date(date), .uuid(taskID)])
        }
        return box.kind
    }

    /// Record what the work found. Nothing else changes: the question it serves keeps its own disposition.
    public func recordOutcome(caseID: UUID, taskID: UUID, outcome: CaseActionOutcome, note: String?, actor: String, at date: Date = Date()) async throws {
        let who = try Self.clean(actor, "Actor")
        try await write("cf_aco", caseID: caseID, actor: who, action: "actionOutcome", detail: outcome.rawValue, at: date, capture: .actionContract(taskID)) { db in
            guard try !db.query("SELECT 1 FROM case_action_contracts WHERE task_id = ? AND case_id = ?;", [.uuid(taskID), .uuid(caseID)]).isEmpty else {
                throw CaseWorkError.noContract
            }
            try db.exec("UPDATE case_action_contracts SET outcome = ?, outcome_note = ?, updated_at = ? WHERE task_id = ?;",
                        [.text(outcome.rawValue), .optionalText(Self.blankToNil(note)), .date(date), .uuid(taskID)])
        }
    }

    // MARK: Checks inside the write

    static func versionInCase(_ db: isolated Database, _ version: UUID, caseID: UUID) throws -> Bool {
        try !db.query("""
            SELECT 1 FROM investigation_case_sources s WHERE s.case_id = ? AND s.in_scope = 1
              AND (s.source_ref IN (?, ?, ?) OR s.source_ref IN (SELECT logical_source_id FROM source_versions WHERE id IN (?, ?))) LIMIT 1;
            """, [.uuid(caseID), .text(version.uuidString), .text(version.uuidString.lowercased()), .text(version.uuidString.uppercased()),
                  .text(version.uuidString), .text(version.uuidString.lowercased())]).isEmpty
    }

    static func taskInCase(_ db: isolated Database, _ task: UUID, caseID: UUID) throws -> Bool {
        try !db.query("SELECT 1 FROM case_task_links WHERE case_id = ? AND task_id IN (?, ?) LIMIT 1;",
                      [.uuid(caseID), .text(task.uuidString), .text(task.uuidString.lowercased())]).isEmpty
    }

    /// One end of a work link: a record of this case.
    static func workEnd(_ db: isolated Database, _ kind: String, _ id: UUID, caseID: UUID) throws -> Bool {
        let b: [SQLValue] = [.uuid(id), .uuid(caseID)]
        switch kind {
        case "allegation": return try !db.query("SELECT 1 FROM case_allegations WHERE id = ? AND case_id = ?;", b).isEmpty
        case "point": return try !db.query("SELECT 1 FROM case_report_points WHERE id = ? AND case_id = ? AND withdrawn_at IS NULL;", b).isEmpty
        case "report": return try !db.query("SELECT 1 FROM case_reports WHERE id = ? AND case_id = ? AND withdrawn_at IS NULL;", b).isEmpty
        case "hypothesis": return try !db.query("SELECT 1 FROM investigation_hypotheses WHERE id = ? AND case_id = ?;", b).isEmpty
        case "task": return try taskInCase(db, id, caseID: caseID)
        default: return false
        }
    }

    /// Would making `parent` the parent of `taskID` put `taskID` among its own ancestors? Walks the parent chain
    /// (cycle-safe: stops at any action seen twice).
    static func wouldCycle(_ db: isolated Database, taskID: UUID, parent: UUID) throws -> Bool {
        var seen = Set<UUID>()
        var current: UUID? = parent
        while let c = current {
            if c == taskID { return true }
            guard seen.insert(c).inserted else { return true }
            current = try db.query("SELECT parent_task_id FROM case_action_contracts WHERE task_id IN (?, ?);",
                                   [.text(c.uuidString), .text(c.uuidString.lowercased())]).first?.uuid(0)
        }
        return false
    }
}

/// Carries the review kind out of the write's closure.
private nonisolated final class ReviewKindBox: @unchecked Sendable { var kind: CaseReviewKind = .independent }

// MARK: - The work flows over the existing services

extension CaseFileService {

    /// "Add point": the passage is verified against the report's own source version by the case's one verifier;
    /// the quote is pinned to its block where it is in exactly one place. An unverified point is still stored,
    /// labelled unverified (the person may fix it).
    @discardableResult
    public func addPoint(caseID: UUID, reportID: UUID, kind: CaseReportPointKind, statement: String, quote: String?,
                         locatorNote: String? = nil, actor: String, at date: Date = Date()) async throws -> UUID {
        let ledger = try await file.reportLedger(caseID: caseID)
        guard let report = ledger.report(reportID) else { throw CaseWorkError.notInCase("report") }
        let words = quote?.trimmingCharacters(in: .whitespacesAndNewlines)
        var passage: StudioEvidenceRef?
        var support: CaseEvidenceSupport = .unverified("no passage quoted — the point is the investigator's reading of the report")
        if let version = report.sourceVersionID, let words, !words.isEmpty {
            let v = await verifier.verify(reference: version.uuidString, passage: StudioEvidenceRef(sourceVersionID: version, quote: words), caseID: caseID)
            passage = v.passage ?? StudioEvidenceRef(sourceVersionID: version, quote: words)
            support = v.support
        } else if let words, !words.isEmpty {
            passage = StudioEvidenceRef(quote: words)
            support = .unverified("the report has no source document in the case")
        }
        return try await file.addPoint(caseID: caseID, reportID: reportID, kind: kind, statement: statement, passage: passage, support: support,
                                       locatorNote: locatorNote, actor: actor, at: date)
    }

    /// "Ask a question about this point": a new question of the case (an allegation, open), linked to the point.
    @discardableResult
    public func raiseQuestion(caseID: UUID, fromPoint pointID: UUID, text: String, actor: String, at date: Date = Date()) async throws -> UUID {
        guard try await file.reportLedger(caseID: caseID).point(pointID) != nil else { throw CaseWorkError.notInCase("point") }
        let question = try await file.addAllegation(caseID: caseID, text: text, actor: actor, at: date)
        try await file.addWorkLink(caseID: caseID, work: .allegation, workID: question, target: .point, targetID: pointID, role: .raisedFrom,
                                   purpose: nil, actor: actor, at: date)
        return question
    }

    /// What a new child action needs.
    public nonisolated struct ChildAction: Sendable {
        public var title: String
        public var purpose: String
        public var deliverable: String
        public var responsible: String?
        public var reviewer: String?
        /// The parent action; nil: the mother case.
        public var parentTaskID: UUID?
        /// The point it was raised from (its frame), if any.
        public var fromPoint: UUID?
        /// The questions (allegations) it serves; one action can serve several.
        public var servesQuestions: [UUID] = []
        public var due: Date?
        public init(title: String, purpose: String, deliverable: String, responsible: String? = nil, reviewer: String? = nil, parentTaskID: UUID? = nil,
                    fromPoint: UUID? = nil, servesQuestions: [UUID] = [], due: Date? = nil) {
            self.title = title; self.purpose = purpose; self.deliverable = deliverable; self.responsible = responsible; self.reviewer = reviewer
            self.parentTaskID = parentTaskID; self.fromPoint = fromPoint; self.servesQuestions = servesQuestions; self.due = due
        }
    }

    /// "Create action": a case task (the existing engine, user authority) with its contract and links. If the
    /// contract cannot be recorded, the new task is cancelled with the reason — no untraceable task row is left open.
    @discardableResult
    public func createAction(caseID: UUID, _ a: ChildAction, actor: String, at date: Date = Date()) async throws -> UUID {
        guard let header = try await caseHeader(caseID) else { throw CaseFileError.caseNotFound(caseID) }
        _ = try CaseFileRepository.clean(a.purpose, "The purpose")
        _ = try CaseFileRepository.clean(a.deliverable, "The expected result")
        let task = try await addTask(caseID: caseID, workspaceID: header.workspaceID, title: a.title, detail: a.purpose, type: .action,
                                     assignee: a.responsible, due: a.due, actor: actor, at: date)
        do {
            try await file.saveContract(caseID: caseID, taskID: task, parentTaskID: a.parentTaskID, purpose: a.purpose, deliverable: a.deliverable,
                                        responsible: a.responsible, reviewer: a.reviewer, actor: actor, at: date)
            if let p = a.fromPoint {
                try await file.addWorkLink(caseID: caseID, work: .task, workID: task, target: .point, targetID: p, role: .raisedFrom, purpose: a.purpose, actor: actor, at: date)
            }
            for q in a.servesQuestions {
                try await file.addWorkLink(caseID: caseID, work: .task, workID: task, target: .allegation, targetID: q, role: .serves, purpose: a.purpose, actor: actor, at: date)
            }
        } catch {
            KalsmritikoshLog.app.error("Child action contract not recorded; cancelling the new task: \(error.localizedDescription, privacy: .public)")
            do { try await setTaskStatus(caseID: caseID, taskID: task, to: .cancelled, actor: actor, at: date) } catch {
                KalsmritikoshLog.app.error("The new task could not be cancelled: \(error.localizedDescription, privacy: .public)")
            }
            throw error
        }
        return task
    }

    /// "Record result": a result report answering the action (with its own points to follow), linked to the point the
    /// action came from. The action's status, its question and every accepted point are left exactly as they were.
    @discardableResult
    public func recordResult(caseID: UUID, taskID: UUID, title: String, sourceVersionID: UUID? = nil, producer: String? = nil, author: String? = nil,
                             reportDate: Date? = nil, reportDateText: String? = nil, methods: String? = nil, limitations: String? = nil,
                             actor: String, at date: Date = Date()) async throws -> UUID {
        let ledger = try await file.reportLedger(caseID: caseID)
        guard ledger.contract(taskID) != nil else { throw CaseWorkError.noContract }
        let fromPoint = ledger.workLinks.first { $0.isActive && $0.workKind == .task && $0.workID == taskID && $0.targetKind == .point && $0.role == .raisedFrom }?.targetID
        return try await file.addReport(caseID: caseID, CaseReportDetails(title: title, kind: .result, sourceVersionID: sourceVersionID, producer: producer,
                                                                          author: author ?? actor, reportDate: reportDate, reportDateText: reportDateText,
                                                                          methods: methods, limitations: limitations, originTaskID: taskID, originPointID: fromPoint),
                                        actor: actor, at: date)
    }
}
