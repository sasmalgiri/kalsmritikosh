//
//  NavigationAreas.swift
//  Kalsmritikosh
//
//  Navigation merge (Core and Add-On Scope 2026-11-06, §3): the Evidence, Search and Outputs areas, the
//  More tools list and the notice a screen shows when its optional pack is off. Each area hosts the
//  existing screens unchanged; what is new is the line at the top that says whether the person is working
//  in the open case or in the whole library, and (in Search) which of the two is searched or asked.
//  The rules behind the words are in NavigationMap.swift.
//

import SwiftUI
import os

// MARK: - The open case

/// The open case's title and document counts, read from the ledger by id (the preference holds the id only).
@MainActor @Observable
final class ActiveCaseModel {
    private(set) var caseID: UUID?
    private(set) var workspaceID: UUID?
    private(set) var facts: ContextLabel.CaseFacts?
    /// The open case could not be read (the label says so instead of claiming the whole library).
    private(set) var loadError: String?
    /// The case last open is no longer in this ledger (erased, or the sample ledger is open).
    private(set) var missing = false
    private(set) var loaded = false

    func load(_ app: AppState, raw: String) async {
        defer { loaded = true }
        loaded = false; loadError = nil; missing = false
        guard let id = ActiveCaseContext.caseID(raw: raw) else { clear(); return }
        guard let repo = app.investigationCases else { clear(); return }
        do {
            guard let record = try await repo.fetch(caseID: id) else { clear(); missing = true; return }
            caseID = id
            workspaceID = record.caseHeader.workspaceID
            facts = .init(title: record.caseHeader.title, inScope: record.authorizedSourceRefs.count,
                          excluded: record.excludedSourceRefs.count, closed: record.caseHeader.status == .closed)
        } catch {
            KalsmritikoshLog.ui.error("Open case read failed: \(error.localizedDescription, privacy: .public)")
            clear()
            loadError = "The open case could not be read, so this shows the whole library."
        }
    }

    private func clear() { caseID = nil; workspaceID = nil; facts = nil }
}

