//
//  CaseMapAccessibility.swift
//  Kalsmritikosh
//
//  Living case map, M9 (plan §4.5, §10, §11 M9; scope §10 "Accessibility and orientation"). Pure, testable
//  rules the map's views follow:
//  • CaseMapCommand — every map action and the control that performs it from the LIST (the list, the header,
//    the view strip, the footer and the inspector are the same in map and list mode), with its keyboard
//    shortcut where it has one. HelpRegistryTests / CaseMapAccessibilityTests check every control name exists.
//  • CaseMapSpoken — VoiceOver labels and values for items, links, header counts and the view strip, so
//    nothing vital is only on hover or only drawn.
//  • CaseMapMotion — no animated transition while Reduce Motion is on.
//  • CaseMapWorkspaceLayout — below a width the inspector becomes a drawer over the map (macOS 26 split-view
//    sizing: the width comes from a GeometryReader, never from the proposal alone).
//  • CaseMapListPaging — the list pages long sections, so a stress-size case stays usable and every record
//    remains reachable ("Show more" until the section ends).
//

import Foundation
import SwiftUI

/// Every map action, with the list-path control that performs the same command.
nonisolated enum CaseMapCommand: String, CaseIterable, Sendable {
    case review, link, request, chronology, report, openSource, viewStrip, back, resetView, history, returnToCurrent
    case pin, hide, select, searchEvidence, export, showDetails

    /// Where the command is in the list path (the inspector, header, strip and footer are shared by map and list).
    var listSurface: String {
        switch self {
        case .review, .link, .request, .chronology, .report, .openSource, .pin, .hide: return "inspector"
        case .viewStrip, .back: return "view strip"
        case .resetView, .export: return "footer"
        case .history, .searchEvidence: return "header"
        case .returnToCurrent: return "history banner"
        case .select: return "list"
        case .showDetails: return "content"
        }
    }

    /// The exact control names that perform it (each exists as a literal in the UI sources).
    var controls: [String] {
        switch self {
        case .review: return ["Confirm", "Dismiss", "Defer"]
        case .link: return ["Link to another item…", "Link to allegation…", "Record link"]
        case .request: return ["Create evidence request…", "Received for request…"]
        case .chronology: return ["Add to chronology"]
        case .report: return ["Include in report"]
        case .openSource: return ["Open source"]
        case .viewStrip: return ["Previous view", "Next view"]
        case .back: return ["Back"]
        case .resetView: return ["Reset view"]
        case .history: return ["History"]
        case .returnToCurrent: return ["Return to current"]
        case .pin: return ["Pin", "Unpin"]
        case .hide: return ["Hide from this view"]
        case .select: return ["case.map.list"]
        case .searchEvidence: return ["Search case evidence"]
        case .export: return ["Export"]
        case .showDetails: return ["Show details"]
        }
    }

    /// The keyboard shortcut, where the command has one (shown in Help ▸ Case Map Keyboard Shortcuts).
    var shortcut: String? {
        switch self {
        case .viewStrip: return "⌃⌘← / ⌃⌘→"
        case .back: return "⌃⌘["
        case .returnToCurrent: return "⌘⎋"
        case .showDetails: return "⌃⌘I"
        case .select: return "↑ ↓ in the list"
        default: return nil
        }
    }

    /// Whether the command needs the spatial map (none does: the list path is complete).
    var mapOnly: Bool { false }
}

/// Keyboard instructions, one line each — the Help menu topic and the legend read the same lines.
nonisolated enum CaseMapKeyboard {
    static let lines: [String] = [
        "Tab and Shift-Tab move between the header, the view strip, the map or list, the inspector and the footer.",
        "⌃⌘← and ⌃⌘→: previous and next view in the strip. ⌃⌘[: Back to the previous view and selection.",
        "In the list, ↑ and ↓ select an item or a link; the inspector shows it. Space or Return on a collapsed group opens it.",
        "⌃⌘I: show or hide the details drawer when the window is narrow.",
        "⌃⌘= and ⌃⌘-: zoom the map in and out. ⌃⌘Z: Undo a move, pin or Arrange.",
        "⌘⎋: Return to current from a recorded state.",
        "Every action on the map is also in the inspector, the header, the strip or the footer, so the list with the keyboard does everything the map does."
    ]
}

