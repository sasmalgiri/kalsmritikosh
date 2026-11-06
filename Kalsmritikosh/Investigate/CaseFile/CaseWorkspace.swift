//
//  CaseWorkspace.swift
//  Kalsmritikosh
//
//  Owner's implementation plan 2026-11-04, P1-A — one persistent case workspace.
//  • CaseWorkspaceState: where the person was in a case (tab, selected item, filter and search text,
//    the source they last opened). A UI PREFERENCE, kept in the preference store keyed by case id; the
//    evidence and every decision stay in the ledger. Reopening the case — or the app — puts them back.
//  • CaseGlance: the case overview's facts — the investigation question, what limits the reading, what
//    is waiting for review, the open evidence requests and the next case-specific step — computed from
//    what the case holds (pure; it decides nothing).
//

import Foundation
import os

/// The last source the person opened in a case, so "Return to the last source" opens it again.
public nonisolated struct CaseSourcePosition: Codable, Sendable, Equatable {
    public var objectID: UUID
    public var quote: String?
    public var label: String?
    public init(objectID: UUID, quote: String?, label: String?) { self.objectID = objectID; self.quote = quote; self.label = label }
}

/// Which contradictions the case screen lists.
public nonisolated enum CaseReviewFilter: String, Codable, Sendable, CaseIterable, Identifiable {
    case awaiting, decided, all
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .awaiting: return "Waiting for a decision"
        case .decided: return "Decided"
        case .all: return "All"
        }
    }
}

public nonisolated struct CaseWorkspaceState: Codable, Sendable, Equatable {
    /// The case file tab (CaseFileTab raw value).
    public var tab: String?
    public var selectedContradictionID: UUID?
    public var contradictionFilter: CaseReviewFilter = .awaiting
    public var contradictionSearch: String = ""
    public var selectedRequestID: UUID?
    public var lastSource: CaseSourcePosition?
    public init() {}
}

/// Load and save a case's workspace state (UI preferences only). The store is injectable for tests.
public nonisolated enum CaseWorkspaceStore {
    static func key(_ caseID: UUID) -> String { "kalsmritikosh.case.workspace.\(caseID.uuidString)" }

    public static func load(caseID: UUID, defaults: UserDefaults) -> CaseWorkspaceState {
        guard let data = defaults.data(forKey: key(caseID)),
              let state = try? JSONDecoder().decode(CaseWorkspaceState.self, from: data) else { return CaseWorkspaceState() }
        return state
    }

    public static func save(_ state: CaseWorkspaceState, caseID: UUID, defaults: UserDefaults) {
        do { defaults.set(try JSONEncoder().encode(state), forKey: key(caseID)) } catch {
            KalsmritikoshLog.ui.error("Case workspace state not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    public static func forget(caseID: UUID, defaults: UserDefaults) { defaults.removeObject(forKey: key(caseID)) }
}

/// The case overview's facts.
public nonisolated struct CaseGlance: Sendable, Equatable {
    /// What the investigation is to answer (the case's purpose, else what was reported).
    public let question: String?
    /// What limits what the app could read or check in this case (from data the case already holds).
    public let limitations: [String]
    public let contradictionsAwaiting: Int
    public let contradictionsReopened: Int
    public let contradictionsDeferred: Int
    /// Job-result rows not yet accepted or rejected, across the case's current results.
    public let resultRowsUndecided: Int
    public let openRequests: Int
    public let overdueRequests: Int
    /// Expected items still missing across the open requests.
    public let missingItems: Int
    public let nextStep: CaseNextStep?

    public var awaitingReview: Int { contradictionsAwaiting + resultRowsUndecided }

    public static func compute(_ s: CaseFileSnapshot, contradictions: [CaseContradictionReviewItem], requests: [EvidenceRequestFile],
                               resultRowsUndecided: Int, aiPermittedDocuments: Int?, unresolvedReferences: Int,
                               custodyReadFailed: Bool, now: Date = Date()) -> CaseGlance {
        let purpose = s.caseHeader.purpose?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reported = s.profile.intake.allegationSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let question = (purpose?.isEmpty == false ? purpose : nil) ?? (reported?.isEmpty == false ? reported : nil)
        var limits: [String] = []
        if custodyReadFailed { limits.append("The custody record could not be read, so the list of documents in this case may be incomplete.") }
        if s.custody.isEmpty && !custodyReadFailed { limits.append("No documents are in this case yet; nothing can be read or checked.") }
        if unresolvedReferences > 0 { limits.append("\(unresolvedReferences) stored reference(s) point at something no longer in this case.") }
        if let n = aiPermittedDocuments {
            if n < s.custody.count { limits.append("The AI was allowed to read \(n) of the \(s.custody.count) documents in this case; the rest are searched on this Mac only.") }
        } else if !s.custody.isEmpty {
            limits.append("The AI has not been allowed to read this case; answers and checks use on-device search and rules.")
        }
        if !s.custody.isEmpty, !s.actions.contains(where: { $0.action == "contradictions checked" }) {
            limits.append("This case's documents have not been compared for contradictions yet (“Find contradictions”).")
        }
        let awaiting = contradictions.filter { $0.status.awaitingReview }
        let reopened = contradictions.filter { $0.status.isReopened }.count
        let deferred = contradictions.filter { $0.status.current == .deferred }.count
        let open = requests.filter { $0.request.status.isOutstanding }
        let steps = CaseNextSteps.compute(s, unresolvedReferences: unresolvedReferences, custodyReadFailed: custodyReadFailed,
                                          evidenceRequests: requests, contradictionsAwaiting: awaiting.count,
                                          contradictionsReopened: reopened, now: now)
        return CaseGlance(question: question, limitations: limits, contradictionsAwaiting: awaiting.count, contradictionsReopened: reopened,
                          contradictionsDeferred: deferred, resultRowsUndecided: resultRowsUndecided, openRequests: open.count,
                          overdueRequests: open.filter { $0.request.isOverdue(at: now) }.count,
                          missingItems: open.reduce(0) { $0 + $1.progress.outstanding.count }, nextStep: steps.first)
    }

    /// Rows still undecided in the case's current job results (a completed result counts none).
    public static func undecidedRows(_ results: [JobResultRecord]) -> Int {
        results.filter { $0.state != .completed && $0.state != .superseded }
            .reduce(0) { $0 + $1.content.rows.filter { $0.decision == nil }.count }
    }
}
