//
//  JobProgressTests.swift
//  KalsmritikoshTests
//
//  Investigator workflow review 2026-10-30, I2 — progress is the state of the work: a blocked
//  result stays an actionable blocker, a not-applicable decision resolves a job without a run, a
//  scope change reopens the review of earlier results, and an empty or blocked result never counts
//  as the job's purpose achieved. Recommendations lead with the case's own next steps.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Job progress and recommendations")
struct JobProgressTests {

    private let t0 = Date(timeIntervalSince1970: 1_769_000_000)

    private func job(_ id: String, _ title: String, _ kind: PersonaJobKind = .contradictionGap) -> PersonaJob {
        PersonaJob(persona: "hr", id: id, title: title, detail: "", kind: kind)
    }
    private func record(_ state: JobResultState, rows: Int = 2, review: JobResultReview? = nil, at: Date? = nil,
                        limitations: [String] = [], next: [String] = []) -> JobResultRecord {
        var rs = (0..<rows).map { JobResultRow(title: "row \($0)") }
        if review != nil { rs = rs.enumerated().map { i, r in var r = r; if i == 0 { r.decision = .accepted }; return r } }
        return JobResultRecord(id: UUID(), caseID: UUID(), jobID: "j", family: "f", state: state,
                               content: JobResultContent(rows: rs, limitations: limitations, nextActions: next, review: review),
                               createdBy: "me", createdAt: at ?? t0)
    }

    @Test("A launch is not progress: a blocked result is a blocker with its remedy, an empty draft is unmet, only completed or not-applicable resolve")
    func statesFromResults() {
        let blocked = JobProgress.of(result: record(.blocked, rows: 0, limitations: ["No statement attributed to a named person"], next: ["Add the statements"]),
                                     ran: true, notApplicable: nil, lastScopeChange: nil)
        #expect(blocked.state == .blocked(reason: "No statement attributed to a named person", remedy: "Add the statements"))
        #expect(!blocked.state.isResolved && blocked.state.needsAttention)
        let empty = JobProgress.of(result: record(.draft, rows: 0), ran: true, notApplicable: nil, lastScopeChange: nil)
        #expect(empty.state == .draft(rows: 0) && !empty.state.isResolved && empty.label == "Draft — produced no rows")
        let draft = JobProgress.of(result: record(.draft, rows: 3), ran: true, notApplicable: nil, lastScopeChange: nil)
        #expect(draft.state == .draft(rows: 3) && !draft.state.isResolved)
        let reviewed = JobProgress.of(result: record(.draft, rows: 3, review: JobResultReview(by: "me", at: t0, note: nil, completed: false)),
                                      ran: true, notApplicable: nil, lastScopeChange: nil)
        #expect(reviewed.state == .reviewed(undecided: 2) && !reviewed.state.isResolved)
        let completed = JobProgress.of(result: record(.completed, review: JobResultReview(by: "Ada", at: t0, note: "checked", completed: true)),
                                       ran: true, notApplicable: nil, lastScopeChange: nil)
        #expect(completed.state == .completed(by: "Ada") && completed.state.isResolved)
        let attempted = JobProgress.of(result: nil, ran: true, notApplicable: nil, lastScopeChange: nil)
        #expect(attempted.state == .attempted && !attempted.state.isResolved)
        #expect(JobProgress.of(result: nil, ran: false, notApplicable: nil, lastScopeChange: nil).state == .notStarted)
        // Not applicable resolves without a run; a blank reason is not a decision.
        let na = JobProgress.of(result: nil, ran: false, notApplicable: "No witnesses in this matter", lastScopeChange: nil)
        #expect(na.state == .notApplicable(reason: "No witnesses in this matter") && na.state.isResolved)
        #expect(JobProgress.of(result: nil, ran: false, notApplicable: "  ", lastScopeChange: nil).state == .notStarted)
    }

    @Test("A scope change after a result marks it as from the earlier scope; a result made after does not carry the mark")
    func scopeChangeReopens() {
        let change = t0.addingTimeInterval(100)
        let before = JobProgress.of(result: record(.completed, at: t0), ran: true, notApplicable: nil, lastScopeChange: change)
        #expect(before.fromEarlierScope && before.label.contains("from an earlier scope"))
        let after = JobProgress.of(result: record(.completed, at: change.addingTimeInterval(1)), ran: true, notApplicable: nil, lastScopeChange: change)
        #expect(!after.fromEarlierScope)
    }

    @Test("The summary counts honestly; resolved = completed + not applicable")
    func summary() {
        let s = JobProgressSummary([
            JobProgress(state: .completed(by: "me")), JobProgress(state: .notApplicable(reason: "n/a")),
            JobProgress(state: .blocked(reason: "x", remedy: nil)), JobProgress(state: .draft(rows: 2)),
            JobProgress(state: .attempted), JobProgress(state: .notStarted), JobProgress(state: .reviewed(undecided: 1), fromEarlierScope: true),
        ])
        #expect(s.total == 7 && s.resolved == 2 && s.blocked == 1 && s.toReview == 2 && s.attempted == 1 && s.notStarted == 1 && s.earlierScope == 1)
        #expect(s.text == "1 completed · 1 not applicable · 1 blocked · 2 to review · 1 ran without a saved result · 1 not started · 1 from an earlier scope")
    }

    @Test("Recommendations: the case's steps lead; a blocked job is an actionable blocker; an irrelevant job holds nothing; a scope change reopens the review; an empty result is named as unmet")
    func recommendations() {
        let steps = [CaseNextStep(id: "sources", text: "No documents are in this case yet. Add the sources the investigation covers.", place: .evidence)]
        let statements = job("hr.statements", "Statement comparison")
        let irrelevant = job("hr.disclosure", "Disclosure review", .capaRegister)
        let contradictions = job("hr.contradictions", "Contradictions")
        let empty = job("hr.timeline", "Incident timeline")
        let draft = job("hr.register", "Evidence register")
        let recs = JobRecommendations.compute(caseSteps: steps, jobs: [
            (statements, JobProgress(state: .blocked(reason: "no statement attributed to a named person", remedy: "Add the statements"))),
            (irrelevant, JobProgress(state: .notApplicable(reason: "no corrective action in this matter"))),
            (contradictions, JobProgress(state: .completed(by: "me"), fromEarlierScope: true)),
            (empty, JobProgress(state: .draft(rows: 0))),
            (draft, JobProgress(state: .draft(rows: 4))),
        ])
        #expect(recs.first?.id == "case-sources", "the case's own next step leads")
        #expect(recs.contains { $0.id == "blocked-hr.statements" && $0.text.contains("Add the statements") })
        #expect(!recs.contains { $0.jobID == "hr.disclosure" }, "a not-applicable job asks for nothing")
        #expect(recs.contains { $0.id == "scope-hr.contradictions" && $0.text.contains("run it again") })
        #expect(recs.contains { $0.id == "empty-hr.timeline" && $0.text.contains("purpose is not met") })
        #expect(recs.contains { $0.id == "review-hr.register" && $0.text.contains("4 row(s)") })
        // Blocked before review; nothing twice.
        #expect(recs.firstIndex { $0.kind == .blockedJob }! < recs.firstIndex { $0.kind == .reviewJob }!)
        #expect(Set(recs.map(\.id)).count == recs.count)
    }
}
