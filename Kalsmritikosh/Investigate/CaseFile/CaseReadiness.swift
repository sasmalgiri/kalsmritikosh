//
//  CaseReadiness.swift
//  Kalsmritikosh
//
//  Living case map, M7 (plan §7): how far the case's work has got, from explicit work states — never a
//  completion percentage, never a verdict. Each area lists its states with counts and the items in them:
//    Questions  unresolved / being investigated / answered with a recorded basis / decided but needing review
//    Evidence   read / partly read / not read (from the case's reading coverage)
//    Review     pending / deferred / decided / reopened
//    Requests   by status (open … fulfilled by decision)
//    Findings   draft / reviewed / approved / outdated
//    Work       outstanding / overdue / completed / not applicable with a reason (and without one)
//  "Needs attention" is the plain list of what is still open. The size of the map does not raise anything:
//  more documents, notes or links only move counts inside their own state, and new contrary evidence recorded
//  after a decision moves that question back to "needs review". The stage and approvals stay where the person
//  recorded them; this panel only reads.
//

import Foundation

public nonisolated struct CaseReadiness: Equatable, Sendable {
    public struct Line: Equatable, Sendable, Identifiable {
        public let id: String
        public let label: String
        public let items: [CaseMapNodeID]
        public let count: Int
        /// The line is open work (it is in "Needs attention" when its count is not zero).
        public let open: Bool
    }
    public struct Area: Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let lines: [Line]
        public let note: String?
        public func count(_ lineID: String) -> Int { lines.first { $0.id == lineID }?.count ?? 0 }
    }
    public let areas: [Area]

    public func area(_ id: String) -> Area? { areas.first { $0.id == id } }
    /// The open lines, in order, as plain sentences.
    public var attention: [String] {
        areas.flatMap { a in a.lines.filter { $0.open && $0.count > 0 }.map { "\(a.title): \($0.count) \($0.label.lowercased())" } }
    }
    /// How many open items there are (a count of work, not a score).
    public var openItems: Int { areas.flatMap(\.lines).filter(\.open).reduce(0) { $0 + $1.count } }

    public static func compute(projection p: CaseMapProjection, snapshot s: CaseFileSnapshot, requests: [EvidenceRequestFile],
                               coverage: CaseCoverageReadout?, now: Date = Date()) -> CaseReadiness {
        let caseID = p.caseID
        func nid(_ kind: CaseMapRecordKind, _ id: UUID) -> CaseMapNodeID { CaseMapNodeID(caseID: caseID, kind: kind, id: id) }
        func line(_ id: String, _ label: String, _ items: [CaseMapNodeID], open: Bool) -> Line {
            Line(id: id, label: label, items: items.sorted(), count: items.count, open: open)
        }

        // Questions: the case's allegations and hypotheses.
        var unresolved: [CaseMapNodeID] = [], investigating: [CaseMapNodeID] = [], answered: [CaseMapNodeID] = [], needsReview: [CaseMapNodeID] = []
        let liveGrid = s.grid
        for a in s.allegations {
            let id = nid(.allegation, a.id)
            let rows = liveGrid.filter { $0.allegationID == a.id }
            let staleLink = p.links(of: id).contains { $0.status.kind == .stale || $0.review == .reopened }
            if a.disposition != .pending {
                let basis = !(a.rationale ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                // Contrary evidence recorded AFTER the decision: the answer needs review again.
                let contraryAfter = rows.contains { row in row.stance == .contradicts && (a.decidedAt.map { d in row.createdAt > d } ?? false) }
                if !basis || contraryAfter || staleLink { needsReview.append(id) } else { answered.append(id) }
            } else {
                let worked = !rows.isEmpty || requests.contains { $0.request.allegationID == a.id } || s.reportItems.contains { $0.allegationID == a.id }
                if worked { investigating.append(id) } else { unresolved.append(id) }
            }
        }
        for n in p.nodes where n.id.kind == .hypothesis {
            if n.review == .unreviewed {
                if p.links(of: n.id).isEmpty { unresolved.append(n.id) } else { investigating.append(n.id) }
            } else {
                answered.append(n.id)   // decided with recorded reasons (the v154 decision requires them)
            }
        }
        var questionNote: String?
        if s.allegations.isEmpty && p.question == nil { questionNote = "No question or allegation is recorded yet." }
        let questions = Area(id: "questions", title: "Questions", lines: [
            line("unresolved", "Unresolved — nothing gathered yet", unresolved, open: true),
            line("investigating", "Being investigated", investigating, open: true),
            line("needsReview", "Decided, but needs review (no basis recorded, contrary evidence after the decision, or a source changed)", needsReview, open: true),
            line("answered", "Answered with a recorded basis", answered, open: false),
        ], note: questionNote)

        // Evidence: what the app could read of the case's documents.
        let docs = p.nodes.filter { $0.id.kind == .document }.map(\.id)
        let evidence: Area
        if let c = coverage {
            evidence = Area(id: "evidence", title: "Evidence", lines: [
                Line(id: "read", label: "Read", items: [], count: c.read, open: false),
                Line(id: "partlyRead", label: "Partly read", items: [], count: c.partlyRead.count, open: true),
                Line(id: "notRead", label: "Not read (could not be read)", items: [], count: c.notRead.count, open: true),
            ], note: c.notes.isEmpty ? nil : c.notes.joined(separator: " "))
        } else {
            let unreadable = p.nodes.filter { $0.id.kind == .document && $0.sources.allSatisfy { $0.objectID == nil } }.map(\.id)
            evidence = Area(id: "evidence", title: "Evidence", lines: [
                line("read", "Read", docs.filter { !unreadable.contains($0) }, open: false),
                line("notRead", "Not read (could not be read)", unreadable, open: true),
            ], note: "The reading coverage could not be loaded; “partly read” is not known here.")
        }

        // Review: suggested items and carried rows, by their recorded review state.
        var pending: [CaseMapNodeID] = [], deferred: [CaseMapNodeID] = [], decided: [CaseMapNodeID] = [], reopened: [CaseMapNodeID] = []
        for n in p.nodes where [.contradiction, .journal, .reportItem].contains(n.id.kind) {
            switch n.review {
            case .unreviewed, .pendingReview: pending.append(n.id)
            case .deferred: deferred.append(n.id)
            case .reopened: reopened.append(n.id)
            case .confirmed, .dismissed, .accepted, .rejected, .completed, .withdrawn: decided.append(n.id)
            case .notApplicable: break
            }
        }
        let review = Area(id: "review", title: "Review", lines: [
            line("pending", "Pending", pending, open: true),
            line("deferred", "Deferred", deferred, open: true),
            line("reopened", "Reopened — a document changed since the decision", reopened, open: true),
            line("decided", "Decided", decided, open: false),
        ], note: nil)

        // Requests by status.
        var byStatus: [String: [CaseMapNodeID]] = [:]
        for f in requests where f.request.caseID == caseID { byStatus[f.request.status.rawValue, default: []].append(nid(.request, f.request.id)) }
        let requestLines: [Line] = [("open", "Open", true), ("confirmed", "Confirmed (sent)", true), ("partial", "Partly received", true),
                                    ("refused", "Refused", false), ("unobtainable", "Unobtainable", false), ("fulfilled", "Fulfilled by decision", false),
                                    ("cancelled", "Cancelled", false)].map { line($0.0, $0.1, byStatus[$0.0] ?? [], open: $0.2) }
        let requestArea = Area(id: "requests", title: "Requests", lines: requestLines, note: "A document arriving does not fulfil a request; fulfilment is a recorded decision.")

        // Findings: report items.
        var draft: [CaseMapNodeID] = [], reviewed: [CaseMapNodeID] = [], approved: [CaseMapNodeID] = [], outdated: [CaseMapNodeID] = []
        for r in s.reportItems {
            let id = nid(.reportItem, r.id)
            let node = p.node(id)
            if s.isSuperseded(r.origin) || node?.status.kind == .stale || node?.review == .reopened { outdated.append(id); continue }
            let state = node?.review ?? .notApplicable
            if !r.included || state == .rejected { reviewed.append(id) }
            else if [.accepted, .completed, .confirmed].contains(state) { approved.append(id) }
            else { draft.append(id) }
        }
        let findings = Area(id: "findings", title: "Findings", lines: [
            line("draft", "Draft — selected, no recorded review", draft, open: true),
            line("outdated", "Outdated — its source result or document changed", outdated, open: true),
            line("reviewed", "Reviewed — excluded or rejected with a recorded reason", reviewed, open: false),
            line("approved", "Approved — accepted on review and in the report", approved, open: false),
        ], note: nil)

        // Work: the case's tasks.
        var outstanding: [CaseMapNodeID] = [], overdue: [CaseMapNodeID] = [], completed: [CaseMapNodeID] = []
        var notApplicable: [CaseMapNodeID] = [], cancelledNoReason: [CaseMapNodeID] = []
        for t in s.tasks {
            let id = nid(.task, t.task.id)
            switch t.task.status {
            case .completed: completed.append(id)
            case .cancelled, .archived:
                if (t.task.detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { cancelledNoReason.append(id) } else { notApplicable.append(id) }
            default: if t.isOverdue(at: now) { overdue.append(id) } else { outstanding.append(id) }
            }
        }
        let work = Area(id: "work", title: "Work", lines: [
            line("overdue", "Overdue", overdue, open: true),
            line("outstanding", "Outstanding", outstanding, open: true),
            line("cancelledNoReason", "Set aside without a recorded reason", cancelledNoReason, open: true),
            line("notApplicable", "Not applicable — reason recorded", notApplicable, open: false),
            line("completed", "Completed", completed, open: false),
        ], note: nil)

        return CaseReadiness(areas: [questions, evidence, review, requestArea, findings, work])
    }
}
