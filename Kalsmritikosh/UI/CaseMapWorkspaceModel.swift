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
//  M6/M7/M8: the case change feed (its own generation; a failed read is shown as a failure), a recorded state
//  opened READ-ONLY (every change to positions, pins, hidden items, views or links is refused while it is shown;
//  "Return to current" puts the live case back), and lock/erase handling: on lock or erase the shown case, the
//  inspector's content, the feed and any recorded state are cleared and late loads are dropped.
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
    /// S3 (BRIEF-01) — the brief panel was asked for, for the case (nil) or for a branch anchored on a record.
    var briefRequested = false
    var briefAnchor: CaseMapNodeID?
    /// S3 (GRAPH-06) — the whole case's stores reconciled with the map (read on demand; nil: not read yet).
    var coverage: CaseMapCoverage?
    var awaitingOnly = false
    /// The kinds a header count narrowed the view to (in memory; cleared when the view changes).
    var kindFocus: Set<CaseMapNodeKind>?
    /// Earlier positions, for Undo of moves, pins and Arrange.
    private(set) var undoStack: [[CaseMapNodeID: CaseMapPlacement]] = []
    /// Set after the case is erased or the screen is locked: nothing late is shown or written.
    private(set) var closedOut = false

    /// M6 — the case change feed (newest load only) and its own generation.
    private(set) var feed: CaseChangeFeedLoad?
    private(set) var feedGeneration: UInt64 = 0
    var feedLoading = false
    /// M7 — a recorded state shown read-only (nil: the live case).
    private(set) var history: CaseCheckpointView?

    /// M9 (§10) — what failed to save, kept so "Try again" repeats it; what was on screen stays on screen.
    enum Retry: Equatable {
        case placements([CaseMapNodeID: CaseMapPlacement])
        case saveView(String)
        case resetLayout
        case markSeen
    }
    private(set) var retry: Retry?

    init(caseID: UUID, workspace: CaseWorkspaceHolder) { self.caseID = caseID; self.workspace = workspace }

    /// What the map, the list and the inspector show: a recorded state while one is open, else the live case.
    var projection: CaseMapProjection? { history?.projection ?? current?.projection }
    /// The live case's projection (never a recorded state).
    var liveProjection: CaseMapProjection? { current?.projection }
    /// The scope the live case was read under.
    var liveScopeFingerprint: String? { current?.scopeFingerprint }
    var loadState: CaseMapLoadState? { history != nil ? .complete : current?.state }
    /// Positions to draw: a recorded state's own layout while it is open.
    var displayPlacements: [CaseMapNodeID: CaseMapPlacement] { history?.placements ?? placements }
    /// History is read-only.
    var isHistorical: Bool { history != nil }

    /// Refuse a change while a recorded state is shown (nothing about the past or the present is edited from it).
    private func refuseInHistory() -> Bool {
        guard isHistorical else { return false }
        notice = "This is a recorded state and it is read-only. Choose “Return to current” to work on the case."
        return true
    }

    var memory: CaseMapWorkspaceMemory {
        get { workspace.state.map ?? CaseMapWorkspaceMemory() }
        set { workspace.state.map = newValue }
    }

    // MARK: - Loading

    /// Start a load: the returned generation must come back with it.
    func beginLoad() -> UInt64 {
        generation &+= 1
        // Deep dive batch 5 — after a close-out nothing is shown, so nothing spins either.
        loading = !closedOut
        return generation
    }

    /// Show a load if it is the newest one for this case (and the case was not erased meanwhile).
    @discardableResult
    func apply(_ load: CaseMapLoad) -> Bool {
        if closedOut { loading = false; return false }
        guard load.caseID == caseID, load.generation == generation else { return false }
        loading = false
        current = load
        rootPlacements = load.placements
        // Deep dive batch 5 — a failed views read is not "no saved views": the views shown before (and the view open) stay.
        if let problem = load.viewsProblem { error = problem } else { savedViews = load.views }
        // Smart-map M1 — frames whose anchor left the case are closed (the deepest valid prefix stays open).
        if let p = load.projection, !isHistorical, let stack = memory.frames, !stack.isEmpty {
            let valid = Array(stack.prefix { p.node($0.anchor) != nil })
            if valid.count != stack.count { var m = memory; m.frames = valid.isEmpty ? nil : valid; memory = m }
        }
        if frameStack.isEmpty { placements = load.placements }
        // A selection whose item is gone (erased, out of scope) is dropped, not shown empty — unless a recorded
        // state is open (its selection is of that state's items).
        if !isHistorical, let p = load.projection {
            var m = memory
            if let n = m.selectedNode, p.node(n) == nil { m.selectedNode = nil }
            if let l = m.selectedLink, p.link(l) == nil { m.selectedLink = nil }
            if load.viewsProblem == nil, case .saved(let id)? = ViewRef(m.view), !savedViews.contains(where: { $0.id == id }) {
                m.view = CaseMapViewKind.overview.rawValue
            }
            if m != memory { memory = m }
        }
        runPendingReveal()
        return true
    }

    func refresh(_ service: CaseMapService) async {
        let g = beginLoad()
        let load = await service.load(caseID: caseID, generation: g)
        if apply(load), !frameStack.isEmpty { await loadFramePlacements(service) }
    }

    /// The screen went away or switched case: whatever is still loading is dropped when it arrives.
    func cancelPending() {
        generation &+= 1
        loading = false
        feedLoading = false
    }

    /// The case was erased, or the screen locked: forget what is shown and drop anything still loading.
    func closeOut() {
        generation &+= 1
        feedGeneration &+= 1
        closedOut = true
        current = nil
        placements = [:]
        rootPlacements = [:]
        savedViews = []
        undoStack = []
        loading = false
        feed = nil
        feedLoading = false
        history = nil
        retry = nil
        coverage = nil
        subset = nil
        multiSelection = []
        pendingRevealObject = nil
    }

    /// After an unlock: the case may be read again (the next load fills it).
    func reopenAfterLock() { closedOut = false }

    // MARK: - M6 change feed

    func beginFeedLoad() -> UInt64 { feedGeneration &+= 1; feedLoading = !closedOut; return feedGeneration }

    /// Show a feed if it is the newest for this case and the case was not closed out meanwhile.
    @discardableResult
    func applyFeed(_ load: CaseChangeFeedLoad) -> Bool {
        if closedOut { feedLoading = false; return false }
        guard load.caseID == caseID, load.generation == feedGeneration else { return false }
        feedLoading = false
        feed = load
        return true
    }

    /// Read the feed against the live projection (never a recorded state). Without a live projection it fails
    /// visibly rather than showing "nothing changed".
    /// S6 (CHANGE-05): whose seen position the feed is read against (nil: the case's last one). Set by "Mark as seen".
    var feedViewer: String?

    /// Deep dive batch 5 — the feed is read against THIS person's seen position from the first read (it started nil, so
    /// "What changed" used whoever marked seen last until this person marked it themselves).
    func adoptViewer(_ actor: String) {
        let who = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        if feedViewer == nil, !who.isEmpty { feedViewer = who }
    }

    func refreshFeed(_ service: CaseChangeFeedService) async {
        let g = beginFeedLoad()
        guard let p = liveProjection else {
            applyFeed(.failed(caseID, g, "The case map has not been read yet, so what changed cannot be read either."))
            return
        }
        applyFeed(await service.load(caseID: caseID, projection: p, generation: g, viewer: feedViewer))
    }

    /// "Mark as seen": moves this case's seen position. Nothing is reviewed or accepted.
    func markSeen(_ service: CaseChangeFeedService, actor: String) async {
        guard let feed else { return }
        do {
            try await service.markSeen(feed, actor: actor, projection: liveProjection)
            feedViewer = actor
            notice = "Marked as seen. Nothing was reviewed, accepted or decided — the items keep their review state."
            if retry == .markSeen { retry = nil; error = nil }
            await refreshFeed(service)
        } catch {
            KalsmritikoshLog.ui.error("Case changes not marked seen: \(error.localizedDescription, privacy: .public)")
            self.error = "Not marked as seen: \(error.localizedDescription). Nothing was reviewed either way — choose “Try again”."
            retry = .markSeen
        }
    }

    /// Items the Changes view adds: those with a new change, and everything resting on changed evidence along typed
    /// dependency links, at any depth (S6, CHANGE-03 / SM-06 — folded dependents included).
    var changedRecords: Set<CaseMapNodeID> {
        guard let feed, let p = liveProjection, !isHistorical else { return [] }
        var out = feed.changedRecords
        for ch in feed.newChanges where ch.kind.affectsEvidence {
            if let r = ch.record { out.formUnion(CaseDependencyTraversal.trace(from: r, in: p).nodes) }
        }
        return out
    }

    // MARK: - M7 history (read-only)

    /// Show a recorded state. The selection and view are kept; nothing is written.
    func openHistory(_ view: CaseCheckpointView) {
        guard view.summary.caseID == caseID, !closedOut else { return }
        history = view
        undoStack = []
        notice = nil
    }

    /// Back to the live case, as it was left.
    func returnToCurrent() {
        history = nil
        notice = nil
        var m = memory
        if let p = current?.projection {
            if let n = m.selectedNode, p.node(n) == nil { m.selectedNode = nil }
            if let l = m.selectedLink, p.link(l) == nil { m.selectedLink = nil }
        }
        if m != memory { memory = m }
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
        case .saved(let id):
            guard let v = savedViews.first(where: { $0.id == id }) else { return "Saved view" }
            // DATA-07: a view whose stored filters could not be read says so instead of passing as the person's filter.
            return v.filterProblem == nil ? v.name : "\(v.name) (filters unreadable — shown unfiltered)"
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
        search = ""; awaitingOnly = false; kindFocus = nil; subset = nil
        var m = memory
        m.view = ref.key
        // S3 (GRAPH-03/MAP-05): a saved view that keeps frames opens into them (those still in the case).
        if case .saved(let id) = ref, let frames = savedViews.first(where: { $0.id == id })?.filter.frames, !frames.isEmpty {
            let valid = frames.filter { projection?.node($0) != nil }
            m.frames = valid.isEmpty ? nil : valid.map { CaseMapFrameLevel(anchor: $0, returnSelectedNode: nil, returnSelectedLink: nil, returnViewport: nil) }
            if let last = valid.last { m.selectedNode = last; m.selectedLink = nil }
        }
        // Deep dive batch 5 — Undo holds positions of the level that was shown; once the frames change they belong elsewhere.
        if m.frames != memory.frames { undoStack = [] }
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
        var f = CaseMapFilter(kinds: kindFocus, awaitingOnly: awaitingOnly, search: search, hidden: memory.hidden?[key] ?? [],
                              collapsed: memory.collapsed?[key])
        f.folded = memory.folded?[key]
        return f
    }

    var result: CaseMapViewResult? {
        guard let p = projection else { return nil }
        var r: CaseMapViewResult
        if let f = frame { r = CaseMapFrames.viewResult(f, in: p, search: search, hidden: Set(memory.hidden?[viewportKey] ?? [])) }
        else { r = CaseMapViewFilter.apply(p, view: baseKind, filter: filter, changed: changedRecords) }
        // GRAPH-06 — never present the map's items as the whole case when other stores hold records.
        if !isHistorical { r.counts.notDrawn = coverage?.summary }
        return r
    }

    /// GRAPH-06 — read the case's stores and reconcile them with the live map (a failed read is said, not hidden).
    func refreshCoverage(_ repository: CaseMapRepository?) async {
        guard let repository, let p = liveProjection, !closedOut else { return }
        do {
            let c = try await repository.coverage(caseID: caseID)
            guard !closedOut, liveProjection?.caseID == caseID else { return }
            coverage = CaseMapCoverage.reconcile(counts: c.counts, problems: c.problems, projection: p)
        } catch {
            KalsmritikoshLog.ui.error("Case map coverage not read: \(error.localizedDescription, privacy: .public)")
            coverage = CaseMapCoverage(rows: [CaseMapCoverageRow(table: "the case's stores", family: "", map: "not shown", rows: nil, onMap: nil,
                                                                  problem: error.localizedDescription)])
        }
    }

    /// SEARCH-08 — Find matches the current view holds back in collapsed groups (they are found, not hidden).
    var collapsedMatches: [CaseMapNodeID] {
        guard !search.trimmingCharacters(in: .whitespaces).isEmpty, let r = result else { return [] }
        return r.collapsedGroups.flatMap(\.members)
    }

    /// Hide an item from this view only (no evidentiary effect; Reset view or "Show hidden" brings it back).
    func hide(_ id: CaseMapNodeID, repository: CaseMapRepository?, actor: String) async {
        if refuseInHistory() { return }
        if frame == nil, let saved = savedView {
            var f = saved.filter
            if !f.hidden.contains(id) { f.hidden.append(id) }
            await update(saved, filter: f, repository: repository, actor: actor)
        } else {
            var m = memory
            var h = m.hidden ?? [:]
            if !(h[viewportKey] ?? []).contains(id) { h[viewportKey, default: []].append(id) }
            m.hidden = h
            if m.selectedNode == id { m.selectedNode = nil }
            memory = m
        }
        notice = "Hidden from this view only. Nothing in the case changed."
    }

    func showHidden(repository: CaseMapRepository?, actor: String) async {
        if refuseInHistory() { return }
        if frame == nil, let saved = savedView {
            var f = saved.filter; f.hidden = []
            await update(saved, filter: f, repository: repository, actor: actor)
        } else {
            var m = memory; m.hidden?[viewportKey] = nil; memory = m
        }
    }

    /// Collapse or expand a group in this view.
    func toggleCollapse(_ groupID: String, repository: CaseMapRepository?, actor: String) async {
        if savedView != nil, refuseInHistory() { return }
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
            self.error = "The change to the view “\(saved.name)” was not saved: \(error.localizedDescription). Do it again, or choose Refresh to see the view as saved."
        }
    }

    /// Save what is on screen as a named view (its filter, hidden items and collapsed groups) in the ledger.
    @discardableResult
    func saveCurrentView(named name: String, repository: CaseMapRepository, actor: String) async -> UUID? {
        if refuseInHistory() { return nil }
        var f = filter
        f.kinds = f.kinds ?? baseKind.kinds
        f.collapsed = f.collapsed ?? Array(baseKind.collapsedByDefault).sorted()
        f.frames = frameStack.isEmpty ? nil : frameStack.map(\.anchor)
        do {
            let id = try await repository.saveView(caseID: caseID, name: name, base: baseKind, filter: f, actor: actor)
            savedViews = try await repository.views(caseID: caseID)
            search = ""; awaitingOnly = false
            go(to: .saved(id))
            notice = "Saved the view “\(name.trimmingCharacters(in: .whitespacesAndNewlines))”."
            if case .saveView? = retry { retry = nil; self.error = nil }
            return id
        } catch {
            KalsmritikoshLog.ui.error("Case map view not saved: \(error.localizedDescription, privacy: .public)")
            self.error = "The view “\(name)” was not saved: \(error.localizedDescription). The name and the view are kept — choose “Try again”."
            retry = .saveView(name)
            return nil
        }
    }

    func deleteSavedView(_ id: UUID, repository: CaseMapRepository) async {
        if refuseInHistory() { return }
        do {
            try await repository.deleteView(caseID: caseID, id: id)
            savedViews.removeAll { $0.id == id }
            if case .saved(id) = view { var m = memory; m.view = CaseMapViewKind.overview.rawValue; memory = m }
        } catch {
            KalsmritikoshLog.ui.error("Case map view not removed: \(error.localizedDescription, privacy: .public)")
            self.error = "The view was not removed: \(error.localizedDescription). It is still in the strip; choose Refresh, then remove it again."
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
        get { presentation == .list }
        set { presentation = newValue ? .list : .map }
    }

    /// S3 (MAP-07): the same records as a map, a list, a table or a timeline — one selection and one subset for all.
    enum Presentation: String, CaseIterable, Identifiable {
        case map, list, table, timeline
        var id: String { rawValue }
        var title: String {
            switch self {
            case .map: return "Map"
            case .list: return "List"
            case .table: return "Table"
            case .timeline: return "Timeline"
            }
        }
        var symbol: String {
            switch self {
            case .map: return "point.3.connected.trianglepath.dotted"
            case .list: return "list.bullet"
            case .table: return "tablecells"
            case .timeline: return "calendar.day.timeline.left"
            }
        }
    }
    var presentation: Presentation {
        get { memory.presentation.flatMap(Presentation.init(rawValue:)) ?? ((memory.listMode ?? false) ? .list : .map) }
        set { var m = memory; m.presentation = newValue.rawValue; m.listMode = newValue == .list; memory = m }
    }

    /// S3 (MAP-07): a date or amount bucket the person chose — its records are highlighted in every presentation. Kept in
    /// memory only; it changes no record and no count.
    var subset: CaseMapBucket?
    func isInSubset(_ id: CaseMapNodeID) -> Bool { subset?.members.contains(id) ?? false }

    /// S3 (MAP-05): the details drawer's state, kept for the next visit.
    var drawerOpen: Bool {
        get { memory.drawerOpen ?? false }
        set { var m = memory; m.drawerOpen = newValue; memory = m }
    }

    // MARK: - S3 multi-selection (MAP-09) and branch folds (MAP-04)

    /// Items chosen together (in memory): arrange, pin or unpin them at once. The single selection stays the inspector's.
    private(set) var multiSelection: Set<CaseMapNodeID> = []
    func toggleMulti(_ id: CaseMapNodeID) {
        if multiSelection.contains(id) { multiSelection.remove(id) } else { multiSelection.insert(id) }
    }
    func clearMulti() { multiSelection = [] }

    /// Pin or unpin every chosen item (one Undo step). Changes no case record.
    func setPinned(_ pinned: Bool, _ ids: Set<CaseMapNodeID>, repository: CaseMapRepository?) async {
        if refuseInHistory() { return }
        var before: [CaseMapNodeID: CaseMapPlacement] = [:]
        var after: [CaseMapNodeID: CaseMapPlacement] = [:]
        for id in ids.sorted() { guard var p = placements[id], p.pinned != pinned else { continue }; before[id] = p; p.pinned = pinned; after[id] = p }
        guard !after.isEmpty else { return }
        undoStack.append(before)
        for (id, p) in after { placements[id] = p }
        await store(after, repository: repository)
        notice = (pinned ? "Pinned" : "Unpinned") + " \(after.count) item(s). Undo puts them back."
    }

    var foldedHere: [CaseMapNodeID] { savedView?.filter.folded ?? memory.folded?[view.key] ?? [] }
    func isFolded(_ id: CaseMapNodeID) -> Bool { foldedHere.contains(id) }

    /// Fold or unfold the branch under a record in this view (nested folds keep their own state). Changes no record.
    func toggleFold(_ id: CaseMapNodeID, repository: CaseMapRepository?, actor: String) async {
        guard frame == nil else { notice = "Folding works on the case map's views; inside a frame every related item is listed."; return }
        if let saved = savedView {
            if refuseInHistory() { return }
            var f = saved.filter
            var list = f.folded ?? []
            if let i = list.firstIndex(of: id) { list.remove(at: i) } else { list.append(id) }
            f.folded = list.isEmpty ? nil : list
            await update(saved, filter: f, repository: repository, actor: actor)
        } else {
            var m = memory
            var all = m.folded ?? [:]
            var list = all[view.key] ?? []
            if let i = list.firstIndex(of: id) { list.remove(at: i) } else { list.append(id) }
            all[view.key] = list.isEmpty ? nil : list
            m.folded = all.isEmpty ? nil : all
            memory = m
        }
        if let s = result?.folds[id] { notice = "Folded: " + s.label + ". Nothing in the case changed." }
    }

    private func pushBack() {
        var m = memory
        var b = m.back ?? []
        b.append(CaseMapFocus(view: view.key, node: m.selectedNode, link: m.selectedLink))
        if b.count > 30 { b.removeFirst(b.count - 30) }
        m.back = b
        m.forward = nil   // a new step forgets the old way forward
        memory = m
    }

    var canGoBack: Bool { !(memory.back ?? []).isEmpty }

    /// Back restores the previous view and what was selected in it.
    func goBack() {
        var m = memory
        guard var b = m.back, let last = b.popLast() else { return }
        m.back = b
        // S3 (MAP-05): where Back left from, for Forward (bounded like Back; kept in the workspace preference).
        var fw = m.forward ?? []
        fw.append(CaseMapFocus(view: view.key, node: m.selectedNode, link: m.selectedLink))
        if fw.count > 30 { fw.removeFirst(fw.count - 30) }
        m.forward = fw
        m.view = last.view
        m.selectedNode = last.node
        m.selectedLink = last.link
        memory = m
    }

    var canGoForward: Bool { !(memory.forward ?? []).isEmpty }

    /// Forward undoes a Back: the view and selection Back left.
    func goForward() {
        var m = memory
        guard var fw = m.forward, let next = fw.popLast() else { return }
        var b = m.back ?? []
        b.append(CaseMapFocus(view: view.key, node: m.selectedNode, link: m.selectedLink))
        if b.count > 30 { b.removeFirst(b.count - 30) }
        m.back = b
        m.forward = fw
        m.view = next.view
        m.selectedNode = next.node
        m.selectedLink = next.link
        memory = m
    }

    /// "Overview › Payment authorization › Approval email"; in a frame, "Overview › Report — … › Finding — …".
    var breadcrumb: [String] {
        var out = [title(view)]
        guard let p = projection else { return out }
        if !frameStack.isEmpty {
            for level in frameStack { out.append(short(p.node(level.anchor)?.title ?? "Item no longer in the case")) }
            if case .node(let id)? = selection, id != frameStack.last?.anchor, let n = p.node(id) { out.append(short(n.title)) }
            return out
        }
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

    /// "Return to overview": the Overview, nothing selected, everything fitted (and out of every frame).
    func returnToOverview() {
        leaveFrames()
        go(to: .builtIn(.overview))
        select(nil, recordBack: false)
        search = ""; awaitingOnly = false; kindFocus = nil
        var m = memory; m.viewports?[CaseMapViewKind.overview.rawValue] = nil; memory = m
    }

    // MARK: - Smart-map M1: recursive frames (ARCH-03, GRAPH-01–03) and reveal (MAP-08, SEARCH-08)

    /// The root frame's positions while a frame is open (the case map's own layout).
    private(set) var rootPlacements: [CaseMapNodeID: CaseMapPlacement] = [:]
    /// The map area's size, so a revealed item can be centred (the canvas keeps it current).
    var canvasSize: (width: Double, height: Double) = (900, 600)

    /// The open frames, outermost first. No depth limit.
    var frameStack: [CaseMapFrameLevel] { memory.frames ?? [] }
    /// The key the active frame's positions are stored under ("" — the case map itself).
    var activeFrameKey: String { frameStack.last.map { CaseMapFrames.key($0.anchor) } ?? "" }
    /// The frame shown now (nil: the case map). A projection over canonical records — never a copy of one.
    var frame: CaseMapFrame? {
        guard let a = frameStack.last?.anchor, let p = projection else { return nil }
        return CaseMapFrames.frame(of: a, in: p)
    }
    /// The breadcrumb's levels: the case map (depth 0), then each frame, with its title.
    var frameTrail: [(depth: Int, title: String)] {
        let p = projection
        return [(0, title(view))] + frameStack.enumerated().map { i, level in (i + 1, short(p?.node(level.anchor)?.title ?? "Item no longer in the case")) }
    }

    /// "Open as frame": focus on this record; its typed relationships are the frame's contents. The level it was
    /// opened from is remembered exactly (selection and viewport) for the way back.
    func openFrame(_ id: CaseMapNodeID, service: CaseMapService?) async {
        guard let p = projection, p.node(id) != nil else {
            notice = "That item is not in this case's map any more, so it can't be opened as a frame."
            return
        }
        guard frameStack.last?.anchor != id else { return }
        var m = memory
        var stack = m.frames ?? []
        stack.append(CaseMapFrameLevel(anchor: id, returnSelectedNode: m.selectedNode, returnSelectedLink: m.selectedLink,
                                       returnViewport: m.viewports?[viewportKey]))
        m.frames = stack
        m.selectedNode = id
        m.selectedLink = nil
        memory = m
        undoStack = []
        await loadFramePlacements(service)
    }

    /// Return to a level of the breadcrumb (0 — the case map). That level's selection and viewport are put back as
    /// they were when the next frame was opened from it.
    func returnToFrame(depth: Int, service: CaseMapService?) async {
        let stack = frameStack
        guard depth >= 0, depth < stack.count else { return }
        let restore = stack[depth]
        var m = memory
        m.frames = depth == 0 ? nil : Array(stack.prefix(depth))
        m.selectedNode = restore.returnSelectedNode
        m.selectedLink = restore.returnSelectedLink
        let key = depth == 0 ? view.key : "frame:" + stack[depth - 1].anchor.key
        var vps = m.viewports ?? [:]
        vps[key] = restore.returnViewport
        m.viewports = vps
        memory = m
        undoStack = []
        if depth == 0 { placements = rootPlacements } else { await loadFramePlacements(service) }
    }

    /// S3: after the frames changed without a frame command (a saved view opened into its frames), put the right positions up.
    func syncFramePlacements(_ service: CaseMapService?) async {
        if frameStack.isEmpty { placements = rootPlacements } else { await loadFramePlacements(service) }
    }

    /// Leave every frame for the case map (nothing restored — used by "Return to overview" and reveal).
    func leaveFrames() {
        guard !frameStack.isEmpty else { return }
        var m = memory; m.frames = nil; memory = m
        placements = rootPlacements
        undoStack = []
    }

    /// The active frame's positions: stored ones, new members placed around the anchor (and stored, unless a recorded
    /// state is shown). A late answer for a frame no longer open is dropped.
    func loadFramePlacements(_ service: CaseMapService?) async {
        guard let anchor = frameStack.last?.anchor, let p = projection, !closedOut else { return }
        let g = generation
        if let service, let opened = await service.openFrame(caseID: caseID, anchor: anchor, in: p, store: !isHistorical) {
            guard frameStack.last?.anchor == anchor, generation == g, !closedOut else { return }
            placements = opened.placements
            if let problem = opened.problem { error = problem }
        } else if let f = CaseMapFrames.frame(of: anchor, in: p) {
            placements = CaseMapLayout.placeFrame(f, existing: [:])
        }
    }

    /// MAP-08 / SEARCH-08 — reveal a record wherever it is folded: leave a frame that does not hold it, clear the Find
    /// words or view filters that exclude it, show it if hidden from this view, open the collapsed group that holds it,
    /// then select it and centre the map on it. The list shows the same (its group open, the row selected). Returns
    /// false when the record is not in the case's map. No case record is changed.
    @discardableResult
    func reveal(_ id: CaseMapNodeID) -> Bool {
        guard let p = projection, p.node(id) != nil else {
            notice = "That item is not in this case's map (it may have been removed, erased or left the case scope)."
            return false
        }
        var steps: [String] = []
        if let f = frame, !f.contains(id) { leaveFrames(); steps.append("left the frame") }
        // Deep dive batch 5 — inside a frame that holds it, Find words or "hidden from this frame" kept it undrawn while the
        // notice said "Shown and selected".
        if frame != nil {
            if !search.isEmpty { search = ""; steps.append("cleared the Find words") }
            if (memory.hidden?[viewportKey] ?? []).contains(id) {
                var m = memory
                m.hidden?[viewportKey]?.removeAll { $0 == id }
                memory = m
                steps.append("showed it again in this frame")
            }
        }
        if frame == nil {
            for _ in 0..<5 {
                let r = CaseMapViewFilter.apply(p, view: baseKind, filter: filter, changed: changedRecords)
                if r.shown.contains(id) { break }
                if let g = r.collapsedGroups.first(where: { $0.members.contains(id) }) {
                    if savedView != nil { go(to: .builtIn(.overview)); steps.append("opened the Overview"); continue }
                    var m = memory
                    var c = m.collapsed ?? [:]
                    var set = Set(c[view.key] ?? Array(baseKind.collapsedByDefault))
                    set.remove(g.id)
                    c[view.key] = set.sorted()
                    m.collapsed = c
                    memory = m
                    steps.append("opened the group “\(g.title)”")
                    continue
                }
                if r.counts.folded > 0, frame == nil, savedView == nil,
                   let outer = foldedHere.first(where: { CaseMapFolds.descendants(of: $0, in: p).contains(id) }) {
                    var m = memory
                    m.folded?[view.key]?.removeAll { $0 == outer }
                    memory = m
                    steps.append("unfolded the branch it is in")
                    continue
                }
                if filter.hidden.contains(id) {
                    if savedView != nil { go(to: .builtIn(.overview)); steps.append("opened the Overview"); continue }
                    var m = memory
                    m.hidden?[view.key]?.removeAll { $0 == id }
                    memory = m
                    steps.append("showed it again in this view")
                    continue
                }
                if !search.isEmpty || awaitingOnly || kindFocus != nil {
                    search = ""; awaitingOnly = false; kindFocus = nil
                    steps.append("cleared the filters")
                    continue
                }
                if view != .builtIn(.overview) { go(to: .builtIn(.overview)); steps.append("opened the Overview"); continue }
                break
            }
        }
        select(.node(id))
        showListRow(id)
        if let pt = displayPlacements[id]?.point {
            setViewport(CaseMapLayout.centred(on: pt, current: viewport(), width: canvasSize.width, height: canvasSize.height))
        }
        notice = steps.isEmpty ? "Shown and selected." : "Shown and selected — " + steps.joined(separator: ", ") + ". No case record changed."
        return true
    }

    // MARK: - Deep dive batch 5: list pages (M9) and a reveal asked for before the first read

    /// Pages the list shows per section ("links" for the links), kept here so a reveal can open the page holding its row.
    var listPages: [String: Int] = [:]

    /// Open enough pages of the list section holding `id` that its row is drawn (a reveal past the first page never was).
    func showListRow(_ id: CaseMapNodeID) {
        guard let p = projection, let r = result else { return }
        for section in CaseMapListPaging.sections(p, result: r) {
            guard let i = section.ids.firstIndex(of: id) else { continue }
            let needed = i / CaseMapListPaging.pageSize + 1
            if (listPages[section.title] ?? 1) < needed { listPages[section.title] = needed }
            return
        }
    }

    /// A document to show on the map once the map has been read ("Show on map" from Search before its first load).
    private(set) var pendingRevealObject: UUID?

    /// Search ▸ "Show on map": reveal the case document read into `object`. Before the map's first read the request is
    /// kept and run when the read arrives — never answered "not on this case's map" from a map not read yet.
    func showDocumentOnMap(object: UUID) {
        guard let p = liveProjection else {
            pendingRevealObject = object
            notice = "Opening the map; the document is shown once the case is read."
            return
        }
        pendingRevealObject = nil
        if let doc = p.nodes.first(where: { $0.id.kind == .document && $0.sources.contains { $0.objectID == object } }) {
            _ = reveal(doc.id)
        } else {
            notice = "That document is not on this case's map (it may not be in the case scope)."
        }
    }

    private func runPendingReveal() {
        guard let object = pendingRevealObject, liveProjection != nil else { return }
        showDocumentOnMap(object: object)
    }

    // MARK: - Viewport

    /// The key the viewport and hidden items are kept under: the view, or the open frame.
    var viewportKey: String { frameStack.last.map { "frame:" + $0.anchor.key } ?? view.key }

    func viewport(default fallback: CaseMapViewport = CaseMapViewport()) -> CaseMapViewport { memory.viewports?[viewportKey] ?? fallback }
    var hasStoredViewport: Bool { memory.viewports?[viewportKey] != nil }

    func setViewport(_ v: CaseMapViewport) {
        var m = memory
        var all = m.viewports ?? [:]
        guard all[viewportKey] != v else { return }
        all[viewportKey] = v
        m.viewports = all
        memory = m
    }

    // MARK: - Layout (ledger), with Undo

    func move(_ id: CaseMapNodeID, to point: CaseMapPoint, repository: CaseMapRepository?) async {
        if refuseInHistory() { return }
        guard var p = placements[id] else { return }
        undoStack.append([id: p])
        p.point = point
        placements[id] = p
        await store([id: p], repository: repository)
    }

    func togglePin(_ id: CaseMapNodeID, repository: CaseMapRepository?) async {
        if refuseInHistory() { return }
        guard var p = placements[id] else { return }
        undoStack.append([id: p])
        p.pinned.toggle()
        placements[id] = p
        await store([id: p], repository: repository)
    }

    enum ArrangeScope: Equatable {
        /// The selected item and what links to it.
        case branch(CaseMapNodeID)
        /// S3 (MAP-09): the items chosen together.
        case chosen(Set<CaseMapNodeID>)
        /// Everything shown in this view.
        case view
    }

    func arrangeScope(_ scope: ArrangeScope) -> Set<CaseMapNodeID> {
        guard let p = projection else { return [] }
        switch scope {
        case .view: return Set(result?.shown ?? [])
        case .branch(let id): return Set([id] + p.links(of: id).map { $0.from == id ? $0.to : $0.from })
        case .chosen(let ids): return ids.filter { p.node($0) != nil }
        }
    }

    /// Arrange the scope (pinned items stay); Undo puts every moved item back.
    @discardableResult
    func arrange(_ scope: ArrangeScope, repository: CaseMapRepository?) async -> Int {
        if refuseInHistory() { return 0 }
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
        if refuseInHistory() { return }
        guard let last = undoStack.popLast() else { return }
        for (id, p) in last { placements[id] = p }
        await store(last, repository: repository)
    }

    /// "Reset view": this view's geometry and filters, and the case's stored positions and pins — never
    /// case content. Items are placed afresh at the next load.
    func resetView(repository: CaseMapRepository?, service: CaseMapService?) async {
        if refuseInHistory() { return }
        var m = memory
        m.viewports?[viewportKey] = nil
        m.hidden?[viewportKey] = nil
        m.collapsed?[view.key] = nil
        // Deep dive batch 5 — folds are this view's too: a branch folded away (even one folded into itself) comes back.
        m.folded?[view.key] = nil
        if m.folded?.isEmpty == true { m.folded = nil }
        memory = m
        search = ""; awaitingOnly = false; kindFocus = nil
        undoStack = []
        if let repository {
            do {
                // In a frame: that frame's positions only; on the case map: every frame's.
                try await repository.resetLayout(caseID: caseID, frame: frameStack.isEmpty ? nil : activeFrameKey)
                if retry == .resetLayout { retry = nil; self.error = nil }
            } catch {
                KalsmritikoshLog.ui.error("Case map reset failed: \(error.localizedDescription, privacy: .public)")
                self.error = "The positions were not reset: \(error.localizedDescription). The zoom and filters were reset; choose “Try again” for the positions."
                retry = .resetLayout
            }
        }
        if let service { await refresh(service) }
        notice = "The view was reset. No case record was changed."
    }

    private func store(_ changes: [CaseMapNodeID: CaseMapPlacement], repository: CaseMapRepository?) async {
        guard let repository, !closedOut, !isHistorical else { return }
        do {
            try await repository.savePlacements(caseID: caseID, frame: activeFrameKey, changes)
            if case .placements? = retry { retry = nil; self.error = nil }
        } catch {
            KalsmritikoshLog.ui.error("Case map positions not saved: \(error.localizedDescription, privacy: .public)")
            self.error = "The new position was not saved: \(error.localizedDescription). It is kept on screen — choose “Try again”."
            var pending: [CaseMapNodeID: CaseMapPlacement] = [:]
            if case .placements(let earlier)? = retry { pending = earlier }
            for (id, p) in changes { pending[id] = p }
            retry = .placements(pending)
        }
    }

    /// "Try again": repeat what failed to save. Nothing else is written.
    func retryLast(repository: CaseMapRepository?, service: CaseMapService?, feedService: CaseChangeFeedService?, actor: String) async {
        guard let r = retry else { return }
        if refuseInHistory() { return }
        switch r {
        case .placements(let changes):
            // Only what is still on screen (a newer move of the same item wins).
            var current: [CaseMapNodeID: CaseMapPlacement] = [:]
            for id in changes.keys { if let p = placements[id] { current[id] = p } }
            await store(current, repository: repository)
        case .saveView(let name):
            if let repository { await saveCurrentView(named: name, repository: repository, actor: actor) }
        case .resetLayout:
            await resetView(repository: repository, service: service)
        case .markSeen:
            if let feedService { await markSeen(feedService, actor: actor) }
        }
    }

    /// The error was read and set aside; nothing failed is retried.
    func dismissError() { error = nil; retry = nil }

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
