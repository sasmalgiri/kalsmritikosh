//
//  AppState+ReferenceShelf.swift
//  Kalsmritikosh
//
//  Unified path SEARCH-17 (owner 2026-11-22) — not tested yet. The reference shelf: add a folder of
//  reference documents, read it into the shelf's own tables (never the archive ledger), and search it
//  for the shelf lane in Ask.
//

import Foundation
import os

extension AppState {

    var referenceShelf: ReferenceShelfRepository? {
        database.map { ReferenceShelfRepository(database: $0) }
    }

    /// Adds a folder the person picked (a security-scoped URL from the open panel) and reads it.
    func addReferenceShelfFolder(_ url: URL) async -> ReferenceShelfReader.Report? {
        guard let shelf = referenceShelf else { return nil }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        var bookmark: Data?
        do {
            bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                            includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            KalsmritikoshLog.app.error("Reference shelf: no bookmark for the folder (it is read now, not re-read later): \(String(describing: error), privacy: .public)")
        }
        do {
            let id = try await shelf.addFolder(path: url.path, label: url.lastPathComponent, bookmark: bookmark)
            let registry = LoaderRegistry.standard()
            return await ReferenceShelfReader(registry: registry, repository: shelf).read(folderID: id, folderURL: url)
        } catch {
            KalsmritikoshLog.app.error("Reference shelf: the folder could not be added: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Reads every shelf folder again (changed files only), through their saved bookmarks.
    func rereadReferenceShelf() async -> ReferenceShelfReader.Report? {
        guard let shelf = referenceShelf else { return nil }
        var total = ReferenceShelfReader.Report()
        do {
            let registry = LoaderRegistry.standard()
            for folder in try await shelf.folders() {
                guard let data = folder.bookmark else { continue }
                var stale = false
                let url: URL
                do {
                    url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
                } catch {
                    KalsmritikoshLog.app.error("Reference shelf: a folder could not be reopened: \(String(describing: error), privacy: .public)")
                    continue
                }
                let accessing = url.startAccessingSecurityScopedResource()
                let r = await ReferenceShelfReader(registry: registry, repository: shelf).read(folderID: folder.id, folderURL: url)
                if accessing { url.stopAccessingSecurityScopedResource() }
                total.read += r.read; total.unchanged += r.unchanged; total.unreadable += r.unreadable
                total.skippedNotDocuments += r.skippedNotDocuments; total.stoppedAtLimit = total.stoppedAtLimit || r.stoppedAtLimit
            }
        } catch {
            KalsmritikoshLog.app.error("Reference shelf: folders unreadable: \(String(describing: error), privacy: .public)")
            return nil
        }
        return total
    }

    /// The shelf lane's block for a question, or nil when the shelf is empty or has nothing on it.
    func referenceShelfBlock(question: String) async -> String? {
        guard let shelf = referenceShelf else { return nil }
        do {
            return ReferenceShelfLane.render(try await shelf.search(question, limit: 3))
        } catch {
            KalsmritikoshLog.app.error("Reference shelf search failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
