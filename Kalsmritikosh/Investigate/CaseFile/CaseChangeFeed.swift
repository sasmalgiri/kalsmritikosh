//
//  CaseChangeFeed.swift
//  Kalsmritikosh
//
//  Living case map, M6 (docs/IME_Living_Case_Map_Implementation_Plan_2026-11-06.md §6.3): what changed in ONE
//  case since the person last looked, typed and keyed by canonical record ids — never by matching titles.
//
//  Where each change comes from (and the feed says which, per entry):
//  • RECORDED at the change, in the same transaction as the mutation: the case action log (stage, triage,
//    closing, questions decided or answered, report selections; joined to the v173 before/after copy for the
//    record id), the case's scope log (documents admitted or excluded), grid rows and chronology entries (each
//    written with its case log row), the investigator's map links, review decisions (append-only), evidence
//    request history (receipts, duplicate receipts, status decisions; append-only), hypothesis decisions,
//    released case outputs and completed job results.
//  • DERIVED from durable records, because nothing recorded the moment it happened: a newer version of a case
//    document (source version records), a document that could or could not be read (compared with what could
//    be read at the person's seen position), a review reopened by a changed document, a task's status or due
//    date (compared with the seen position — the task engine keeps no history), a hypothesis revised (its
//    revision counter), and detections (contradictions found by the rules or the AI reading) that appeared or
//    are no longer detected.
//
//  Rules: "seen" moves the person's position only — it never reviews, accepts or decides anything. A detection
//  that disappeared is "no longer detected", never "resolved". A part that could not be read is reported as
//  not read; a feed that could not be read at all is a failure, never "nothing changed". For changed evidence
//  the feed lists the records that depend on it directly (with the dependency) and those linked to them as
//  "may need review"; it reverses nothing. Reads the ledger only; nothing is sent anywhere.
//

import Foundation
import os

// MARK: - Vocabulary

public nonisolated enum CaseChangeKind: String, Codable, Sendable, CaseIterable {
    case documentAdmitted, documentExcluded, documentUnreadable, documentNewlyReadable, documentRevised
    case linkAdded, linkWithdrawn
    case reviewDecided, reviewReopened
    case requestReceipt, requestDuplicate, requestStatusDecided
    case taskDueChanged, taskStatusChanged
    case questionRevised, hypothesisRevised, findingRevised, caseDetailsRevised
    case outputApproved, outputReleased, stageChanged
    case detected, noLongerDetected

    public var label: String {
        switch self {
        case .documentAdmitted: return "Document admitted to the case"
        case .documentExcluded: return "Document excluded from the case"
        case .documentUnreadable: return "Document could not be read"
        case .documentNewlyReadable: return "Document can now be read"
        case .documentRevised: return "Document revised (a newer version)"
        case .linkAdded: return "Evidence link added"
        case .linkWithdrawn: return "Evidence link withdrawn"
        case .reviewDecided: return "Review decided"
        case .reviewReopened: return "Review reopened — a document behind it changed"
        case .requestReceipt: return "Evidence request: item received"
        case .requestDuplicate: return "Evidence request: duplicate received (not counted)"
        case .requestStatusDecided: return "Evidence request: status decided"
        case .taskDueChanged: return "Task due date changed"
        case .taskStatusChanged: return "Task status changed"
        case .questionRevised: return "Question or allegation revised"
        case .hypothesisRevised: return "Hypothesis or lead revised"
        case .findingRevised: return "Finding or report selection revised"
        case .caseDetailsRevised: return "Case details revised"
        case .outputApproved: return "Result approved (completed by a person)"
        case .outputReleased: return "Output released (exported, copied or printed)"
        case .stageChanged: return "Case stage changed"
        case .detected: return "Newly detected"
        case .noLongerDetected: return "No longer detected — not resolved"
        }
    }

    public var symbol: String {
        switch self {
        case .documentAdmitted: return "doc.badge.plus"
        case .documentExcluded: return "doc.badge.ellipsis"
        case .documentUnreadable: return "doc.questionmark"
        case .documentNewlyReadable: return "doc.text"
        case .documentRevised: return "doc.on.doc"
        case .linkAdded: return "link.badge.plus"
        case .linkWithdrawn: return "link"
        case .reviewDecided: return "checkmark.circle"
        case .reviewReopened: return "arrow.triangle.2.circlepath"
        case .requestReceipt, .requestDuplicate: return "tray.and.arrow.down"
        case .requestStatusDecided: return "tray.full"
        case .taskDueChanged: return "calendar.badge.clock"
        case .taskStatusChanged: return "checklist"
        case .questionRevised: return "questionmark.circle"
        case .hypothesisRevised: return "lightbulb"
        case .findingRevised: return "checkmark.seal"
        case .caseDetailsRevised: return "folder"
        case .outputApproved: return "checkmark.seal.fill"
        case .outputReleased: return "square.and.arrow.up"
        case .stageChanged: return "flag"
        case .detected: return "exclamationmark.triangle"
        case .noLongerDetected: return "eye.slash"
        }
    }

    /// A change to evidence other work may rest on: its dependents are listed.
    public var affectsEvidence: Bool { [.documentExcluded, .documentUnreadable, .documentRevised, .documentNewlyReadable, .linkWithdrawn].contains(self) }
}

