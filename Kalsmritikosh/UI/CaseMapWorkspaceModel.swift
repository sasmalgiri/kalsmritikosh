//
//  CaseMapWorkspaceModel.swift
//  Kalsmritikosh
//
//  Living case map, M2/M3 — the map workspace's state, testable without a view: the manual view strip
//  (built-in and saved views, Previous/Next, never automatic), the selection shared by the map and the
//  list, Back to the previous focus, per-view viewport, hidden items and collapsed groups, the stored
//  layout with Undo, and the generation token that drops a late load after a case switch or an erase.
//
//  Identifiers and geometry go to the case's workspace preference (CaseWorkspaceState.map); saved views,
//  positions, pins and links go to the encrypted ledger through CaseMapRepository.
//

import Foundation
import Observation
import os

@MainActor @Observable
final class CaseMapWorkspaceModel {
    let caseID: UUID
    let workspace: CaseWorkspaceHolder

    /// The newest load asked for; a load with another generation is dropped.
    private(set) var generation: UInt64 = 0
    private(set) var current: CaseMapLoad?
    var placements: [CaseMapNodeID: CaseMapPlacement] = [:]
    var savedViews: [CaseMapSavedView] = []
    var loading = false
    var error: String?
    var notice: String?
    /// "Find on this map" words for a built-in view (kept in memory only; a saved view keeps its own).
    var search = ""
    /// M5 — the person chose "Search case evidence" (the case screen opens the panel).
    var searchEvidenceRequested = false
    var awaitingOnly = false
    /// The kinds a header count narrowed the view to (in memory; cleared when the view changes).
    var kindFocus: Set<CaseMapNodeKind>?
    /// Earlier positions, for Undo of moves, pins and Arrange.
    private(set) var undoStack: [[CaseMapNodeID: CaseMapPlacement]] = []
    /// Set after the case is erased or the screen is locked: nothing late is shown or written.
    private(set) var closedOut = false

    init(caseID: UUID, workspace: CaseWorkspaceHolder) { self.caseID = caseID; self.workspace = workspace }

    var projection: CaseMapProjection? { current?.projection }
    var loadState: CaseMapLoadState? { current?.state }

    var memory: CaseMapWorkspaceMemory {
        get { workspace.state.map ?? CaseMapWorkspaceMemory() }
        set { workspace.state.map = newValue }
    }

    // MARK: - Loading

    /// Start a load: the returned generation must come back with it.
    func beginLoad() -> UInt64 {
        generation &+= 1
        loading = true
        return generation
    }

    /// Show a load if it is the newest one for this case (and the case was not erased meanwhile).
    @discardableResult
    func apply(_ load: CaseMapLoad) -> Bool {
        guard load.caseID == caseID, load.generation == generation, !closedOut else { return false }
        loading = false
        current = load
        placements = load.placements
        savedViews = load.views
        // A selection whose item is gone (erased, out of scope) is dropped, not shown empty.
        if let p = load.projection {
            var m = memory
            if let n = m.selectedNode, p.node(n) == nil { m.selectedNode = nil }
            if let l = m.selectedLink, p.link(l) == nil { m.selectedLink = nil }
            if case .saved(let id)? = ViewRef(m.view), !savedViews.contains(where: { $0.id == id }) { m.view = CaseMapViewKind.overview.rawValue }
            if m != memory { memory = m }
        }
        return true
    }

    func refresh(_ service: CaseMapService) async {
        let g = beginLoad()
        let load = await service.load(caseID: caseID, generation: g)
        apply(load)
    }

    /// The screen went away or switched case: whatever is still loading is dropped when it arrives.
    func cancelPending() {
        generation &+= 1
        loading = false
    }

    /// The case was erased, or the screen locked: forget what is shown and drop anything still loading.
    func closeOut() {
        generation &+= 1
        closedOut = true
        current = nil
        placements = [:]
        savedViews = []
        undoStack = []
        loading = false
    }

    // MARK: - Views

    enum ViewRef: Hashable {
        case builtIn(CaseMapViewKind)
        case saved(UUID)
        init?(_ raw: String?) {
            guard let raw else { return nil }
            if raw.hasPrefix("saved:"), let id = UUID(uuidString: String(raw.dropFirst(6))) { self = .saved(id); return }
            guard let k = CaseMapViewKind(rawValue: raw) else { return nil }
            self = .builtIn(k)
        }
        var key: String {
            switch self {
            case .builtIn(let k): return k.rawValue
            case .saved(let id): return "saved:\(id.uuidString)"
            }
        }
    }

    /// The strip: the built-in views, then the person's saved views in their order.
    var strip: [ViewRef] { CaseMapViewKind.allCases.map(ViewRef.builtIn) + savedViews.map { .saved($0.id) } }

