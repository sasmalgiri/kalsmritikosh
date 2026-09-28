//
//  SampleArchiveModeTests.swift
//  Kalsmritikosh Tests
//
//  §1.1 — the sample archive lives in a SEPARATE ledger: its database file is
//  never the user's, the mode flag is off unless explicitly entered, and the
//  sample boot's folder store starts empty and never persists.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("§1.1 — sample archive in a separate ledger", .serialized)
@MainActor
struct SampleArchiveModeTests {

    @Test("The sample database is a different file from the user's ledger")
    func separateDatabaseFile() throws {
        let sample = try #require(SampleArchiveMode.databaseURL)
        #expect(sample.standardizedFileURL != DatabaseLocations.defaultDatabaseURL.standardizedFileURL)
        #expect(sample.lastPathComponent == "sample-knowledge.sqlite")
        #expect(sample.deletingLastPathComponent().lastPathComponent == "DemoArchive")
    }

    @Test("The mode is OFF unless entered; the flag alone decides")
    func flagDecides() {
        let key = SampleArchiveMode.defaultsKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        #expect(!SampleArchiveMode.isActive, "a fresh install runs on the user's own ledger")
        UserDefaults.standard.set(true, forKey: key)
        #expect(SampleArchiveMode.isActive)
    }

    @Test("The sample boot's folder store starts empty — the user's saved folders are never loaded")
    func ephemeralFolders() {
        let store = BookmarkStore(ephemeral: true)
        #expect(store.roots.isEmpty)
    }
}

@Suite("§1.1 — persona choice at onboarding")
@MainActor
struct OnboardingPersonaStepTests {

    @Test("Onboarding asks for the focus right after the welcome, before any folder is chosen")
    func personaStepOrder() {
        #expect(OnboardingView.Step.persona.rawValue == OnboardingView.Step.welcome.rawValue + 1)
        #expect(OnboardingView.Step.persona.rawValue < OnboardingView.Step.folder.rawValue)
    }

    @Test("Every offered persona has a unique id the sidebar can resolve")
    func personasResolvable() {
        let ids = GuideContent.personas.map(\.id)
        #expect(!ids.isEmpty)
        #expect(Set(ids).count == ids.count)
    }
}