/// Where an entry comes from.
public nonisolated enum CaseChangeBasis: Hashable, Sendable {
    /// Written by the canonical mutation, in the same transaction (the record named).
    case recorded(String)
    /// Derived from existing durable records (named): nothing recorded the moment it happened.
    case derived(String)

    public var label: String {
        switch self {
        case .recorded(let r): return "Recorded when it happened (\(r))"
        case .derived(let r): return "Derived from \(r) — not recorded at the moment it happened"
        }
    }
    public var isRecorded: Bool { if case .recorded = self { return true }; return false }
}

public nonisolated struct CaseChange: Identifiable, Hashable, Sendable {
    /// Stable: the kind and the canonical row it comes from.
    public let id: String
    public let kind: CaseChangeKind
    /// The canonical case item it concerns (nil when it is not an item of the map, e.g. an excluded document's
    /// version that is no longer in the case's scope is still named by its logical document).
    public let record: CaseMapNodeID?
    /// When it was recorded (nil for a change found by comparing with the seen position).
    public let recordedAt: Date?
    public let actor: String?
    public let summary: String
    public let basis: CaseChangeBasis
    /// After the person's seen position (or found by comparing with it).
    public let isNew: Bool
}

/// What the case looked like at the seen position — identifiers and states only, never document text.
public nonisolated struct CaseChangeSeenState: Codable, Equatable, Sendable {
    /// Detected contradictions on the map (their ids).
    public var detections: [String] = []
    /// Items reopened because a document changed (node keys).
    public var reopened: [String] = []
    /// Case source versions that could and could not be read.
    public var readable: [String] = []
    public var unreadable: [String] = []
    /// Task id → "status|due".
    public var tasks: [String: String] = [:]
    public init() {}
}

public nonisolated struct CaseChangeSeen: Equatable, Sendable {
    public let seenThrough: Date
    public let state: CaseChangeSeenState
    public let seenBy: String
    public let seenAt: Date
}

/// The parts the feed reads; each loads or fails on its own.
public nonisolated enum CaseChangePart: String, Sendable, CaseIterable, Hashable {
    case caseLog, scope, documents, links, reviews, requests, hypotheses, outputs, detections, tasks
    public var label: String {
        switch self {
        case .caseLog: return "the case log"
        case .scope: return "the case's scope log"
        case .documents: return "the case's document versions"
        case .links: return "evidence links"
        case .reviews: return "review decisions"
        case .requests: return "evidence request history"
        case .hypotheses: return "hypotheses"
        case .outputs: return "released outputs and results"
        case .detections: return "detections"
        case .tasks: return "tasks"
        }
    }
}

/// For changed evidence: what rests on it.
public nonisolated struct CaseChangeImpact: Equatable, Sendable {
    public struct Dependent: Hashable, Sendable, Identifiable {
        public let node: CaseMapNodeID
        public let title: String
        /// How it depends on the changed item ("cites this document: …", "linked to …").
        public let dependency: String
        /// Its recorded review state — shown as it is; the feed changes nothing.
        public let review: CaseMapReviewState
        public var id: CaseMapNodeID { node }
    }
    public let changed: CaseMapNodeID
    /// Records that cite, derive from or link to the changed item.
    public let direct: [Dependent]
    /// Records linked to a direct dependent: they may need review; nothing about them was decided again.
    public let mayNeedReview: [Dependent]
}

public nonisolated struct CaseChangeFeedLoad: Sendable {
    public enum State: Equatable, Sendable {
        case loaded
        /// Some parts could not be read: the feed is incomplete and says which.
        case partial([CaseChangePart])
        /// The feed could not be read: never shown as "nothing changed".
        case failed(String)
    }
    public let caseID: UUID
    public let generation: UInt64
    public let state: State
    public let seen: CaseChangeSeen?
    /// When this build started recording case history (the v173 baseline).
    public let baseline: Date?
    /// Newest first; new (after the seen position) before earlier ones.
    public let changes: [CaseChange]
    /// The state now, kept as the seen position when the person marks the feed as seen.
    public let current: CaseChangeSeenState
    /// When the feed was read: changes recorded after this stay new after "Mark as seen".
    public let readAt: Date
    /// Entries beyond the display cap (disclosed, never silently dropped).
    public let omitted: Int
    public let failedParts: [CaseChangePart]

    public var newChanges: [CaseChange] { changes.filter(\.isNew) }
    /// Canonical items with a new change (the Changes view shows them).
    public var changedRecords: Set<CaseMapNodeID> { Set(newChanges.compactMap(\.record)) }

    static func failed(_ caseID: UUID, _ generation: UInt64, _ why: String) -> CaseChangeFeedLoad {
        CaseChangeFeedLoad(caseID: caseID, generation: generation, state: .failed(why), seen: nil, baseline: nil, changes: [],
                           current: CaseChangeSeenState(), readAt: Date(), omitted: 0, failedParts: [])
    }
}

public nonisolated enum CaseChangeFeedError: Error, Equatable, LocalizedError {
    case caseNotFound
    case blankActor
    case feedNotLoaded
    public var errorDescription: String? {
        switch self {
        case .caseNotFound: return "The case was not found (it may have been erased)."
        case .blankActor: return "Marking the changes as seen needs your name."
        case .feedNotLoaded: return "The changes could not be read, so they were not marked as seen."
        }
    }
}

