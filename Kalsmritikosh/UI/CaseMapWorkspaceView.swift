//
//  CaseMapWorkspaceView.swift
//  Kalsmritikosh
//
//  Living case map, M2 (plan §4): the case's working view when "Case map (preview)" is on.
//  • A header that stays put: title, stage, the question (expandable), what the app could read, and counts
//    that open the matching items; "What changed", "Next action", "Search this case", "Return to overview".
//  • The manual view strip: Overview, Questions, People, Chronology, Findings, Changes and saved views;
//    Previous/Next and keys; it never moves on its own. A breadcrumb and Back to the previous focus.
//  • The map or the equivalent list (same filters, same selection, same inspector), and one inspector.
//  Opening, panning or switching views reads the ledger only: nothing is sent anywhere.
//  M6–M8: "What changed" opens the case's change feed; "History" the recorded states (read-only, with an
//  obvious "Return to current"); "Readiness" the explicit work states; "Export" goes through CaseOutputService
//  only (CaseMapExportRoutes). Locking the app clears what is shown and drops late loads.
//

import SwiftUI
import os

struct CaseMapWorkspaceView: View {
    @Environment(AppState.self) private var appState
    let model: CaseFileModel
    let s: CaseFileSnapshot
    @State private var service: CaseMapService?
    @State private var questionExpanded = false
    @State private var showChanges = false
    @State private var showLegend = false
    @State private var savingView = false
    @State private var newViewName = ""
    @State private var confirmArrange: CaseMapWorkspaceModel.ArrangeScope?
    @State private var openSource: CitationOpenTarget?
    @State private var openedPassage: OpenedSource?
    @State private var feedService: CaseChangeFeedService?
    @State private var historyService: CaseHistoryService?
    @State private var showHistory = false
    @State private var showReadiness = false
    @State private var exportStatus: String?
    @State private var lock = AppLock.shared
    @State private var showCoverage = false
    @State private var firstUse = CaseMapFirstUse.shouldShow(AppDefaults.store)
    /// S12 — the case tools sheet (automation, AI assistant, money, people and roles, patterns, history set, briefings, exchange).
    @State private var tools: CaseMapTool?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var findFocused: Bool

