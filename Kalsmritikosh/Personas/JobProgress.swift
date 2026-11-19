//
//  JobProgress.swift
//  Kalsmritikosh
//
//  Investigator workflow review 2026-10-30, I2 — a matter's progress is the state of its work, not
//  the number of jobs launched. A job is NOT STARTED, ATTEMPTED (launched, nothing saved), BLOCKED
//  (the case gave it nothing; the remedy is named), a DRAFT to review, REVIEWED (decisions saved,
//  not yet completed), COMPLETED, or NOT APPLICABLE by the person's recorded decision with its
//  reason. Only completed and not-applicable count as resolved; a blocked or empty result never
//  suggests that the job's purpose was achieved.
//
//  Recommendations come from the case's own next steps (CaseNextSteps — the one guide), then the
//  blockers and reviews the job results add. Pure values; the model feeds them.
//

import Foundation

public nonisolated enum JobWorkState: Equatable, Sendable {
    case notStarted
    /// Launched; the service returned, nothing was saved for review (a service-kind job).
    case attempted
    /// The result is blocked: what is missing and what would fix it.
    case blocked(reason: String, remedy: String?)
    /// A generated result awaiting review (`rows` to look at; 0 means it produced nothing).
    case draft(rows: Int)
    /// The person saved decisions but has not completed it (`undecided` rows left).
    case reviewed(undecided: Int)
    case completed(by: String)
    /// The person decided this job does not apply to the matter, with the reason.
    case notApplicable(reason: String)

    /// Resolved work: it no longer holds the matter in its phase.
    public var isResolved: Bool {
        switch self {
        case .completed, .notApplicable: return true
        default: return false
        }
    }
    /// Work that needs the person's attention now.
    public var needsAttention: Bool {
        switch self {
        case .blocked, .draft, .reviewed: return true
        default: return false
        }
    }
    public var label: String {
        switch self {
        case .notStarted: return "Not started"
        case .attempted: return "Ran — nothing saved to review"
        case .blocked: return "Blocked"
        case .draft(let n): return n == 0 ? "Draft — produced no rows" : "Draft — \(n) row(s) to review"
        case .reviewed(let n): return n == 0 ? "Reviewed — ready to complete" : "Reviewed — \(n) row(s) still undecided"
        case .completed(let by): return "Completed by \(by)"
        case .notApplicable(let r): return "Not applicable — \(r)"
        }
    }
}

public nonisolated struct JobProgress: Equatable, Sendable {
    public let state: JobWorkState
    /// The saved result predates the case's last scope change.
    public let fromEarlierScope: Bool

    public init(state: JobWorkState, fromEarlierScope: Bool = false) {
        self.state = state; self.fromEarlierScope = fromEarlierScope
    }

    /// The state of one job from what the ledger holds for it.
    public static func of(result: JobResultRecord?, ran: Bool, notApplicable: String?, lastScopeChange: Date?) -> JobProgress {
        if let reason = notApplicable?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            return JobProgress(state: .notApplicable(reason: reason))
        }
        guard let r = result else { return JobProgress(state: ran ? .attempted : .notStarted) }
        let stale = lastScopeChange.map { r.createdAt < $0 } ?? false
        switch r.state {
        case .blocked:
            return JobProgress(state: .blocked(reason: r.content.limitations.first ?? "the case gave this job nothing to work from",
                                               remedy: r.content.nextActions.first), fromEarlierScope: stale)
        case .draft:
            if r.content.review != nil {
                return JobProgress(state: .reviewed(undecided: r.content.rows.filter { $0.decision == nil }.count), fromEarlierScope: stale)
            }
            return JobProgress(state: .draft(rows: r.content.rows.count), fromEarlierScope: stale)
        case .completed:
            return JobProgress(state: .completed(by: r.content.review?.by ?? r.createdBy), fromEarlierScope: stale)
        case .superseded:
            return JobProgress(state: ran ? .attempted : .notStarted)
        }
    }

    public var label: String {
        state.label + (fromEarlierScope ? " · from an earlier scope — run again to cover the documents added since" : "")
    }
}

