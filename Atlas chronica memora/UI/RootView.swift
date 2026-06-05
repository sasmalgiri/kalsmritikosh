//
//  RootView.swift
//  Atlas chronica memora
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
            tabs
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
            KnowledgeView()
                .tabItem { Label("Knowledge", systemImage: "books.vertical") }
            SourcesView()
                .tabItem { Label("Sources", systemImage: "folder") }
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