    private var map: CaseMapWorkspaceModel { model.map }
    private var repository: CaseMapRepository? { service?.repository }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            strip
            Divider()
            content
            Divider()
            footer
        }
        // M9 — Reduce Motion: no animated transition anywhere in the map workspace.
        .transaction { t in if reduceMotion { t.animation = nil; t.disablesAnimations = true } }
        .task(id: model.caseID) { await start() }
        .onDisappear { map.cancelPending() }
        .onChange(of: model.snapshot?.actions.count) { _, _ in Task { await reload() } }
        .onChange(of: model.review.items) { _, _ in Task { await reload() } }
        .onChange(of: model.requests.map(\.request.revision)) { _, _ in Task { await reload() } }
        .sheet(isPresented: $showChanges) {
            CaseChangeFeedPanel(map: map, feedService: feedService, actor: model.actor) { showChanges = false }
        }
        .sheet(isPresented: $showHistory) {
            CaseHistoryPanel(map: map, history: historyService, caseID: model.caseID, actor: model.actor) { showHistory = false }
        }
        .sheet(isPresented: $showReadiness) {
            CaseReadinessPanel(readiness: readiness, select: { _ = map.reveal($0) }) { showReadiness = false }
        }
        // M8 — locking the app clears the case, the inspector's content, the feed and any recorded state, and
        // drops whatever is still loading; unlocking reads the case again.
        .onChange(of: lock.locked) { _, locked in
            if locked {
                showChanges = false; showHistory = false; showReadiness = false
                openSource = nil; openedPassage = nil
                map.closeOut()
            } else {
                map.reopenAfterLock()
                Task { await reload() }
            }
        }
        .sheet(isPresented: Binding(get: { map.briefRequested }, set: { map.briefRequested = $0 })) {
            CaseMapBriefPanel(model: model, service: service) { map.briefRequested = false }
        }
        // S3 — a saved view that opened into its frames puts the frame's positions up.
        .onChange(of: map.activeFrameKey) { _, _ in Task { await map.syncFramePlacements(service) } }
        .sheet(isPresented: $savingView) { saveViewSheet }
        .sheet(item: $tools) { t in
            CaseMapToolsPanel(model: model, projection: map.projection, service: service, tool: t) { tools = nil; Task { await reload() } }
        }
        .sheet(item: $openSource) { target in CitationSourceSheet(target: target) { openSource = nil } }
        .sheet(item: $openedPassage) { opened in
            VStack(spacing: 0) {
                if let note = opened.note {
                    Label(note, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        .accessibilityIdentifier("caseMap.source.unavailable")
                }
                EvidenceViewer(citation: opened.citation)
                HStack { Spacer(); Button("Close") { openedPassage = nil }.keyboardShortcut(.cancelAction) }.padding(10)
            }
        }
        .confirmationDialog(arrangeTitle, isPresented: Binding(get: { confirmArrange != nil }, set: { if !$0 { confirmArrange = nil } })) {
            Button("Arrange") {
                if let scope = confirmArrange { Task { await map.arrange(scope, repository: repository) } }
                confirmArrange = nil
            }
            Button("Cancel", role: .cancel) { confirmArrange = nil }
        } message: {
            Text("Pinned items stay where they are. Undo puts every moved item back. No case record changes.")
        }
    }

    // MARK: Loading

    private func start() async {
        if service == nil { service = CaseMapServiceFactory.map(appState) }
        if let db = appState.database {
            if feedService == nil { feedService = CaseChangeFeedService(database: db) }
            if historyService == nil, let service { historyService = CaseHistoryService(database: db, map: service) }
        }
        await reload()
        // S12 (HELP-01) — a case started from a question "with a team" opens on People and roles.
        if let t = CaseMapWorkspaceMemoryHint.take(caseID: model.caseID) { tools = t }
        // M7 — the daily record: kept when the case changed since its newest recorded state (local ledger only).
        if let historyService, map.liveProjection != nil, !lock.locked {
            await historyService.recordAutomaticIfChanged(caseID: model.caseID, actor: model.actor)
        }
    }

    /// Read the case again (the view, selection and positions are kept), then what changed.
    func reload() async {
        guard let service else { map.error = "The ledger isn't ready yet."; return }
        guard !lock.locked else { return }
        await map.refresh(service)
        if let feedService { await map.refreshFeed(feedService) }
        await map.refreshCoverage(service.repository)
    }

    /// M7 — the readiness panel's states, from the same projection the map shows (the live case).
    private var readiness: CaseReadiness? {
        guard let p = map.liveProjection, let snap = model.snapshot else { return nil }
        return CaseReadiness.compute(projection: p, snapshot: snap, requests: model.requests, coverage: model.coverage)
    }

    // MARK: Header (stays visible)

    private var header: some View {
        let counts = map.headerCounts
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "map").accessibilityHidden(true)
                Text(s.caseHeader.title).font(.headline).lineLimit(1)
                StageChip(stage: s.caseHeader.status == .closed ? .closed : s.profile.stage)
                Text("Preview").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .help("The case map is a preview. The case sections stay available and hold the same records.")
                Spacer()
                if map.loading { ProgressView().controlSize(.small) }
                Button { Task { await reload() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Read the case again from the ledger. Nothing is sent anywhere.")
            }
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "questionmark.circle").foregroundStyle(.secondary).accessibilityHidden(true)
                if let q = map.projection?.question {
                    Text(q).font(.callout).lineLimit(questionExpanded ? nil : 1)
                        .fixedSize(horizontal: false, vertical: questionExpanded)
                    if q.count > 80 {
                        Button(questionExpanded ? "Less" : "More") { questionExpanded.toggle() }.buttonStyle(.borderless).font(.caption)
                    }
                } else {
                    Text("No question recorded yet — record it in Case sections ▸ Overview (purpose) or the intake summary.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 14) {
                if let coverage = model.coverage {
                    Label(coverage.summaryLine, systemImage: "doc.on.doc").font(.caption).lineLimit(1)
                        .help("What the app could read of this case's documents. Case sections ▸ Overview lists every document not read, with its reason.")
                } else {
                    Label("Reading coverage not loaded yet", systemImage: "doc.on.doc").font(.caption).foregroundStyle(.secondary)
                }
                countButton(counts.unresolvedQuestions, "open question(s)", .questions, "questionmark.circle")
                countButton(counts.awaitingReview, "awaiting review", .review, "hourglass")
                countButton(counts.outstandingRequests, "outstanding request(s)", .requests, "tray.and.arrow.down")
                countButton(counts.overdueActions, "overdue action(s)", .overdue, "exclamationmark.circle")
                Spacer()
            }
            HStack(spacing: 10) {
                Button { showChanges = true } label: {
                    Label("What changed" + (map.feed.map { f in f.newChanges.isEmpty ? "" : " (\(f.newChanges.count))" } ?? ""), systemImage: "clock.arrow.circlepath")
                }
                .help("This case's changes since your seen position. Seeing them is not reviewing them.")
                Button { showHistory = true } label: { Label("History", systemImage: "calendar.badge.clock") }
                    .help("Recorded states of this case map: open one read-only, or compare two.")
                Button { showReadiness = true } label: { Label("Readiness", systemImage: "list.bullet.clipboard") }
                    .help("The state of the work — questions, evidence, review, requests, findings and tasks. No percentage.")
                Button { map.briefAnchor = nil; map.briefRequested = true } label: { Label("Brief", systemImage: "doc.richtext") }
                    .help("The case brief: purpose, scope, the recorded position, what is unresolved, contrary material, changes and next work — each opens on the map. Also your own brief, briefings and what changed since you were here.")
                Button { nextAction() } label: { Label("Next action", systemImage: "arrow.right.circle") }
                    .disabled(reason: model.glance?.nextStep == nil ? "No next step is recorded for this case." : nil)
                Menu {
                    Button("Find on this map") { findFocused = true }
                        .help("Finds items of this whole case on the map by their words, including collapsed groups. It does not look inside documents.")
                    Button("Search case evidence") { map.searchEvidenceRequested = true }
                        .help("Searches the text and recorded details of this case's documents, and says what it could not search.")
                } label: { Label("Search this case", systemImage: "magnifyingglass") }
                    .fixedSize()
                    .help("Choose: find items on this map, or search the case's documents.")
                Button { map.returnToOverview() } label: { Label("Return to overview", systemImage: "house") }
                // S12 — the case's services that had no screen, reachable by keyboard (⌃⌘T) and VoiceOver.
                Menu {
                    ForEach(CaseMapTool.allCases) { t in
                        Button { tools = t } label: { Label(t.title, systemImage: t.symbol) }
                    }
                } label: { Label("Case tools", systemImage: "wrench.and.screwdriver") }
                    .fixedSize()
                    .caseMapControlHelp("Case tools")
                    .accessibilityIdentifier("case.map.tools")
                Button("Open case tools") { tools = .automation }
                    .keyboardShortcut("t", modifiers: [.command, .control])
                    .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
                Spacer()
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func countButton(_ n: Int, _ label: String, _ which: CaseMapWorkspaceModel.HeaderCount, _ symbol: String) -> some View {
        Button { map.open(which) } label: { Label("\(n) \(label)", systemImage: symbol).font(.caption.monospacedDigit()) }
            .buttonStyle(.borderless)
            .help("Open these items in the list.")
            .accessibilityLabel(label)
            .accessibilityValue(String(n))
            .accessibilityHint(CaseMapSpoken.countHint())
    }

    private func nextAction() {
        guard let step = model.glance?.nextStep else { return }
        // The step is done in the case sections; the map is kept where it was.
        var m = model.workspace.state.map ?? CaseMapWorkspaceMemory()
        m.showsSections = true
        model.workspace.state.map = m
        CaseGlanceSection.follow(step, model: model)
    }

    // MARK: View strip, breadcrumb, Back

    private var strip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { map.step(-1) } label: { Label("Previous view", systemImage: "chevron.left") }
                    .labelStyle(.iconOnly)
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
                    .help("Previous view (⌃⌘←)")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        let refs = map.strip
                        ForEach(Array(refs.enumerated()), id: \.element) { index, ref in
                            let selected = ref == map.view
                            Button { map.go(to: ref) } label: {
                                Label(map.title(ref), systemImage: symbol(ref)).font(.callout)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(selected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected ? 1.5 : 0.5))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(CaseMapSpoken.stripLabel(map.title(ref)))
                            .accessibilityValue(CaseMapSpoken.stripValue(index: index, count: refs.count, selected: selected))
                            .accessibilityAddTraits(selected ? [.isSelected] : [])
                            .contextMenu {
                                if case .saved(let id) = ref, let repository {
                                    Button("Remove this saved view") { Task { await map.deleteSavedView(id, repository: repository) } }
                                }
                            }
                        }
                    }
                }
                Button { map.step(1) } label: { Label("Next view", systemImage: "chevron.right") }
                    .labelStyle(.iconOnly)
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
                    .help("Next view (⌃⌘→)")
                Button("Save view…") { newViewName = ""; savingView = true }.controlSize(.small)
                Picker("Show as", selection: Binding(get: { map.presentation }, set: { map.presentation = $0 })) {
                    ForEach(CaseMapWorkspaceModel.Presentation.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
                .accessibilityLabel("Show as map, list, table or timeline")
                .help("The same records, selection and chosen range as a map, a list, a table or a timeline.")
            }
            HStack(spacing: 6) {
                Button { map.goBack() } label: { Label("Back", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(.borderless).controlSize(.small)
                    .disabled(reason: map.canGoBack ? nil : "Nothing to go back to yet.")
                    .keyboardShortcut("[", modifiers: [.command, .control])
                    .help("Back to the previous view and selection (⌃⌘[)")
                Button { map.goForward() } label: { Label("Forward", systemImage: "arrow.uturn.forward") }
                    .buttonStyle(.borderless).controlSize(.small)
                    .disabled(reason: map.canGoForward ? nil : "Nothing to go forward to.")
                    .keyboardShortcut("]", modifiers: [.command, .control])
                    .help("Forward to where Back left (⌃⌘])")
                Text(map.breadcrumb.joined(separator: " › ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityLabel("Location: " + map.breadcrumb.joined(separator: ", "))
                Spacer()
                @Bindable var m = map
                TextField("Find on this map", text: $m.search)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                    .focused($findFocused)
                    .help("Finds items of this whole case by their words, including those in collapsed groups. It does not search inside the documents.")
                Toggle("Waiting for me", isOn: $m.awaitingOnly).toggleStyle(.checkbox).controlSize(.small)
                    .help("Only items not reviewed yet, deferred, reopened or pending.")
            }
            if !map.frameStack.isEmpty { frameBar }
            else { Text(map.baseKind.emphasis).font(.caption2).foregroundStyle(.secondary) }
            let held = map.collapsedMatches
            if !held.isEmpty {
                Button { _ = map.reveal(held[0]) } label: {
                    Label("\(held.count) match(es) are in collapsed groups — show the first", systemImage: "rectangle.expand.vertical")
                }
                .buttonStyle(.link).font(.caption)
                .help("Opens the group that holds it, selects it and centres the map on it. Nothing in the case changes.")
                .accessibilityIdentifier("case.map.revealCollapsedMatch")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    /// Smart-map M1 — the frame breadcrumb: the case map, then each frame opened; any level returns exactly to how it was.
    private var frameBar: some View {
        HStack(spacing: 4) {
            Image(systemName: "square.on.square").foregroundStyle(.secondary).accessibilityHidden(true)
            ForEach(map.frameTrail, id: \.depth) { level in
                if level.depth > 0 { Text("›").foregroundStyle(.secondary).accessibilityHidden(true) }
                if level.depth == map.frameStack.count {
                    Text(level.title).font(.caption.weight(.semibold)).lineLimit(1)
                        .accessibilityLabel("Frame \(level.depth): \(level.title), current")
                } else {
                    Button(level.depth == 0 ? "Case map" : level.title) { Task { await map.returnToFrame(depth: level.depth, service: service) } }
                        .buttonStyle(.link).font(.caption).lineLimit(1)
                        .help(level.depth == 0 ? "Back to the case map, as you left it." : "Back to this frame, as you left it.")
                        .accessibilityLabel(level.depth == 0 ? "Return to the case map" : "Return to frame \(level.depth): \(level.title)")
                }
            }
            Spacer()
            Button("Up one frame") { Task { await map.returnToFrame(depth: map.frameStack.count - 1, service: service) } }
                .buttonStyle(.borderless).font(.caption)
                .keyboardShortcut(.upArrow, modifiers: [.command, .control])
                .help("Back to the level this frame was opened from, exactly as it was (⌃⌘↑).")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Frames")
        .accessibilityIdentifier("case.map.frames")
    }

    private func symbol(_ ref: CaseMapWorkspaceModel.ViewRef) -> String {
        switch ref {
        case .builtIn(let k): return k.symbol
        case .saved: return "bookmark"
        }
    }

    // MARK: Content: honest states, then the map or the list, with the inspector

    @ViewBuilder private var content: some View {
        if let state = map.loadState, case .failed(let why) = state {
            stateMessage("The case map could not be read", why + " Nothing is shown as if it were the case. Choose Refresh, or use Case sections.", "xmark.octagon")
        } else if let p = map.projection, let result = map.result {
            VStack(alignment: .leading, spacing: 0) {
                banners(p)
                if firstUse { firstUseCard }
                // M9 — narrow windows: below the threshold the inspector is a drawer over the map. The width comes
                // from the GeometryReader and every part is pinned to it (macOS 26 split-view sizing).
                GeometryReader { geo in
                    let drawer = CaseMapWorkspaceLayout.inspectorIsDrawer(width: geo.size.width)
                    ZStack(alignment: .topTrailing) {
                        HStack(spacing: 0) {
                            mainArea(p, result)
                                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                            if !drawer {
                                Divider()
                                inspector(p).frame(width: CaseMapWorkspaceLayout.inspectorWidth)
                            }
                        }
                        if drawer {
                            Button { setDrawer(!map.drawerOpen) } label: {
                                Label(map.drawerOpen ? "Hide details" : "Show details", systemImage: "sidebar.trailing")
                            }
                            .keyboardShortcut("i", modifiers: [.command, .control])
                            .help("Shows the inspector for the selected item over the map (⌃⌘I). The window is too narrow to show it beside the map.")
                            .accessibilityIdentifier("case.map.showDetails")
                            .padding(8)
                            .zIndex(2)
                            if map.drawerOpen {
                                VStack(spacing: 0) {
                                    Color.clear.frame(height: 40)
                                    inspector(p)
                                }
                                .frame(width: CaseMapWorkspaceLayout.drawerWidth(for: geo.size.width), height: geo.size.height)
                                .background(.regularMaterial)
                                .overlay(alignment: .leading) { Divider() }
                                .zIndex(1)
                                .accessibilityElement(children: .contain)
                                .accessibilityLabel("Details")
                            }
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        } else {
            ProgressView("Reading the case…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func mainArea(_ p: CaseMapProjection, _ result: CaseMapViewResult) -> some View {
        if p.nodes.count <= 1 {
            stateMessage("Nothing to map yet",
                         "Next: record the question this case is to answer, then bring documents into the case (Case sections ▸ Evidence ▸ “Add documents to this case”), select passages and decide contradictions. Each appears here.",
                         "map")
        } else if let empty = CaseMapEmptyState.viewEmpty(result.counts, view: map.baseKind) {
            stateMessage(empty.title, "Next: " + empty.next, "eye.slash")
        } else {
            switch map.presentation {
            case .list:
                CaseMapList(map: map, projection: p, result: result, repository: repository, actor: model.actor,
                            openFrame: { id in Task { await map.openFrame(id, service: service) } })
            case .table:
                CaseMapTable(map: map, projection: p, result: result)
            case .timeline:
                CaseMapTimeline(map: map, projection: p, result: result)
            case .map:
                CaseMapCanvas(map: map, projection: p, result: result, repository: repository, actor: model.actor)
            }
        }
    }

    private func inspector(_ p: CaseMapProjection) -> some View {
        CaseMapInspector(model: model, s: s, projection: p, repository: repository,
                         reload: { await reload() }, openSource: { open($0) },
                         openFrame: { id in Task { await map.openFrame(id, service: service) } })
    }

    private func setDrawer(_ open: Bool) {
        if let a = CaseMapMotion.animation(reduceMotion: reduceMotion) { withAnimation(a) { map.drawerOpen = open } } else { map.drawerOpen = open }
    }

    /// The first-use explanation: once, above the map, dismissible; the person can work while it shows.
    private var firstUseCard: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lightbulb").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(CaseMapFirstUse.text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("More about the case map") { SurfaceOpener.openHelp("task-case-map-first-use") }.buttonStyle(.link).font(.caption)
            Button("Got it") { CaseMapFirstUse.dismiss(AppDefaults.store); firstUse = false }.controlSize(.small)
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 16).padding(.bottom, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("case.map.firstUse")
    }

    @ViewBuilder private func banners(_ p: CaseMapProjection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let h = map.history {
                HStack(spacing: 8) {
                    Label(h.summary.stateLabel + " Read-only.", systemImage: "clock.arrow.circlepath")
                        .font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { map.returnToCurrent() } label: { Label("Return to current", systemImage: "arrow.uturn.forward.circle") }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .keyboardShortcut(.escape, modifiers: [.command])
                        .accessibilityIdentifier("case.map.returnToCurrent")
                }
                .padding(8)
                .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                if !h.unavailableVersions.isEmpty {
                    Label("\(h.unavailableVersions.count) source version(s) this state cited are no longer in the ledger: their words are not shown and the current version is not shown in their place.",
                          systemImage: "questionmark.folder").foregroundStyle(.secondary)
                }
            }
            switch map.loadState {
            case .partial(let parts)?:
                Label("Incomplete: \(parts.map(\.label).joined(separator: ", ")) could not be read. Those items are not on the map; this is not an empty result.",
                      systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            case .stale(let why)?:
                Label(why, systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
            default: EmptyView()
            }
            // MAP-10 — access, processing and availability explained for the view, not only per item.
            if let r = map.result {
                ForEach(CaseMapViewExplanation.lines(p, result: r), id: \.self) { line in
                    Label(line, systemImage: "info.circle").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let s = map.subset, map.presentation != .table, map.presentation != .timeline { CaseMapSubsetBar(map: map, bucket: s) }
            if p.danglingLinks > 0 {
                Label("\(p.danglingLinks) of your map link(s) point at an item no longer in this case; they are not drawn.", systemImage: "link.badge.plus")
                    .foregroundStyle(.secondary)
            }
            if let e = exportStatus { Label(e, systemImage: "square.and.arrow.up").foregroundStyle(.secondary) }
            if let e = map.error {
                HStack(spacing: 8) {
                    Label(e, systemImage: "xmark.octagon").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    if map.retry != nil {
                        Button("Try again") {
                            Task { await map.retryLast(repository: repository, service: service, feedService: feedService, actor: model.actor) }
                        }
                        .controlSize(.small)
                    }
                    Button("Dismiss") { map.dismissError() }.buttonStyle(.borderless).controlSize(.small)
                }
            }
            else if let n = map.notice { Label(n, systemImage: "info.circle").foregroundStyle(.secondary) }
            if let e = model.error { Label(e, systemImage: "xmark.octagon").foregroundStyle(.red) }
        }
        .font(.caption)
        .padding(.horizontal, 16).padding(.vertical, 4)
    }

    private func stateMessage(_ title: String, _ text: String, _ symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(title).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: Footer: counts and legend

    private var footer: some View {
        HStack(spacing: 10) {
            if let r = map.result {
                Text(r.counts.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityIdentifier("case.map.counts")
            }
            Spacer()
            Button { showCoverage.toggle(); if showCoverage { Task { await map.refreshCoverage(repository) } } } label: { Label("Coverage", systemImage: "square.grid.3x3.topleft.filled") }
                .buttonStyle(.borderless)
                .help("Every store of this case, how many records it holds, and how many of them are on the map — so the map's count is never read as the whole case.")
                .accessibilityIdentifier("case.map.coverage")
                .popover(isPresented: $showCoverage) { CaseMapCoveragePopover(coverage: map.coverage).padding(14).frame(width: 520) }
            Button { showLegend.toggle() } label: { Label("Legend", systemImage: "info.square") }
                .buttonStyle(.borderless)
                .help("Every icon, line and state, with what each means; and the keys.")
                .accessibilityIdentifier("case.map.legend")
                .popover(isPresented: $showLegend) { CaseMapLegend().padding(14).frame(width: 420) }
            Button("Reset view") { Task { await map.resetView(repository: repository, service: service) } }
                .buttonStyle(.borderless)
                .help("Puts this view's zoom, filters, hidden items and the map's positions back to their starting state. No case record is changed or removed.")
            Button("Undo") { Task { await map.undo(repository: repository) } }
                .buttonStyle(.borderless)
                .disabled(reason: map.canUndo ? nil : "Nothing to undo.")
                .keyboardShortcut("z", modifiers: [.command, .control])
            Menu("Export") {
                Button("Export map as PDF (with its relationship table)…") { export(.pdf) }
                Button("Export map as PNG and the table as CSV…") { export(.png) }
                Button("Export the relationship table (CSV)…") { export(.csv) }
                Divider()
                Button("Copy the relationship table") { exportCopy() }
                Button("Print the relationship table") { exportPrint() }
                Divider()
                Button("Export the case package (read-only, whole case)…") { exportProduct(.wholeCase) }
                if case .node(let id)? = map.selection {
                    Button("Export the selected branch as a package…") { exportProduct(.branch(id)) }
                }
                Button("Export the money report…") { exportProduct(nil) }
                Button("Export this case's review record…") { exportReviewRecord() }
                Divider()
                Button("Approve the reports and the package at this revision") { approveOutputs() }
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Exports what this view shows, with every link traced to its sources, through the app's export checks. A recorded state says which state it is.")
            .disabled(reason: map.result == nil ? "The map has not been read yet." : nil)
            Menu("Arrange") {
                if case .node(let id)? = map.selection {
                    Button("Arrange the selected item's branch") { confirmArrange = .branch(id) }
                }
                Button("Arrange everything in this view") { confirmArrange = .view }
                if !map.multiSelection.isEmpty {
                    Divider()
                    Button("Arrange the chosen items (\(map.multiSelection.count))") { confirmArrange = .chosen(map.multiSelection) }
                    Button("Pin the chosen items") { Task { await map.setPinned(true, map.multiSelection, repository: repository) } }
                    Button("Unpin the chosen items") { Task { await map.setPinned(false, map.multiSelection, repository: repository) } }
                    Button("Clear the choice") { map.clearMulti() }
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
    }

    private var arrangeTitle: String {
        switch confirmArrange {
        case .branch?: return "Arrange the selected item and the items linked to it?"
        case .view?: return "Arrange every item shown in this view (\(map.result?.shown.count ?? 0))?"
        case .chosen(let ids)?: return "Arrange the \(ids.count) chosen item(s)?"
        case nil: return "Arrange"
        }
    }

    // MARK: Sheets

    private var saveViewSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save this view").font(.headline)
            Text("Keeps the view's kinds, filters, hidden items, collapsed groups, folded branches and the frames open now under a name, in this case's encrypted ledger. It copies no case record.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Name (e.g. Payment authorisation)", text: $newViewName)
            HStack {
                Spacer()
                Button("Cancel") { savingView = false }.keyboardShortcut(.cancelAction)
                Button("Save view") {
                    guard let repository else { return }
                    let name = newViewName
                    Task { await map.saveCurrentView(named: name, repository: repository, actor: model.actor) }
                    savingView = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(reason: newViewName.trimmingCharacters(in: .whitespaces).isEmpty ? "Give the view a name." : nil)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    // MARK: Export (M8) — through CaseOutputService only

    private func exportRequest() -> CaseMapExportRequest? {
        guard let p = map.projection, let r = map.result else { return nil }
        let selected: CaseMapNodeID? = { if case .node(let id)? = map.selection { return id }; return nil }()
        let state: CaseMapExportRequest.State = map.history.map { .recorded($0.summary) } ?? .current(Date())
        let scope = map.history?.summary.scopeFingerprint ?? map.liveScopeFingerprint
        return CaseMapExportRequest(projection: p, placements: map.displayPlacements, shown: r.shown, links: r.links, selection: selected,
                                    viewTitle: map.title(map.view), state: state, scopeFingerprint: scope)
    }

    private func export(_ format: CaseMapExportFormat) {
        guard let outputs = appState.caseOutputs, let req = exportRequest() else { exportStatus = "The ledger isn't ready yet; nothing was exported."; return }
        Task { exportStatus = await CaseMapExportRoutes.exportFile(outputs: outputs, request: req, format: format, actor: model.actor) }
    }

    /// S11 — the case package (whole case or a branch), or the money report (nil), through CaseOutputService.
    private func exportProduct(_ selection: CasePackageSelection?) {
        guard let outputs = appState.caseOutputs, let service else { exportStatus = "The ledger isn't ready yet; nothing was exported."; return }
        let caseID = model.caseID, actor = model.actor, title = map.projection?.title ?? "Case"
        Task {
            if let selection {
                exportStatus = await CaseMapExportRoutes.exportPackage(outputs: outputs, caseID: caseID, title: title, selection: selection, actor: actor, service: service)
            } else {
                exportStatus = await CaseMapExportRoutes.exportMoneyReport(outputs: outputs, caseID: caseID, title: title, actor: actor)
            }
        }
    }

    /// S11 (OUTPUT-01) — a review case's own record, through the release check.
    private func exportReviewRecord() {
        guard let outputs = appState.caseOutputs, let db = appState.database, let file = appState.caseFiles?.file, let service else {
            exportStatus = "The ledger isn't ready yet; nothing was exported."; return
        }
        let review = CaseHistoryReviewService(database: db, file: file, map: service)
        let caseID = model.caseID, actor = model.actor, title = map.projection?.title ?? "Case"
        Task { exportStatus = await CaseMapExportRoutes.exportReviewRecord(outputs: outputs, review: review, caseID: caseID, title: title, actor: actor) }
    }

    /// S11 (OUTPUT-08) — approve the case's conclusion outputs at its current revision (a review decision; refused without
    /// the review role in a team case; labelled self-approved in a solo case).
    private func approveOutputs() {
        guard let outputs = appState.caseOutputs else { exportStatus = "The ledger isn't ready yet; nothing was approved."; return }
        let caseID = model.caseID, actor = model.actor
        Task {
            do {
                let done = try await outputs.approve(caseID: caseID, kinds: [.caseFileReport, .casePackage, .moneyReport, .briefing, .reviewRecord], note: nil, actor: actor)
                exportStatus = "Approved \(done.count) kind(s) of output at case revision \(done.first.map { String($0.revisionFence.prefix(12)) } ?? ""). Any change to the case makes them drafts again."
            } catch {
                KalsmritikoshLog.ui.error("Output approval not recorded: \(error.localizedDescription, privacy: .public)")
                exportStatus = error.localizedDescription
            }
        }
    }

    private func exportCopy() {
        guard let outputs = appState.caseOutputs, let req = exportRequest() else { exportStatus = "The ledger isn't ready yet; nothing was copied."; return }
        Task { exportStatus = await CaseMapExportRoutes.copyTable(outputs: outputs, request: req, actor: model.actor) }
    }

    private func exportPrint() {
        guard let outputs = appState.caseOutputs, let req = exportRequest() else { exportStatus = "The ledger isn't ready yet; nothing was printed."; return }
        Task { exportStatus = await CaseMapExportRoutes.printTable(outputs: outputs, request: req, actor: model.actor) }
    }

    // MARK: Open a source (the existing source-reopen path; identifiers only in the preference)

    func open(_ ref: CaseMapSourceRef) {
        guard let object = ref.objectID else { model.error = "This source has no readable document in the case; it cannot be opened."; return }
        model.workspace.state.lastSource = CaseSourcePosition(objectID: object, origin: nil, revision: ref.sourceVersionID)
        let quote = ref.quote
        Task { @MainActor in
            // SRC-01/SRC-08 — the CITED version: its kept copy, or the file only when its bytes are the cited
            // ones. Otherwise the cited passage from the ledger, labelled — never a newer document in its place.
            switch await CitedSourceOpening.resolve(appState, objectID: object, sourceVersionID: ref.sourceVersionID, quote: quote, blockID: ref.blockID) {
            case .viewer(let target): openSource = target
            case .passage(let opened): openedPassage = opened
            }
        }
    }
}

/// The legend: every kind's icon, every line style, every state — always available.
struct CaseMapLegend: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Legend").font(.headline)
                Text("Items").font(.caption.weight(.semibold))
                ForEach(CaseMapNodeKind.allCases) { k in Label(k.label, systemImage: k.symbol).font(.caption) }
                Text("Links (the arrow points from the item to what it relates to)").font(.caption.weight(.semibold))
                ForEach(CaseMapLinkType.allCases) { t in
                    HStack(alignment: .firstTextBaseline) {
                        Text(t.stroke == .solid ? "———" : t.stroke == .dashed ? "– – –" : "· · · ·").font(.caption.monospaced()).frame(width: 52, alignment: .leading)
                            .accessibilityLabel("\(t.stroke.rawValue) line" + (t.directed ? " with an arrow" : ""))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.label).font(.caption.weight(.medium))
                            Text(HelpRegistry.caseMapLinkHelp(t)).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Text("States").font(.caption.weight(.semibold))
                ForEach(CaseMapStatus.Kind.allCases, id: \.self) { k in
                    VStack(alignment: .leading, spacing: 1) {
                        Label(k.label, systemImage: k.symbol).font(.caption.weight(.medium))
                        Text(HelpRegistry.caseMapStatusHelp(k)).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Review states").font(.caption.weight(.semibold))
                ForEach(CaseMapReviewState.allCases, id: \.self) { r in
                    Text("\(r.label) — \(HelpRegistry.caseMapReviewHelp(r))").font(.caption2).fixedSize(horizontal: false, vertical: true)
                }
                // S12 (HELP-03) — folds, what changed and uncertainty, in the legend's own words (the same text as Help).
                Text("Groups, changes and certainty").font(.caption.weight(.semibold))
                ForEach(CaseMapLegendExtras.lines, id: \.title) { line in
                    VStack(alignment: .leading, spacing: 1) {
                        Label(line.title, systemImage: line.symbol).font(.caption.weight(.medium))
                        Text(line.text).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Keys").font(.caption.weight(.semibold))
                ForEach(CaseMapKeyboard.lines, id: \.self) { Text($0).font(.caption2).fixedSize(horizontal: false, vertical: true) }
                Text("Zoom changes how much of each item is shown — at close zoom a card adds its state, date, amount, sources and first line — never the records or their states. A folded branch shows how many items it holds and how many are new, blocked or waiting for review.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Every item has the same size and every line the same width, whatever its certainty. Size, position, the number of links and how tidy the map looks say nothing about whether something is proved. A pin keeps an item where you put it. Hiding an item removes it from this view only.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 460)
    }
}

/// S3 (GRAPH-06) — every store of the case, its records and how many are on the map.
struct CaseMapCoveragePopover: View {
    let coverage: CaseMapCoverage?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Coverage of this case").font(.headline)
            Text("The map draws the case's questions, people, documents, statements, events, reports, work and money. Other stores are reached from the item they belong to (the inspector's “Other records” for a person, an interview or the case) or in the case sections. Counts are this case's rows now.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let c = coverage {
                if let s = c.summary { Label(s, systemImage: "exclamationmark.circle").font(.caption).fixedSize(horizontal: false, vertical: true) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(c.rows.filter { ($0.rows ?? 1) > 0 }) { r in
                            HStack(alignment: .firstTextBaseline) {
                                Text(r.table.replacingOccurrences(of: "_", with: " ")).font(.caption).frame(width: 200, alignment: .leading).lineLimit(1)
                                Text(r.rows.map(String.init) ?? "not counted").font(.caption.monospacedDigit()).frame(width: 70, alignment: .trailing)
                                Text(r.onMap.map { "\($0) on the map" } ?? r.map).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                            if let p = r.problem { Text(p).font(.caption2).foregroundStyle(.red) }
                        }
                    }
                }
                .frame(maxHeight: 360)
            } else {
                Text("Reading the case's stores…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
