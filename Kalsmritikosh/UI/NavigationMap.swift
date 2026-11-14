//
//  NavigationMap.swift
//  Kalsmritikosh
//
//  Navigation merge (Core and Add-On Scope 2026-11-06, §3 and §9.5–9.6). Four global areas — Cases,
//  Evidence, Search and Outputs — with Settings and Help as utilities and every specialist screen under
//  More tools and the ⌘K palette. Nothing was removed: every `Destination` keeps its raw value (so saved
//  Back/Forward history, palette and menu entries and `SurfaceOpener` calls still resolve) and maps here
//  to the area it now lives in and the surface that shows it. The rules are pure, so the mapping is
//  tested without a window (NavigationMergeTests).
//

import Foundation

/// The area of the app a screen belongs to: the sidebar row that is highlighted while it is open.
public nonisolated enum NavHome: String, CaseIterable, Sendable {
    case cases, evidence, search, outputs, moreTools, settings, help

    public var title: String {
        switch self {
        case .cases: return "Cases"
        case .evidence: return "Evidence"
        case .search: return "Search"
        case .outputs: return "Outputs"
        case .moreTools: return "More tools"
        case .settings: return "Settings"
        case .help: return "Help"
        }
    }

    /// The four global areas, in sidebar and ⌘1–⌘4 order.
    public static let primaries: [NavHome] = [.cases, .evidence, .search, .outputs]
}

/// The sections of the Evidence area. Each is an existing screen; the old destinations open their section.
public nonisolated enum EvidenceSection: String, CaseIterable, Identifiable, Sendable {
    case sources, library, completeness, live
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .sources: return "Sources"
        case .library: return "Library"
        case .completeness: return "Completeness"
        case .live: return "Processing"
        }
    }
}

/// The sections of the Outputs area: saved answers, saved questions, notes and work products.
public nonisolated enum OutputsSection: String, CaseIterable, Identifiable, Sendable {
    case answers, saved, notebook, handoff
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .answers: return "Saved answers"
        case .saved: return "Saved questions"
        case .notebook: return "Notebook"
        case .handoff: return "Work products"
        }
    }
}

/// What the Search area does: find words, or ask a question (Ask lives here, not as a homepage).
public nonisolated enum SearchMode: String, CaseIterable, Identifiable, Sendable {
    case find, ask
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .find: return "Find words"
        case .ask: return "Ask a question"
        }
    }
}

/// Where a search or a question looks. The active case is the default; the whole library is chosen.
public nonisolated enum SearchScope: Equatable, Sendable {
    case activeCase(UUID)
    case library

    /// The scope Search opens with: the active case when there is one, else the library.
    public static func initial(activeCase: UUID?) -> SearchScope {
        activeCase.map { .activeCase($0) } ?? .library
    }

    public var caseID: UUID? {
        if case .activeCase(let id) = self { return id }
        return nil
    }
}

/// What the detail area shows for a destination. Every destination has one (no blank screen).
public nonisolated enum NavigationSurface: Equatable, Sendable {
    /// The Evidence area, on a section (nil: the section last used).
    case evidence(EvidenceSection?)
    /// The Outputs area, on a section (nil: the section last used).
    case outputs(OutputsSection?)
    /// The Search area in a mode.
    case search(SearchMode)
    /// The More tools list.
    case moreTools
    /// The destination's own screen.
    case screen
}

extension Destination {

    /// The four global areas' own destinations (⌘1–⌘4), then the utilities under them.
    nonisolated static let primaries: [Destination] = [.cases, .evidence, .search, .outputs]
    nonisolated static let utilities: [Destination] = [.moreTools, .settings, .guide]

    /// The area each screen now lives in. Exhaustive, so a new destination cannot be left without one.
    nonisolated var home: NavHome {
        switch self {
        case .home, .cases, .workspaces, .caseload:
            return .cases
        case .evidence, .sources, .library, .completeness, .live:
            return .evidence
        case .search, .ask:
            return .search
        case .outputs, .answers, .saved, .notebook, .handoff:
            return .outputs
        case .settings:
            return .settings
        case .guide:
            return .help
        case .moreTools, .work, .workCenter, .registers, .dataLab,
             .timeline, .history, .findings, .dossier, .explore, .matrix, .compareDocs, .connections, .story,
             .reasoning, .hypotheses, .hrStudio, .privilegeStudio, .siuStudio, .faStudio, .jnStudio,
             .rsStudio, .gnStudio, .ccStudio, .inStudio, .dsStudio, .sopBoard, .fundFlow, .emailThreads,
             .review, .transcripts, .insights, .changes, .knowledge, .assertions, .audit, .verifyReceipt,
             .authenticity, .citations, .freshness, .trends, .query, .convert, .redaction, .sutra:
            return .moreTools
        }
    }