    var view: ViewRef {
        get { ViewRef(memory.view) ?? .builtIn(.overview) }
        set { go(to: newValue) }
    }

    func title(_ ref: ViewRef) -> String {
        switch ref {
        case .builtIn(let k): return k.title
        case .saved(let id): return savedViews.first { $0.id == id }?.name ?? "Saved view"
        }
    }

    var savedView: CaseMapSavedView? {
        if case .saved(let id) = view { return savedViews.first { $0.id == id } }
        return nil
    }

    var baseKind: CaseMapViewKind {
        switch view {
        case .builtIn(let k): return k
        case .saved: return savedView?.base ?? .overview
        }
    }

    /// Move to a view by choice (the strip never moves by itself). The current focus is kept for Back.
    func go(to ref: ViewRef) {
        guard ref != view else { return }
        pushBack()
        search = ""; awaitingOnly = false; kindFocus = nil
        var m = memory
        m.view = ref.key
        memory = m
    }

    /// Previous / Next through the strip, stopping at either end.
    func step(_ delta: Int) {
        let list = strip
        guard let i = list.firstIndex(of: view) else { go(to: .builtIn(.overview)); return }
        let j = max(0, min(list.count - 1, i + delta))
        if j != i { go(to: list[j]) }
    }

    /// The filter the current view applies (the same one for the map and the list).
    var filter: CaseMapFilter {
        if let saved = savedView {
            var f = saved.filter
            if !search.isEmpty { f.search = (f.search + " " + search).trimmingCharacters(in: .whitespaces) }
            if awaitingOnly { f.awaitingOnly = true }
            return f
        }
        let key = view.key
        return CaseMapFilter(kinds: kindFocus, awaitingOnly: awaitingOnly, search: search, hidden: memory.hidden?[key] ?? [],
                             collapsed: memory.collapsed?[key])
    }

    var result: CaseMapViewResult? {
        guard let p = projection else { return nil }
        return CaseMapViewFilter.apply(p, view: baseKind, filter: filter)
    }

    /// Hide an item from this view only (no evidentiary effect; Reset view or "Show hidden" brings it back).
    func hide(_ id: CaseMapNodeID, repository: CaseMapRepository?, actor: String) async {
        if let saved = savedView {
            var f = saved.filter
            if !f.hidden.contains(id) { f.hidden.append(id) }
            await update(saved, filter: f, repository: repository, actor: actor)
        } else {
            var m = memory
            var h = m.hidden ?? [:]
            if !(h[view.key] ?? []).contains(id) { h[view.key, default: []].append(id) }
            m.hidden = h
            if m.selectedNode == id { m.selectedNode = nil }
            memory = m
        }
        notice = "Hidden from this view only. Nothing in the case changed."
    }

    func showHidden(repository: CaseMapRepository?, actor: String) async {
        if let saved = savedView {
            var f = saved.filter; f.hidden = []
            await update(saved, filter: f, repository: repository, actor: actor)
        } else {
            var m = memory; m.hidden?[view.key] = nil; memory = m
        }
    }

    /// Collapse or expand a group in this view.
    func toggleCollapse(_ groupID: String, repository: CaseMapRepository?, actor: String) async {
        var set = Set(filter.collapsed ?? Array(baseKind.collapsedByDefault))
        if set.contains(groupID) { set.remove(groupID) } else { set.insert(groupID) }
        if let saved = savedView {
            var f = saved.filter; f.collapsed = set.sorted()
            await update(saved, filter: f, repository: repository, actor: actor)
        } else {
            var m = memory
            var c = m.collapsed ?? [:]
            c[view.key] = set.sorted()
            m.collapsed = c
            memory = m
        }
    }

    private func update(_ saved: CaseMapSavedView, filter: CaseMapFilter, repository: CaseMapRepository?, actor: String) async {
        guard let repository else { return }
        do {
            _ = try await repository.saveView(caseID: caseID, id: saved.id, name: saved.name, base: saved.base, filter: filter, actor: actor)
            if let i = savedViews.firstIndex(where: { $0.id == saved.id }) { savedViews[i].filter = filter }
        } catch {
            KalsmritikoshLog.ui.error("Case map view not saved: \(error.localizedDescription, privacy: .public)")
            self.error = "The view was not saved: \(error.localizedDescription)"
        }
    }

    /// Save what is on screen as a named view (its filter, hidden items and collapsed groups) in the ledger.
    @discardableResult
    func saveCurrentView(named name: String, repository: CaseMapRepository, actor: String) async -> UUID? {
        var f = filter
        f.kinds = f.kinds ?? baseKind.kinds
        f.collapsed = f.collapsed ?? Array(baseKind.collapsedByDefault).sorted()
        do {
            let id = try await repository.saveView(caseID: caseID, name: name, base: baseKind, filter: f, actor: actor)
            savedViews = try await repository.views(caseID: caseID)
            search = ""; awaitingOnly = false
            go(to: .saved(id))
            notice = "Saved the view “\(name.trimmingCharacters(in: .whitespacesAndNewlines))”."
            return id
        } catch {
            KalsmritikoshLog.ui.error("Case map view not saved: \(error.localizedDescription, privacy: .public)")
            self.error = "The view was not saved: \(error.localizedDescription)"
            return nil
        }
    }

