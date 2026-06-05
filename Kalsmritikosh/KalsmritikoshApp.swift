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

@main
struct KalsmritikoshApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .task {
                    await appState.boot()
                }
        }
        .defaultSize(width: 1100, height: 720)
    }
}
