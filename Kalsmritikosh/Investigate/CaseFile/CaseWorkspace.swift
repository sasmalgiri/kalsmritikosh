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
/// Candidate review LB3 (2026-11-06): only identifiers are kept in the preference — the document, where
/// the passage came from (a contradiction side or a case entry) and the source version it was read at.
/// The passage and the document's name are read again from the ledger when it is reopened, so no
/// document text or file name sits in the plain preferences file.
public nonisolated struct CaseSourcePosition: Codable, Sendable, Equatable {
    public enum Side: String, Codable, Sendable { case a, b }
    /// Where the passage was opened from (its text lives in the ledger, not here).
    public enum Origin: Codable, Sendable, Equatable {
        case contradiction(id: UUID, side: Side)
        case caseEntry(id: UUID)
    }
    public var objectID: UUID
    public var origin: Origin?
    /// The source version the passage was opened at (nil: not known).
    public var revision: UUID?
    public init(objectID: UUID, origin: Origin?, revision: UUID?) { self.objectID = objectID; self.origin = origin; self.revision = revision }

    /// The passage to show again, re-read from what the case holds now: the contradiction's side or the
    /// case entry's quote. Nil when the item is gone, or when the document has a newer version than the one
    /// the passage was opened at (the document then opens without a highlight).
    public func passage(contradictions: [CaseContradictionReviewItem], entries: [CaseJournalEntry],
                        objectForVersion: [UUID: UUID]) -> String? {
        switch origin {
        case .contradiction(let id, let side)?:
            guard let item = contradictions.first(where: { $0.id == id }) else { return nil }
            if let revision, let current = item.currentVersions[objectID], current != revision { return nil }
            return side == .a ? item.contradiction.claimA : item.contradiction.claimB
        case .caseEntry(let id)?:
            guard let entry = entries.first(where: { $0.id == id }) else { return nil }
            return PassageChronology.openTarget(for: entry, objectForVersion: objectForVersion)?.quote
        case nil:
            return nil
        }
    }
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
    /// Living case map (M2) — where the person was on the map: identifiers and geometry only.
    public var map: CaseMapWorkspaceMemory?
    public init() {}
}

/// The case map's place in a case, kept with the case's workspace preference (identifiers and geometry
/// only — no names, quotes or search words; saved views with their words live in the encrypted ledger).
/// Every field is optional so a state written by any earlier build still reads.
public nonisolated struct CaseMapWorkspaceMemory: Codable, Sendable, Equatable {
    /// The person chose the tabbed sections for this case instead of the map.
    public var showsSections: Bool?
    /// The view in the strip: a built-in view's id, or "saved:<uuid>".
    public var view: String?
    /// The list instead of the map.
    public var listMode: Bool?
    public var selectedNode: CaseMapNodeID?
    public var selectedLink: String?
    /// Per view: where the map was looking.
    public var viewports: [String: CaseMapViewport]?
    /// Per built-in view: items hidden from it and groups collapsed in it (saved views keep theirs in the ledger).
    public var hidden: [String: [CaseMapNodeID]]?
    public var collapsed: [String: [String]]?
    /// Earlier focus, for Back (bounded).
    public var back: [CaseMapFocus]?
    /// Smart-map M1 — the frames opened, outermost first (no depth limit; identifiers and geometry only).
    public var frames: [CaseMapFrameLevel]?
    public init() {}
}

/// One open frame: the record it is anchored on, and exactly how the level it was opened from looked (selection and
/// viewport), so returning restores it.
public nonisolated struct CaseMapFrameLevel: Codable, Sendable, Equatable {
    public var anchor: CaseMapNodeID
    public var returnSelectedNode: CaseMapNodeID?
    public var returnSelectedLink: String?
    public var returnViewport: CaseMapViewport?
    public init(anchor: CaseMapNodeID, returnSelectedNode: CaseMapNodeID?, returnSelectedLink: String?, returnViewport: CaseMapViewport?) {
        self.anchor = anchor; self.returnSelectedNode = returnSelectedNode; self.returnSelectedLink = returnSelectedLink; self.returnViewport = returnViewport
    }
}

/// One focus the person can go Back to: a view and what was selected in it.
public nonisolated struct CaseMapFocus: Codable, Sendable, Equatable {
    public var view: String
    public var node: CaseMapNodeID?
    public var link: String?
    public init(view: String, node: CaseMapNodeID?, link: String?) { self.view = view; self.node = node; self.link = link }
}

/// The reversible "Case map (preview)" switch (plan §11: the map does not become the default for anyone
/// until M1–M9 pass). Off unless the person turns it on; turning it off returns every case to its sections
/// and changes no case record.
public nonisolated enum CaseMapPreview {
    public static let key = "kalsmritikosh.caseMap.preview"
    public static func isEnabled(_ defaults: UserDefaults) -> Bool { defaults.bool(forKey: key) }
    public static func set(_ on: Bool, _ defaults: UserDefaults) { defaults.set(on, forKey: key) }
}

/// Load and save a case's workspace state (UI preferences only). The store is injectable for tests.
public nonisolated enum CaseWorkspaceStore {
    /// Every case's key starts with this; a full erase clears the prefix (AppState.caseContentPreferencePrefixes).
    static let keyPrefix = "kalsmritikosh.case.workspace."
    static func key(_ caseID: UUID) -> String { keyPrefix + caseID.uuidString }

    public static func load(caseID: UUID, defaults: UserDefaults) -> CaseWorkspaceState {
        guard let data = defaults.data(forKey: key(caseID)),
              let state = try? JSONDecoder().decode(CaseWorkspaceState.self, from: data) else { return CaseWorkspaceState() }
        // LB3 — a state saved by an earlier build may still hold a quote and a file name: write it back
        // without them (decoding drops every field this build no longer keeps).
        if String(decoding: data, as: UTF8.self).contains("\"quote\"") { save(state, caseID: caseID, defaults: defaults) }
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
        if let line = contradictionCheckLimit(s, contradictions: contradictions) { limits.append(line) }
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

    /// What the overview says about the case's own contradiction check (UI walk 2026-11-06: it must not
    /// say the documents were never compared while contradictions from the archive scan are listed).
    /// Nil when the case check has run (recorded, or its findings are present) or there are no documents.
    static func contradictionCheckLimit(_ s: CaseFileSnapshot, contradictions: [CaseContradictionReviewItem]) -> String? {
        guard !s.custody.isEmpty, !s.actions.contains(where: { $0.action == "contradictions checked" }) else { return nil }
        if contradictions.contains(where: { CaseContradictionFinder.provenance(of: $0.contradiction) != nil }) { return nil }
        if contradictions.isEmpty {
            return "This case's documents have not been compared for contradictions yet (“Find contradictions”)."
        }
        return "The archive scan compared these documents and found \(contradictions.count) contradiction(s), listed below; "
            + "this case's own comparison (“Find contradictions”: the rules, and the AI reading where allowed) has not run yet."
    }

    /// Rows still undecided in the case's current job results (a completed result counts none).
    public static func undecidedRows(_ results: [JobResultRecord]) -> Int {
        results.filter { $0.state != .completed && $0.state != .superseded }
            .reduce(0) { $0 + $1.content.rows.filter { $0.decision == nil }.count }
    }
}
