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
import CoreSpotlight
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

    /// K7 — on Quit, pending studio writes finish (or the person is asked) before the app exits.
    @NSApplicationDelegateAdaptor(AppTerminationGuard.self) private var terminationGuard

    /// N-6 — the menu-bar panel's switch (the module's own persisted key).
    @AppStorage("kalsmritikosh.product.menuBarAsk") private var menuBarAskOn = false

    init() {
        #if canImport(TipKit)
        if #available(macOS 15.0, *) {
            try? Tips.configure([
                .displayFrequency(.immediate),
                .datastoreLocation(.applicationDefault)
            ])
        }
        #endif
        DiagnosticsReporter.shared.start()   // U-4 — MetricKit crash/hang reports, saved on this Mac only
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                // O-3/O-7 — Online badge with one-click return to Private, and failure banner.
                .safeAreaInset(edge: .top, spacing: 0) { OnlineStatusBar().environment(appState) }
                // O-5 — nothing goes online without this sheet.
                .sheet(item: Binding(get: { OutboundConsent.shared.pending },
                                     set: { if $0 == nil, OutboundConsent.shared.pending != nil { OutboundConsent.shared.resolve(allow: false) } })) { preview in
                    OutboundConsentSheet(preview: preview)
                }
                .preferredColorScheme(.light)   // light UI across all phases
                .purchaseGate()                 // free 14-day trial, then one purchase (Purchase.swift)
                .appLockOverlay()               // W2-7 — Touch ID / password lock
                // W1-5 — kalsmritikosh:// links (scheme registered in the target's URL Types).
                .onOpenURL { url in Task { await appState.handleDeepLink(url) } }
                // P-3 — File ▸ Import from iPhone or iPad (Continuity Camera), with "Share and capture" on.
                .importsItemProviders(ProductModuleFlags.isEnabled(.captureExtensions) ? DeviceImport.acceptedTypes : []) { providers in
                    Task { await appState.importFromDevice(providers) }
                    return true
                }
                // W3-7 — a Spotlight result was opened.
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                        Task { await appState.openSpotlightItem(id) }
                    }
                }
                .sheet(item: Binding(get: { appState.deepLinkTarget },
                                     set: { appState.deepLinkTarget = $0 })) { target in
                    CitationSourceSheet(target: target) { appState.deepLinkTarget = nil }
                        .environment(appState)
                }
                .alert("Link", isPresented: Binding(get: { appState.deepLinkMessage != nil },
                                                   set: { if !$0 { appState.deepLinkMessage = nil } })) {
                    Button("OK") { appState.deepLinkMessage = nil }
                } message: {
                    Text(appState.deepLinkMessage ?? "")
                }
                // N-6 — the menu-bar item follows its module switch (AppKit status item, not a scene).
                .onChange(of: menuBarAskOn, initial: true) { _, _ in MenuBarAskController.shared.update(appState: appState) }
                .task {
                    // W2-7 — when this process is only the unit-test host, never open the person's
                    // ledger: tests boot their own AppState on temporary ledgers. Booting the real
                    // one here would convert it with the TEST Keychain key and lock the person out.
                    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
                    IntentBridge.appState = appState   // W1-6 — Shortcuts actions act on the live ledger
                    CaptureServiceProvider.shared.install(appState: appState)   // W3-6 — Services menu
                    #if DEBUG
                    // PA-PROD B5 — DEBUG-only manual GUI checkpoint. When launched with
                    // `--pa-prod-gui-smoke`, boot against a disposable database and seed the
                    // VALID/BLOCKED workspaces instead of the normal path. Absent from release.
                    if PAProdGUISmokeFixture.isRequested {
                        await PAProdGUISmokeFixture.bootAndSeed(appState)
                        return
                    }
                    // Investigator workflow review 2026-10-30 — DEBUG-only: `--acceptance-case` boots a
                    // disposable ledger holding the supplier-payment acceptance case for a UI walk-through.
                    if AcceptanceCaseGUIFixture.isRequested {
                        await AcceptanceCaseGUIFixture.boot(appState)
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
            ImportFromDevicesCommands()   // P-3 — Take Photo / Scan Documents from a nearby iPhone or iPad
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

/// K7 — pending studio saves are written before the app quits. Edits are saved as they happen, but a
/// write still in flight at Quit used to be abandoned; one that failed is now named, not lost silently.
final class AppTerminationGuard: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The test host quits at the runner's request; it must never wait on a dialog.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return .terminateNow }
        Task { @MainActor in
            let saved = await Self.flushWithin(seconds: 5)
            if saved {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }
            let alert = NSAlert()
            alert.messageText = "A studio change has not been saved"
            alert.informativeText = "One or more studio changes could not be written to the ledger. If you quit now, they are lost. Cancel to go back and choose Retry."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit Anyway")
            sender.reply(toApplicationShouldTerminate: alert.runModal() == .alertSecondButtonReturn)
        }
        return .terminateLater
    }

    /// True when every open studio's writes landed within the time allowed.
    @MainActor static func flushWithin(seconds: Double) async -> Bool {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask { @MainActor in await StudioStorage.flushAll() }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? false
        }
    }
}

