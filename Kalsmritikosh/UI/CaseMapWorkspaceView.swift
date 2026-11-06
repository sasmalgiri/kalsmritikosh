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
        .task(id: model.caseID) { await start() }
        .onDisappear { map.cancelPending() }
        .onChange(of: model.snapshot?.actions.count) { _, _ in Task { await reload() } }
        .onChange(of: model.review.items) { _, _ in Task { await reload() } }
        .onChange(of: model.requests.map(\.request.revision)) { _, _ in Task { await reload() } }
        .sheet(isPresented: $showChanges) { changesSheet }
        .sheet(isPresented: $savingView) { saveViewSheet }
        .sheet(item: $openSource) { target in CitationSourceSheet(target: target) { openSource = nil } }
        .sheet(item: $openedPassage) { opened in
            VStack(spacing: 0) {
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
        if service == nil, let db = appState.database, let files = appState.caseFiles, let objects = appState.objects {
            service = CaseMapService(sources: .live(database: db, caseFiles: files, custody: appState.investigationCustody,
                                                   analysis: appState.investigationAnalysis, desk: appState.investigationContradictionGap,
                                                   objects: objects))
        }
        await reload()
    }

    func reload() async {
        guard let service else { map.error = "The ledger isn't ready yet."; return }
        await map.refresh(service)
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
                Button { showChanges = true } label: { Label("What changed", systemImage: "clock.arrow.circlepath") }
                Button { nextAction() } label: { Label("Next action", systemImage: "arrow.right.circle") }
                    .disabled(reason: model.glance?.nextStep == nil ? "No next step is recorded for this case." : nil)
                Button { findFocused = true } label: { Label("Search this case", systemImage: "magnifyingglass") }
                    .help("Find items on this map — the whole case's items, including collapsed groups. Search ▸ in the sidebar searches the documents' text.")
                Button { map.returnToOverview() } label: { Label("Return to overview", systemImage: "house") }
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
            .accessibilityHint("Opens the matching items in the list.")
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
                        ForEach(map.strip, id: \.self) { ref in
                            let selected = ref == map.view
                            Button { map.go(to: ref) } label: {
                                Label(map.title(ref), systemImage: symbol(ref)).font(.callout)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(selected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected ? 1.5 : 0.5))
                            }
                            .buttonStyle(.plain)
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
                Picker("Show as", selection: Binding(get: { map.listMode }, set: { map.listMode = $0 })) {
                    Label("Map", systemImage: "point.3.connected.trianglepath.dotted").tag(false)
                    Label("List", systemImage: "list.bullet").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                .accessibilityLabel("Show as map or list")
            }
            HStack(spacing: 6) {
                Button { map.goBack() } label: { Label("Back", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(.borderless).controlSize(.small)
                    .disabled(reason: map.canGoBack ? nil : "Nothing to go back to yet.")
                    .keyboardShortcut("[", modifiers: [.command, .control])
                    .help("Back to the previous view and selection (⌃⌘[)")
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
            Text(map.baseKind.emphasis).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
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
                HStack(spacing: 0) {
                    Group {
                        if p.nodes.count <= 1 {
                            stateMessage("Nothing to map yet",
                                         "Record the question this case is to answer, then bring documents into the case (Case sections ▸ Evidence ▸ “Add documents to this case”), select passages and decide contradictions. Each appears here.",
                                         "map")
                        } else if map.listMode {
                            CaseMapList(map: map, projection: p, result: result, repository: repository, actor: model.actor)
                        } else {
                            CaseMapCanvas(map: map, projection: p, result: result, repository: repository, actor: model.actor)
                        }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    CaseMapInspector(model: model, s: s, projection: p, repository: repository,
                                     reload: { await reload() }, openSource: { open($0) })
                        .frame(width: 340)
                }
            }
        } else {
            ProgressView("Reading the case…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func banners(_ p: CaseMapProjection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch map.loadState {
            case .partial(let parts)?:
                Label("Incomplete: \(parts.map(\.label).joined(separator: ", ")) could not be read. Those items are not on the map; this is not an empty result.",
                      systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            case .stale(let why)?:
                Label(why, systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
            default: EmptyView()
            }
            if p.danglingLinks > 0 {
                Label("\(p.danglingLinks) of your map link(s) point at an item no longer in this case; they are not drawn.", systemImage: "link.badge.plus")
                    .foregroundStyle(.secondary)
            }
            if let e = map.error { Label(e, systemImage: "xmark.octagon").foregroundStyle(.red) }
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
            Button { showLegend.toggle() } label: { Label("Legend", systemImage: "info.square") }
                .buttonStyle(.borderless)
                .popover(isPresented: $showLegend) { CaseMapLegend().padding(14).frame(width: 380) }
            Button("Reset view") { Task { await map.resetView(repository: repository, service: service) } }
                .buttonStyle(.borderless)
                .help("Puts this view's zoom, filters, hidden items and the map's positions back to their starting state. No case record is changed or removed.")
            Button("Undo") { Task { await map.undo(repository: repository) } }
                .buttonStyle(.borderless)
                .disabled(reason: map.canUndo ? nil : "Nothing to undo.")
                .keyboardShortcut("z", modifiers: [.command, .control])
            Menu("Arrange") {
                if case .node(let id)? = map.selection {
                    Button("Arrange the selected item's branch") { confirmArrange = .branch(id) }
                }
                Button("Arrange everything in this view") { confirmArrange = .view }
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
    }

    private var arrangeTitle: String {
        switch confirmArrange {
        case .branch?: return "Arrange the selected item and the items linked to it?"
        case .view?: return "Arrange every item shown in this view (\(map.result?.shown.count ?? 0))?"
        case nil: return "Arrange"
        }
    }

    // MARK: Sheets

    private var changesSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What changed").font(.headline)
            Text("The case-scoped list of changes is still being built. Until then: the Changes view in the strip shows this case's items that changed since they were decided or carried (reopened contradictions, superseded results, revised statements); below are the archive-wide changes. Seeing a change is not reviewing it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Show the Changes view") { map.go(to: .builtIn(.changes)); showChanges = false }
                Spacer()
                Button("Close") { showChanges = false }.keyboardShortcut(.cancelAction)
            }
            Divider()
            ChangesView()
        }
        .padding(16)
        .frame(width: 720, height: 560)
    }

    private var saveViewSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save this view").font(.headline)
            Text("Keeps the view's kinds, filters, hidden items and collapsed groups under a name, in this case's encrypted ledger. It copies no case record.")
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

    // MARK: Open a source (the existing source-reopen path; identifiers only in the preference)

    func open(_ ref: CaseMapSourceRef) {
        guard let object = ref.objectID else { model.error = "This source has no readable document in the case; it cannot be opened."; return }
        model.workspace.state.lastSource = CaseSourcePosition(objectID: object, origin: nil, revision: ref.sourceVersionID)
        let quote = ref.quote
        Task { @MainActor in
            do {
                if let repo = appState.objects, let url = try await repo.fetchSourceURL(id: object) {
                    openSource = CitationOpenTarget(url: url, objectID: object, quote: quote)
                    return
                }
            } catch {
                KalsmritikoshLog.ui.error("Case map open source failed: \(error.localizedDescription, privacy: .public)")
            }
            openedPassage = OpenedSource(citation: VerifiedAnswer.Citation(objectID: object, snippet: quote ?? ""))
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
                    HStack {
                        Text(t.stroke == .solid ? "———" : t.stroke == .dashed ? "– – –" : "· · · ·").font(.caption.monospaced()).frame(width: 52, alignment: .leading)
                        Text(t.label).font(.caption)
                    }
                }
                Text("States").font(.caption.weight(.semibold))
                ForEach(CaseMapStatus.Kind.allCases, id: \.self) { k in Label(k.label, systemImage: k.symbol).font(.caption) }
                Text("Every item has the same size. Size, position, the number of links and how tidy the map looks say nothing about whether something is proved. A pin keeps an item where you put it. Hiding an item removes it from this view only.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 460)
    }
}
