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
            Text("Investigations Made Easy").font(.headline)
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

#if canImport(AppKit)
/// N-6 — the menu-bar item, managed with AppKit (NSStatusItem + NSPopover) rather than a
/// SwiftUI `MenuBarExtra` scene: an extra scene in the App body stopped the unit-test host
/// from ever connecting to the test runner, even with the panel switched off. The item
/// exists only while its module is on.
@MainActor
final class MenuBarAskController {
    static let shared = MenuBarAskController()
    private var item: NSStatusItem?
    private let popover = NSPopover()

    /// Show or remove the item to match the module switch.
    func update(appState: AppState) {
        let on = ProductModuleFlags.isEnabled(.menuBarAsk)
        if on, item == nil {
            let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            status.button?.image = NSImage(systemSymbolName: "text.magnifyingglass", accessibilityDescription: "Ask Investigations Made Easy")
            status.button?.target = self
            status.button?.action = #selector(toggle(_:))
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(rootView: MenuBarAskView(appState: appState).padding(12))
            item = status
        } else if !on, let status = item {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(status)
            item = nil
        }
    }

    @objc private func toggle(_ sender: NSStatusBarButton) {
        if popover.isShown { popover.performClose(sender) }
        else { popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY); NSApp.activate() }
    }
}
#endif
