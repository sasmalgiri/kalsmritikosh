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
    /// §1.1 — in sample-archive mode the folder store is in-memory only, so
    /// the user's saved folders are neither loaded nor overwritten.
    @State private var appState = SampleArchiveMode.isActive
        ? AppState(bookmarks: BookmarkStore(ephemeral: true))
        : AppState()

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
                    if SampleArchiveMode.isActive, let sampleDB = SampleArchiveMode.databaseURL {
                        // §1.1 — the sample ledger: its own database file, the
                        // bundled fixtures as its only folder (the empty-root
                        // auto-ingest picks them up on first entry).
                        if let demo = DemoArchive.url() {
                            try? appState.bookmarks.register(url: demo)
                        }
                        await appState.boot(databaseURL: sampleDB)
                    } else {
                        await appState.boot()
                    }
                }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            // D-10 — menu-bar mirrors of palette entries. Each item posts its
            // catalog entry id; RootView resolves it through the SAME target
            // router as ⌘K, so the menu can never drift from the palette.
            // Bonus: macOS Help-menu search now finds these by name.
            CommandGroup(after: .newItem) {
                Button("Add Folder…") { postPaletteEntry("act.addFolder") }
                Button("Ingest All") { postPaletteEntry("act.ingestAll") }
            }
            CommandGroup(after: .appSettings) {
                // Navigation only: opens Settings anchored at "Your data".
                // The type-to-confirm sheet there remains the sole erase trigger.
                Button("Delete All My Data…") { postPaletteEntry("act.deleteAllData") }
            }
        }
    }

    private func postPaletteEntry(_ id: String) {
        NotificationCenter.default.post(name: .kalsmritikoshPaletteEntry, object: id)
    }
}