    /// What the detail area shows for this destination.
    nonisolated var surface: NavigationSurface {
        switch self {
        case .evidence: return .evidence(nil)
        case .sources: return .evidence(.sources)
        case .library: return .evidence(.library)
        case .completeness: return .evidence(.completeness)
        case .live: return .evidence(.live)
        case .outputs: return .outputs(nil)
        case .answers: return .outputs(.answers)
        case .saved: return .outputs(.saved)
        case .notebook: return .outputs(.notebook)
        case .handoff: return .outputs(.handoff)
        case .search: return .search(.find)
        case .ask: return .search(.ask)
        case .moreTools: return .moreTools
        default: return .screen
        }
    }

    /// The optional pack a screen belongs to, when it has one. With the pack off the screen still opens —
    /// work made with it stays readable — and says that the pack is off and where to turn it on.
    nonisolated var requiredPack: ProductModule? {
        switch self {
        case .ccStudio: return .contentCreatorPersona
        default: return nil
        }
    }

    /// The breadcrumb shown for a screen opened from its area ("Evidence ▸ Library", "More tools ▸ Timeline").
    var breadcrumb: String {
        switch surface {
        case .evidence(let s?): return "Evidence ▸ \(s.title)"
        case .outputs(let s?): return "Outputs ▸ \(s.title)"
        case .search(let m): return "Search ▸ \(m.title)"
        default:
            return home == .moreTools && self != .moreTools ? "More tools ▸ \(title)" : home.title
        }
    }
}

extension EvidenceSection {
    nonisolated var destination: Destination {
        switch self {
        case .sources: return .sources
        case .library: return .library
        case .completeness: return .completeness
        case .live: return .live
        }
    }
}

extension OutputsSection {
    nonisolated var destination: Destination {
        switch self {
        case .answers: return .answers
        case .saved: return .saved
        case .notebook: return .notebook
        case .handoff: return .handoff
        }
    }
}

/// Compatibility routing: a stored screen name (Back/Forward history, a recent-screens list, a menu or
/// palette entry id "go.<name>", a tutorial step) resolves to a destination and the area it opens in.
public nonisolated enum NavigationCompat {
    /// Every destination raw value the app shipped before the merge (2026-11-07). Each still resolves.
    public static let legacyRawValues: [String] = [
        "home", "ask", "search", "work", "workCenter", "registers", "workspaces", "dataLab",
        "timeline", "history", "findings", "notebook", "dossier", "explore", "matrix", "compareDocs", "connections", "story",
        "reasoning", "hypotheses", "hrStudio", "privilegeStudio", "siuStudio", "faStudio", "jnStudio",
        "rsStudio", "gnStudio", "ccStudio", "inStudio", "dsStudio", "sopBoard", "fundFlow", "emailThreads",
        "review", "handoff", "transcripts", "insights", "changes",
        "knowledge", "assertions", "answers", "audit", "verifyReceipt", "library", "saved",
        "authenticity", "citations", "freshness", "trends", "query",
        "sources", "convert", "completeness", "live", "redaction", "caseload", "cases",
        "guide", "settings", "sutra"
    ]

    /// A stored screen name → its destination (nil for a name this version does not know; the caller
    /// stays where it is rather than opening an empty screen).
    public static func destination(raw: String) -> Destination? {
        let name = raw.hasPrefix("go.") ? String(raw.dropFirst(3)) : raw
        return Destination(rawValue: name)
    }

    /// The fixed shortcuts under the persona header before the merge were Professional Jobs, Cases,
    /// Review and Guide; Cases and Help are now permanent rows, so the two that are not stay as shortcuts.
    public static func personaShortcuts(permanent: Set<Destination>) -> [Destination] {
        [Destination.work, .cases, .review, .guide].filter { !permanent.contains($0) }
    }
}

/// The case the person is working in: the case open in Cases (or open when the app last quit). The
/// preference holds the case id only — never its title or contents (scope §9.8).
public nonisolated enum ActiveCaseContext {
    /// The same key CasesView writes (`CasesView.lastOpenKey`; the tests pin that they agree).
    public static let key = "kalsmritikosh.cases.lastOpen"

    public static func caseID(defaults: UserDefaults = AppDefaults.store) -> UUID? {
        defaults.string(forKey: key).flatMap(UUID.init(uuidString:))
    }

    public static func caseID(raw: String) -> UUID? { UUID(uuidString: raw) }

    /// Open a case on one of its sections: remember the section for that case and make it the active case;
    /// the Cases screen then opens it there.
    public static func prepareOpen(caseID: UUID, tab: String?, defaults: UserDefaults = AppDefaults.store) {
        if let tab {
            var state = CaseWorkspaceStore.load(caseID: caseID, defaults: defaults)
            state.tab = tab
            CaseWorkspaceStore.save(state, caseID: caseID, defaults: defaults)
        }
        defaults.set(caseID.uuidString, forKey: key)
    }
}

