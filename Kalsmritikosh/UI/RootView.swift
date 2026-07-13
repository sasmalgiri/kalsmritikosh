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

// MARK: - Navigation model

/// Every surface the app exposes, grouped into sidebar sections. One
/// source of truth for title + SF Symbol + section so the sidebar and
/// the detail switch never drift apart.
public enum Destination: String, CaseIterable, Identifiable, Hashable {
    case home
    case ask, search
    case workspaces
    case timeline, history, findings, notebook, dossier, explore
    case review
    case transcripts
    case insights
    case knowledge, assertions, answers, library, saved
    case sources, convert, completeness, live
    case guide, settings

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .home:         return "Home"
        case .ask:          return "Ask"
        case .search:       return "Search"
        case .workspaces:   return "Workspaces"
        case .timeline:     return "Timeline"
        case .history:      return "History"
        case .findings:     return "Findings"
        case .notebook:     return "Notebook"
        case .dossier:      return "Dossier"
        case .explore:      return "Explore"
        case .review:       return "Review"
        case .transcripts:  return "Transcripts"
        case .insights:     return "Insights"
        case .knowledge:    return "Knowledge"
        case .assertions:   return "Assertions"
        case .answers:      return "Answers"
        case .library:      return "Library"
        case .saved:        return "Saved"
        case .sources:      return "Sources"
        case .convert:      return "Convert"
        case .completeness: return "Completeness"
        case .live:         return "Live"
        case .guide:        return "Guide"
        case .settings:     return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home:         return "house"
        case .ask:          return "bubble.left.and.text.bubble.right"
        case .search:       return "magnifyingglass"
        case .workspaces:   return "folder.badge.gearshape"
        case .timeline:     return "calendar.day.timeline.left"
        case .history:      return "book.closed"
        case .findings:     return "checkmark.seal"
        case .notebook:     return "note.text"
        case .dossier:      return "person.text.rectangle"
        case .explore:      return "point.3.connected.trianglepath.dotted"
        case .review:       return "checkmark.bubble"
        case .transcripts:  return "waveform"
        case .insights:     return "lightbulb.max"
        case .knowledge:    return "books.vertical"
        case .assertions:   return "scroll"
        case .answers:      return "text.bubble"
        case .library:      return "books.vertical.fill"
        case .saved:        return "bookmark"
        case .sources:      return "folder"
        case .convert:      return "arrow.right.doc.on.clipboard"
        case .completeness: return "checklist"
        case .live:         return "waveform.path.ecg"
        case .guide:        return "book"
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
        case .workspaces:   return "Organize a matter, case, or project — a filtered view over your evidence"
        case .timeline:     return "Chronological view of all dated events"
        case .history:      return "Narrative reconstruction of what happened"
        case .findings:     return "Every fact by status — proven, inferred, contradicted, missing"
        case .notebook:     return "Your saved notes and working pages"
        case .dossier:      return "Everything known about a person or entity"
        case .explore:      return "Entity graph — see who and what connects"
        case .review:       return "Resolve contradictions and follow up on missing evidence"
        case .transcripts:  return "Timecoded transcripts — search, play, quote audio & video"
        case .insights:     return "Auto-surfaced gaps, contradictions and patterns"
        case .knowledge:    return "Canonical entities, events and distilled memory"
        case .assertions:   return "Extracted claims with their supporting evidence"
        case .answers:      return "Past answers with their evidence — replayable and auditable"
        case .library:      return "Every document you've ingested"
        case .saved:        return "Your bookmarked questions"
        case .sources:      return "Folders being watched and ingested"
        case .convert:      return "Turn files between formats, back and forth"
        case .completeness: return "How fully your archive has been processed"
        case .live:         return "Live pipeline and background activity"
        case .guide:        return "What every screen does, and how facts are graded"
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
            case .converse:    return [.home, .ask, .search]
            case .reconstruct: return [.workspaces, .timeline, .history, .findings, .review, .transcripts, .notebook, .dossier, .explore, .insights]
            case .knowledge:   return [.knowledge, .assertions, .answers, .library, .saved]
            case .workspace:   return [.sources, .convert, .completeness, .live]
            case .system:      return [.guide, .settings]
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
    @State private var selection: Destination? = .home
    /// Game-style quick-swap: the previously-viewed screen, so ⌘\ toggles
    /// straight back to it (like weapon quick-swap in shooters).
    @State private var previousSelection: Destination = .ask
    @State private var showMaintenance: Bool = true
    /// Interface mode. Simple hides the power-user surfaces (Notebook, Explore)
    /// from the sidebar; Advanced shows every screen. Persisted; default Simple.
    @AppStorage("kalsmritikosh.settings.simpleMode") private var simpleMode: Bool = true
    /// Screens hidden in Simple mode (still reachable via ⌘K).
    private let simpleHidden: Set<Destination> = [.notebook, .explore]
    /// ⌘K command palette visibility.
    @State private var showPalette: Bool = false
    /// Text in the always-visible header search box.
    @State private var headerSearch: String = ""
    @Namespace private var sidebarNS

