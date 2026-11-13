//
//  TestHost.swift
//  Kalsmritikosh
//
//  The one switch for "this process is the unit-test host" (autonomous completion mandate 2026-11-01, N3).
//  Test-only configurations — an in-memory ledger key store, an ephemeral signing key, isolated
//  preferences, a store-less purchase centre — exist so tests never touch the person's ledger, Keychain or
//  preferences. They must never be reachable in a shipped build: a Release launch with a test-looking
//  environment variable stays a normal launch. In Release this is a constant `false`.
//

import Foundation

nonisolated enum TestHost {
    #if DEBUG
    static let isActive = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    #else
    static let isActive = false
    #endif

    /// S18 (QA-14) — the unit-test host IS the app (same sandbox container), so a store under Application Support would be
    /// the owner's own. Under the test host the app's user-data folders (notes, capture intake, diagnostics, import
    /// receipts, AI transcriptions) resolve here instead: one throwaway folder per test process.
    static let scratchSupport: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("kalsmritikosh-testhost-support-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

    /// S18 (QA-14) — the Documents folder the app's diagnostic reports (EvalBaselines) are written to: the real one, or a
    /// folder inside `scratchSupport` in the test host, so a test run never replaces the owner's own reports.
    static func documentsDirectory(create: Bool) throws -> URL {
        if isActive {
            let d = scratchSupport.appendingPathComponent("Documents", isDirectory: true)
            if create { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
            return d
        }
        return try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: create)
    }

    /// The Application Support folder the app's user-data stores use: the real one, or `scratchSupport` in the test host.
    static func applicationSupport() -> URL? {
        if isActive { return scratchSupport }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }
}
