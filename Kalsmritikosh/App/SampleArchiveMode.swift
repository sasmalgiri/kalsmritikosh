//
//  SampleArchiveMode.swift
//  Kalsmritikosh
//
//  §1.1 (owner decision 2026-09-27) — the sample archive lives in a SEPARATE
//  ledger. "Try the sample archive" relaunches the app into a mode whose
//  database is its own file and whose folder bookmarks are in-memory only, so
//  the bundled example documents can never mix with the user's archive, and
//  the user's database and saved folders are never even opened. "Back to my
//  archive" clears the mode and relaunches into the real ledger.
//
//  A relaunch (not an in-process database swap) is deliberate: boot starts
//  many long-running background tasks bound to one database; restarting the
//  process is the only switch that provably leaves none of them attached to
//  the wrong ledger.
//

import Foundation
import OSLog
#if canImport(AppKit)
import AppKit
#endif

public nonisolated enum SampleArchiveMode {
    static let defaultsKey = "kalsmritikosh.sampleArchiveMode"

    /// True while the app runs against the sample ledger.
    public static var isActive: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    /// The sample ledger's own database file — never the user's.
    public static var databaseURL: URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("DemoArchive", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sample-knowledge.sqlite")
    }

    /// Enter the sample archive (relaunches the app).
    @MainActor public static func enter() {
        UserDefaults.standard.set(true, forKey: defaultsKey)
        relaunch()
    }

    /// Return to the user's own archive (relaunches the app).
    @MainActor public static func exit() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        relaunch()
    }

    @MainActor private static func relaunch() {
        #if canImport(AppKit)
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, error in
            if let error {
                KalsmritikoshLog.app.error("Sample archive relaunch failed: \(String(describing: error), privacy: .public)")
                return
            }
            Task { @MainActor in NSApp.terminate(nil) }
        }
        #endif
    }
}