// MARK: - Impact (pure)

public nonisolated enum CaseChangeImpactAnalysis {
    /// What depends on `changed` in the projection: direct dependents with the link that makes them depend,
    /// then items linked to those as "may need review". Reads only.
    public static func impact(of changed: CaseMapNodeID, in p: CaseMapProjection) -> CaseChangeImpact {
        var direct: [CaseChangeImpact.Dependent] = []
        var seen: Set<CaseMapNodeID> = [changed]
        for l in p.links(of: changed).sorted(by: { $0.id < $1.id }) {
            let other = l.from == changed ? l.to : l.from
            guard !seen.contains(other), let n = p.node(other) else { continue }
            seen.insert(other)
            let how = l.from == other ? "\(l.type.label) this item" : "this item \(l.type.label) it"
            direct.append(.init(node: other, title: n.title, dependency: "\(how): \(l.basis)", review: n.review))
        }
        var indirect: [CaseChangeImpact.Dependent] = []
        for d in direct {
            for l in p.links(of: d.node).sorted(by: { $0.id < $1.id }) {
                let other = l.from == d.node ? l.to : l.from
                guard !seen.contains(other), let n = p.node(other), n.id.kind != .document else { continue }
                seen.insert(other)
                indirect.append(.init(node: other, title: n.title, dependency: "May need review: linked to “\(d.title)” (\(l.type.label)), which rests on the changed item.",
                                      review: n.review))
            }
        }
        return CaseChangeImpact(changed: changed, direct: direct, mayNeedReview: indirect)
    }
}

// MARK: - The feed