    func deleteSavedView(_ id: UUID, repository: CaseMapRepository) async {
        do {
            try await repository.deleteView(caseID: caseID, id: id)
            savedViews.removeAll { $0.id == id }
            if case .saved(id) = view { var m = memory; m.view = CaseMapViewKind.overview.rawValue; memory = m }
        } catch {
            KalsmritikoshLog.ui.error("Case map view not removed: \(error.localizedDescription, privacy: .public)")
            self.error = "The view was not removed: \(error.localizedDescription)"
        }
    }

    // MARK: - Selection, Back and breadcrumb

    enum Selection: Hashable {
        case node(CaseMapNodeID)
        case link(String)
    }

    /// Shared by the map and the list: switching between them keeps it.
    var selection: Selection? {
        if let n = memory.selectedNode { return .node(n) }
        if let l = memory.selectedLink { return .link(l) }
        return nil
    }

    func select(_ s: Selection?, recordBack: Bool = true) {
        guard s != selection else { return }
        if recordBack { pushBack() }
        var m = memory
        switch s {
        case .node(let id)?: m.selectedNode = id; m.selectedLink = nil
        case .link(let id)?: m.selectedLink = id; m.selectedNode = nil
        case nil: m.selectedNode = nil; m.selectedLink = nil
        }
        memory = m
    }

    var listMode: Bool {
        get { memory.listMode ?? false }
        set { var m = memory; m.listMode = newValue; memory = m }
    }

    private func pushBack() {
        var m = memory
        var b = m.back ?? []
        b.append(CaseMapFocus(view: view.key, node: m.selectedNode, link: m.selectedLink))
        if b.count > 30 { b.removeFirst(b.count - 30) }
        m.back = b
        memory = m
    }

    var canGoBack: Bool { !(memory.back ?? []).isEmpty }

    /// Back restores the previous view and what was selected in it.
    func goBack() {
        var m = memory
        guard var b = m.back, let last = b.popLast() else { return }
        m.back = b
        m.view = last.view
        m.selectedNode = last.node
        m.selectedLink = last.link
        memory = m
    }

    /// "Overview › Payment authorization › Approval email".
    var breadcrumb: [String] {
        var out = [title(view)]
        guard let p = projection else { return out }
        switch selection {
        case .node(let id)?:
            if let n = p.node(id) {
                if let q = p.links(of: id).compactMap({ l -> CaseMapNode? in
                    let other = l.from == id ? l.to : l.from
                    return p.node(other).flatMap { $0.kind == .question || $0.kind == .hypothesis ? $0 : nil }
                }).sorted(by: { $0.id < $1.id }).first, q.id != id { out.append(short(q.title)) }
                out.append(short(n.title))
            }
        case .link(let id)?:
            if let l = p.link(id), let a = p.node(l.from) { out.append(short(a.title)); out.append(l.type.label) }
        case nil: break
        }
        return out
    }

    private func short(_ s: String) -> String { s.count > 40 ? String(s.prefix(39)) + "…" : s }

    /// "Return to overview": the Overview, nothing selected, everything fitted.
    func returnToOverview() {
        go(to: .builtIn(.overview))
        select(nil, recordBack: false)
        search = ""; awaitingOnly = false; kindFocus = nil
        var m = memory; m.viewports?[CaseMapViewKind.overview.rawValue] = nil; memory = m
    }

    // MARK: - Viewport

    func viewport(default fallback: CaseMapViewport = CaseMapViewport()) -> CaseMapViewport { memory.viewports?[view.key] ?? fallback }
    var hasStoredViewport: Bool { memory.viewports?[view.key] != nil }

    func setViewport(_ v: CaseMapViewport) {
        var m = memory
        var all = m.viewports ?? [:]
        guard all[view.key] != v else { return }
        all[view.key] = v
        m.viewports = all
        memory = m
    }

    // MARK: - Layout (ledger), with Undo

    func move(_ id: CaseMapNodeID, to point: CaseMapPoint, repository: CaseMapRepository?) async {
        guard var p = placements[id] else { return }
        undoStack.append([id: p])
        p.point = point
        placements[id] = p
        await store([id: p], repository: repository)
    }

    func togglePin(_ id: CaseMapNodeID, repository: CaseMapRepository?) async {
        guard var p = placements[id] else { return }
        undoStack.append([id: p])
        p.pinned.toggle()
        placements[id] = p
        await store([id: p], repository: repository)
    }

