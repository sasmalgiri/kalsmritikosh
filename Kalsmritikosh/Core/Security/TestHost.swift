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
}