public actor CaseChangeFeedService {
    private let database: Database
    /// Test hooks: parts made to fail, and the seen position made unreadable.
    public struct Faults: Sendable {
        public var parts: Set<CaseChangePart> = []
        public var seenUnreadable = false
        public init(parts: Set<CaseChangePart> = [], seenUnreadable: Bool = false) { self.parts = parts; self.seenUnreadable = seenUnreadable }
    }
    private var faults = Faults()
    /// The most entries shown; the rest are counted.
    public static let displayCap = 500

    public init(database: Database) { self.database = database }
    public func setFaults(_ f: Faults) { faults = f }

    struct InjectedFault: LocalizedError { let part: String; var errorDescription: String? { "\(part) could not be read (injected)" } }

    /// Read the case's change feed against the map projection (the same scoped records the map shows).
    /// Never throws: a failure is the load's state.
    public func load(caseID: UUID, projection: CaseMapProjection, generation: UInt64 = 0, now: Date = Date()) async -> CaseChangeFeedLoad {
        guard projection.caseID == caseID else { return .failed(caseID, generation, "The map that was read is not this case's.") }
        // The seen position decides what is new: without it the feed cannot say, so it fails rather than guess.
        let seen: CaseChangeSeen?
        do {
            if faults.seenUnreadable { throw InjectedFault(part: "the seen position") }
            guard try await database.query("SELECT 1 FROM investigation_cases WHERE id = ?;", [.uuid(caseID)]).first != nil else {
                return .failed(caseID, generation, "This case is not in the ledger (it may have been erased).")
            }
            seen = try await readSeen(caseID)
        } catch {
            KalsmritikoshLog.app.error("Case change feed: seen position unreadable: \(error.localizedDescription, privacy: .public)")
            return .failed(caseID, generation, "What changed could not be read: \(error.localizedDescription). This is not “nothing changed”.")
        }
        let since = seen?.seenThrough
        func isNew(_ at: Date?) -> Bool { guard let at else { return true }; return since.map { at > $0 } ?? true }
        let baseline = try? await CaseHistoryService.installBaseline(database)

        let current = Self.state(of: projection, now: now)
        var out: [CaseChange] = []
        var failed: [CaseChangePart] = []
        let c = SQLValue.uuid(caseID)
        let sinceValue: SQLValue = since.map { .date($0) } ?? .real(-1)
        // version → document item (the projection's documents), and the case's document logical ids.
        var docForVersion: [String: CaseMapNodeID] = [:]
        for n in projection.nodes where n.id.kind == .document {
            for s in n.sources { if let v = s.sourceVersionID { docForVersion[v.uuidString.lowercased()] = n.id } }
        }
        func node(_ kind: CaseMapRecordKind, _ id: String?) -> CaseMapNodeID? {
            guard let id, !id.isEmpty else { return nil }
            return CaseMapNodeID(caseID: caseID, kind: kind, recordID: id)
        }
        func title(_ id: CaseMapNodeID?) -> String? { id.flatMap { projection.node($0)?.title } }

        func part(_ p: CaseChangePart, _ body: () async throws -> [CaseChange]) async {
            do {
                if faults.parts.contains(p) { throw InjectedFault(part: p.label) }
                out += try await body()
            } catch {
                KalsmritikoshLog.app.error("Case change feed: \(p.rawValue, privacy: .public) unreadable: \(error.localizedDescription, privacy: .public)")
                failed.append(p)
            }
        }

        // The case action log, joined to the before/after copy written in the same savepoint (record id).
        await part(.caseLog) {
            let rows = try await database.query("""
                SELECT a.id, a.action, a.detail, a.actor, a.at, r.record_kind, r.record_id, r.before_json, r.after_json
                FROM case_actions a LEFT JOIN case_record_revisions r ON r.action_id = a.id
                WHERE a.case_id = ? AND a.at > ? AND a.action IN ('stage','triage','closed','reopened','archived','allegationAdded','allegationDecided',
                      'responseRecorded','reportItemIncluded','reportItemExcluded','profileSaved','taskAdded')
                ORDER BY a.at DESC, a.sequence DESC;
                """, [c, sinceValue])
            return rows.compactMap { r -> CaseChange? in
                guard let id = r.string(0), let action = r.string(1), let at = r.date(4) else { return nil }
                let detail = r.string(2)
                let rev = CaseRecordRevision(id: UUID(), caseID: caseID, actionID: nil, recordKind: r.string(5) ?? "", recordID: r.string(6) ?? "",
                                             change: action, before: r.string(7), after: r.string(8), actor: r.string(3) ?? "", recordedAt: at)
                let basis = CaseChangeBasis.recorded("the case log" + (r.string(5) != nil ? " and the record's before/after copy" : ""))
                let kind: CaseChangeKind
                var record: CaseMapNodeID?
                var summary: String
                switch action {
                case "stage", "triage", "closed", "reopened", "archived":
                    kind = .stageChanged; record = node(.caseFile, caseID.uuidString)
                    let (b, a) = rev.value("stage")
                    summary = (action == "stage" ? "Stage: " : action.capitalized + ": ") + (detail ?? (b != nil || a != nil ? "\(b ?? "—") → \(a ?? "—")" : ""))
                case "allegationAdded", "allegationDecided", "responseRecorded":
                    kind = .questionRevised; record = node(.allegation, r.string(6))
                    let label = title(record).map { "“\($0)”" } ?? "An allegation"
                    switch action {
                    case "allegationAdded": summary = "\(label) recorded"
                    case "allegationDecided":
                        let (b, a) = rev.value("disposition")
                        summary = "\(label): decision \(b ?? "pending") → \(a ?? "—")" + (detail.map { " — \($0)" } ?? "")
                    default: summary = "\(label): the response put to the respondent was recorded"
                    }
                case "reportItemIncluded", "reportItemExcluded":
                    kind = .findingRevised; record = node(.reportItem, r.string(6))
                    summary = (action == "reportItemIncluded" ? "Selected for the report" : "Excluded from the report") + (detail.map { ": \($0.prefix(120))" } ?? "")
                case "profileSaved":
                    let fields = rev.changedFields.filter { !["updated_at"].contains($0) }
                    guard !fields.isEmpty else { return nil }
                    kind = fields.contains("allegation_summary") ? .questionRevised : .caseDetailsRevised
                    record = node(.caseFile, caseID.uuidString)
                    summary = "Case details saved: " + fields.map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: ", ")
                case "taskAdded":
                    kind = .taskStatusChanged; record = nil
                    summary = "Task added" + (detail.map { ": \($0)" } ?? "")
                default: return nil
                }
                return CaseChange(id: "\(kind.rawValue):case_actions:\(id.lowercased())", kind: kind, record: record, recordedAt: at, actor: r.string(3),
                                  summary: summary, basis: basis, isNew: true)
            }
        }

        // Documents admitted and excluded: the case's scope log.
        await part(.scope) {
            let rows = try await database.query("""
                SELECT e.id, e.action, e.detail, e.actor, e.occurred_at, sv.logical_source_id, sv.filename
                FROM investigation_case_events e LEFT JOIN source_versions sv ON sv.id IN (e.detail, upper(e.detail), lower(e.detail))
                WHERE e.case_id = ? AND e.action IN ('sourceIncluded','sourceExcluded') AND e.occurred_at > ? ORDER BY e.occurred_at DESC;
                """, [c, sinceValue])
            return rows.compactMap { r in
                guard let id = r.string(0), let action = r.string(1), let at = r.date(4) else { return nil }
                let included = action == "sourceIncluded"
                let doc = node(.document, r.string(5)) ?? r.string(2).flatMap { docForVersion[$0.lowercased()] }
                let name = r.string(6) ?? title(doc) ?? "A document"
                return CaseChange(id: "\(included ? "documentAdmitted" : "documentExcluded"):case_events:\(id.lowercased())",
                                  kind: included ? .documentAdmitted : .documentExcluded, record: doc, recordedAt: at, actor: r.string(3),
                                  summary: "\(name) " + (included ? "was admitted to the case" : "was excluded from the case (its work is not erased)"),
                                  basis: .recorded("the case's scope log"), isNew: true)
            }
        }

        // Document versions: a newer version of a case document; readability compared with the seen position.
        await part(.documents) {
            var list: [CaseChange] = []
            let rows = try await database.query("""
                SELECT sv.id, sv.logical_source_id, sv.filename, sv.created_at,
                       EXISTS (SELECT 1 FROM investigation_case_sources s WHERE s.case_id = ? AND s.in_scope = 1 AND s.source_ref IN (sv.id, upper(sv.id), lower(sv.id)))
                FROM source_versions sv
                WHERE sv.created_at > ?
                  AND sv.logical_source_id IN (SELECT v.logical_source_id FROM investigation_case_sources s CROSS JOIN source_versions v
                                                 ON v.id IN (s.source_ref, upper(s.source_ref), lower(s.source_ref)) WHERE s.case_id = ? AND s.in_scope = 1)
                  AND EXISTS (SELECT 1 FROM source_versions o WHERE o.logical_source_id = sv.logical_source_id AND o.created_at < sv.created_at)
                ORDER BY sv.created_at DESC;
                """, [c, sinceValue, c])
            for r in rows {
                guard let v = r.string(0), let at = r.date(3) else { continue }
                let doc = node(.document, r.string(1))
                let inScope = (r.int(4) ?? 0) == 1
                list.append(CaseChange(id: "documentRevised:source_versions:\(v.lowercased())", kind: .documentRevised, record: doc, recordedAt: at, actor: nil,
                                       summary: "A newer version of \(r.string(2) ?? title(doc) ?? "a case document") was recorded (version \(v.prefix(8))). "
                                        + (inScope ? "It is in this case's scope." : "It is not in this case's scope until you admit it; earlier work still cites the version it cited."),
                                       basis: .derived("the document's version records"), isNew: true))
            }
            let before = seen?.state
            let readableBefore = Set(before?.readable ?? []), unreadableBefore = Set(before?.unreadable ?? [])
            for v in current.unreadable.sorted() where !unreadableBefore.contains(v) {
                let doc = docForVersion[v]
                let was = readableBefore.contains(v)
                list.append(CaseChange(id: "documentUnreadable:\(v)", kind: .documentUnreadable, record: doc, recordedAt: nil, actor: nil,
                                       summary: "\(title(doc) ?? "A case document") " + (was ? "could be read before and cannot be read now" : "is in the case but could not be read")
                                        + ". Nothing in it was searched or cited.",
                                       basis: .derived("comparing what could be read now with your seen position"), isNew: true))
            }
            for v in current.readable.sorted() where unreadableBefore.contains(v) {
                let doc = docForVersion[v]
                list.append(CaseChange(id: "documentNewlyReadable:\(v)", kind: .documentNewlyReadable, record: doc, recordedAt: nil, actor: nil,
                                       summary: "\(title(doc) ?? "A case document") can now be read; it was not readable at your seen position.",
                                       basis: .derived("comparing what could be read now with your seen position"), isNew: true))
            }
            return list
        }

        // Evidence links: grid rows, chronology citations, hypothesis citations and the investigator's map links.
        await part(.links) {
            var list: [CaseChange] = []
            for r in try await database.query("""
                SELECT e.id, e.allegation_id, e.stance, e.added_by, e.created_at, e.removed_at, coalesce(e.label, e.evidence_ref)
                FROM case_allegation_evidence e JOIN case_allegations a ON a.id = e.allegation_id
                WHERE a.case_id = ? AND (e.created_at > ? OR coalesce(e.removed_at, -1) > ?);
                """, [c, sinceValue, sinceValue]) {
                guard let id = r.string(0), let added = r.date(4) else { continue }
                let record = node(.allegation, r.string(1))
                let what = "\(r.string(2) ?? "") \(r.string(6) ?? "evidence")".trimmingCharacters(in: .whitespaces)
                if isNew(added) {
                    list.append(CaseChange(id: "linkAdded:grid:\(id.lowercased())", kind: .linkAdded, record: record, recordedAt: added, actor: r.string(3),
                                           summary: "\(title(record) ?? "An allegation"): \(what)", basis: .recorded("the evidence grid row and the case log"), isNew: true))
                }
                if let removed = r.date(5), isNew(removed) {
                    list.append(CaseChange(id: "linkWithdrawn:grid:\(id.lowercased())", kind: .linkWithdrawn, record: record, recordedAt: removed, actor: nil,
                                           summary: "\(title(record) ?? "An allegation"): unlinked \(what) (kept in the record, marked removed)",
                                           basis: .recorded("the evidence grid row and the case log"), isNew: true))
                }
            }
            for r in try await database.query("""
                SELECT id, entry_kind, author, created_at, removed_at, substr(text, 1, 120), coalesce(evidence_ref, citations_json)
                FROM case_journal WHERE case_id = ? AND entry_kind = 'chronology' AND (created_at > ? OR coalesce(removed_at, -1) > ?);
                """, [c, sinceValue, sinceValue]) {
                guard let id = r.string(0), let at = r.date(3), r.string(6) != nil else { continue }
                let record = node(.journal, id)
                if isNew(at) {
                    list.append(CaseChange(id: "linkAdded:journal:\(id.lowercased())", kind: .linkAdded, record: record, recordedAt: at, actor: r.string(2),
                                           summary: "Chronology entry citing a source: \(r.string(5) ?? "")", basis: .recorded("the chronology entry and the case log"), isNew: true))
                }
                if let removed = r.date(4), isNew(removed) {
                    list.append(CaseChange(id: "linkWithdrawn:journal:\(id.lowercased())", kind: .linkWithdrawn, record: record, recordedAt: removed, actor: nil,
                                           summary: "Chronology entry retracted: \(r.string(5) ?? "")", basis: .recorded("the chronology entry and the case log"), isNew: true))
                }
            }
            for r in try await database.query("""
                SELECT e.id, e.hypothesis_id, e.stance, e.added_by, e.created_at FROM investigation_hypothesis_evidence e
                JOIN investigation_hypotheses h ON h.id = e.hypothesis_id WHERE h.case_id = ? AND e.created_at > ?;
                """, [c, sinceValue]) {
                guard let id = r.string(0), let at = r.date(4) else { continue }
                let record = node(.hypothesis, r.string(1))
                list.append(CaseChange(id: "linkAdded:hypothesis:\(id.lowercased())", kind: .linkAdded, record: record, recordedAt: at, actor: r.string(3),
                                       summary: "\(title(record) ?? "A hypothesis"): cited \(r.string(2) == "for" ? "for" : "against")",
                                       basis: .recorded("the hypothesis citation"), isNew: true))
            }
            for r in try await database.query("""
                SELECT id, link_type, from_kind, from_id, created_by, created_at, withdrawn_by, withdrawn_at
                FROM case_map_links WHERE case_id = ? AND (created_at > ? OR coalesce(withdrawn_at, -1) > ?);
                """, [c, sinceValue, sinceValue]) {
                guard let id = r.string(0), let at = r.date(5) else { continue }
                let record = r.string(2).flatMap(CaseMapRecordKind.init(rawValue:)).flatMap { node($0, r.string(3)) }
                let type = r.string(1).flatMap(CaseMapLinkType.init(rawValue:))?.label ?? "linked"
                if isNew(at) {
                    list.append(CaseChange(id: "linkAdded:map:\(id.lowercased())", kind: .linkAdded, record: record, recordedAt: at, actor: r.string(4),
                                           summary: "Map link drawn: \(title(record) ?? "an item") \(type) …", basis: .recorded("your map link"), isNew: true))
                }
                if let w = r.date(7), isNew(w) {
                    list.append(CaseChange(id: "linkWithdrawn:map:\(id.lowercased())", kind: .linkWithdrawn, record: record, recordedAt: w, actor: r.string(6),
                                           summary: "Map link withdrawn: \(title(record) ?? "an item") \(type) … (kept, marked withdrawn)", basis: .recorded("your map link"), isNew: true))
                }
            }
            return list
        }

        // Review decisions (append-only) and reviews reopened by a changed document (compared with the seen position).
        await part(.reviews) {
            var list: [CaseChange] = []
            for r in try await database.query("""
                SELECT id, item_kind, item_id, decision, reason, actor, decided_at FROM investigation_review_decisions
                WHERE case_id = ? AND decided_at > ? ORDER BY decided_at DESC;
                """, [c, sinceValue]) {
                guard let id = r.string(0), let at = r.date(6) else { continue }
                let record = r.string(1) == "contradiction" ? node(.contradiction, r.string(2)) : nil
                list.append(CaseChange(id: "reviewDecided:decision:\(id.lowercased())", kind: .reviewDecided, record: record, recordedAt: at, actor: r.string(5),
                                       summary: "\(title(record) ?? "A \(r.string(1) ?? "review") item"): \(r.string(3) ?? "decided")" + (r.string(4).map { " (\($0))" } ?? ""),
                                       basis: .recorded("the review decision record"), isNew: true))
            }
            let reopenedBefore = Set(seen?.state.reopened ?? [])
            for key in current.reopened where !reopenedBefore.contains(key) {
                guard let n = projection.nodes.first(where: { $0.id.key == key }) else { continue }
                list.append(CaseChange(id: "reviewReopened:\(key)", kind: .reviewReopened, record: n.id, recordedAt: nil, actor: nil,
                                       summary: "\(n.title): \(n.changedSourceWarning ?? "a document behind the decision changed"). The decision stays recorded; review it again.",
                                       basis: .derived("the decision's document versions compared with the case's current versions"), isNew: true))
            }
            return list
        }

        // Evidence request history (append-only): receipts, duplicate receipts, status decisions.
        await part(.requests) {
            try await database.query("""
                SELECT e.id, e.request_id, e.event, e.status_after, e.detail, e.actor, e.occurred_at, r.description
                FROM investigation_evidence_request_events e LEFT JOIN investigation_evidence_requests r ON r.id = e.request_id
                WHERE e.case_id = ? AND e.occurred_at > ? AND e.event IN ('received','duplicateReceived','statusDecided') ORDER BY e.occurred_at DESC;
                """, [c, sinceValue]).compactMap { r in
                guard let id = r.string(0), let event = r.string(2), let at = r.date(6) else { return nil }
                let kind: CaseChangeKind = event == "received" ? .requestReceipt : event == "duplicateReceived" ? .requestDuplicate : .requestStatusDecided
                let desc = r.string(7).map { "“\($0)”" } ?? "A request"
                let summary: String
                switch kind {
                case .requestReceipt: summary = "\(desc): an item was received. Receiving it does not fulfil the request; that is a recorded decision."
                case .requestDuplicate: summary = "\(desc): a duplicate of an item already received (kept with its provenance, not counted)."
                default: summary = "\(desc): status decided — \(r.string(3) ?? "")" + (r.string(4).map { " (\($0))" } ?? "")
                }
                return CaseChange(id: "\(kind.rawValue):request_events:\(id.lowercased())", kind: kind, record: node(.request, r.string(1)), recordedAt: at,
                                  actor: r.string(5), summary: summary, basis: .recorded("the request's history"), isNew: true)
            }
        }

        // Hypotheses: decisions (recorded) and revisions (the record keeps only its latest revision and time).
        await part(.hypotheses) {
            var list: [CaseChange] = []
            for r in try await database.query("""
                SELECT d.id, d.hypothesis_id, d.decision, d.actor, d.decided_at FROM investigation_hypothesis_decisions d
                JOIN investigation_hypotheses h ON h.id = d.hypothesis_id WHERE h.case_id = ? AND d.decided_at > ?;
                """, [c, sinceValue]) {
                guard let id = r.string(0), let at = r.date(4) else { continue }
                let record = node(.hypothesis, r.string(1))
                list.append(CaseChange(id: "hypothesisRevised:decision:\(id.lowercased())", kind: .hypothesisRevised, record: record, recordedAt: at, actor: r.string(3),
                                       summary: "\(title(record) ?? "A hypothesis"): \(r.string(2) ?? "decided") with the reasons recorded",
                                       basis: .recorded("the hypothesis decision"), isNew: true))
            }
            for r in try await database.query("SELECT id, status, revision, actor, updated_at, created_at FROM investigation_hypotheses WHERE case_id = ? AND updated_at > ?;",
                                              [c, sinceValue]) {
                guard let id = r.string(0), let at = r.date(4) else { continue }
                let record = node(.hypothesis, id)
                let created = r.date(5).map { abs($0.timeIntervalSince(at)) < 0.001 } ?? false
                list.append(CaseChange(id: "hypothesisRevised:hypothesis:\(id.lowercased()):\(r.int(2) ?? 0)", kind: .hypothesisRevised, record: record, recordedAt: at,
                                       actor: r.string(3),
                                       summary: "\(title(record) ?? "A hypothesis") " + (created ? "recorded" : "revised (now revision \(r.int(2) ?? 0), \(r.string(1) ?? ""))"),
                                       basis: .derived("the hypothesis record (its latest revision only)"), isNew: true))
            }
            return list
        }

        // Released case outputs and completed (approved) job results.
        await part(.outputs) {
            var list: [CaseChange] = []
            for r in try await database.query("""
                SELECT id, kind, route, file_name, released_by, released_at FROM case_document_outputs
                WHERE case_id = ? AND status IN ('written','released') AND released_at > ?;
                """, [c, sinceValue]) {
                guard let id = r.string(0), let at = r.date(5) else { continue }
                list.append(CaseChange(id: "outputReleased:outputs:\(id.lowercased())", kind: .outputReleased, record: nil, recordedAt: at, actor: r.string(4),
                                       summary: "\(r.string(1) ?? "Output") released by \(r.string(2) ?? "")" + (r.string(3).map { " (\($0))" } ?? ""),
                                       basis: .recorded("the case's output record"), isNew: true))
            }
            for r in try await database.query("SELECT id, job_id, created_by, created_at FROM job_results WHERE case_id = ? AND state = 'completed' AND created_at > ?;",
                                              [c, sinceValue]) {
                guard let id = r.string(0), let at = r.date(3) else { continue }
                list.append(CaseChange(id: "outputApproved:job_results:\(id.lowercased())", kind: .outputApproved, record: nil, recordedAt: at, actor: r.string(2),
                                       summary: "A result of \(r.string(1) ?? "a job") was completed by \(r.string(2) ?? "a person"): it is the approved result of that job",
                                       basis: .recorded("the job result record"), isNew: true))
            }
            return list
        }

        // Detections: contradictions on the map now, compared with those at the seen position.
        await part(.detections) {
            var list: [CaseChange] = []
            let before = Set(seen?.state.detections ?? [])
            let now = Set(current.detections)
            if seen != nil {
                for id in now.subtracting(before).sorted() {
                    let n = node(.contradiction, id)
                    list.append(CaseChange(id: "detected:\(id)", kind: .detected, record: n, recordedAt: n.flatMap { projection.node($0)?.recordedAt }, actor: nil,
                                           summary: "\(title(n) ?? "A possible contradiction") was detected. It is a suggestion until a person decides.",
                                           basis: .derived("the detections on the map compared with your seen position"), isNew: true))
                }
            }
            for id in before.subtracting(now).sorted() {
                list.append(CaseChange(id: "noLongerDetected:\(id)", kind: .noLongerDetected, record: node(.contradiction, id), recordedAt: nil, actor: nil,
                                       summary: "A possible contradiction shown at your seen position is no longer detected. That is not a resolution: nobody recorded a decision because it disappeared, and its documents may have changed or left the case.",
                                       basis: .derived("the detections on the map compared with your seen position"), isNew: true))
            }
            return list
        }

        // Tasks: status and due date compared with the seen position (the task engine keeps no history).
        await part(.tasks) {
            var list: [CaseChange] = []
            guard let before = seen?.state.tasks else { return [] }
            for (id, value) in current.tasks.sorted(by: { $0.key < $1.key }) {
                let n = node(.task, id)
                let parts = value.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard let old = before[id] else {
                    list.append(CaseChange(id: "taskStatusChanged:\(id):new", kind: .taskStatusChanged, record: n, recordedAt: nil, actor: nil,
                                           summary: "\(title(n) ?? "A task") was linked to the case (\(parts.first ?? ""))",
                                           basis: .derived("the case's tasks compared with your seen position"), isNew: true))
                    continue
                }
                let was = old.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                if was.first != parts.first {
                    list.append(CaseChange(id: "taskStatusChanged:\(id):\(value)", kind: .taskStatusChanged, record: n, recordedAt: nil, actor: nil,
                                           summary: "\(title(n) ?? "A task"): \(was.first ?? "—") → \(parts.first ?? "—")",
                                           basis: .derived("the case's tasks compared with your seen position"), isNew: true))
                }
                if was.count > 1, parts.count > 1, was[1] != parts[1] {
                    list.append(CaseChange(id: "taskDueChanged:\(id):\(value)", kind: .taskDueChanged, record: n, recordedAt: nil, actor: nil,
                                           summary: "\(title(n) ?? "A task"): due \(Self.dayText(was[1])) → \(Self.dayText(parts[1]))",
                                           basis: .derived("the case's tasks compared with your seen position"), isNew: true))
                }
            }
            return list
        }

        // Newest first; changes found by comparison (no time) first; the rest counted beyond the cap.
        let sorted = out.sorted { a, b in
            switch (a.recordedAt, b.recordedAt) {
            case (nil, nil): return a.id < b.id
            case (nil, _): return true
            case (_, nil): return false
            case let (x?, y?): return x != y ? x > y : a.id < b.id
            }
        }
        var unique: [CaseChange] = []
        var ids = Set<String>()
        for ch in sorted where ids.insert(ch.id).inserted { unique.append(ch) }
        let shown = Array(unique.prefix(Self.displayCap))
        let state: CaseChangeFeedLoad.State = failed.isEmpty ? .loaded : .partial(CaseChangePart.allCases.filter(failed.contains))
        return CaseChangeFeedLoad(caseID: caseID, generation: generation, state: state, seen: seen, baseline: baseline, changes: shown, current: current,
                                  readAt: now, omitted: unique.count - shown.count, failedParts: CaseChangePart.allCases.filter(failed.contains))
    }

    static func dayText(_ raw: String) -> String {
        guard let t = Double(raw) else { return "none" }
        return Date(timeIntervalSince1970: t).formatted(date: .abbreviated, time: .omitted)
    }

    /// The identifiers and states the seen position keeps (no document text).
    static func state(of p: CaseMapProjection, now: Date) -> CaseChangeSeenState {
        var s = CaseChangeSeenState()
        s.detections = p.nodes.filter { $0.id.kind == .contradiction }.map(\.id.recordID).sorted()
        s.reopened = p.nodes.filter { $0.review == .reopened }.map(\.id.key).sorted()
        var readable = Set<String>(), unreadable = Set<String>()
        for n in p.nodes where n.id.kind == .document {
            for src in n.sources {
                guard let v = src.sourceVersionID?.uuidString.lowercased() else { continue }
                if src.objectID != nil { readable.insert(v) } else { unreadable.insert(v) }
            }
        }
        s.readable = readable.sorted(); s.unreadable = unreadable.subtracting(readable).sorted()
        for n in p.nodes where n.id.kind == .task {
            let status = n.status.text.components(separatedBy: " — ").first ?? n.status.text
            s.tasks[n.id.recordID] = "\(status)|\(n.eventDate.map { String($0.timeIntervalSince1970) } ?? "")"
        }
        return s
    }

    private func readSeen(_ caseID: UUID) async throws -> CaseChangeSeen? {
        guard let r = try await database.query("SELECT seen_through, state_json, seen_by, seen_at FROM case_change_seen WHERE case_id = ?;", [.uuid(caseID)]).first,
              let through = r.date(0), let by = r.string(2), let at = r.date(3) else { return nil }
        let state = (r.string(1)?.data(using: .utf8)).flatMap { try? JSONDecoder().decode(CaseChangeSeenState.self, from: $0) } ?? CaseChangeSeenState()
        return CaseChangeSeen(seenThrough: through, state: state, seenBy: by, seenAt: at)
    }

    public func seenPosition(caseID: UUID) async throws -> CaseChangeSeen? { try await readSeen(caseID) }

    /// "Mark as seen": move this case's seen position to the moment the feed was read, keeping the identifiers
    /// of what was detected, readable and open then. It reviews, accepts and decides NOTHING; it writes no case
    /// record and no case log entry. Refused for a feed that was not read, and for a case no longer in the ledger.
    public func markSeen(_ load: CaseChangeFeedLoad, actor: String, at date: Date = Date()) async throws {
        let who = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !who.isEmpty else { throw CaseChangeFeedError.blankActor }
        if case .failed = load.state { throw CaseChangeFeedError.feedNotLoaded }
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let json = String(decoding: try enc.encode(load.current), as: UTF8.self)
        let caseID = load.caseID, through = load.readAt
        try await database.withSavepoint("ccseen_\(UUID().uuidString.prefix(8))") { db in
            // Late work cannot recreate an erased case's seen position.
            guard try db.query("SELECT 1 FROM investigation_cases WHERE id = ?;", [.uuid(caseID)]).first != nil else { throw CaseChangeFeedError.caseNotFound }
            try db.exec("""
                INSERT INTO case_change_seen (case_id, seen_through, state_json, seen_by, seen_at) VALUES (?,?,?,?,?)
                ON CONFLICT(case_id) DO UPDATE SET seen_through = excluded.seen_through, state_json = excluded.state_json,
                    seen_by = excluded.seen_by, seen_at = excluded.seen_at;
                """, [.uuid(caseID), .date(through), .text(json), .text(who), .date(date)])
        }
    }
}
