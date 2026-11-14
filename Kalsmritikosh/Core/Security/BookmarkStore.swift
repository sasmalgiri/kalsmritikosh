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
import os

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
    /// True for a harness store that neither loads nor writes the person's saved folders.
    public var isEphemeral: Bool { ephemeral }

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
        // GUI walk 2026-11-13 D3 — one row per folder: registering a folder that is already a root (by its standardized
        // path) keeps the existing row, so a second launch path, a second window or a repeated pick cannot add a twin.
        let identity = Self.identityPath(of: url)
        if roots.contains(where: { path(of: $0) == identity }) {
            KalsmritikoshLog.app.info("Folder already registered — not adding it twice")
            return
        }
        let root = Root(displayName: url.lastPathComponent, bookmarkData: data)
        roots.append(root)
        persist()
    }

    /// D3 — the identity of a folder: its standardized, symlink-resolved path without a trailing slash.
    public nonisolated static func identityPath(of url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }

    /// D3 — the folder a root's bookmark points at (without starting security-scoped access), or nil when the bookmark
    /// no longer resolves. A root that does not resolve is never merged with another.
    func path(of root: Root) -> String? {
        var stale = false
        #if canImport(AppKit)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI, .withoutMounting]
        #else
        let options: URL.BookmarkResolutionOptions = [.withoutUI]
        #endif
        do {
            let url = try URL(resolvingBookmarkData: root.bookmarkData, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
            return Self.identityPath(of: url)
        } catch {
            KalsmritikoshLog.app.error("Folder bookmark did not resolve: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// D3 — merge roots that point at the same folder, keeping the first (oldest) row. Only the duplicate bookmark rows
    /// go: no file, document or ledger record is touched (the ledger keys files by path, not by root). Returns how many
    /// rows were merged away.
    @discardableResult
    public func mergeDuplicateRoots() -> Int {
        let kept = Self.mergedRoots(roots) { path(of: $0) }
        let merged = roots.count - kept.count
        guard merged > 0 else { return 0 }
        roots = kept
        persist()
        KalsmritikoshLog.app.notice("Merged \(merged, privacy: .public) duplicate folder row(s)")
        return merged
    }

    /// D3 — `roots` with every later row that points at an earlier row's folder dropped; a row whose folder is unknown
    /// (`path` nil) is always kept.
    public nonisolated static func mergedRoots(_ roots: [Root], path: (Root) -> String?) -> [Root] {
        var seen = Set<String>()
        var kept: [Root] = []
        for root in roots {
            guard let identity = path(root) else { kept.append(root); continue }
            if seen.insert(identity).inserted { kept.append(root) }
        }
        return kept
    }

    /// D3 — the folders to read, each once: duplicate paths are dropped and a folder inside another listed folder is
    /// left to the outer one, so two overlapping roots never select or count a file twice. Order is kept.
    public nonisolated static func distinctFolders(_ urls: [URL]) -> [URL] {
        distinctFolderIndices(urls).map { urls[$0] }
    }

    /// D3 — the positions in `urls` that `distinctFolders` keeps (so a caller can release the others' access).
    public nonisolated static func distinctFolderIndices(_ urls: [URL]) -> [Int] {
        let paths = urls.map { identityPath(of: $0) }
        var seen = Set<String>()
        var firsts: [Int] = []
        for (i, p) in paths.enumerated() where seen.insert(p).inserted { firsts.append(i) }
        return firsts.filter { i in
            let mine = paths[i]
            return !seen.contains { other in other != mine && mine.hasPrefix(other == "/" ? "/" : other + "/") }
        }
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
            mergeDuplicateRoots()   // D3 — twins left by an earlier build are merged on load
            return
        }
        // One-time recovery: adopt roots stranded under the legacy key and copy
        // them forward under the current key.
        if let legacy = UserDefaults.standard.data(forKey: legacyDefaultsKey),
           let decoded = try? JSONDecoder().decode([Root].self, from: legacy),
           !decoded.isEmpty {
            roots = decoded
            persist()
            mergeDuplicateRoots()
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
