//
//  BookmarkStore.swift
//  Kalsmritikosh
//
//  Sandboxed macOS apps lose access to user-picked folders on relaunch
//  unless a security-scoped bookmark is persisted. The store hides that
//  ceremony behind a small API.
//
//  iOS shim: the target still builds for iOS in v1, but the ingestion
//  paths only run on macOS. We gate the security-scoped APIs so the
//  iOS build keeps compiling for shared `Core` reuse later.
//

import Foundation
import Observation

@MainActor
@Observable
public final class BookmarkStore {
    public static let shared = BookmarkStore()

    private let defaultsKey = "kalsmritikosh.bookmarks"
    public private(set) var roots: [Root] = []

    /// When true the store neither loads persisted roots at init nor writes
    /// roots back to `UserDefaults`. Used by the eval harness so its "isolated"
    /// store starts genuinely empty — otherwise it would inherit the user's
    /// real watched folders and the eval would ingest the real archive into
    /// the throwaway DB, contaminating every metric.
    private let ephemeral: Bool

    public struct Root: Codable, Identifiable, Hashable, Sendable {
        public let id: UUID
        public let displayName: String
        public let bookmarkData: Data
        public let createdAt: Date

        public init(
            id: UUID = UUID(),
            displayName: String,
            bookmarkData: Data,
            createdAt: Date = .init()
        ) {
            self.id = id
            self.displayName = displayName
            self.bookmarkData = bookmarkData
            self.createdAt = createdAt
        }
    }

    public init() {
        self.ephemeral = false
        load()
    }

    /// Create a store for the eval / test harness. `ephemeral: true` starts
    /// with no roots and never touches `UserDefaults`, so it can neither
    /// inherit nor overwrite the user's real bookmarks.
    public init(ephemeral: Bool) {
        self.ephemeral = ephemeral
        if !ephemeral { load() }
    }

    public func register(url: URL) throws {
        let data: Data
        #if canImport(AppKit)
        data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #else
        data = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #endif
        let root = Root(displayName: url.lastPathComponent, bookmarkData: data)
        roots.append(root)
        persist()
    }

    public func remove(_ root: Root) {
        roots.removeAll { $0.id == root.id }
        persist()
    }

    /// Resolve a bookmark to a URL with security-scoped access started.
    /// Caller is responsible for calling `stopAccessing(_:)`.
    public func resolve(_ root: Root) throws -> URL {
        var stale = false
        #if canImport(AppKit)
        let url = try URL(
            resolvingBookmarkData: root.bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        #else
        let url = try URL(
            resolvingBookmarkData: root.bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        #endif
        guard url.startAccessingSecurityScopedResource() else {
            throw BookmarkError.accessDenied
        }
        return url
    }

    public func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }

    // MARK: - Persistence

    /// The pre-rename key. The atlas→kalsmritikosh rename started writing roots
    /// under `defaultsKey` but never migrated existing ones, so a user who had
    /// registered a folder before the rename was left with an EMPTY new key and
    /// their real root stranded here — the app then had nothing to ingest.
    private let legacyDefaultsKey = "atlas.bookmarks"

    private func load() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([Root].self, from: data),
           !decoded.isEmpty {
            roots = decoded
            return
        }
        // One-time recovery: adopt roots stranded under the legacy key and copy
        // them forward under the current key.
        if let legacy = UserDefaults.standard.data(forKey: legacyDefaultsKey),
           let decoded = try? JSONDecoder().decode([Root].self, from: legacy),
           !decoded.isEmpty {
            roots = decoded
            persist()
        }
    }

    private func persist() {
        guard !ephemeral else { return }
        guard let data = try? JSONEncoder().encode(roots) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    public enum BookmarkError: Error, Sendable {
        case accessDenied
    }
}
