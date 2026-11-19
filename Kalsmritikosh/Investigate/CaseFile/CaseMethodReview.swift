//
//  CaseMethodReview.swift
//  Kalsmritikosh
//
//  Case plan 2026-11-16 (REASON-14) — "What haven't we considered?": one review of every registered professional method
//  against one case question, revision and evidence scope. Each method gets exactly one outcome — useful now, already
//  covered, needs an input, useful later or inapplicable — with its reason in plain words; a method this build has no
//  guidance for is "not assessed", never silently left out. Deterministic and offline: the same case state gives the same
//  review, and no AI is involved (AI-15 may propose more under the case's permission, through the same contract).
//
//  A method considered here is not a method performed: the review never creates, completes or edits a MethodRun.
//  Performing a method opens or creates its run through the existing lifecycle (ProfessionalMethodLifecycleEngine);
//  a completed run of the same method version is reused and shown as "already covered".
//

import Foundation

/// What the review knows about the case — counts read from the ledger, nothing interpreted.
public nonisolated struct CaseMethodReviewInput: Sendable, Equatable {
    /// The investigator's question (empty: none stated yet).
    public var question = ""
    /// The case revision the review was made at (a fingerprint of its document versions), kept with the review.
    public var caseRevision: String?
    public var documents = 0
    /// Documents in the case not yet read or not readable (a gap in what any method can rest on).
    public var unreadDocuments = 0
    public var people = 0
    public var datedEvents = 0
    public var moneyRecords = 0
    /// Look-alike money pairs counted once until a person decides.
    public var undecidedMoneyPairs = 0
    /// Contradictions not yet decided (awaiting or reopened).
    public var openContradictions = 0
    /// Explanations / lines of inquiry still open (hypotheses, leads, alternatives).
    public var openExplanations = 0
    /// Expected items not found, and evidence requests not fully answered.
    public var missingItems = 0
    public var openRequests = 0
    /// Sources with a recorded preservation or response deadline still ahead.
    public var datedDeadlines = 0
    /// Whether a root cause is stated in a reviewed analysis, and whether one is stated at all.
    public var rootCauseReviewed = false
    public var rootCauseStated = false
    /// Corrective actions recorded, and how many of them have a follow-up measure.
    public var correctiveActions = 0
    public var correctiveActionsFollowedUp = 0
    /// The case's method runs (any status).
    public var runs: [Run] = []

    public struct Run: Sendable, Equatable {
        public var id: UUID
        public var methodID: String
        public var methodVersion: Int
        public var status: MethodRunStatus
        public var contentRevision: Int
        public init(id: UUID, methodID: String, methodVersion: Int, status: MethodRunStatus, contentRevision: Int) {
            self.id = id; self.methodID = methodID; self.methodVersion = methodVersion; self.status = status; self.contentRevision = contentRevision
        }
    }
    public init() {}
}

/// One registered method version, as the catalog describes it.
public nonisolated struct CaseMethodReviewMethod: Sendable, Equatable {
    public var id: String
    public var version: Int
    public var label: String
    public init(id: String, version: Int, label: String) { self.id = id; self.version = version; self.label = label }
}

public nonisolated enum CaseMethodApplicability: String, Sendable, Codable, CaseIterable {
    case usefulNow, alreadyCovered, needsInput, usefulLater, inapplicable, notAssessed
    public var label: String {
        switch self {
        case .usefulNow: return "Useful now"
        case .alreadyCovered: return "Already covered"
        case .needsInput: return "Needs an input"
        case .usefulLater: return "Useful later"
        case .inapplicable: return "Not applicable"
        case .notAssessed: return "Not assessed"
        }
    }
}

/// One method's outcome for this question: why, the check it would contribute, and any run it rests on.
public nonisolated struct CaseMethodAssessment: Sendable, Equatable, Identifiable {
    public var id: String { methodID }
    public let methodID: String
    public let methodVersion: Int
    public let label: String
    public let outcome: CaseMethodApplicability
    public let reason: String
    /// The question this method contributes (plan §B) — what performing it would answer.
    public let contributes: String
    /// A run of this method the outcome rests on (in progress or completed at this version).
    public let priorRunID: UUID?
}