/// The line at the top of Evidence and Outputs: in a case (which, how many documents) or the whole library.
struct CaseContextBar: View {
    enum Area { case evidence, outputs }
    let area: Area
    let model: ActiveCaseModel
    let onNavigate: (Destination) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: model.facts == nil ? "books.vertical" : "folder.badge.person.crop")
                .foregroundStyle(model.facts == nil ? Color.secondary : Theme.brand)
            VStack(alignment: .leading, spacing: 2) {
                if let f = model.facts {
                    Text(ContextLabel.caseHeadline(f)).font(.callout.weight(.semibold))
                    Text(area == .evidence ? ContextLabel.evidenceDetail(f)
                         : "Saved answers, questions and notes below are the library's. This case's report and its exports are in its file ▸ Log & exports.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(ContextLabel.libraryHeadline).font(.callout.weight(.semibold))
                    Text(model.loadError ?? (model.missing ? "The case last open is not in this ledger. " + ContextLabel.libraryDetail : ContextLabel.libraryDetail))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let id = model.caseID {
                Button(area == .evidence ? "Open this case's evidence" : "Open this case's report and exports") {
                    ActiveCaseContext.prepareOpen(caseID: id, tab: (area == .evidence ? CaseFileTab.evidence : CaseFileTab.log).rawValue)
                    onNavigate(.cases)
                }
                .controlSize(.small)
            } else {
                Button("Open Cases") { onNavigate(.cases) }.controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.brand.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nav.context")
    }
}

// MARK: - Evidence

/// Evidence: intake and review — Sources, Library, Completeness and Processing, with the import queue.
struct EvidenceAreaView: View {
    @Environment(AppState.self) private var appState
    /// The section an old destination opens (nil: the section last used).
    let section: EvidenceSection?
    let onNavigate: (Destination) -> Void
    @AppStorage("kalsmritikosh.nav.evidenceSection", store: AppDefaults.store) private var lastSection = EvidenceSection.sources.rawValue
    @AppStorage(ActiveCaseContext.key, store: AppDefaults.store) private var activeRaw = ""
    @State private var context = ActiveCaseModel()
    @State private var showImportQueue = false

    private var current: EvidenceSection { section ?? EvidenceSection(rawValue: lastSection) ?? .sources }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text("Evidence").font(.title2.bold())
                    Spacer()
                    if ProductModuleFlags.isEnabled(.importQueue), !appState.importQueue.items.isEmpty {
                        Button { showImportQueue = true } label: {
                            Label("Import queue (\(appState.importQueue.pendingCount))", systemImage: "list.bullet.rectangle")
                        }
                        .controlSize(.small)
                    }
                    Picker("Section", selection: Binding(get: { current }, set: { pick($0) })) {
                        ForEach(EvidenceSection.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("nav.evidence.section")
                }
                CaseContextBar(area: .evidence, model: context, onNavigate: onNavigate)
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)
            Divider()
            Group {
                switch current {
                case .sources: SourcesView()
                case .library: LibraryView()
                case .completeness: CompletenessView()
                case .live: LiveDashboardView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task(id: activeRaw) { await context.load(appState, raw: activeRaw) }
        .onAppear { if let section { lastSection = section.rawValue } }
        .sheet(isPresented: $showImportQueue) { ImportQueueView(queue: appState.importQueue) }
    }

    private func pick(_ s: EvidenceSection) {
        lastSection = s.rawValue
        onNavigate(s.destination)
    }
}

// MARK: - Outputs

/// Outputs: saved answers, saved questions, notes and work products; exports of the timeline, people or
/// documents; the open case's report is one click away in its file.
struct OutputsAreaView: View {
    @Environment(AppState.self) private var appState
    let section: OutputsSection?
    let onNavigate: (Destination) -> Void
    @AppStorage("kalsmritikosh.nav.outputsSection", store: AppDefaults.store) private var lastSection = OutputsSection.answers.rawValue
    @AppStorage(ActiveCaseContext.key, store: AppDefaults.store) private var activeRaw = ""
    @State private var context = ActiveCaseModel()
    @State private var showExports = false

    private var current: OutputsSection { section ?? OutputsSection(rawValue: lastSection) ?? .answers }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text("Outputs").font(.title2.bold())
                    Spacer()
                    Button { showExports = true } label: { Label("Export timeline, people or documents…", systemImage: "square.and.arrow.up") }
                        .controlSize(.small)
                        .help("CSV, Word and PDF, with a count first and a receipt beside the file. Case reports are exported from the case file.")
                    Picker("Section", selection: Binding(get: { current }, set: { pick($0) })) {
                        ForEach(OutputsSection.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("nav.outputs.section")
                }
                CaseContextBar(area: .outputs, model: context, onNavigate: onNavigate)
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)
            Divider()
            Group {
                switch current {
                case .answers: AnswersView()
                case .saved: SavedQueriesView()
                case .notebook: NotebookView()
                case .handoff: WorkProductHandoffView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task(id: activeRaw) { await context.load(appState, raw: activeRaw) }
        .onAppear { if let section { lastSection = section.rawValue } }
        .sheet(isPresented: $showExports) {
            VStack(spacing: 0) {
                ExportCenterView()
                HStack { Spacer(); Button("Done") { showExports = false }.keyboardShortcut(.cancelAction) }.padding(10)
            }
            .environment(appState)
        }
    }

    private func pick(_ s: OutputsSection) {
        lastSection = s.rawValue
        onNavigate(s.destination)
    }
}

// MARK: - Search (with Ask)

/// Search: find words or ask a question, in the open case by default; the whole library only when chosen.
/// Case scope runs the case search (CaseSearchService, this case's documents only) and the case's Ask
/// (InvestigationAnswerService); library scope runs the archive search and the archive Ask.
struct SearchAreaView: View {
    @Environment(AppState.self) private var appState
    let mode: SearchMode
    let onNavigate: (Destination) -> Void
    @AppStorage(ActiveCaseContext.key, store: AppDefaults.store) private var activeRaw = ""
    @State private var context = ActiveCaseModel()
    /// Starts from the stored case id at once, so a query handed over from the header search box is never
    /// run on the library before the case is known.
    @State private var state = SearchAreaState(activeCase: ActiveCaseContext.caseID())
    /// A query typed into the header box while searching a case (the case search runs it).
    @State private var caseSeed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text("Search").font(.title2.bold())
                    Picker("Mode", selection: Binding(get: { mode }, set: { onNavigate($0 == .ask ? .ask : .search) })) {
                        ForEach(SearchMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("nav.search.mode")
                    Spacer()
                    if let facts = context.facts, state.activeCase != nil {
                        Picker("Look in", selection: Binding(get: { state.scope.caseID != nil }, set: { $0 ? state.narrow() : state.widen() })) {
                            Text("This case").tag(true)
                            Text("Whole library").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .help("“This case” looks only in “\(facts.title)”. “Whole library” looks in every document you added.")
                        .accessibilityIdentifier("nav.search.scope")
                    } else {
                        Label("Whole library", systemImage: "books.vertical").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(context.loadError ?? ContextLabel.searchDetail(effectiveScope, mode: mode, caseTitle: context.facts?.title))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("nav.search.detail")
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task(id: activeRaw) {
            state.caseChanged(ActiveCaseContext.caseID(raw: activeRaw))
            await context.load(appState, raw: activeRaw)
            // The stored case is gone or unreadable: say so and search the library (shown in the label);
            // a query handed over meanwhile goes to the library search, which the label names.
            if context.caseID == nil {
                state.caseChanged(nil)
                if let q = caseSeed { caseSeed = nil; appState.pendingSearchQuery = q }
            }
        }
        .onAppear(perform: takePendingQuery)
        .onChange(of: appState.pendingSearchQuery) { _, _ in takePendingQuery() }
    }

    /// The scope actually used: a case scope only once the case is known to be readable.
    private var effectiveScope: SearchScope {
        if let id = state.scope.caseID, context.caseID == id || !context.loaded { return .activeCase(id) }
        return .library
    }

    @ViewBuilder
    private var content: some View {
        switch (effectiveScope, mode) {
        case (.activeCase(let id), .find):
            if context.caseID == id {
                CaseSearchPanel(caseID: id, actor: InvestigatorProfile.name, closed: context.facts?.closed ?? false,
                                embedded: true, seed: $caseSeed) {}
                    .id(id)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case (.activeCase(let id), .ask):
            if context.caseID == id, let ws = context.workspaceID, let facts = context.facts {
                AskView(caseScope: AskCaseScope(caseID: id, workspaceID: ws, title: facts.title))
                    .id(id)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case (.library, .find):
            SearchView()
        case (.library, .ask):
            AskView()
        }
    }

    /// A query from the header search box or the menu bar: in a case it runs as a case search.
    private func takePendingQuery() {
        guard mode == .find, effectiveScope.caseID != nil,
              let q = appState.pendingSearchQuery?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty else { return }
        appState.pendingSearchQuery = nil
        caseSeed = q
    }
}

// MARK: - More tools

/// Every specialist screen, grouped by the work it supports. None is needed for an ordinary case.
struct MoreToolsView: View {
    let onNavigate: (Destination) -> Void

    private var groups: [(group: Destination.Group, items: [Destination])] {
        Destination.Group.allCases.compactMap { g in
            let items = g == .system ? g.items.filter { ![.settings, .guide, .moreTools].contains($0) } : g.items
            return (g.inMoreTools && !items.isEmpty) ? (g, items) : nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("More tools").font(.title2.bold())
                    Text("Every specialist screen. None is needed for an ordinary case: start and resume in Cases, add and review documents in Evidence, search or ask in Search, find saved work in Outputs. Each screen here is also in the ⌘K palette.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(groups, id: \.group) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.group.rawValue).font(.headline)
                        Text(entry.group.blurb).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 8, alignment: .top)], alignment: .leading, spacing: 8) {
                            ForEach(entry.items) { dest in row(dest) }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .accessibilityIdentifier("nav.moreTools")
    }

    private func row(_ dest: Destination) -> some View {
        Button { onNavigate(dest) } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: dest.icon).foregroundStyle(Theme.brand).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(dest.title).font(.callout.weight(.medium))
                        if let hint = dest.shortcutHint { Text(hint).font(.caption2.monospaced()).foregroundStyle(.tertiary) }
                    }
                    Text(dest.blurb).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(dest.title) — \(dest.blurb)")
        .accessibilityIdentifier("nav.moreTools.\(dest.rawValue)")
    }
}

// MARK: - A screen whose optional pack is off

/// The screen of an optional pack opens either way — work made with it stays readable — and, with the pack
/// off, says so at the top with the way to turn it on.
struct PackGatedScreen<Content: View>: View {
    let dest: Destination
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            if let text = PackNotice.text(for: dest) {
                HStack(spacing: 10) {
                    Image(systemName: "puzzlepiece.extension").foregroundStyle(.orange)
                    Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(PackNotice.remedy) {
                        NotificationCenter.default.post(name: .kalsmritikoshPaletteEntry, object: "set.modules")
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("nav.pack.turnOn")
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.10))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("nav.pack.off")
                Divider()
            }
            content
        }
    }
}