    enum ArrangeScope: Equatable {
        /// The selected item and what links to it.
        case branch(CaseMapNodeID)
        /// Everything shown in this view.
        case view
    }

    func arrangeScope(_ scope: ArrangeScope) -> Set<CaseMapNodeID> {
        guard let p = projection else { return [] }
        switch scope {
        case .view: return Set(result?.shown ?? [])
        case .branch(let id): return Set([id] + p.links(of: id).map { $0.from == id ? $0.to : $0.from })
        }
    }

    /// Arrange the scope (pinned items stay); Undo puts every moved item back.
    @discardableResult
    func arrange(_ scope: ArrangeScope, repository: CaseMapRepository?) async -> Int {
        guard let p = projection else { return 0 }
        let moved = CaseMapLayout.arrangeScope(arrangeScope(scope), in: p, current: placements)
        guard !moved.isEmpty else { return 0 }
        var before: [CaseMapNodeID: CaseMapPlacement] = [:]
        var after: [CaseMapNodeID: CaseMapPlacement] = [:]
        for (id, point) in moved {
            guard let old = placements[id] else { continue }
            before[id] = old
            after[id] = CaseMapPlacement(point: point, pinned: old.pinned)
        }
        undoStack.append(before)
        for (id, p) in after { placements[id] = p }
        await store(after, repository: repository)
        notice = "Arranged \(after.count) item(s). Pinned items stayed. Undo puts them back."
        return after.count
    }

    var canUndo: Bool { !undoStack.isEmpty }

    func undo(repository: CaseMapRepository?) async {
        guard let last = undoStack.popLast() else { return }
        for (id, p) in last { placements[id] = p }
        await store(last, repository: repository)
    }

    /// "Reset view": this view's geometry and filters, and the case's stored positions and pins — never
    /// case content. Items are placed afresh at the next load.
    func resetView(repository: CaseMapRepository?, service: CaseMapService?) async {
        var m = memory
        m.viewports?[view.key] = nil
        m.hidden?[view.key] = nil
        m.collapsed?[view.key] = nil
        memory = m
        search = ""; awaitingOnly = false; kindFocus = nil
        undoStack = []
        if let repository {
            do { try await repository.resetLayout(caseID: caseID) } catch {
                KalsmritikoshLog.ui.error("Case map reset failed: \(error.localizedDescription, privacy: .public)")
                self.error = "The layout was not reset: \(error.localizedDescription)"
            }
        }
        if let service { await refresh(service) }
        notice = "The view was reset. No case record was changed."
    }

    private func store(_ changes: [CaseMapNodeID: CaseMapPlacement], repository: CaseMapRepository?) async {
        guard let repository, !closedOut else { return }
        do { try await repository.savePlacements(caseID: caseID, changes) } catch {
            KalsmritikoshLog.ui.error("Case map positions not saved: \(error.localizedDescription, privacy: .public)")
            self.error = "The new position was not saved: \(error.localizedDescription). It is kept on screen; try again."
        }
    }

    // MARK: - Header counts (from the same projection the map shows)

    struct HeaderCounts: Equatable {
        var unresolvedQuestions = 0
        var awaitingReview = 0
        var outstandingRequests = 0
        var overdueActions = 0
    }

    var headerCounts: HeaderCounts {
        guard let p = projection else { return HeaderCounts() }
        var c = HeaderCounts()
        for n in p.nodes {
            switch n.id.kind {
            case .allegation: if n.review == .unreviewed { c.unresolvedQuestions += 1 }
            case .request: if n.review == .pendingReview { c.outstandingRequests += 1 }
            case .task: if n.status.text.hasSuffix("overdue") { c.overdueActions += 1 }
            default: break
            }
            if n.kind != .action, n.id.kind != .allegation, n.review.awaitingReview { c.awaitingReview += 1 }
        }
        return c
    }

    enum HeaderCount { case questions, review, requests, overdue }

    /// A count opens the matching items: the list, filtered to them, in the view that holds them.
    func open(_ count: HeaderCount) {
        switch count {
        case .questions: go(to: .builtIn(.questions)); kindFocus = [.question]; awaitingOnly = true
        case .review: go(to: .builtIn(.overview)); kindFocus = Set(CaseMapNodeKind.allCases).subtracting([.action, .group]); awaitingOnly = true
        case .requests: go(to: .builtIn(.questions)); kindFocus = [.action]; awaitingOnly = true
        case .overdue: go(to: .builtIn(.overview)); kindFocus = [.action]; search = "overdue"
        }
        // Collapsed groups would hide matches: open them in this view.
        var m = memory; var c = m.collapsed ?? [:]; c[view.key] = []; m.collapsed = c; memory = m
        listMode = true
    }
}
