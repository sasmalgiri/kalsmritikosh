//
//  CaseNextSteps.swift
//  Kalsmritikosh
//
//  Implementation brief §14: next-action guidance from what the case actually holds, not a
//  decorative completion score. Each step names the observable fact behind it and the tab where
//  it is done. Pure — computed from the case snapshot; it decides nothing for the investigator.
//

import Foundation

public nonisolated struct CaseNextStep: Identifiable, Sendable, Equatable {
    public enum Place: String, Sendable { case overview, plan, tasks, people, evidence, log }
    public let id: String
    public let text: String
    public let place: Place
}

public nonisolated enum CaseNextSteps {

    /// The steps the case's own state calls for, most pressing first.
    /// `evidenceRequests` and the contradiction counts (P1-A/P1-B, 2026-11-04) add the case's open
    /// collection follow-up and review queue; callers that pass neither get the steps they always had.
    public static func compute(_ s: CaseFileSnapshot, unresolvedReferences: Int = 0, custodyReadFailed: Bool = false,
                               evidenceRequests: [EvidenceRequestFile] = [], contradictionsAwaiting: Int = 0,
                               contradictionsReopened: Int = 0, now: Date = Date()) -> [CaseNextStep] {
        var out: [CaseNextStep] = []
        let stage = s.caseHeader.status == .closed ? .closed : s.profile.stage
        guard ![.closed, .declined, .referred].contains(stage) else { return [] }

        if custodyReadFailed {
            out.append(.init(id: "custody", text: "The custody record could not be read. Reports are marked incomplete until it can.", place: .evidence))
        }
        if unresolvedReferences > 0 {
            out.append(.init(id: "refs", text: "\(unresolvedReferences) piece(s) of evidence point at something that isn't in this case. Relink or retract them.", place: .evidence))
        }
        if stage == .intake || (stage == .triage && s.profile.triage.decision == nil) {
            out.append(.init(id: "triage", text: "Rate the complaint and decide whether to investigate, decline or refer it.", place: .overview))
        }
        let overdue = s.tasks.filter { $0.isOverdue(at: now) }
        if !overdue.isEmpty {
            out.append(.init(id: "overdue", text: "\(overdue.count) task(s) are past their due date.", place: .tasks))
        }
        for f in evidenceRequests where f.request.isOverdue(at: now) {
            let missing = f.progress.outstanding.count
            out.append(.init(id: "request-overdue-\(f.id)", text: "The request “\(f.request.description)” is past its due date"
                             + (missing > 0 ? " with \(missing) item(s) still missing." : "."), place: .evidence))
        }
        for f in evidenceRequests where f.request.status.isOutstanding && !f.request.isOverdue(at: now) && f.progress.state == .partlyReceived {
            out.append(.init(id: "request-partial-\(f.id)", text: "“\(f.request.description)”: still missing " + f.progress.outstanding.map(\.label).joined(separator: "; ") + ".",
                             place: .evidence))
        }
        for f in evidenceRequests where f.request.status.isOutstanding && f.progress.state == .allReceived {
            out.append(.init(id: "request-complete-\(f.id)", text: "Everything asked for in “\(f.request.description)” has arrived. Check it and record whether the request is fulfilled.",
                             place: .evidence))
        }
        if contradictionsReopened > 0 {
            out.append(.init(id: "contradictions-reopened", text: "\(contradictionsReopened) contradiction(s) reopened because a document changed. Review them again.", place: .overview))
        }
        if contradictionsAwaiting > contradictionsReopened {
            out.append(.init(id: "contradictions-awaiting", text: "\(contradictionsAwaiting - contradictionsReopened) contradiction(s) are waiting for your decision.", place: .overview))
        }
        if s.custody.isEmpty && !custodyReadFailed {
            out.append(.init(id: "sources", text: "No documents are in this case yet. Add the sources the investigation covers.", place: .evidence))
        }
        let open = s.allegations.filter { $0.disposition == .pending }
        if s.allegations.isEmpty && [.open, .inProgress].contains(stage) {
            out.append(.init(id: "allegations", text: "Frame what is alleged as questions the evidence can answer.", place: .plan))
        }
        for a in open {
            let links = s.grid.filter { $0.allegationID == a.id }
            if links.isEmpty {
                out.append(.init(id: "grid-\(a.id)", text: "\(a.label) has no evidence linked for or against it.", place: .plan))
            } else if !links.contains(where: { $0.stance == .contradicts }) {
                // Brief §8: absence of contradiction proves nothing — say that nothing against was looked at.
                out.append(.init(id: "contrary-\(a.id)", text: "\(a.label) has only supporting evidence. Record what was checked against it, even if nothing was found.", place: .plan))
            }
        }
        for iv in s.interviews where iv.status != .attested && !(iv.statementText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let who = s.person(iv.personID)?.name ?? "the interviewee"
            out.append(.init(id: "attest-\(iv.id)", text: "\(who)'s statement is written but not yet confirmed by \(who).", place: .people))
        }
        for h in s.holds where h.isOutstanding {
            out.append(.init(id: "hold-\(h.id)", text: "The hold notice to \(h.custodian) has not been acknowledged.", place: .evidence))
        }
        if !s.allegations.isEmpty && open.isEmpty && stage != .findings {
            out.append(.init(id: "findings", text: "Every allegation has a decision. Move the case to findings and write up the reasoning.", place: .overview))
        }
        return out
    }
}
