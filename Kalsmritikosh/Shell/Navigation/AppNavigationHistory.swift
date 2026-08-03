//
//  AppNavigationHistory.swift
//  Kalsmritikosh
//
//  SHELL-001 (Product shell) — the shared macOS shell's LOCATION navigation. This is browser-style
//  Back / Forward across the app's top-level places (Home, Sources, Timeline, DataLab, a specific
//  dataset, the Evidence Inspector, …). It is DELIBERATELY DISTINCT from workflow Prev / Next: workflow
//  stepping walks the ordered steps of one professional workflow run, whereas this history walks the
//  places the user has visited. The two are never the same control and never share state — this model
//  has no knowledge of workflows or steps. It is a pure value type; persistence + resume live in the
//  ShellSessionRepository.
//

import Foundation

/// The closed set of top-level app locations the shell can navigate between. A dataset/scenario/etc. is
/// addressed by pairing a destination with a context id on the entry, not by a per-item destination case.
public nonisolated enum AppNavigationDestination: String, Codable, Sendable, Equatable, CaseIterable {
    case home
    case sources
    case timeline
    case entities
    case relationships
    case dataLab
    case methods
    case jobs
    case answers
    case reports
    case evidenceInspector
    case settings
}

/// One visited location: a destination plus an optional context (e.g. a specific dataset or source id)
/// so Back / Forward returns not just to "DataLab" but to the exact item that was open.
public nonisolated struct AppNavigationEntry: Sendable, Equatable {
    public let destination: AppNavigationDestination
    public let contextKind: String?
    public let contextID: String?

    public nonisolated init(destination: AppNavigationDestination, contextKind: String? = nil, contextID: String? = nil) {
        self.destination = destination; self.contextKind = contextKind; self.contextID = contextID
    }
}

/// A browser-style Back / Forward history. `currentIndex` points at the entry currently shown. Navigating
/// to a new location truncates any forward entries (the classic "you can't redo after taking a new path")
/// and appends; Back / Forward only move the cursor and never destroy history until a new navigation.
public nonisolated struct AppNavigationHistory: Sendable, Equatable {
    public private(set) var entries: [AppNavigationEntry]
    public private(set) var currentIndex: Int

    /// An empty history (no location yet).
    public nonisolated init() { self.entries = []; self.currentIndex = -1 }

    /// Reconstruct a history from persisted state (used by resume). The index is clamped into range.
    public nonisolated init(entries: [AppNavigationEntry], currentIndex: Int) {
        self.entries = entries
        if entries.isEmpty { self.currentIndex = -1 }
        else { self.currentIndex = Swift.min(Swift.max(currentIndex, 0), entries.count - 1) }
    }

    public nonisolated var current: AppNavigationEntry? {
        guard currentIndex >= 0, currentIndex < entries.count else { return nil }
        return entries[currentIndex]
    }
    public nonisolated var canGoBack: Bool { currentIndex > 0 }
    public nonisolated var canGoForward: Bool { currentIndex >= 0 && currentIndex < entries.count - 1 }
    public nonisolated var isEmpty: Bool { entries.isEmpty }

    /// Navigate to a new location. Truncates any forward history, appends, and moves the cursor to it.
    /// Navigating to the exact same entry that is already current is a no-op (no duplicate stacking).
    public nonisolated mutating func navigate(to entry: AppNavigationEntry) {
        if let cur = current, cur == entry { return }
        if canGoForward { entries.removeSubrange((currentIndex + 1)...) }
        entries.append(entry)
        currentIndex = entries.count - 1
    }

    /// Move back one location, if possible; returns the new current entry.
    @discardableResult
    public nonisolated mutating func goBack() -> AppNavigationEntry? {
        guard canGoBack else { return nil }
        currentIndex -= 1
        return current
    }

    /// Move forward one location, if possible; returns the new current entry.
    @discardableResult
    public nonisolated mutating func goForward() -> AppNavigationEntry? {
        guard canGoForward else { return nil }
        currentIndex += 1
        return current
    }
}
