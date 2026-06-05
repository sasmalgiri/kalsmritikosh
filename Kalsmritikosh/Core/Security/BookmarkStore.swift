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

    private let defaultsKey = "atlas.bookmarks"
    public private(set) var roots: [Root] = []

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
        load()
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

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return }
        if let decoded = try? JSONDecoder().decode([Root].self, from: data) {
            roots = decoded
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(roots) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    public enum BookmarkError: Error, Sendable {
        case accessDenied
    }
}
