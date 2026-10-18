//
//  AppState+Groups.swift
//  Kalsmritikosh
//
//  X-2 — your own folders: the app-side entry points (module gate, mirroring a source
//  folder's structure). The tree and membership rules live in GroupRepository.
//

import Foundation
import os

extension AppState {
    /// A repository over the open ledger, or nil before boot / with the module off.
    var groupRepository: GroupRepository? {
        guard ProductModuleFlags.isEnabled(.userGroups), let database else { return nil }
        return GroupRepository(database: database)
    }

    /// Mirror a source folder's sub-folders as groups (files on disk are never touched).
    @discardableResult
    func mirrorFolders(of root: BookmarkStore.Root) async -> GroupRepository.MirrorResult? {
        guard let repo = groupRepository, let database, let url = try? bookmarks.resolve(root) else { return nil }
        defer { bookmarks.stopAccessing(url) }
        do {
            let rows = try await database.query("""
                SELECT ko.id, f.url FROM knowledge_objects ko JOIN files f ON f.id = ko.file_id;
                """, [])
            let rootPath = url.standardizedFileURL.path
            let docs: [(objectID: UUID, path: String)] = rows.compactMap { r in
                guard let id = r.uuid(0), let raw = r.string(1) else { return nil }
                let path = (URL(string: raw)?.isFileURL == true ? URL(string: raw)?.path : raw) ?? raw
                return path.hasPrefix(rootPath + "/") ? (id, path) : nil
            }
            return try await repo.mirror(rootName: root.displayName, rootPath: rootPath, documents: docs)
        } catch {
            KalsmritikoshLog.app.error("Mirror folders failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