public nonisolated struct CaseMethodReviewResult: Sendable, Equatable {
    public let question: String
    public let caseRevision: String?
    public let assessments: [CaseMethodAssessment]
    /// The methods worth doing now, in catalog order (the short list); `assessments` is "Show all".
    public var shortlist: [CaseMethodAssessment] { assessments.filter { $0.outcome == .usefulNow } }
    /// Every registered method has exactly one assessment (none silently omitted).
    public func accountsFor(_ methods: [CaseMethodReviewMethod]) -> Bool {
        Set(assessments.map(\.methodID)) == Set(methods.map(\.id)) && assessments.count == methods.count
    }
}

public nonisolated enum CaseMethodReview {

    /// Registered ids (ProfessionalMethodCatalog.standardMethods).
    static let prefix = "com.kalsmritikosh.method."

    /// What each method contributes to an investigation question (plan §B), by its id.
    static let contributes: [String: String] = [
        "brainstorming": "Which materially different explanations have we overlooked?",
        "5w1h": "Which who, what, when, where, why or how is still unknown?",
        "hypothesis-matrix": "Which evidence counts against each explanation?",
        "evidence-collection-plan": "What should we obtain, from whom, and by when?",
        "five-whys": "What upstream condition might explain this observation?",
        "fishbone": "Which families of causes have received little scrutiny?",
        "root-cause": "Which causal account survives the alternatives?",
        "capa": "What change addresses the established cause or failed safeguard?",
        "effectiveness-review": "Did the corrective action change the outcome?",
        "contradiction-matrix": "Are two statements genuinely about the same event and subject?",
        "gap-analysis": "What expected evidence is absent within the checked scope?",
        "timeline-analysis": "What sequence is possible once uncertainty is included?",
        "relationship-analysis": "Which direct or indirect link matters, and what supports it?",
        "transaction-flow": "Where did the value go, and what was reversed or duplicated?",
        "risk-matrix": "Which plausible consequence or expiring source needs attention?",
        "decision-matrix": "Which next checks best distinguish the remaining explanations?",
    ]

    /// The review: one assessment per method, in the order given (the catalog's).
    public static func assess(methods: [CaseMethodReviewMethod], input: CaseMethodReviewInput) -> CaseMethodReviewResult {
        CaseMethodReviewResult(question: input.question, caseRevision: input.caseRevision,
                               assessments: methods.map { assess($0, input) })
    }

    static func assess(_ m: CaseMethodReviewMethod, _ c: CaseMethodReviewInput) -> CaseMethodAssessment {
        let key = m.id.hasPrefix(prefix) ? String(m.id.dropFirst(prefix.count)) : m.id
        func out(_ o: CaseMethodApplicability, _ reason: String, run: UUID? = nil) -> CaseMethodAssessment {
            CaseMethodAssessment(methodID: m.id, methodVersion: m.version, label: m.label, outcome: o, reason: reason,
                                 contributes: contributes[key] ?? "", priorRunID: run)
        }
        guard contributes[key] != nil else {
            return out(.notAssessed, "This build has no guidance for this method yet; open it to judge for yourself.")
        }
        // Existing work at this method version: a completed run covers it; an unfinished one is the place to continue.
        let runs = c.runs.filter { $0.methodID == m.id && $0.methodVersion == m.version && $0.status != .superseded && $0.status != .cancelled }
        if let done = runs.first(where: { $0.status == .completed }) {
            return out(.alreadyCovered, "A completed run of this method exists (content revision \(done.contentRevision)); reopen it if the case has changed since.", run: done.id)
        }
        if let open = runs.first {
            return out(.usefulNow, "A run of this method is \(open.status.rawValue); continue it rather than starting another.", run: open.id)
        }
        if c.documents == 0 {
            return out(.needsInput, "The case has no documents yet; add the material first.")
        }
        let question = !c.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch key {
        case "brainstorming":
            return c.openExplanations < 2
                ? out(.usefulNow, c.openExplanations == 0 ? "No explanation is recorded yet: list materially different ones before testing any."
                                                          : "Only one explanation is recorded: list materially different alternatives before testing it.")
                : out(.usefulLater, "\(c.openExplanations) explanations are open; brainstorm again when new evidence arrives.")
        case "5w1h":
            guard question else { return out(.needsInput, "State the question the case is to answer first.") }
            if c.people == 0 || c.datedEvents == 0 {
                return out(.usefulNow, c.people == 0 ? "No person is recorded: who is involved is still unknown." : "No dated event is recorded: when is still unknown.")
            }
            return out(.usefulLater, "People and dated events are recorded; use it when a new question opens.")
        case "hypothesis-matrix":
            return c.openExplanations >= 2
                ? out(.usefulNow, "\(c.openExplanations) explanations are open: test the evidence against each, including what counts against it.")
                : out(.needsInput, "Needs at least two competing explanations (brainstorm first).")
        case "evidence-collection-plan":
            return c.missingItems + c.openRequests > 0
                ? out(.usefulNow, "\(c.missingItems) expected item(s) are missing and \(c.openRequests) request(s) are open: plan who to obtain them from and by when.")
                : out(.usefulLater, "Nothing is recorded as missing or requested yet.")
        case "five-whys":
            guard question else { return out(.needsInput, "State the observation or question to ask why about first.") }
            return c.rootCauseReviewed
                ? out(.usefulLater, "A reviewed root cause is recorded; use it again if that cause is challenged.")
                : out(.usefulNow, "No reviewed cause is recorded: trace the upstream conditions, citing a source or stating an assumption at each step.")
        case "fishbone":
            return c.rootCauseReviewed
                ? out(.usefulLater, "A reviewed root cause is recorded.")
                : out(.usefulNow, "Check which families of causes (people, process, equipment, material, environment, information) have had little scrutiny.")
        case "root-cause":
            return c.rootCauseStated && !c.rootCauseReviewed
                ? out(.usefulNow, "A root cause is stated but not reviewed: assess it against the alternatives, or record it as inconclusive.")
                : (c.rootCauseReviewed ? out(.usefulLater, "A reviewed root-cause conclusion is recorded.")
                                       : out(.usefulLater, "No cause is stated yet: propose causes first (Five Whys, Fishbone)."))
        case "capa":
            return c.rootCauseReviewed
                ? out(.usefulNow, "A reviewed cause is recorded: tie corrective and preventive actions to it, each with an owner.")
                : out(.usefulLater, "Premature: no reviewed cause or failed safeguard is established yet.")
        case "effectiveness-review":
            guard c.correctiveActions > 0 else { return out(.inapplicable, "No corrective action is recorded, so there is nothing to review yet.") }
            return c.correctiveActionsFollowedUp < c.correctiveActions
                ? out(.usefulNow, "\(c.correctiveActions - c.correctiveActionsFollowedUp) corrective action(s) have no follow-up measure or review date.")
                : out(.alreadyCovered, "Every corrective action has a follow-up measure.")
        case "contradiction-matrix":
            return c.openContradictions > 0
                ? out(.usefulNow, "\(c.openContradictions) contradiction(s) await review: check each pair is about the same event and subject.")
                : out(.usefulLater, "No contradiction is open; run “Find contradictions” to check the documents.")
        case "gap-analysis":
            if c.unreadDocuments > 0 {
                return out(.usefulNow, "\(c.unreadDocuments) document(s) are not read yet: an absence found now may only be unread material.")
            }
            return c.missingItems > 0
                ? out(.usefulNow, "\(c.missingItems) expected item(s) are missing: record where they were looked for and what remains uncertain.")
                : out(.usefulLater, "Nothing is recorded as missing; state what you expect to find and check for it.")
        case "timeline-analysis":
            return c.datedEvents >= 2
                ? out(.usefulNow, "\(c.datedEvents) dated events: check which sequences are possible once each date's precision is included.")
                : out(.needsInput, "Needs at least two dated events.")
        case "relationship-analysis":
            return c.people >= 2
                ? out(.usefulNow, "\(c.people) people are recorded: check which links matter and what supports each.")
                : out(.needsInput, "Needs at least two people or organisations recorded.")
        case "transaction-flow":
            guard c.moneyRecords > 0 else { return out(.inapplicable, "No money records are in the case.") }
            return c.undecidedMoneyPairs > 0
                ? out(.usefulNow, "\(c.undecidedMoneyPairs) look-alike payment pair(s) are counted once until decided: trace where the value went.")
                : out(.usefulNow, "\(c.moneyRecords) money record(s): reconcile per account and currency, keeping refunds and duplicates apart.")
        case "risk-matrix":
            return c.datedDeadlines > 0
                ? out(.usefulNow, "\(c.datedDeadlines) source(s) have a recorded deadline ahead: weigh what could be lost and when.")
                : out(.usefulLater, "No source has a recorded deadline; use it when one is known.")
        case "decision-matrix":
            return c.openExplanations >= 2 && c.missingItems + c.openRequests > 0
                ? out(.usefulNow, "Several explanations are open and checks are pending: compare which next check best tells them apart.")
                : out(.usefulLater, c.openExplanations < 2 ? "Needs two or more open explanations to choose between." : "No check is pending to compare.")
        default:
            return out(.notAssessed, "This build has no guidance for this method yet; open it to judge for yourself.")
        }
    }
}