/// VoiceOver text. Nothing vital is only drawn or only on hover.
nonisolated enum CaseMapSpoken {
    static func nodeLabel(_ n: CaseMapNode) -> String { "\(n.kind.label): \(n.title)" }

    static func nodeValue(_ n: CaseMapNode, pinned: Bool, selected: Bool) -> String {
        var parts = ["\(n.status.kind.label): \(n.status.text)", n.review.label]
        if n.changedSourceWarning != nil { parts.append("a source changed since") }
        if pinned { parts.append("pinned") }
        if selected { parts.append("selected") }
        return parts.joined(separator: ". ")
    }

    static func linkLabel(_ l: CaseMapLink, in p: CaseMapProjection) -> String {
        "Link: \(p.node(l.from)?.title ?? "an item") \(l.type.label) \(p.node(l.to)?.title ?? "an item")"
    }

    static func linkValue(_ l: CaseMapLink, selected: Bool) -> String {
        var parts = ["\(l.status.kind.label): \(l.status.text)", l.review.label, l.assertedBy.label]
        if selected { parts.append("selected") }
        return parts.joined(separator: ". ")
    }

    static func countLabel(_ n: Int, _ what: String) -> String { "\(n) \(what)" }
    static func countHint() -> String { "Opens the matching items in the list." }

    static func stripLabel(_ title: String) -> String { "View: \(title)" }
    static func stripValue(index: Int, count: Int, selected: Bool) -> String {
        "\(index + 1) of \(count)" + (selected ? ", current view" : "")
    }
}

/// Reduce Motion: no animated transition at all while it is on.
nonisolated enum CaseMapMotion {
    static func animation(reduceMotion: Bool) -> Animation? { reduceMotion ? nil : .easeOut(duration: 0.15) }
}

/// Narrow windows: the inspector becomes a drawer over the map.
nonisolated enum CaseMapWorkspaceLayout {
    /// The inspector's width beside the map.
    static let inspectorWidth: CGFloat = 340
    /// The narrowest map that is still useful beside the inspector.
    static let minimumMapWidth: CGFloat = 520
    /// Below this content width the inspector is a drawer.
    static var drawerThreshold: CGFloat { inspectorWidth + minimumMapWidth }

    static func inspectorIsDrawer(width: CGFloat) -> Bool { width < drawerThreshold }

    /// The drawer's width: the inspector's own width, never wider than most of the window.
    static func drawerWidth(for width: CGFloat) -> CGFloat { max(0, min(inspectorWidth, width * 0.85)) }
}

/// The list pages long sections; every record stays reachable through "Show more".
nonisolated enum CaseMapListPaging {
    static let pageSize = 500

    /// The shown items by kind, then the unlinked material, in the projection's order.
    static func sections(_ p: CaseMapProjection, result: CaseMapViewResult) -> [(title: String, ids: [CaseMapNodeID])] {
        let shown = Set(result.shown)
        let unlinkedIDs = p.unlinked.filter { shown.contains($0) }
        let unlinked = Set(unlinkedIDs)
        var byKind: [CaseMapNodeKind: [CaseMapNodeID]] = [:]
        for n in p.nodes where shown.contains(n.id) && !unlinked.contains(n.id) { byKind[n.kind, default: []].append(n.id) }
        var out: [(title: String, ids: [CaseMapNodeID])] = []
        for kind in CaseMapNodeKind.allCases { if let ids = byKind[kind], !ids.isEmpty { out.append((kind.plural, ids)) } }
        if !unlinkedIDs.isEmpty { out.append(("Unlinked material", unlinkedIDs)) }
        return out
    }

    /// The rows of a section shown after `pages` pages, and how many are still to come.
    static func visible<T>(_ items: [T], pages: Int) -> (rows: ArraySlice<T>, remaining: Int) {
        let n = min(items.count, max(1, pages) * pageSize)
        return (items.prefix(n), items.count - n)
    }

    /// How many pages reach every row of a section.
    static func pagesToReachAll(_ count: Int) -> Int { max(1, (count + pageSize - 1) / pageSize) }
}

/// The first-use explanation (plan §10): shown once above the map, dismissible, never a slideshow.
nonisolated enum CaseMapFirstUse {
    static let key = "kalsmritikosh.caseMap.firstUseSeen"
    static func shouldShow(_ defaults: UserDefaults) -> Bool { !defaults.bool(forKey: key) }
    static func dismiss(_ defaults: UserDefaults) { defaults.set(true, forKey: key) }
    static let text = "Items are this case's own records; a link says how two relate and why; a review state is what a person decided, separate from what the documents say; “What changed” lists what is new since you last looked — seeing is not reviewing."
}

/// Empty states name the next action (plan §10).
nonisolated enum CaseMapEmptyState {
    /// When a view shows nothing although the case has items: what hides them, and what to do.
    static func viewEmpty(_ counts: CaseMapCounts, view: CaseMapViewKind) -> (title: String, next: String)? {
        // Collapsed groups are drawn as cards (and listed), so a view holding only groups is not empty.
        guard counts.shown == 0, counts.collapsed == 0, counts.total > 1 else { return nil }
        if counts.hidden > 0 && counts.filtered == 0 { return ("Every item of this view is hidden", "Choose “Reset view” to show them again; nothing was removed from the case.") }
        if view == .changes { return ("Nothing changed since you last marked the changes as seen", "Choose “What changed” to see the list, or another view in the strip.") }
        return ("No item matches this view's filters", "Clear “Find on this map” and “Waiting for me”, or choose “Reset view”.")
    }
}