/// The words that say whether a screen is working in a case or in the whole library (Evidence, Search,
/// Outputs). Pure, so the label is tested; the screens show exactly these strings.
public nonisolated enum ContextLabel {
    public struct CaseFacts: Equatable, Sendable {
        public let title: String
        public let inScope: Int
        public let excluded: Int
        public let closed: Bool
        public init(title: String, inScope: Int, excluded: Int, closed: Bool = false) {
            self.title = title; self.inScope = inScope; self.excluded = excluded; self.closed = closed
        }
    }

    public static let libraryHeadline = "Whole library — no case is open"
    public static let libraryDetail = "These lists cover every document you added. Open a case in Cases to work within it."

    public static func caseHeadline(_ c: CaseFacts) -> String {
        "Active case: \(c.title)" + (c.closed ? " (closed)" : "")
    }

    /// The Evidence area in a case: the lists are still the whole library, and the case's own documents
    /// are counted, with excluded ones kept excluded.
    public static func evidenceDetail(_ c: CaseFacts) -> String {
        let docs = "\(c.inScope) document\(c.inScope == 1 ? "" : "s") in this case"
        let excl = c.excluded > 0 ? "; \(c.excluded) excluded, and they stay excluded" : ""
        return "\(docs)\(excl). The lists below cover the whole library; the case's own evidence is in the case file."
    }

    public static func searchDetail(_ scope: SearchScope, mode: SearchMode, caseTitle: String?) -> String {
        switch (scope, mode) {
        case (.activeCase, .find):
            return "Searching only the documents in \(caseTitle.map { "“\($0)”" } ?? "this case"). Choose “Whole library” to search everything."
        case (.activeCase, .ask):
            return "Answers come only from the documents in \(caseTitle.map { "“\($0)”" } ?? "this case"). Choose “Whole library” to ask across everything."
        case (.library, .find):
            return "Searching every document in the library, not only one case."
        case (.library, .ask):
            return "Answers may come from any document in the library, not only one case."
        }
    }
}

extension Destination {
    /// The Evidence section this destination opens (nil for the area itself: the section last used).
    nonisolated var evidenceSection: EvidenceSection? {
        if case .evidence(let s) = surface { return s }
        return nil
    }

    /// The Outputs section this destination opens (nil for the area itself: the section last used).
    nonisolated var outputsSection: OutputsSection? {
        if case .outputs(let s) = surface { return s }
        return nil
    }
}

/// The Search area's scope: the active case by default, the whole library only when the person chooses
/// it. A change of active case starts again from that case; widening is never automatic.
public nonisolated struct SearchAreaState: Equatable, Sendable {
    public private(set) var activeCase: UUID?
    public private(set) var scope: SearchScope

    public init(activeCase: UUID?) {
        self.activeCase = activeCase
        self.scope = .initial(activeCase: activeCase)
    }

    /// The active case changed (opened, closed in Cases, or no longer in the ledger).
    public mutating func caseChanged(_ id: UUID?) {
        guard id != activeCase else { return }
        activeCase = id
        scope = .initial(activeCase: id)
    }

    /// The person chose "Whole library".
    public mutating func widen() { scope = .library }

    /// The person chose "This case" (only when a case is open).
    public mutating func narrow() {
        if let activeCase { scope = .activeCase(activeCase) }
    }

    /// The case a question is asked in (nil: the whole library).
    public func askCase(mode: SearchMode) -> UUID? { mode == .ask ? scope.caseID : nil }
}

/// A screen whose optional pack is off says so, and where to turn it on — never a blank screen.
public nonisolated enum PackNotice {
    public static let remedy = "Turn on in Settings ▸ Modules"

    /// The explanation for a destination whose pack is off (nil: no pack, or the pack is on).
    public static func text(for dest: Destination, isEnabled: (ProductModule) -> Bool = ProductModuleFlags.isEnabled) -> String? {
        guard let pack = dest.requiredPack, !isEnabled(pack) else { return nil }
        return "“\(pack.title)” is switched off. Work made with it earlier stays readable here; making new work needs it on. \(remedy)."
    }
}
