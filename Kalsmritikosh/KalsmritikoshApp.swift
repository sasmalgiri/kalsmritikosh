//
//  KalsmritikoshApp.swift
//  Kalsmritikosh
//
//  App entry. Owns the single AppState instance and hosts RootView.
//  AppState boots SQLite + sqlite-vec + migrations in the background;
//  RootView reads `phase` and shows the right surface as soon as the
//  database is ready.
//

import SwiftUI
#if canImport(TipKit)
import TipKit
#endif

@main
struct KalsmritikoshApp: App {
    @State private var appState = AppState()

    init() {
        #if canImport(TipKit)
        if #available(macOS 15.0, *) {
            try? Tips.configure([
                .displayFrequency(.immediate),
                .datastoreLocation(.applicationDefault)
            ])
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .preferredColorScheme(.light)   // light UI across all phases
                .task {
                    #if DEBUG
                    // PA-PROD B5 — DEBUG-only manual GUI checkpoint. When launched with
                    // `--pa-prod-gui-smoke`, boot against a disposable database and seed the
                    // VALID/BLOCKED workspaces instead of the normal path. Absent from release.
                    if PAProdGUISmokeFixture.isRequested {
                        await PAProdGUISmokeFixture.bootAndSeed(appState)
                        return
                    }
                    #endif
                    // First run: wait for the user to pick a system mode so
                    // the engine boots in the chosen mode. Returns at once on
                    // later launches.
                    await appState.awaitModeSelectionIfNeeded()
                    await appState.boot()
                }
        }
        .defaultSize(width: 1100, height: 720)
    }
}
