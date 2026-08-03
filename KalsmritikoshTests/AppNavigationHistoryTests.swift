//
//  AppNavigationHistoryTests.swift
//  KalsmritikoshTests
//
//  SHELL-001 — the shell's browser-style Back/Forward location history. Proves navigate/append,
//  same-entry no-op, back/forward cursor movement, forward-branch truncation on a new navigation, and
//  bounds/clamping on reconstruction. Pure — no data.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("SHELL-001 — navigation history")
struct AppNavigationHistoryTests {

    private func entry(_ d: AppNavigationDestination, _ id: String? = nil) -> AppNavigationEntry {
        AppNavigationEntry(destination: d, contextKind: id == nil ? nil : "item", contextID: id)
    }

    @Test("An empty history has no current location and cannot go back or forward")
    func empty() {
        let h = AppNavigationHistory()
        #expect(h.current == nil && h.isEmpty)
        #expect(!h.canGoBack && !h.canGoForward)
    }

    @Test("Navigating appends and moves the cursor to the new location")
    func navigateAppends() {
        var h = AppNavigationHistory()
        h.navigate(to: entry(.home))
        h.navigate(to: entry(.dataLab, "ds-1"))
        #expect(h.entries.count == 2)
        #expect(h.current == entry(.dataLab, "ds-1"))
        #expect(h.canGoBack && !h.canGoForward)
    }

    @Test("Navigating to the entry already shown is a no-op (no duplicate stacking)")
    func sameEntryNoOp() {
        var h = AppNavigationHistory()
        h.navigate(to: entry(.home))
        h.navigate(to: entry(.home))
        #expect(h.entries.count == 1)
    }

    @Test("Back and forward move the cursor without destroying history")
    func backForward() {
        var h = AppNavigationHistory()
        h.navigate(to: entry(.home)); h.navigate(to: entry(.sources)); h.navigate(to: entry(.timeline))
        #expect(h.goBack() == entry(.sources))
        #expect(h.goBack() == entry(.home))
        #expect(!h.canGoBack)
        #expect(h.goForward() == entry(.sources))
        #expect(h.entries.count == 3)   // history intact
    }

    @Test("A new navigation after going back truncates the forward branch")
    func truncateForward() {
        var h = AppNavigationHistory()
        h.navigate(to: entry(.home)); h.navigate(to: entry(.sources)); h.navigate(to: entry(.timeline))
        _ = h.goBack()   // now at sources, forward = [timeline]
        h.navigate(to: entry(.reports))
        #expect(h.entries.map(\.destination) == [.home, .sources, .reports])   // timeline dropped
        #expect(!h.canGoForward)
    }

    @Test("Back/forward at the bounds return nil and do not move")
    func bounds() {
        var h = AppNavigationHistory()
        h.navigate(to: entry(.home))
        #expect(h.goBack() == nil)      // already at the first
        #expect(h.goForward() == nil)   // already at the last
        #expect(h.current == entry(.home))
    }

    @Test("Reconstruction clamps an out-of-range cursor into a valid position")
    func reconstructionClamps() {
        let entries = [entry(.home), entry(.sources)]
        #expect(AppNavigationHistory(entries: entries, currentIndex: 99).currentIndex == 1)
        #expect(AppNavigationHistory(entries: entries, currentIndex: -5).currentIndex == 0)
        #expect(AppNavigationHistory(entries: [], currentIndex: 3).currentIndex == -1)
    }

    @Test("The destination vocabulary is the fixed closed set of top-level locations")
    func destinationVocabulary() {
        #expect(AppNavigationDestination.allCases.count == 12)
    }
}
