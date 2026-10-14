//
//  MenuBarAskView.swift
//  Kalsmritikosh
//
//  N-6 — ask from anywhere: a menu-bar panel that sends a question or a search
//  to the main window, which answers with its sources. A system-wide keyboard
//  shortcut would need Accessibility permission, which this sandboxed app does
//  not request; the menu-bar item is reachable from any app instead.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct MenuBarAskView: View {
    let appState: AppState
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Kalsmritikosh").font(.headline)
            TextField("Ask or search your archive", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit { ask() }
            HStack {
                Button("Ask") { ask() }.keyboardShortcut(.defaultAction).disabled(text.isEmpty)
                Button("Search") { search() }.disabled(text.isEmpty)
                Spacer()
                Button("Open app") { activate() }
            }
            Text("Answers open in the main window with their sources.").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private func ask() {
        appState.pendingAskQuestion = text
        SurfaceOpener.open(.ask)
        text = ""
        activate()
    }

    private func search() {
        appState.pendingSearchQuery = text
        SurfaceOpener.open(.search)
        text = ""
        activate()
    }

    private func activate() {
        #if canImport(AppKit)
        NSApp.activate(ignoringOtherApps: true)
        #endif
    }
}
