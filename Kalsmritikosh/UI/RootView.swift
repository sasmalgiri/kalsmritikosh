//
//  RootView.swift
//  Kalsmritikosh
//
//  Modern macOS shell. Replaces the old 16-tab TabView with a
//  NavigationSplitView + grouped sidebar — the standard shape for a
//  content-dense Mac app. Sidebars and toolbars pick up Liquid Glass
//  automatically from the system; we add standard materials only for
//  the floating ingest-status pill (content-layer element).
//

import SwiftUI
#if canImport(TipKit)
import TipKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import UniformTypeIdentifiers

// MARK: - Navigation model

/// Every surface the app exposes, grouped into sidebar sections. One
/// source of truth for title + SF Symbol + section so the sidebar and
/// the detail switch never drift apart.
public enum Destination: String, CaseIterable, Identifiable, Hashable {
    case home
    case ask, search
    case work
    case workCenter
    case registers
    case workspaces
    case dataLab
    case timeline, history, findings, notebook, dossier, explore, matrix, connections, story
    case reasoning, hypotheses, hrStudio
    case fundFlow, emailThreads
    case review
    case handoff
    case transcripts
    case insights, changes
    case knowledge, assertions, answers, audit, verifyReceipt, library, saved
    case authenticity, citations, freshness, trends, query
    case sources, convert, completeness, live
    case redaction, caseload
    case guide, settings, sutra

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .home:         return "Home"
        case .ask:          return "Ask"
        case .search:       return "Search"
        case .work:         return "Professional Jobs"
        case .workCenter:   return "Work Center"
        case .registers:    return "Logs & Trackers"
        case .dataLab:      return "DataLab"
        case .handoff:      return "Handoff & Review"
        case .workspaces:   return "Workspaces"
        case .timeline:     return "Timeline"
        case .history:      return "History"
        case .findings:     return "Findings"
        case .notebook:     return "Notebook"
        case .dossier:      return "Dossier"
        case .explore:      return "Explore"
        case .matrix:       return "Cross-Doc Matrix"
        case .connections:  return "Connections"
        case .fundFlow:     return "Fund Flow"
        case .emailThreads: return "Email Threads"
        case .story:        return "Case Story"
        case .reasoning:    return "Reasoning Studio"
        case .hypotheses:   return "Competing Hypotheses"
        case .hrStudio:     return "HR Investigation"
        case .review:       return "Review"
        case .transcripts:  return "Transcripts"
        case .insights:     return "Insights"
        case .changes:      return "What Changed"
        case .knowledge:    return "Knowledge"
        case .assertions:   return "Assertions"
        case .answers:      return "Answers"
        case .audit:        return "Audit"
        case .verifyReceipt: return "Verify Receipt"
        case .library:      return "Library"
        case .saved:        return "Saved"
        case .authenticity: return "Authenticity"
        case .citations:    return "Citations"
        case .freshness:    return "Freshness"
        case .trends:       return "Trends"
        case .query:        return "Query"
        case .caseload:     return "Caseload"
        case .sources:      return "Sources"
        case .convert:      return "Convert"
        case .completeness: return "Completeness"
        case .live:         return "Live"
        case .redaction:    return "Redaction"
        case .guide:        return "Guide"
        case .sutra:        return "Constitution"
        case .settings:     return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home:         return "house"
        case .ask:          return "bubble.left.and.text.bubble.right"
        case .search:       return "magnifyingglass"
        case .work:         return "person.crop.rectangle.stack"
        case .workCenter:   return "list.bullet.clipboard"
        case .registers:    return "tray.full"
        case .dataLab:      return "tablecells.badge.ellipsis"
        case .handoff:      return "checkmark.seal"
        case .workspaces:   return "folder.badge.gearshape"
        case .timeline:     return "calendar.day.timeline.left"
        case .history:      return "book.closed"
        case .findings:     return "checkmark.seal"
        case .notebook:     return "note.text"
        case .dossier:      return "person.text.rectangle"
        case .explore:      return "point.3.connected.trianglepath.dotted"
        case .matrix:       return "square.grid.3x3.topleft.filled"
        case .connections:  return "point.topleft.down.to.point.bottomright.curvepath"
        case .fundFlow:     return "arrow.triangle.branch"
        case .emailThreads: return "envelope.badge.person.crop"
        case .story:        return "book.pages"
        case .reasoning:    return "brain.head.profile"
        case .hypotheses:   return "tablecells"
        case .hrStudio:     return "person.2.badge.gearshape"
        case .review:       return "checkmark.bubble"
        case .transcripts:  return "waveform"
        case .insights:     return "lightbulb.max"
        case .changes:      return "bell.badge"
        case .knowledge:    return "books.vertical"
        case .assertions:   return "scroll"
        case .answers:      return "text.bubble"
        case .audit:        return "shield.lefthalf.filled"
        case .verifyReceipt: return "checkmark.seal"
        case .library:      return "books.vertical.fill"
        case .saved:        return "bookmark"
        case .authenticity: return "checkmark.shield"
        case .citations:    return "quote.bubble"
        case .freshness:    return "clock.badge.exclamationmark"
        case .trends:       return "chart.xyaxis.line"
        case .query:        return "line.3.horizontal.decrease.circle"
        case .caseload:     return "square.stack.3d.up"
        case .sources:      return "folder"
        case .convert:      return "arrow.right.doc.on.clipboard"
        case .completeness: return "checklist"
        case .live:         return "waveform.path.ecg"
        case .redaction:    return "eye.slash"
        case .guide:        return "book"
        case .sutra:        return "building.columns"
        case .settings:     return "gearshape"
        }
    }

    /// Curated ⌘1…⌘9 quick-jumps — a game-style "hotbar" of the nine
    /// most-used screens. Shown as hints in the sidebar rows.
    static let quickShortcuts: [(key: KeyEquivalent, dest: Destination)] = [
        ("1", .ask), ("2", .search), ("3", .timeline), ("4", .insights),
        ("5", .knowledge), ("6", .sources), ("7", .convert),
        ("8", .live), ("9", .settings)
    ]

    /// The visible "⌘N" hint for a hotbar screen, or nil if it has none.
    var shortcutHint: String? {
        Self.quickShortcuts.first { $0.dest == self }
            .map { "⌘\($0.key.character)" }
    }

    /// One-line explanation of what each screen is for. Shown in header
    /// tooltips and as the command-palette subtitle.
    var blurb: String {
        switch self {
        case .home:         return "Start here — pick the lens that fits your work"
        case .ask:          return "Ask in plain language; answers cite their evidence"
        case .search:       return "Instant full-text search across every chunk"
        case .work:         return "Pick a professional focus and run its jobs — Investigator, Researcher, Journalist, Individual, Lawyer"
        case .workCenter:   return "Run a guided workflow step by step — gated steps, per-field guidance, and a numbered document for every confirmed step"
        case .registers:    return "Your day-to-day logs — interviews & statements, records requests (FOIA), and a research log. Each entry is editable and keeps its full change history"
        case .dataLab:      return "Build cited datasets over your evidence — transform, test scenarios, check quality; every cell drills to its source"
        case .handoff:      return "Review a matter's findings and evidence, then record the human decisions that hand it off — approve, close, reopen"
        case .workspaces:   return "Organize a matter, case, or project — a filtered view over your evidence"
        case .timeline:     return "Chronological view of all dated events"
        case .history:      return "Narrative reconstruction of what happened"
        case .findings:     return "Every fact by status — proven, inferred, contradicted, missing"
        case .notebook:     return "Your saved notes and working pages"
        case .dossier:      return "Everything known about a person or entity"
        case .explore:      return "Entity graph — see who and what connects"
        case .matrix:       return "Ask one question across every document — what each source says, cited"
        case .connections:  return "Find the shortest chain of relationships linking two people or organizations"
        case .fundFlow:     return "See how money moved between parties — payer to payee — drawn from your evidence"
        case .emailThreads: return "A big email dump, deduplicated and grouped into conversations"
        case .story:        return "The whole cited story of a subject — timeline, parties, clauses, roadblocks, gaps"
        case .reasoning:    return "Run a root-cause investigation start to finish — brainstorm, 5 Whys, a fishbone diagram, a conclusion, and an approval-ready report"
        case .hypotheses:   return "Weigh competing explanations against your evidence — an Analysis of Competing Hypotheses matrix that ranks by fewest inconsistencies"
        case .hrStudio:     return "Run a workplace investigation the real-life way — mandate, allegations, evidence, credibility, classified findings — and produce the exact report an investigator signs"
        case .review:       return "Resolve contradictions and follow up on missing evidence"
        case .transcripts:  return "Timecoded transcripts — search, play, quote audio & video"
        case .insights:     return "Auto-surfaced gaps, contradictions and patterns"
        case .changes:      return "What's new or resolved since your last review — as documents arrive"
        case .knowledge:    return "Canonical entities, events and distilled memory"
        case .assertions:   return "Extracted claims with their supporting evidence"
        case .answers:      return "Past answers with their evidence — replayable and auditable"
        case .audit:        return "Chain-of-custody and every human decision — the append-only record"
        case .verifyReceipt: return "Open an exported receipt and re-check its hash chain — genuine or tampered"
        case .library:      return "Every document you've ingested"
        case .saved:        return "Your bookmarked questions"
        case .authenticity: return "Check a file's provenance — fingerprint, capture metadata, editing traces, PDF edit markers"
        case .citations:    return "Build layered Evidence Explained citations — full note, short note, bibliography"
        case .freshness:    return "Confirmed facts ranked by how long since they were checked — catch stale ones before they're reused"
        case .trends:       return "Patterns across everything — activity over time, event types, entity makeup"
        case .query:        return "Ask a precise question of your ledger — pick a subject, add filters, run. No SQL to write; see the SQL if you want"
        case .caseload:     return "Every matter triaged by how much attention it needs"
        case .sources:      return "Folders being watched and ingested"
        case .convert:      return "Turn files between formats, back and forth"
        case .completeness: return "How fully your archive has been processed"
        case .live:         return "Live pipeline and background activity"
        case .redaction:    return "Remove text from a PDF for real — flattened and verified, not just a black box"
        case .guide:        return "What every screen does, and how facts are graded"
        case .sutra:        return "The constitution the app runs on — every phase, the tooling it earns, its obligations, human decisions, and prohibited conclusions"
        case .settings:     return "Modes, privacy, models and diagnostics"
        }
    }

    enum Group: String, CaseIterable, Identifiable {
        case converse   = "Ask & Search"
        case reconstruct = "Reconstruct"
        case knowledge   = "Knowledge"
        case workspace   = "Workspace"
        case system      = "System"

        var id: String { rawValue }

        var items: [Destination] {
            switch self {
            case .converse:    return [.home, .ask, .search, .work, .workCenter, .registers]
            case .reconstruct: return [.workspaces, .dataLab, .timeline, .history, .findings, .review, .handoff, .matrix, .connections, .fundFlow, .emailThreads, .story, .reasoning, .hypotheses, .hrStudio, .transcripts, .notebook, .dossier, .explore, .insights, .changes]
            case .knowledge:   return [.knowledge, .assertions, .answers, .audit, .verifyReceipt, .library, .saved, .authenticity, .citations, .freshness, .trends, .query]
            case .workspace:   return [.sources, .convert, .completeness, .live, .redaction, .caseload]
            case .system:      return [.guide, .sutra, .settings]
            }
        }

        /// The SINGLE destination kept in Simple mode for this group — Simple collapses each group to one
        /// primary surface for a calmer first-run. Everything else stays reachable via the always-on header
        /// search and the ⌘K palette, so nothing is lost (Simple state == Advanced state).
        var simplePrimary: Destination {
            switch self {
            case .converse:    return .ask
            case .reconstruct: return .workspaces
            case .knowledge:   return .knowledge
            case .workspace:   return .sources
            case .system:      return .settings
            }
        }

        /// Short uppercase caption shown under each header group.
        var shortTitle: String {
            switch self {
            case .converse:    return "ASK"
            case .reconstruct: return "REBUILD"
            case .knowledge:   return "KNOW"
            case .workspace:   return "WORK"
            case .system:      return "SYSTEM"
            }
        }

        /// One-line explanation of what the group is for (header tooltip).
        var blurb: String {
            switch self {
            case .converse:    return "Ask questions and search your archive"
            case .reconstruct: return "Rebuild timelines, histories and dossiers"
            case .knowledge:   return "Browse the structured knowledge base"
            case .workspace:   return "Add sources, convert files, watch activity"
            case .system:      return "Settings and diagnostics"
            }
        }
    }
}