/// Counts for the matter card — honest about what each number is.
public nonisolated struct JobProgressSummary: Equatable, Sendable {
    public var total = 0, completed = 0, notApplicable = 0, blocked = 0, toReview = 0, attempted = 0, notStarted = 0, earlierScope = 0

    public init(_ progress: [JobProgress]) {
        total = progress.count
        for p in progress {
            switch p.state {
            case .completed: completed += 1
            case .notApplicable: notApplicable += 1
            case .blocked: blocked += 1
            case .draft, .reviewed: toReview += 1
            case .attempted: attempted += 1
            case .notStarted: notStarted += 1
            }
            if p.fromEarlierScope { earlierScope += 1 }
        }
    }

    /// Resolved work (completed or not applicable) over the total.
    public var resolved: Int { completed + notApplicable }
    public var fraction: Double { total == 0 ? 0 : Double(resolved) / Double(total) }

    public var text: String {
        var parts = ["\(completed) completed"]
        if notApplicable > 0 { parts.append("\(notApplicable) not applicable") }
        if blocked > 0 { parts.append("\(blocked) blocked") }
        if toReview > 0 { parts.append("\(toReview) to review") }
        if attempted > 0 { parts.append("\(attempted) ran without a saved result") }
        if notStarted > 0 { parts.append("\(notStarted) not started") }
        if earlierScope > 0 { parts.append("\(earlierScope) from an earlier scope") }
        return parts.joined(separator: " · ")
    }
}

/// One recommended next action with the case fact behind it.
public nonisolated struct JobRecommendation: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case caseStep(CaseNextStep.Place), blockedJob, reviewJob, earlierScope, emptyResult }
    public let id: String
    public let text: String
    public let kind: Kind
    /// The job the action belongs to (nil for a case-file step).
    public let jobID: String?
}

public nonisolated enum JobRecommendations {
    /// The case's own next steps lead (CaseNextSteps is the one guide); then every blocked job
    /// with its remedy; then results overtaken by a scope change (a new document reopens the
    /// review); then drafts waiting for review; then results that produced nothing.
    public static func compute(caseSteps: [CaseNextStep], jobs: [(job: PersonaJob, progress: JobProgress)]) -> [JobRecommendation] {
        var out: [JobRecommendation] = caseSteps.map { .init(id: "case-\($0.id)", text: $0.text, kind: .caseStep($0.place), jobID: nil) }
        for (job, p) in jobs {
            if case .blocked(let reason, let remedy) = p.state {
                out.append(.init(id: "blocked-\(job.id)", text: "\(job.title) is blocked: \(reason)" + (remedy.map { " — \($0)" } ?? ""), kind: .blockedJob, jobID: job.id))
            }
        }
        // Any saved result — reviewed, completed or still a draft — that predates the scope change.
        for (job, p) in jobs where p.fromEarlierScope {
            out.append(.init(id: "scope-\(job.id)", text: "\(job.title) was produced before documents were added to the case — run it again and review what the new documents change.", kind: .earlierScope, jobID: job.id))
        }
        for (job, p) in jobs {
            switch p.state {
            case .draft(let n) where n > 0 && !p.fromEarlierScope:
                out.append(.init(id: "review-\(job.id)", text: "\(job.title): \(n) row(s) await your review.", kind: .reviewJob, jobID: job.id))
            case .reviewed(let n) where !p.fromEarlierScope:
                out.append(.init(id: "finish-\(job.id)", text: n == 0 ? "\(job.title) is reviewed — complete it with your note." : "\(job.title): \(n) row(s) still undecided.", kind: .reviewJob, jobID: job.id))
            case .draft(0):
                out.append(.init(id: "empty-\(job.id)", text: "\(job.title) produced no rows — its purpose is not met; check the case's documents or mark it not applicable with the reason.", kind: .emptyResult, jobID: job.id))
            default: break
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }
    }
}
