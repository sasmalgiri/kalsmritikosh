//
//  CaseMapViewFilter.swift
//  Kalsmritikosh
//
//  Living case map, M2/M3: the manual view strip's views (Overview, Questions, People, Chronology, Findings,
//  Changes), the filters a view applies, and the counts every view discloses. One function decides what a
//  view shows, for the map AND the list, so both always show the same records under the same filters.
//  Every projected item is accounted for: shown + collapsed + filtered + hidden = everything in the case.
//  Hiding an item from a view has no evidentiary effect.
//

import Foundation

/// The built-in views of the strip, in order. The strip never advances on its own.
public nonisolated enum CaseMapViewKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case overview, questions, people, chronology, findings, changes
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .overview: return "Overview"
        case .questions: return "Questions"
        case .people: return "People"
        case .chronology: return "Chronology"
        case .findings: return "Findings"
        case .changes: return "Changes"
        }
    }
    public var symbol: String {
        switch self {
        case .overview: return "map"
        case .questions: return "questionmark.bubble"
        case .people: return "person.2"
        case .chronology: return "calendar.day.timeline.left"
        case .findings: return "checkmark.seal"
        case .changes: return "clock.arrow.circlepath"
        }
    }
    public var emphasis: String {
        switch self {
        case .overview: return "The main question, its issue groups, what is unresolved and the next actions."
        case .questions: return "Each question or allegation with supporting, challenging and missing material."
        case .people: return "People and organisations, their statements, events, documents and recorded connections."
        case .chronology: return "Recorded events with their dates and linked evidence."
        case .findings: return "Report items and decided questions, with contrary evidence and what needs review."
        case .changes: return "Items changed since you last marked the changes as seen, items resting on changed evidence, and items changed since they were decided or carried (reopened, superseded, stale)."
        }
    }
    /// The kinds the view shows by default.
    public var kinds: Set<CaseMapNodeKind> {
        switch self {
        case .overview: return Set(CaseMapNodeKind.allCases).subtracting([.group])
        case .questions: return [.question, .hypothesis, .evidence, .statement, .contradiction, .action, .note]
        case .people: return [.person, .statement, .event, .evidence]
        case .chronology: return [.event, .evidence, .statement]
        case .findings: return [.finding, .question, .evidence, .contradiction]
        case .changes: return Set(CaseMapNodeKind.allCases).subtracting([.group])
        }
    }
    /// Groups collapsed until the person opens them (the overview starts small).
    public var collapsedByDefault: Set<String> {
        switch self {
        case .overview: return ["group:evidence", "group:event", "group:note", "group:statement", "group:person", CaseMapGroup.unlinkedID]
        default: return []
        }
    }
}

/// What a view filters by. Saved views keep it in the ledger (case_map_views.filters_json).
public nonisolated struct CaseMapFilter: Codable, Equatable, Sendable {
    /// Kinds shown (nil: the view's own kinds).
    public var kinds: Set<CaseMapNodeKind>?
    /// Only items waiting for the person (not reviewed, deferred, reopened, pending).
    public var awaitingOnly = false
    /// Words that must all appear in the item's title or wording.
    public var search = ""
    /// Items hidden from this view (identity only).
    public var hidden: [CaseMapNodeID] = []
    /// Group ids collapsed in this view (nil: the view's defaults).
    public var collapsed: [String]?
    public init(kinds: Set<CaseMapNodeKind>? = nil, awaitingOnly: Bool = false, search: String = "", hidden: [CaseMapNodeID] = [], collapsed: [String]? = nil) {
        self.kinds = kinds; self.awaitingOnly = awaitingOnly; self.search = search; self.hidden = hidden; self.collapsed = collapsed
    }

    func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
    static func decode(_ raw: String?) -> CaseMapFilter {
        guard let raw, let data = raw.data(using: .utf8), let f = try? JSONDecoder().decode(CaseMapFilter.self, from: data) else { return CaseMapFilter() }
        return f
    }

    /// DATA-07: the same decode, saying precisely why stored filters could not be read (nil problem: read, or nothing stored).
    static func decodeChecked(_ raw: String?) -> (CaseMapFilter, String?) {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (CaseMapFilter(), nil) }
        do {
            return (try JSONDecoder().decode(CaseMapFilter.self, from: Data(raw.utf8)), nil)
        } catch {
            return (CaseMapFilter(), "The view's saved filters could not be read (\(error.localizedDescription)). It is shown unfiltered; save the view again to replace them.")
        }
    }
}

