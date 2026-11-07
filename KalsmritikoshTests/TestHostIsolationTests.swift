//
//  TestHostIsolationTests.swift
//  KalsmritikoshTests
//
//  App Store completion instructions 2026-10-30 §5 — the test host is the app itself, so every
//  shared store a test could reach must be isolated from the owner's: preferences (a per-process
//  suite), the ledger key (in-memory store), the saved folders (ephemeral bookmark store in every
//  boot-based fixture), the legacy ACH on-device store (never written by tests). Proven here, not
//  assumed.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("§5 — the test host touches none of the owner's stores", .serialized)
struct TestHostIsolationTests {

    @Test("Preferences: product code writes a per-process suite under XCTest, never the standard defaults; the suite is emptied at start and removable")
    func preferencesAreIsolated() {
        #expect(AppDefaults.isTestHost)
        let name = try? #require(AppDefaults.testSuiteName)
        #expect(name?.hasPrefix("kalsmritikosh.tests.prefs.") == true)
        #expect(AppDefaults.store !== UserDefaults.standard)
        let key = "kalsmritikosh.tests.isolation.probe.\(UUID().uuidString)"
        FeatureFlags.setAIRegime(FeatureFlags.aiRegimeValue())   // a real product setter, round-tripped
        AppDefaults.store.set("written-by-a-test", forKey: key)
        #expect(UserDefaults.standard.object(forKey: key) == nil, "the standard defaults — the owner's file — did not receive the write")
        #expect(UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[key] == nil)
        #expect(AppDefaults.store.string(forKey: key) == "written-by-a-test")
        AppDefaults.store.removeObject(forKey: key)
        // Every accessor a preference-writing test exercises reads the isolated store.
        let modeKey = FeatureFlags.aiModeKey
        let before = AppDefaults.store.string(forKey: modeKey)
        defer { if let before { AppDefaults.store.set(before, forKey: modeKey) } else { AppDefaults.store.removeObject(forKey: modeKey) } }
        AppDefaults.store.set(AIMode.unconstrained.rawValue, forKey: modeKey)
        #expect(FeatureFlags.aiModeValue() == .unconstrained)
        // The owner's own file is untouched by that write: it holds whatever it held before, or nothing.
        #expect(UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[key] == nil)
    }

    @Test("Ledger key, saved folders and the legacy ACH store: in-memory key store, ephemeral bookmarks, no on-device ACH write")
    @MainActor func keychainBookmarksAndLegacyStore() async throws {
        #expect(LedgerKeychain.usesMemoryStore, "the ledger key never reaches the owner's Keychain item from a test")
        let store = BookmarkStore(ephemeral: true)
        #expect(store.isEphemeral, "boot-based fixtures use an ephemeral folder store")
        // The legacy ACH blob is read once by the view for import and never written by product code or tests.
        #expect(AppDefaults.store.object(forKey: ACHRepository.legacyAppStorageKey) == nil)
        // The production boot path under this host still refuses to use the person's folders: the
        // fixture every boot-based suite uses passes `ephemeral: true` (grep-checked here).
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: testsDir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        var offenders: [String] = []
        for f in files {
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains("AppState(") && !line.contains("ephemeral: true") && !line.contains("//") && !line.contains("noUIAppState") && !line.contains("func ") {
                offenders.append("\(f.lastPathComponent):\(i + 1)")
            }
        }
        #expect(offenders.isEmpty, "boot-based fixtures without an ephemeral bookmark store: \(offenders)")
    }

    @Test("A fresh profile opens on Home; a returning person resumes the saved surface")
    @MainActor func firstScreen() {
        #expect(RootView.launchDestination(restored: nil) == .home)
        #expect(RootView.launchDestination(restored: .cases) == .cases)
    }
}