public extension CaseMethodReviewMethod {
    /// Every method version the standard catalog registers, in its order (the review accounts for each).
    @MainActor static var registered: [CaseMethodReviewMethod] {
        ProfessionalMethodCatalog.standardMethods.map {
            CaseMethodReviewMethod(id: $0.definition.id.rawValue, version: $0.definition.version, label: $0.definition.label)
        }
    }
}

// MARK: - The review's input from the case (case plan 2026-11-16, REASON-14)

public extension CaseMethodReviewInput {
    /// The counts read from the case's own records. `question` is the case's purpose (the question it is to answer) unless
    /// the person asked about one point. Pure, so it is tested without a ledger.
    static func from(question: String, snapshot: CaseFileSnapshot, coverage: CaseCoverageReadout?, openContradictions: Int,
                     money: CaseMoneyLedger?, hypotheses: [InvestigationHypothesis], requests: [EvidenceRequestFile],
                     runs: [MethodRun], now: Date) -> CaseMethodReviewInput {
        var c = CaseMethodReviewInput()
        c.question = question
        let versions = snapshot.custody.map(\.sourceVersionID.uuidString).sorted()
        c.caseRevision = versions.isEmpty ? nil : CaseFileHash.sha256(versions.joined(separator: ","))
        c.documents = snapshot.custody.count
        c.unreadDocuments = coverage?.entries.count ?? 0
        c.people = snapshot.people.count
        c.datedEvents = snapshot.journal.filter { $0.kind == .chronology && $0.eventDate != nil }.count
        if let money {
            c.moneyRecords = money.current.filter { $0.kind.isMovement }.count
            c.undecidedMoneyPairs = money.undecidedPairs().count
        }
        c.openContradictions = openContradictions
        c.openExplanations = hypotheses.filter { $0.status == .proposed }.count
        let live = requests.filter { [.open, .partial].contains($0.request.status) }
        c.openRequests = live.count
        c.missingItems = live.reduce(0) { $0 + $1.progress.outstanding.count }
        c.datedDeadlines = live.filter { ($0.request.dueAt ?? .distantPast) > now }.count
        c.runs = runs.map { .init(id: $0.id, methodID: $0.methodDefinitionID.rawValue, methodVersion: $0.methodDefinitionVersion,
                                  status: $0.status, contentRevision: $0.contentRevision) }
        return c
    }
}