// MARK: - Root

public struct RootView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("kalsmritikosh.onboarding.shown") private var onboardingShown: Bool = false
    @State private var presentingOnboarding = false
    @State private var selection: Destination? = .ask
    /// Game-style quick-swap: the previously-viewed screen, so ⌘\ toggles
    /// straight back to it (like weapon quick-swap in shooters).
    @State private var previousSelection: Destination = .ask
    /// Interface mode. Simple collapses each sidebar group to its ONE primary surface
    /// (Group.simplePrimary); Advanced shows every screen. Everything hidden in Simple stays
    /// reachable via the header search + ⌘K palette. Persisted; default Simple.
    @AppStorage("kalsmritikosh.settings.simpleMode") private var simpleMode: Bool = true
    /// ENGINE POWER — same defaults key FeatureFlags.fullPowerMode reads, so
    /// the sidebar toggle and the engine's value getters stay in lockstep.
    @AppStorage("kalsmritikosh.feature.fullPower") private var fullPower: Bool = true
    /// Semantic-index backlog (embedded chunks vs total), refreshed every 30s
    /// — drives the caption under the Engine picker so Lightning's deferred
    /// indexing is never silent.
    @State private var semanticBacklog: (done: Int, total: Int) = (0, 0)
    /// Engine-switch confirmation. When the user flips Full power ↔ Lightning
    /// while background work is running, we hold the desired value here and
    /// raise a Stop all / Keep running / Cancel dialog instead of flipping
    /// silently — so the switch never strands in-flight work without a choice.
    @State private var pendingEnginePower: Bool?
    @State private var showEngineSwitchConfirm = false
    /// Presents the native "Add files" importer (SwiftUI-managed, sizes correctly).
    @State private var showAddFiles = false
    /// Presents the add-folder importer (from the ⌘K palette).
    @State private var showAddFolder = false
    /// ⌘K command palette visibility.
    @State private var showPalette: Bool = false
    /// "?" keyboard cheat-sheet visibility.
    @State private var showShortcutHelp: Bool = false
    /// Text in the always-visible header search box.
    @State private var headerSearch: String = ""
    /// Chosen persona (GuidePersona.id). Empty = not yet picked → first-run
    /// picker. Drives the "For you" sidebar section (persona's own screens).
    @AppStorage("kalsmritikosh.persona") private var personaID: String = ""
    /// First-run / "change focus" persona picker sheet.
    @State private var showPersonaPicker = false
    /// Which sidebar groups are expanded (Advanced mode only). Default = ALL expanded so the
    /// navigation is visible on first open; the user can collapse a group by clicking its header.
    /// (Simple mode ignores this — it shows one flat row per group, no collapsing.)
    @State private var expandedGroups: Set<Destination.Group> = Set(Destination.Group.allCases)
    /// Sidebar column visibility. Pinned to `.all` so the sidebar is ALWAYS shown by default —
    /// otherwise a narrow window lets NavigationSplitView auto-collapse it and the navigation
    /// "disappears". The user can still hide it via the toolbar toggle.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @Namespace private var sidebarNS

    /// SHELL-001 live wiring — browser-style Back/Forward across surfaces.
    /// The durable model + repository landed with SHELL-001; this connects
    /// them to the actual UI: every navigate() pushes an entry, the toolbar
    /// chevrons walk the cursor, and the whole history autosaves so a
    /// relaunch resumes exactly where the user left off.
    @State private var navHistory = AppNavigationHistory()
    /// True once resume has run (or found nothing) — pushes before that
    /// would race the restored history.
    @State private var navRestored = false

    /// Single navigation entry point. Records the outgoing screen for the
    /// ⌘\ quick-swap, pushes the new location into the durable Back/Forward
    /// history (SHELL-001), then animates to the new one.
    private func navigate(to dest: Destination) {
        if let current = selection, current != dest { previousSelection = current }
        withAnimation(Theme.springFast) { selection = dest }
        navHistory.navigate(to: AppNavigationEntry(
            destination: Self.navBucket(for: dest),
            contextKind: "surface",
            contextID: dest.rawValue))
        autosaveNavHistory()
    }

    /// Back one location (⌘[ or the toolbar chevron).
    private func navGoBack() {
        guard let entry = navHistory.goBack() else { return }
        applyNavEntry(entry)
        autosaveNavHistory()
    }

    /// Forward one location (⌘] or the toolbar chevron).
    private func navGoForward() {
        guard let entry = navHistory.goForward() else { return }
        applyNavEntry(entry)
        autosaveNavHistory()
    }

    /// Show a history entry WITHOUT pushing (cursor moves only — that's the
    /// browser contract). The exact surface round-trips via contextID.
    private func applyNavEntry(_ entry: AppNavigationEntry) {
        guard let dest = entry.contextID.flatMap(Destination.init(rawValue:)) else { return }
        if let current = selection, current != dest { previousSelection = current }
        withAnimation(Theme.springFast) { selection = dest }
    }

    private func autosaveNavHistory() {
        let snapshot = navHistory
        Task { try? await appState.shellSession?.saveHistory(scopeKey: "shell.root", history: snapshot, at: Date()) }
    }

    /// Resume the last session's history (entries + cursor) and land on the
    /// exact surface that was open. Runs once, before any user navigation.
    private func resumeNavHistory() async {
        defer { navRestored = true }
        guard !navRestored else { return }
        if let history = try? await appState.shellSession?.loadHistory(scopeKey: "shell.root"),
           !history.isEmpty {
            navHistory = history
            if let entry = history.current { applyNavEntry(entry) }
        } else if let dest = selection {
            // Fresh session — seed the history with the launch surface.
            navHistory.navigate(to: AppNavigationEntry(
                destination: Self.navBucket(for: dest),
                contextKind: "surface",
                contextID: dest.rawValue))
        }
    }

    /// Coarse mapping of every UI surface into the closed SHELL-001
    /// destination vocabulary; the EXACT surface rides in contextID.
    private static func navBucket(for dest: Destination) -> AppNavigationDestination {
        switch dest {
        case .home:                                                   return .home
        case .ask, .search, .answers, .saved:                         return .answers
        case .work, .workCenter, .registers:                          return .jobs
        case .sources, .convert, .live, .completeness, .workspaces,
             .redaction, .caseload:                                   return .sources
        case .timeline, .history, .changes:                           return .timeline
        case .knowledge, .assertions, .insights, .library,
             .transcripts, .authenticity, .citations,
             .freshness, .trends, .emailThreads, .query:              return .entities
        case .dataLab:                                                return .dataLab
        case .connections, .explore, .matrix, .fundFlow:              return .relationships
        case .findings, .notebook, .dossier, .story, .review,
             .handoff, .verifyReceipt, .audit, .reasoning, .hypotheses,
             .hrStudio:                                                return .reports
        case .guide, .settings, .sutra:                               return .settings
        }
    }

    public init() {}

    public var body: some View {
        phaseContent
            // P0.5 — v1 is single-mode (.ledgerEventDriven pinned), so there is
            // NO user-visible mode chooser in release. The chooser is retained
            // only for internal/debug builds; release never wires the sheet.
            #if DEBUG
            .sheet(isPresented: Binding(
                get: { appState.showModeChooser },
                set: { appState.showModeChooser = $0 }
            )) {
                ModeChooserView(mustChoose: !FeatureFlags.shared.systemModeChosen)
                    .environment(appState)
            }
            #endif
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch appState.phase {
        case .starting:
            loadingView
        case .failed(let message):
            failedView(message)
        case .ready:
            main
        }
    }

    // MARK: Phase views

    private var loadingView: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse)
            ProgressView()
                .controlSize(.small)
            Text("Starting Kalsmritikosh…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 820, minHeight: 520)
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 42))
                .foregroundStyle(.orange)
            Text("Kalsmritikosh couldn't start.")
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(40)
        .frame(minWidth: 820, minHeight: 520)
    }

    // MARK: Main split

    private var main: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            // FLOATING-SIDEBAR FIX — below ~1040pt the split view FLOATS the
            // sidebar as an overlay whose invisible scrim swallows clicks on the
            // header buttons ("upper buttons not clickable when not full screen").
            // Watch the detail width and HIDE the docked sidebar instead of
            // letting it float; it reopens automatically when the window widens.
            detailStack
                .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.width } action: { width in
                    if width < 760, columnVisibility != .detailOnly {
                        columnVisibility = .detailOnly
                    } else if width >= 900, columnVisibility == .detailOnly {
                        columnVisibility = .all
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(Theme.brand)
        .preferredColorScheme(.light)
        .frame(minWidth: 1040, minHeight: 640)
        .background(shortcutButtons)
        .overlay(paletteOverlay)
        .overlay(shortcutHelpOverlay)
        .task { await resumeNavHistory() }   // SHELL-001 — resume last session's location + history
        .onReceive(NotificationCenter.default.publisher(for: .kalsmritikoshNavigate)) { note in
            if let raw = note.object as? String, let dest = Destination(rawValue: raw) {
                navigate(to: dest)
            }
        }
        .onChange(of: appState.pendingWorkCenterDefID) { _, newValue in
            if newValue != nil { navigate(to: .workCenter) }
        }
        .task {
            // ENGINE POWER — refresh the semantic-index backlog caption.
            while !Task.isCancelled {
                let p = await appState.ingestProgress()
                semanticBacklog = (p.embedDone, p.embedTotal)
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        .sheet(isPresented: $presentingOnboarding) {
            OnboardingView()
                .environment(appState)
        }
        .sheet(isPresented: $showPersonaPicker) {
            PersonaPickerView(current: personaID) { picked in
                personaID = picked
                showPersonaPicker = false
            }
        }
        .task {
            if !onboardingShown && appState.bookmarks.roots.isEmpty {
                presentingOnboarding = true
                onboardingShown = true
            }
            // First-run focus pick: if no persona chosen yet, prompt once.
            if personaID.isEmpty && !presentingOnboarding {
                showPersonaPicker = true
            }
        }
    }

    private var detailStack: some View {
            NavigationStack {
                VStack(spacing: 0) {
                    appHeader
                    Divider()
                    detail
                }
                .navigationTitle(selection?.title ?? "Kalsmritikosh")
                .toolbar {
                    // SHELL-001 — browser-style location Back/Forward, deliberately
                    // distinct from any workflow's Prev/Next stepping.
                    ToolbarItemGroup(placement: .navigation) {
                        Button { navigate(to: .home) } label: {
                            Image(systemName: "house")
                        }
                        .keyboardShortcut(.home, modifiers: .command)
                        .help("Home — back to the start screen")
                        Button(action: navGoBack) {
                            Image(systemName: "chevron.backward")
                        }
                        .disabled(!navHistory.canGoBack)
                        .keyboardShortcut("[", modifiers: .command)
                        .help("Back — previous place you visited  (⌘[)")
                        Button(action: navGoForward) {
                            Image(systemName: "chevron.forward")
                        }
                        .disabled(!navHistory.canGoForward)
                        .keyboardShortcut("]", modifiers: .command)
                        .help("Forward  (⌘])")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { showPalette = true } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .help("Jump to any screen or command  (⌘K)")
                    }
                }
            }
    }

    /// Engine picker binding. If background work is in flight, a change is held
    /// as `pendingEnginePower` and the confirmation dialog decides what happens;
    /// otherwise it flips immediately. The getter always returns the committed
    /// `fullPower`, so the segmented control stays put until the user confirms.
    private var enginePowerBinding: Binding<Bool> {
        Binding(
            get: { fullPower },
            set: { newValue in
                guard newValue != fullPower else { return }
                if appState.hasStoppableBackgroundWork {
                    pendingEnginePower = newValue
                    showEngineSwitchConfirm = true
                } else {
                    fullPower = newValue
                }
            })
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                brandHeader
                    .padding(.bottom, 4)
                modeBadge
                    .padding(.bottom, 6)
                paletteButton
                    .padding(.bottom, 6)
                // ADD FILES — always-visible ingestion entry point: pick supported
                // files and the app reads them into your archive (folders are added
                // from Sources). Complements the auto-watched folders.
                Button {
                    showAddFiles = true
                } label: {
                    Label("Add files", systemImage: "plus.rectangle.on.folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                .help("Ingest files into your private archive so you can ask and cite over them. Supported: \(SourceType.attachableSummary)")
                .fileImporter(isPresented: $showAddFiles,
                              allowedContentTypes: SourceType.attachableContentTypes,
                              allowsMultipleSelection: true) { result in
                    if case .success(let urls) = result {
                        Task { await appState.ingestFiles(urls) }
                    }
                }
                .fileImporter(isPresented: $showAddFolder,
                              allowedContentTypes: [.folder],
                              allowsMultipleSelection: false) { result in
                    if case .success(let urls) = result, let url = urls.first {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        try? appState.bookmarks.register(url: url)
                        navigate(to: .sources)
                    }
                }
                // Simple / Advanced interface toggle. Simple shows one primary screen per group;
                // everything else stays reachable via the header search + ⌘K.
                Picker("Interface", selection: $simpleMode) {
                    Text("Simple").tag(true)
                    Text("Advanced").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                // ENGINE POWER (owner request 2026-08-16) — Full power runs the
                // complete stack (embeddings, vector search, on-device AI);
                // Lightning answers from structure + full-text alone: fastest,
                // lowest energy, still evidence-cited. Lossless flip: vectors
                // resume backfilling the moment Full power returns.
                Picker("Engine", selection: enginePowerBinding) {
                    Label("Full power", systemImage: "brain").tag(true)
                    Label("Lightning", systemImage: "bolt.fill").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                .help("Full power: embeddings, vector search and on-device AI. Lightning: structure + full-text only — fastest and lowest energy; answers stay cited to your documents.")
                .confirmationDialog(
                    "Background work is running",
                    isPresented: $showEngineSwitchConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Stop all and switch", role: .destructive) {
                        appState.stopAllBackgroundWork()
                        if let p = pendingEnginePower { fullPower = p }
                        pendingEnginePower = nil
                    }
                    Button("Keep running and switch") {
                        if let p = pendingEnginePower { fullPower = p }
                        pendingEnginePower = nil
                    }
                    Button("Cancel", role: .cancel) { pendingEnginePower = nil }
                } message: {
                    Text("Ingesting, relationship extraction and semantic indexing are still in progress. Switching the engine loses nothing — the work pauses and resumes automatically. Choose Stop all to halt it now instead.")
                }
                // ENGINE POWER visibility — the one honest caveat of the flip:
                // content ingested during Lightning has no semantic index yet.
                // Surface the backlog so catch-up is never silent.
                if semanticBacklog.total > 0 && semanticBacklog.done < semanticBacklog.total {
                    Label(
                        fullPower
                            ? "Semantic index catching up — \(semanticBacklog.done) of \(semanticBacklog.total)"
                            : "Semantic indexing paused — \(semanticBacklog.total - semanticBacklog.done) waiting",
                        systemImage: fullPower ? "arrow.triangle.2.circlepath" : "pause.circle"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                    .help(fullPower
                          ? "New content becomes semantically searchable as the background index catches up. Exact and structured search already covers everything."
                          : "Lightning skips semantic indexing. Everything stays searchable by structure and full text; the semantic index resumes when you switch to Full power.")
                }
                // STOP ALL — always reachable while any background task is in flight
                // (bulk ingest, relationship extraction, semantic indexing, the idle
                // maintenance scan). Halts them at the next safe checkpoint; finished
                // work is kept and a later run resumes the rest. Hidden when idle so
                // the sidebar stays calm.
                if appState.hasStoppableBackgroundWork {
                    Button(role: .destructive) {
                        appState.stopAllBackgroundWork()
                    } label: {
                        Label("Stop all background work", systemImage: "stop.circle.fill")
                            .font(.caption2.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.small)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                    .help("Halt ingesting, relationship extraction and semantic indexing now. Finished work is kept; a later run resumes the rest.")
                }
                onboardingTip
                personaSection
                if simpleMode {
                    // Simple mode: exactly one primary per group. Collapsing a single-item group would
                    // hide it behind a chevron (the "empty sidebar" bug), so show the primaries as a
                    // flat, always-visible list under one calm caption. Everything else is one ⌘K away.
                    Text("GO TO")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .tracking(0.5)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 2)
                    ForEach(Destination.Group.allCases) { group in
                        SidebarRow(dest: group.simplePrimary, isSelected: selection == group.simplePrimary, namespace: sidebarNS) {
                            navigate(to: group.simplePrimary)
                        }
                    }
                    // Even in Simple mode, keep the professional workflow surfaces one
                    // click away — jobs run their guided workflows in the Work Center.
                    ForEach([Destination.work, .workCenter], id: \.self) { dest in
                        SidebarRow(dest: dest, isSelected: selection == dest, namespace: sidebarNS) {
                            navigate(to: dest)
                        }
                    }
                } else {
                    // Advanced mode: every screen, grouped and collapsible (groups start expanded).
                    ForEach(Destination.Group.allCases) { group in
                        if !group.items.isEmpty {
                            collapsibleGroup(group, visible: group.items)
                        }
                    }
                }
            }
            .padding(8)
            .animation(Theme.springFast, value: selection)
        }
        .scrollContentBackground(.hidden)
        .background(
            LinearGradient(
                colors: [Theme.brand.opacity(0.07), Color.clear],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .navigationSplitViewColumnWidth(min: 220, ideal: 244, max: 320)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                maintenanceAskPrompt
                scanContinuePrompt
                // Persistent live-activity window pinned to the sidebar corner
                // (always visible — replaces the old auto-hiding pills). Tap to
                // open the full Live dashboard.
                LiveActivityPanel(onOpen: { navigate(to: .live) })
            }
            .animation(Theme.springSoft, value: appState.scanContinuePromptPending)
            .animation(Theme.springSoft, value: appState.maintenanceAskPending)
            .animation(Theme.springSoft, value: appState.maintenanceActive)
            .animation(Theme.springSoft, value: appState.ingestActiveCount)
            .animation(Theme.springSoft, value: appState.isDistillingMemory)
        }
    }

    /// The persona the user picked (nil until they choose one).
    private var currentPersona: GuidePersona? {
        GuideContent.personas.first { $0.id == personaID }
    }

    /// "For you" — the chosen persona's own screens up top, so a user isn't
    /// faced with every screen. If no persona is chosen yet, shows a single
    /// "Choose your focus" button that opens the picker.
    @ViewBuilder
    private var personaSection: some View {
        if let p = currentPersona {
            HStack {
                Text("FOR YOU · \(p.title.uppercased())")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.5)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Change") { showPersonaPicker = true }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.brand)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 2)
            ForEach(p.keyScreens, id: \.label) { screen in
                SidebarRow(dest: screen.dest, isSelected: selection == screen.dest, namespace: sidebarNS) {
                    navigate(to: screen.dest)
                }
            }
            // Ask is the universal entry point — always offer it in For You.
            if !p.keyScreens.contains(where: { $0.dest == .ask }) {
                SidebarRow(dest: .ask, isSelected: selection == .ask, namespace: sidebarNS) {
                    navigate(to: .ask)
                }
            }
        } else {
            Button {
                showPersonaPicker = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").imageScale(.small).foregroundStyle(Theme.brand)
                    Text("Choose your focus").font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Theme.brand.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.top, 8)
        }
    }

    /// A collapsible sidebar group. Header click toggles it; collapsed by
    /// default so the sidebar isn't a wall of buttons. The chevron shows state.
    @ViewBuilder
    private func collapsibleGroup(_ group: Destination.Group, visible: [Destination]) -> some View {
        let expanded = expandedGroups.contains(group)
        Button {
            withAnimation(Theme.springFast) {
                if expanded { expandedGroups.remove(group) } else { expandedGroups.insert(group) }
            }
        } label: {
            HStack(spacing: 6) {
                Text(group.rawValue.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.5)
                Spacer(minLength: 0)
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if expanded {
            ForEach(visible) { dest in
                SidebarRow(dest: dest, isSelected: selection == dest, namespace: sidebarNS) {
                    navigate(to: dest)
                }
            }
        }
    }

    /// "Ask first" consent prompt. Appears when the Mac is idle and the
    /// user has chosen Ask mode. Run now / Not now resume the scheduler.
    @ViewBuilder
    private var maintenanceAskPrompt: some View {
        if appState.maintenanceAskPending {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "moon.zzz.fill")
                        .foregroundStyle(Theme.brand)
                        .imageScale(.small)
                    Text("Run maintenance now?")
                        .font(.caption.weight(.semibold))
                }
                Text("Your Mac is idle. Tidy summaries + memories in the background?")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Not now") { appState.respondToMaintenancePrompt(false) }
                        .controlSize(.small)
                        .buttonStyle(.pressable)
                    Button("Run now") { appState.respondToMaintenancePrompt(true) }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.brand)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.brand.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 10)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Owner decision 2026-08-15 — the idle background scan may START after
    /// 90 quiet seconds, but the moment the user RESUMES activity mid-pass
    /// this card asks whether to keep scanning or stop. Stop cancels the pass
    /// at its next rule boundary; the prior derived layers stay intact.
    @ViewBuilder
    private var scanContinuePrompt: some View {
        if appState.scanContinuePromptPending {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.rays")
                        .foregroundStyle(Theme.brand)
                        .imageScale(.small)
                    Text("Background work running")
                        .font(.caption.weight(.semibold))
                }
                Text("You're back — scanning/enrichment is still running. Keep going or stop?")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Stop") { appState.respondToScanContinuePrompt(continueScanning: false) }
                        .controlSize(.small)
                        .buttonStyle(.pressable)
                        .help("Pauses ingest/enrichment (resume any time from the Live panel) and cancels the maintenance scan — nothing is left half-written.")
                    Button("Continue") { appState.respondToScanContinuePrompt(continueScanning: true) }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.brand)
                        .help("Lets the work finish — you won't be asked again until it completes.")
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.brand.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 10)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Gradient app wordmark at the top of the sidebar.
    private var brandHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Theme.brandGradient(), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: Theme.brand.opacity(0.35), radius: 5, y: 2)
            Text("Kalsmritikosh")
                .font(Theme.display(17, .bold))
                .foregroundStyle(Theme.brandGradient())
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }

    /// Always-visible badge showing the active system mode. Tapping opens
    /// the chooser (a change applies on next launch once booted). Also
    /// surfaces the count of files discovered this launch.
    private var modeBadge: some View {
        let mode = FeatureFlags.shared.systemMode
        return Button {
            appState.showModeChooser = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: mode.symbolName)
                    .imageScale(.small)
                    .foregroundStyle(Theme.brand)
                VStack(alignment: .leading, spacing: 0) {
                    Text("MODE")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(.tertiary)
                        .tracking(0.5)
                    Text(mode.shortLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if appState.newFilesSinceLaunch > 0 {
                    Text("\(appState.newFilesSinceLaunch) new")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.brandAlt.opacity(0.16), in: .capsule)
                        .foregroundStyle(Theme.brandAlt)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.brand.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Theme.brand.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    /// First-run walkthrough tip (TipKit) — one ordered tip at a time,
    /// shown inline at the top of the sidebar. No-op once all are dismissed.
    @ViewBuilder
    private var onboardingTip: some View {
        #if canImport(TipKit)
        if #available(macOS 15.0, *), let tip = Onboarding.group.currentTip {
            TipView(tip)
                .tipBackground(.regularMaterial)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
        }
        #endif
    }

    // MARK: Header (grouped icon nav + always-on search)

    /// Two-row app header shown above every screen:
    ///  • Row 1 — every screen as an icon, grouped (Ask · Rebuild · Know ·
    ///    Work · System) with a caption under each group. Active screen is
    ///    highlighted; hovering any icon or group caption shows a one-line
    ///    explanation.
    ///  • Row 2 — an always-visible search box: type and press return to
    ///    search the archive from anywhere, no navigation first.
    private var appHeader: some View {
        VStack(spacing: 8) {
            // The group icons lay out in a WRAPPING flow — NOT a horizontal ScrollView. On macOS a horizontal
            // ScrollView intercepts the mouse-down for panning, so child Buttons never fire (the sidebar uses
            // the same Button pattern but in a vertical scroll and works). A flow keeps every icon directly
            // hittable and always visible (wraps to another line instead of hiding behind a scroll).
            FlowLayout(spacing: 12, lineSpacing: 8) {
                ForEach(Destination.Group.allCases) { group in
                    headerGroup(group)
                }
            }
            .padding(.horizontal, 16)
            headerSearchBar
                .padding(.horizontal, 16)
        }
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    /// One group of the header: its icons in a row, a short caption below.
    private func headerGroup(_ group: Destination.Group) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                ForEach(simpleMode ? group.items.filter { $0 == group.simplePrimary } : group.items) { dest in
                    headerIcon(dest)
                }
            }
            Text(group.shortTitle)
                .font(.system(size: 8, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(.tertiary)
                .help(group.blurb)
        }
    }

    /// A single header icon button. Filled/brand when active; tooltip gives
    /// the screen's name, one-line explanation, and its ⌘N shortcut.
    private func headerIcon(_ dest: Destination) -> some View {
        let isSelected = selection == dest
        return Button {
            navigate(to: dest)
        } label: {
            Image(systemName: dest.icon)
                .font(.system(size: 13, weight: isSelected ? .bold : .regular))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(Theme.brand))
                .frame(width: 30, height: 26)
                .background(
                    isSelected
                        ? AnyShapeStyle(Theme.brandGradient())
                        : AnyShapeStyle(Theme.brand.opacity(0.10)),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                // Make the whole 30×26 frame the hover/hit region so the tooltip
                // fires anywhere over the chip, not just the glyph pixels.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(dest.title) — \(dest.blurb)\(dest.shortcutHint.map { "  (\($0))" } ?? "")")
    }

    /// Always-visible archive search. Enter seeds SearchView and jumps to it.
    private var headerSearchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search your archive — type and press return…", text: $headerSearch)
                .textFieldStyle(.plain)
                .onSubmit(runHeaderSearch)
            if !headerSearch.isEmpty {
                Button { headerSearch = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            Button { showPalette = true } label: {
                Text("⌘K").font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Jump to any screen or command (⌘K)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.05), in: Capsule())
        .overlay(Capsule().stroke(Theme.brand.opacity(0.15), lineWidth: 1))
    }

    private func runHeaderSearch() {
        let q = headerSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        appState.pendingSearchQuery = q
        navigate(to: .search)
    }

    // MARK: Command palette + keyboard shortcuts

    /// Visible ⌘K affordance (best practice: pair a visible trigger with the
    /// hidden shortcut so the feature is discoverable).
    private var paletteButton: some View {
        Button { showPalette = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text("Jump to…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text("⌘K")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .help("Jump to any screen or run a command (⌘K)")
    }

    /// Zero-size, invisible buttons that carry the app's window-scoped
    /// keyboard shortcuts: ⌘K palette, ⌘1…⌘9 hotbar (game-style quick
    /// slots), and ⌘\ quick-swap to the previous screen.
    private var shortcutButtons: some View {
        Group {
            Button("") { showPalette.toggle() }
                .keyboardShortcut("k", modifiers: .command)
            Button("") { navigate(to: previousSelection) }
                .keyboardShortcut("\\", modifiers: .command)
            // "?" opens the shortcut cheat-sheet — the discoverability
            // pattern the mature review platforms train users on.
            Button("") { showShortcutHelp.toggle() }
                .keyboardShortcut("?", modifiers: [])
            ForEach(Array(Destination.quickShortcuts.enumerated()), id: \.offset) { _, item in
                Button("") { navigate(to: item.dest) }
                    .keyboardShortcut(item.key, modifiers: .command)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// The "?" cheat-sheet: every window shortcut on one card.
    @ViewBuilder
    private var shortcutHelpOverlay: some View {
        if showShortcutHelp {
            ZStack {
                Color.black.opacity(0.22)
                    .ignoresSafeArea()
                    .onTapGesture { showShortcutHelp = false }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Keyboard shortcuts", systemImage: "keyboard")
                            .font(.headline)
                        Spacer()
                        Button { showShortcutHelp = false } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    Divider()
                    shortcutRow("⌘K", "Command palette — jump anywhere, run anything")
                    shortcutRow("⌘\\", "Swap back to the previous screen")
                    shortcutRow("⌘[  ⌘]", "Back / forward through your location history")
                    ForEach(Array(Destination.quickShortcuts.enumerated()), id: \.offset) { _, item in
                        shortcutRow("⌘\(item.key.character)", item.dest.title)
                    }
                    shortcutRow("?", "Show this card")
                }
                .padding(18)
                .frame(width: 420)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .shadow(radius: 24)
            }
            .transition(.opacity)
        }
    }

    private func shortcutRow(_ keys: String, _ what: String) -> some View {
        HStack(spacing: 12) {
            Text(keys)
                .font(.callout.monospaced().weight(.semibold))
                .frame(width: 70, alignment: .leading)
            Text(what).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
    }

    @ViewBuilder
    private var paletteOverlay: some View {
        if showPalette {
            ZStack(alignment: .top) {
                Color.black.opacity(0.22)
                    .ignoresSafeArea()
                    .onTapGesture { showPalette = false }
                CommandPaletteView(
                    isPresented: $showPalette,
                    onNavigate: { navigate(to: $0) },
                    onAddFolder: addFolderFromPalette,
                    onIngestAll: { Task { await appState.ingestAllRoots() } }
                )
                .padding(.top, 90)
            }
            .transition(.opacity)
        }
    }

    /// Open a folder picker directly from the palette, register it, and jump
    /// to Sources — the whole "add source" flow in one keyboard-driven pass.
    private func addFolderFromPalette() { showAddFolder = true }

    // MARK: Detail router

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .home {
        case .home:         HomeView(onNavigate: { navigate(to: $0) })
        case .ask:
            // Hard-frame Ask to the REAL viewport. On macOS 26 the split-view
            // detail can propose a pathological size to non-scroll content
            // (measured: 210×1698 for a 850×630 viewport), which pushed the
            // composer/header off-window. GeometryReader reports the actual
            // available area; pinning AskView to it makes the layout immune
            // to whatever the container proposes.
            GeometryReader { g in
                AskView().frame(width: g.size.width, height: g.size.height)
            }
        case .search:       SearchView()
        case .work:         PersonaJobsView()
        case .workCenter:   WorkCenterView(onNavigate: { navigate(to: $0) })
        case .registers:    RegistersView()
        case .dataLab:      DataLabView()
        case .handoff:      WorkProductHandoffView()
        case .workspaces:   WorkspacesView()
        case .timeline:     TimelineView()
        case .history:      HistoryView()
        case .findings:     FactStatusView()
        case .notebook:     NotebookView()
        case .dossier:      DossierView()
        case .explore:      ExplorerView()
        case .matrix:       CrossDocumentMatrixView()
        case .connections:  ConnectionFinderView()
        case .fundFlow:     FundFlowView()
        case .emailThreads: EmailThreadsView()
        case .story:        CaseStoryView()
        case .reasoning:    ReasoningStudioView()
        case .hypotheses:   ACHMatrixView()
        case .hrStudio:     WorkplaceStudioView()
        case .review:       ReviewView()
        case .transcripts:  TranscriptsView()
        case .insights:     InsightsView()
        case .changes:      ChangesView()
        case .knowledge:    KnowledgeView()
        case .assertions:   AssertionsView()
        case .answers:      AnswersView()
        case .audit:        AuditView()
        case .verifyReceipt: ReceiptVerifierView()
        case .library:      LibraryView()
        case .saved:        SavedQueriesView()
        case .authenticity: AuthenticityView()
        case .citations:    CitationBuilderView()
        case .freshness:    FreshnessView()
        case .trends:       TrendsView()
        case .query:        QueryView()
        case .caseload:     CaseloadView()
        case .sources:      SourcesView()
        case .convert:      ConvertView()
        case .completeness: CompletenessView()
        case .live:         LiveDashboardView()
        case .redaction:    RedactionView()
        case .guide:        GuideView(onNavigate: { navigate(to: $0) })
        case .sutra:        SutraView()
        case .settings:     SettingsView()
        }
    }

}

// MARK: - Flow layout

/// A minimal wrapping layout: places subviews left-to-right, wrapping to the next line when the row is full.
/// Used for the header icon groups so they are laid out as ordinary, directly-clickable controls (no
/// horizontal ScrollView, which on macOS swallows child Button clicks) and never hidden behind a scroll.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 12
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth { x = 0; y += lineHeight + lineSpacing; lineHeight = 0 }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        // Return the FULL proposed width (not the widest line): placeSubviews wraps
        // against bounds.width, so reporting a narrower width made placement wrap
        // EARLIER than measurement — extra rows landed below the measured height,
        // under the detail view, visible but not clickable at windowed sizes.
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxX = bounds.minX + bounds.width
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > maxX { x = bounds.minX; y += lineHeight + lineSpacing; lineHeight = 0 }
            sub.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Sidebar row

/// A single navigation item. Selected state slides a brand-tinted pill
/// (via matchedGeometryEffect) and fills the icon chip with the brand
/// gradient; hover lifts a subtle highlight. Icon pops on selection.
private struct SidebarRow: View {
    let dest: Destination
    let isSelected: Bool
    let namespace: Namespace.ID
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: dest.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : Theme.brand)
                    .frame(width: 26, height: 26)
                    .background(iconChip)
                    .symbolEffect(.bounce, value: isSelected)
                Text(dest.title)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                Spacer(minLength: 0)
                if let hint = dest.shortcutHint {
                    Text(hint)
                        .font(.caption2.monospaced())
                        .foregroundStyle(isSelected ? .secondary : .tertiary)
                        .opacity(hovering || isSelected ? 1 : 0.5)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(dest.title) — \(dest.blurb)\(dest.shortcutHint.map { "  (\($0))" } ?? "")")
        .onHover { h in
            withAnimation(.easeOut(duration: 0.12)) { hovering = h }
        }
    }

    @ViewBuilder
    private var iconChip: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.brandGradient())
                .shadow(color: Theme.brand.opacity(0.35), radius: 4, y: 1)
        } else {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.brand.opacity(0.10))
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.brand.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Theme.brand.opacity(0.22), lineWidth: 1)
                )
                .matchedGeometryEffect(id: "sidebarSelection", in: namespace)
        } else if hovering {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        }
    }
}

// MARK: - Command palette (⌘K)

/// One executable entry in the palette — a screen jump or a top action.
private struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let run: () -> Void
}

