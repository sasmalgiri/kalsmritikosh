//
//  SpotlightIndexer.swift
//  Kalsmritikosh
//
//  W3-7 — make documents findable from Spotlight (ported in spirit from
//  mailin's SpotlightIndexer). OFF by default because it copies text — the
//  file name and a short snippet — into macOS's own search index. Switching
//  the module off removes every item this app added. Opening a result jumps to
//  the document through the kalsmritikosh:// link handler.
//

import Foundation
import CoreSpotlight
import UniformTypeIdentifiers
import os

extension AppState {

    static let spotlightDomain = "ecosanskritiinnovation.Kalsmritikosh.documents"

    /// Speed PERF-31 (owner 2026-11-23) — not tested yet. When the last sync finished; a later sync sends only the
    /// documents added or changed since then (the first, a forced one and one after erasure send all, as before).
    static let spotlightLastSyncKey = "kalsmritikosh.spotlight.lastSync"

    /// Index (or refresh) up to `limit` documents. Removes everything when the module is off.
    public func syncSpotlight(limit: Int = 2000, full: Bool = false) async {
        guard ProductModuleFlags.isEnabled(.spotlightIndex) else {
            AppDefaults.store.removeObject(forKey: Self.spotlightLastSyncKey)
            do { try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [Self.spotlightDomain]) }
            catch { KalsmritikoshLog.app.error("Spotlight cleanup failed: \(error.localizedDescription, privacy: .public)") }
            return
        }
        guard let database else { return }
        let started = Date()
        let since = full ? nil : AppDefaults.store.object(forKey: Self.spotlightLastSyncKey) as? Date
        let rows: [SQLRow]
        do {
            rows = try await database.query("""
            SELECT ko.id, f.url, (SELECT text FROM chunks c WHERE c.object_id = ko.id AND c.review_status IS NULL
                                  AND c.superseded_by_run IS NULL ORDER BY ordinal LIMIT 1)
            FROM knowledge_objects ko JOIN files f ON f.id = ko.file_id
            \(since == nil ? "" : "WHERE ko.updated_at >= ? OR ko.created_at >= ?")
            ORDER BY ko.created_at DESC LIMIT ?;
            """, (since.map { [SQLValue.date($0), SQLValue.date($0)] } ?? []) + [.integer(Int64(limit))])
        } catch {
            KalsmritikoshLog.app.error("Spotlight: documents unreadable: \(String(describing: error), privacy: .private)")
            return
        }
        let items = rows.compactMap { r -> CSSearchableItem? in
            guard let id = r.uuid(0) else { return nil }
            let attrs = CSSearchableItemAttributeSet(contentType: .text)
            attrs.title = r.string(1).flatMap { URL(string: $0)?.lastPathComponent } ?? "Document"
            attrs.contentDescription = r.string(2).map { String($0.prefix(240)) }
            return CSSearchableItem(uniqueIdentifier: id.uuidString, domainIdentifier: Self.spotlightDomain, attributeSet: attrs)
        }
        do {
            if !items.isEmpty { try await CSSearchableIndex.default().indexSearchableItems(items) }
            AppDefaults.store.set(started, forKey: Self.spotlightLastSyncKey)
        } catch { KalsmritikoshLog.app.error("Spotlight index failed: \(error.localizedDescription, privacy: .public)") }
    }

    /// S14 (SEC-07) — documents were erased: every item this app put in macOS's search index is removed, and (with the
    /// module on) the documents still in the ledger are indexed again, so an erased document's name and snippet do not
    /// stay findable in Spotlight. The test host never touches the system index.
    func refreshSpotlightAfterErasure() async {
        guard !TestHost.isActive else { return }
        do { try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [Self.spotlightDomain]) }
        catch { KalsmritikoshLog.app.error("Spotlight cleanup after erasure failed: \(error.localizedDescription, privacy: .public)") }
        if ProductModuleFlags.isEnabled(.spotlightIndex) { await syncSpotlight(full: true) }
    }

    /// A Spotlight result was opened.
    public func openSpotlightItem(_ identifier: String) async {
        guard let id = UUID(uuidString: identifier), let url = DeepLink.document(id: id, quote: nil).url else { return }
        await handleDeepLink(url)
    }
}