/// Every item of the case accounted for in one view.
public nonisolated struct CaseMapCounts: Equatable, Sendable {
    public let total: Int
    public let shown: Int
    public let collapsed: Int
    public let filtered: Int
    public let hidden: Int
    /// Parts of the case that could not be read (their items are not in `total`).
    public let notLoaded: [CaseMapPart]
    public var reconciles: Bool { shown + collapsed + filtered + hidden == total }
    public var summary: String {
        var parts = ["\(shown) shown"]
        if collapsed > 0 { parts.append("\(collapsed) in collapsed groups") }
        if filtered > 0 { parts.append("\(filtered) filtered out") }
        if hidden > 0 { parts.append("\(hidden) hidden from this view") }
        var s = parts.joined(separator: " · ") + " — \(total) in the case"
        if !notLoaded.isEmpty { s += "; not loaded: " + notLoaded.map(\.label).joined(separator: ", ") }
        return s
    }
}

/// What a view shows.
public nonisolated struct CaseMapViewResult: Equatable, Sendable {
    public let shown: [CaseMapNodeID]
    /// Collapsed groups with the members they hold back (in this view).
    public let collapsedGroups: [CaseMapGroup]
    public let links: [String]
    public let counts: CaseMapCounts
}

public nonisolated enum CaseMapViewFilter {
    /// Decide what one view shows. Order of accounting: filtered (kinds, waiting-only, search, the Changes
    /// view's rule), then hidden, then collapsed. Links are shown only between shown items. `changed` (M6) are the
    /// items the case change feed reports as changed since the person's seen position (and what rests on changed
    /// evidence): the Changes view shows them too.
    public static func apply(_ p: CaseMapProjection, view: CaseMapViewKind, filter: CaseMapFilter,
                             changed: Set<CaseMapNodeID> = []) -> CaseMapViewResult {
        let kinds = filter.kinds ?? view.kinds
        let words = filter.search.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let hidden = Set(filter.hidden)
        let collapsedIDs = Set(filter.collapsed ?? Array(view.collapsedByDefault))
        let unlinked = Set(p.unlinked)
        var shown: [CaseMapNodeID] = []
        var held: [String: [CaseMapNodeID]] = [:]
        var filtered = 0, hiddenCount = 0
        for n in p.nodes {
            let passes: Bool = {
                guard kinds.contains(n.kind) else { return false }
                if view == .changes, n.status.kind != .stale, n.review != .reopened, n.changedSourceWarning == nil, !changed.contains(n.id) { return false }
                if filter.awaitingOnly, !n.review.awaitingReview { return false }
                if !words.isEmpty {
                    let hay = (n.title + " " + (n.wording ?? "") + " " + n.status.text).lowercased()
                    if !words.allSatisfy({ hay.contains($0) }) { return false }
                }
                return true
            }()
            if !passes { filtered += 1; continue }
            if hidden.contains(n.id) { hiddenCount += 1; continue }
            // Unlinked material is held by its own group when that group is collapsed, else by its kind's.
            let groupID = unlinked.contains(n.id) && collapsedIDs.contains(CaseMapGroup.unlinkedID) ? CaseMapGroup.unlinkedID : "group:\(n.kind.rawValue)"
            if collapsedIDs.contains(groupID) { held[groupID, default: []].append(n.id); continue }
            shown.append(n.id)
        }
        let shownSet = Set(shown)
        let links = p.links.filter { shownSet.contains($0.from) && shownSet.contains($0.to) }.map(\.id)
        let collapsedGroups = held.keys.sorted().compactMap { gid -> CaseMapGroup? in
            guard let members = held[gid], !members.isEmpty else { return nil }
            let base = p.groups.first { $0.id == gid }
            return CaseMapGroup(id: gid, title: base?.title ?? gid, kind: base?.kind, members: members)
        }
        let collapsedCount = held.values.reduce(0) { $0 + $1.count }
        return CaseMapViewResult(shown: shown, collapsedGroups: collapsedGroups, links: links,
                                 counts: CaseMapCounts(total: p.nodes.count, shown: shown.count, collapsed: collapsedCount, filtered: filtered,
                                                       hidden: hiddenCount, notLoaded: p.failedParts))
    }
}
