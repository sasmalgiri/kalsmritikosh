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

// MARK: - Navigation model

/// Every surface the app exposes, grouped into sidebar sections. One
/// source of truth for title + SF Symbol + section so the sidebar and
/// the detail switch never drift apart.
public enum Destination: String, CaseIterable, Identifiable, Hashable {
    case ask, search
    case timeline, history, notebook, dossier, explore
    case insights
    case knowledge, assertions, library, saved
    case sources, convert, completeness, live
    case settings

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .ask:          return "Ask"
        case .search:       return "Search"
        case .timeline:     return "Timeline"
        case .history:      return "History"
        case .notebook:     return "Notebook"
        case .dossier:      return "Dossier"
        case .explore:      return "Explore"
        case .insights:     return "Insights"
        case .knowledge:    return "Knowledge"
        case .assertions:   return "Assertions"
        case .library:      return "Library"
        case .saved:        return "Saved"
        case .sources:      return "Sources"
        case .convert:      return "Convert"
        case .completeness: return "Completeness"
        case .live:         return "Live"
        case .settings:     return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .ask:          return "bubble.left.and.text.bubble.right"
        case .search:       return "magnifyingglass"
        case .timeline:     return "calendar.day.timeline.left"
        case .history:      return "book.closed"
        case .notebook:     return "notebook"
        case .dossier:      return "person.text.rectangle"
        case .explore:      return "point.3.connected.trianglepath.dotted"
        case .insights:     return "lightbulb.max"
        case .knowledge:    return "books.vertical"
        case .assertions:   return "scroll"
        case .library:      return "books.vertical.fill"
        case .saved:        return "bookmark"
        case .sources:      return "folder"
        case .convert:      return "arrow.right.doc.on.clipboard"
        case .completeness: return "checklist"
        case .live:         return "waveform.path.ecg"
        case .settings:     return "gearshape"
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
            case .converse:    return [.ask, .search]
            case .reconstruct: return [.timeline, .history, .notebook, .dossier, .explore, .insights]
            case .knowledge:   return [.knowledge, .assertions, .library, .saved]
            case .workspace:   return [.sources, .convert, .completeness, .live]
            case .system:      return [.settings]
            }
        }
    }
}

// MARK: - Root

public struct RootView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("atlas.onboarding.shown") private var onboardingShown: Bool = false
    @State private var presentingOnboarding = false
    @State private var selection: Destination? = .ask
    @State private var showMaintenance: Bool = true
    @Namespace private var sidebarNS

    public init() {}

    public var body: some View {
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
                detail
                    .navigationTitle(selection?.title ?? "Kalsmritikosh")
            }
        }
        .tint(Theme.brand)
        .preferredColorScheme(.light)
        .frame(minWidth: 980, minHeight: 660)
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
                    .padding(.bottom, 6)
                ForEach(Destination.Group.allCases) { group in
                    Text(group.rawValue.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .tracking(0.5)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 2)
                    ForEach(group.items) { dest in
                        SidebarRow(
                            dest: dest,
                            isSelected: selection == dest,
                            namespace: sidebarNS
                        ) {
                            withAnimation(Theme.springFast) { selection = dest }
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

    // MARK: Detail router

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .ask {
        case .ask:          AskView()
        case .search:       SearchView()
        case .timeline:     TimelineView()
        case .history:      HistoryView()
        case .notebook:     NotebookView()
        case .dossier:      DossierView()
        case .explore:      ExplorerView()
        case .insights:     InsightsView()
        case .knowledge:    KnowledgeView()
        case .assertions:   AssertionsView()
        case .library:      LibraryView()
        case .saved:        SavedQueriesView()
        case .sources:      SourcesView()
        case .convert:      ConvertView()
        case .completeness: CompletenessView()
        case .live:         LiveDashboardView()
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