    /// Single navigation entry point. Records the outgoing screen for the
    /// ⌘\ quick-swap, then animates to the new one.
    private func navigate(to dest: Destination) {
        if let current = selection, current != dest { previousSelection = current }
        withAnimation(Theme.springFast) { selection = dest }
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
        NavigationSplitView {
            sidebar
        } detail: {
            NavigationStack {
                VStack(spacing: 0) {
                    appHeader
                    Divider()
                    detail
                }
                .navigationTitle(selection?.title ?? "Kalsmritikosh")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showPalette = true } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .help("Jump to any screen or command  (⌘K)")
                    }
                }
            }
        }
        .tint(Theme.brand)
        .preferredColorScheme(.light)
        .frame(minWidth: 980, minHeight: 660)
        .background(shortcutButtons)
        .overlay(paletteOverlay)
        .sheet(isPresented: $presentingOnboarding) {
            OnboardingView()
                .environment(appState)
        }
        .task {
            if !onboardingShown && appState.bookmarks.roots.isEmpty {
                presentingOnboarding = true
                onboardingShown = true
            }
        }
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
                // Simple / Advanced interface toggle. Simple hides power-user
                // screens (Notebook, Explore); everything stays reachable via ⌘K.
                Picker("Interface", selection: $simpleMode) {
                    Text("Simple").tag(true)
                    Text("Advanced").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                onboardingTip
                ForEach(Destination.Group.allCases) { group in
                    let visible = group.items.filter { !(simpleMode && simpleHidden.contains($0)) }
                    if !visible.isEmpty {
                        Text(group.rawValue.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .tracking(0.5)
                            .padding(.horizontal, 12)
                            .padding(.top, 12)
                            .padding(.bottom, 2)
                        ForEach(visible) { dest in
                            SidebarRow(
                                dest: dest,
                                isSelected: selection == dest,
                                namespace: sidebarNS
                            ) {
                                navigate(to: dest)
                            }
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
                maintenancePill
                ingestPill
            }
            .animation(Theme.springSoft, value: appState.maintenanceAskPending)
            .animation(Theme.springSoft, value: appState.maintenanceActive)
            .animation(Theme.springSoft, value: showMaintenance)
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

    /// Idle-maintenance status pill. Appears when a pass starts (machine
    /// idle) and briefly after it completes / pauses so the user always
    /// knows the app worked while they were away — and stopped when they
    /// returned. Auto-hides a few seconds after the last transition.
    @ViewBuilder
    private var maintenancePill: some View {
        if let status = appState.maintenanceStatus, showMaintenance {
            let active = appState.maintenanceActive
            HStack(spacing: 8) {
                Image(systemName: active ? "moon.zzz.fill" : "checkmark.circle.fill")
                    .foregroundStyle(active ? Theme.brand : .green)
                    .imageScale(.small)
                    .symbolEffect(.pulse, isActive: active)
                Text(status)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke((active ? Theme.brand : Color.green).opacity(0.3), lineWidth: 1)
            )
            .padding(.horizontal, 10)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: appState.maintenanceLastEventAt) {
                // Keep completed/paused pills visible briefly, then hide.
                showMaintenance = true
                if !appState.maintenanceActive {
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    withAnimation(Theme.springSoft) { showMaintenance = false }
                }
            }
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
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Destination.Group.allCases) { group in
                        headerGroup(group)
                        if group != .system {
                            Divider().frame(height: 30)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            // A horizontal ScrollView is greedy vertically by default; without
            // this it competes with the (greedy) detail view below and can
            // collapse to zero height on some screens (e.g. History). Pin it
            // to its natural content height.
            .fixedSize(horizontal: false, vertical: true)
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
                ForEach(group.items.filter { !(simpleMode && simpleHidden.contains($0)) }) { dest in
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
            ForEach(Array(Destination.quickShortcuts.enumerated()), id: \.offset) { _, item in
                Button("") { navigate(to: item.dest) }
                    .keyboardShortcut(item.key, modifiers: .command)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
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
    private func addFolderFromPalette() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? appState.bookmarks.register(url: url)
        navigate(to: .sources)
        #endif
    }

    // MARK: Detail router

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .home {
        case .home:         HomeView(onNavigate: { navigate(to: $0) })
        case .ask:          AskView()
        case .search:       SearchView()
        case .workspaces:   WorkspacesView()
        case .timeline:     TimelineView()
        case .history:      HistoryView()
        case .findings:     FactStatusView()
        case .notebook:     NotebookView()
        case .dossier:      DossierView()
        case .explore:      ExplorerView()
        case .review:       ReviewView()
        case .transcripts:  TranscriptsView()
        case .insights:     InsightsView()
        case .knowledge:    KnowledgeView()
        case .assertions:   AssertionsView()
        case .answers:      AnswersView()
        case .library:      LibraryView()
        case .saved:        SavedQueriesView()
        case .sources:      SourcesView()
        case .convert:      ConvertView()
        case .completeness: CompletenessView()
        case .live:         LiveDashboardView()
        case .guide:        GuideView(onNavigate: { navigate(to: $0) })
        case .settings:     SettingsView()
        }
    }

    // MARK: Ingest status pill

    /// Compact status chip pinned to the bottom of the sidebar. Shows a
    /// live spinner during ingest, a green check when idle. Uses a
    /// standard material capsule (content-layer element — not Liquid
    /// Glass, per HIG guidance).
    @ViewBuilder
    private var ingestPill: some View {
        let active = appState.ingestActiveCount > 0
        if active || appState.ingestLastFile != nil {
            HStack(spacing: 8) {
                if active {
                    ProgressView().controlSize(.mini)
                    Text("Ingesting \(appState.ingestActiveCount)…")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .imageScale(.small)
                    Text("Ingestion idle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(
                Capsule().stroke(active ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.18), lineWidth: 1)
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .animation(.easeInOut(duration: 0.25), value: active)
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
