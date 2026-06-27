//
//  RootView.swift
//  Kalsmritikosh
//
//  The five Phase-16 surfaces live behind a top-level TabView:
//  Ask, Search, Timeline, Knowledge, Sources. macOS first.
//

import SwiftUI

public struct RootView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("atlas.onboarding.shown") private var onboardingShown: Bool = false
    @State private var presentingOnboarding = false

    public init() {}

    public var body: some View {
        switch appState.phase {
        case .starting:
            ProgressView("Starting Atlas…")
                .frame(minWidth: 800, minHeight: 500)
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text("Atlas couldn't start.")
                    .font(.title2)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(40)
            .frame(minWidth: 800, minHeight: 500)
        case .ready:
            VStack(spacing: 0) {
                ingestBanner
                tabs
            }
        }
    }

    /// Persistent thin strip across the top whenever there's any ingest
    /// activity (bulk "Ingest All", folder-watcher pickup, query-boost).
    /// Invisible when idle.
    @ViewBuilder
    private var ingestBanner: some View {
        if appState.ingestActiveCount > 0 || appState.ingestLastFile != nil {
            HStack(spacing: 8) {
                if appState.ingestActiveCount > 0 {
                    ProgressView().controlSize(.small)
                    Text("Ingesting \(appState.ingestActiveCount) file\(appState.ingestActiveCount == 1 ? "" : "s")…")
                        .font(.caption.weight(.medium))
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Ingestion idle")
                        .font(.caption.weight(.medium))
                }
                if let last = appState.ingestLastFile {
                    Text("· last: \(last)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(appState.ingestActiveCount > 0
                ? Color.yellow.opacity(0.18)
                : Color.green.opacity(0.10))
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: appState.ingestActiveCount)
        }
    }

    private var tabs: some View {
        TabView {
            AskView()
                .tabItem { Label("Ask", systemImage: "bubble.left.and.text.bubble.right") }
            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            TimelineView()
                .tabItem { Label("Timeline", systemImage: "calendar.day.timeline.left") }
            HistoryView()
                .tabItem { Label("History", systemImage: "book.closed") }
            LibraryView()
                .tabItem { Label("Library", systemImage: "books.vertical.fill") }
            KnowledgeView()
                .tabItem { Label("Knowledge", systemImage: "books.vertical") }
            SourcesView()
                .tabItem { Label("Sources", systemImage: "folder") }
            CompletenessView()
                .tabItem { Label("Completeness", systemImage: "checklist") }
            ConvertView()
                .tabItem { Label("Convert", systemImage: "arrow.right.doc.on.clipboard") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .frame(minWidth: 900, minHeight: 600)
        .sheet(isPresented: $presentingOnboarding) {
            OnboardingView()
                .environment(appState)
        }
        .task {
            // Surface onboarding once, the first time the app opens with
            // no bookmarks registered yet.
            if !onboardingShown && appState.bookmarks.roots.isEmpty {
                presentingOnboarding = true
                onboardingShown = true
            }
        }
    }
}