/// ⌘K command palette. The keyboard-first way to reach any screen or run a
/// top action without touching the sidebar — the pattern popularized by
/// Linear / Raycast / Superhuman. Autofocused, fuzzy subsequence match
/// (type "cvt" → Convert), Enter runs the top hit, ↑/↓ move, Esc closes.
private struct CommandPaletteView: View {
    @Binding var isPresented: Bool
    let onNavigate: (Destination) -> Void
    let onAddFolder: () -> Void
    let onIngestAll: () -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    private var commands: [PaletteCommand] {
        var cmds: [PaletteCommand] = Destination.allCases.map { dest in
            PaletteCommand(
                id: "go.\(dest.rawValue)",
                title: dest.title,
                subtitle: dest.blurb,
                icon: dest.icon
            ) { onNavigate(dest) }
        }
        cmds.append(PaletteCommand(
            id: "act.addFolder", title: "Add Folder…",
            subtitle: "Watch a new folder", icon: "folder.badge.plus",
            run: onAddFolder))
        cmds.append(PaletteCommand(
            id: "act.ingest", title: "Ingest All",
            subtitle: "Re-scan every watched folder now",
            icon: "arrow.triangle.2.circlepath", run: onIngestAll))
        return cmds
    }

    private var filtered: [PaletteCommand] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return commands }
        return commands.filter { paletteFuzzyMatch(q, $0.title) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Jump to a screen or run a command…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit(runHighlighted)
                keycap("esc")
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if filtered.isEmpty {
                            Text("No matches")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                        } else {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, cmd in
                                paletteRow(cmd, index: idx).id(idx)
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 340)
                .onChange(of: highlighted) { _, new in
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(new, anchor: .center) }
                }
            }
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
        .onAppear { fieldFocused = true; highlighted = 0 }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.escape) { isPresented = false; return .handled }
    }

    private func paletteRow(_ cmd: PaletteCommand, index: Int) -> some View {
        Button { run(cmd) } label: {
            HStack(spacing: 10) {
                Image(systemName: cmd.icon)
                    .frame(width: 22)
                    .foregroundStyle(Theme.brand)
                VStack(alignment: .leading, spacing: 1) {
                    Text(cmd.title).font(.callout.weight(.medium))
                    Text(cmd.subtitle).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if index == highlighted { keycap("return") }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                index == highlighted ? Theme.brand.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func keycap(_ text: String) -> some View {
        Text(text)
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func move(_ delta: Int) {
        let n = filtered.count
        guard n > 0 else { return }
        highlighted = (highlighted + delta + n) % n
    }

    private func runHighlighted() {
        guard filtered.indices.contains(highlighted) else { return }
        run(filtered[highlighted])
    }

    private func run(_ cmd: PaletteCommand) {
        isPresented = false
        cmd.run()
    }
}

/// Case-insensitive subsequence match: every character of `needle` appears
/// in order (not necessarily adjacent) within `haystack`. So "cvt" matches
/// "Convert" and "tgl" matches "Toggle".
private func paletteFuzzyMatch(_ needle: String, _ haystack: String) -> Bool {
    var iterator = haystack.lowercased().makeIterator()
    for ch in needle.lowercased() {
        var found = false
        while let h = iterator.next() {
            if h == ch { found = true; break }
        }
        if !found { return false }
    }
    return true
}

// MARK: - Persona picker (first-run "choose your focus")

/// First-run / change-focus sheet. Picking a persona tailors the sidebar's
/// "For you" section to that role's key screens (reuses GuideContent.personas —
/// one shared engine, per-persona lens; not five separate apps).
private struct PersonaPickerView: View {
    let current: String
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What do you want to do?")
                    .font(Theme.display(22, .bold))
                    .foregroundStyle(Theme.brandGradient())
                Text("Pick the focus that fits your work. It tailors the sidebar to the screens you'll use most — you can change it any time, and everything else stays one click away.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(GuideContent.personas) { p in
                        Button {
                            onPick(p.id)
                        } label: {
                            HStack(spacing: 12) {
                                Text(p.emoji).font(.system(size: 26))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.title).font(.headline)
                                    Text(p.tagline).font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer(minLength: 0)
                                if p.id == current {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.brand)
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(p.id == current ? Theme.brand.opacity(0.4) : Color.primary.opacity(0.08), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Skip for now") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 520, height: 560)
    }
}
