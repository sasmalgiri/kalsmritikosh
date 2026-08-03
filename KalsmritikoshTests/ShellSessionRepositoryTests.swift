//
//  ShellSessionRepositoryTests.swift
//  KalsmritikoshTests
//
//  SHELL-001 — the autosave/resume repository over a real ledger. Proves a saved navigation history
//  resumes byte-for-byte (same entries, same cursor), that resuming after a Back restores the exact
//  cursor position, that re-saving a scope replaces it (one session per scope, revision advances), and
//  that an unknown scope resumes as nil. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("SHELL-001 — session autosave/resume")
struct ShellSessionRepositoryTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private func repo() async throws -> ShellSessionRepository {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("PRAGMA foreign_keys = ON;")
        return ShellSessionRepository(database: db)
    }

    private func entry(_ d: AppNavigationDestination, _ id: String? = nil) -> AppNavigationEntry {
        AppNavigationEntry(destination: d, contextKind: id == nil ? nil : "item", contextID: id)
    }

    @Test("A saved history resumes with identical entries and cursor")
    func saveResumeRoundTrip() async throws {
        let r = try await repo()
        var h = AppNavigationHistory()
        h.navigate(to: entry(.home)); h.navigate(to: entry(.dataLab, "ds-1")); h.navigate(to: entry(.evidenceInspector, "blk-9"))
        try await r.saveHistory(scopeKey: "default", history: h, at: t0)
        let resumed = try await r.loadHistory(scopeKey: "default")
        #expect(resumed == h)
        #expect(resumed?.current == entry(.evidenceInspector, "blk-9"))
    }

    @Test("Resuming after a Back restores the exact cursor position, not the end")
    func resumeCursorAfterBack() async throws {
        let r = try await repo()
        var h = AppNavigationHistory()
        h.navigate(to: entry(.home)); h.navigate(to: entry(.sources)); h.navigate(to: entry(.timeline))
        _ = h.goBack()   // cursor at sources (index 1), forward = [timeline]
        try await r.saveHistory(scopeKey: "default", history: h, at: t0)
        let resumed = try await r.loadHistory(scopeKey: "default")
        #expect(resumed?.currentIndex == 1)
        #expect(resumed?.current == entry(.sources))
        #expect(resumed?.canGoForward == true)
    }

    @Test("Re-saving a scope replaces it and advances the revision (one session per scope)")
    func resaveReplaces() async throws {
        let r = try await repo()
        var h1 = AppNavigationHistory(); h1.navigate(to: entry(.home))
        try await r.saveHistory(scopeKey: "default", history: h1, at: t0)
        var h2 = AppNavigationHistory(); h2.navigate(to: entry(.reports)); h2.navigate(to: entry(.settings))
        try await r.saveHistory(scopeKey: "default", history: h2, at: t0)
        let resumed = try await r.loadHistory(scopeKey: "default")
        #expect(resumed == h2)
        #expect(try await r.revision(scopeKey: "default") == 2)
    }

    @Test("Two scopes keep independent histories")
    func independentScopes() async throws {
        let r = try await repo()
        var a = AppNavigationHistory(); a.navigate(to: entry(.dataLab, "a"))
        var b = AppNavigationHistory(); b.navigate(to: entry(.methods))
        try await r.saveHistory(scopeKey: "workspace-A", history: a, at: t0)
        try await r.saveHistory(scopeKey: "workspace-B", history: b, at: t0)
        #expect(try await r.loadHistory(scopeKey: "workspace-A") == a)
        #expect(try await r.loadHistory(scopeKey: "workspace-B") == b)
    }

    @Test("An unknown scope resumes as nil; a blank scope is rejected")
    func unknownAndBlank() async throws {
        let r = try await repo()
        #expect(try await r.loadHistory(scopeKey: "never-saved") == nil)
        await #expect(throws: ShellSessionError.self) { try await r.saveHistory(scopeKey: "  ", history: AppNavigationHistory(), at: t0) }
    }

    @Test("An empty history round-trips (no current location)")
    func emptyRoundTrip() async throws {
        let r = try await repo()
        try await r.saveHistory(scopeKey: "default", history: AppNavigationHistory(), at: t0)
        let resumed = try await r.loadHistory(scopeKey: "default")
        #expect(resumed?.isEmpty == true)
        #expect(resumed?.currentIndex == -1)
    }
}
