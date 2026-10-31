//
//  AppDefaults.swift
//  Kalsmritikosh
//
//  App Store completion instructions 2026-10-30 §5 — test isolation of preferences.
//
//  The unit-test host is the app itself (same bundle identifier), so `UserDefaults.standard` inside a
//  test IS the person's real preference file: a test that switched the AI mode, the sample-archive
//  flag or the app lock and then crashed left the owner's settings changed. Product code that reads
//  or writes a preference goes through `AppDefaults.store`: the standard defaults in the app, and in
//  a test host a per-process suite that is emptied when the process starts and removed when it ends.
//  Views' `@AppStorage` properties still bind to the standard defaults, which is the same store in
//  the app; unit tests do not instantiate them.
//
//  The same rule already governs the ledger key (`LedgerEncryption.usesMemoryStore`), the erase
//  preferences (`AppState.erasePreferences`), the pending restore record and the conformance seal
//  key: nothing a test does reaches the owner's Keychain item, preferences or saved folders.
//

import Foundation

public nonisolated enum AppDefaults {
    /// True when running inside the unit-test host.
    public static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// The suite a test host uses instead of the standard defaults (nil in the app).
    public static let testSuiteName: String? = isTestHost ? "kalsmritikosh.tests.prefs.\(ProcessInfo.processInfo.processIdentifier)" : nil

    /// The preference store for product code.
    public static let store: UserDefaults = {
        guard let name = testSuiteName, let suite = UserDefaults(suiteName: name) else { return .standard }
        // A process number is reused: an earlier host that died mid-test may have left this suite behind.
        suite.removePersistentDomain(forName: name)
        atexit { AppDefaults.removeTestSuite() }
        return suite
    }()

    /// Remove the test host's suite file (called at process exit; safe to call again).
    public static func removeTestSuite() {
        guard let name = testSuiteName else { return }
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
    }
}
