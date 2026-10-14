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

    /// Index (or refresh) up to `limit` documents. Removes everything when the module is off.
    public func syncSpotlight(limit: Int = 2000) async {
        guard ProductModuleFlags.isEnabled(.spotlightIndex) else {
            do { try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [Self.spotlightDomain]) }
            catch { KalsmritikoshLog.app.error("Spotlight cleanup failed: \(error.localizedDescription, privacy: .public)") }
            return
        }
        guard let database else { return }
        let rows = (try? await database.query("""
            SELECT ko.id, f.url, (SELECT text FROM chunks c WHERE c.object_id = ko.id AND c.review_status IS NULL
                                  AND c.superseded_by_run IS NULL ORDER BY ordinal LIMIT 1)
            FROM knowledge_objects ko JOIN files f ON f.id = ko.file_id
            ORDER BY ko.created_at DESC LIMIT ?;
            """, [.integer(Int64(limit))])) ?? []
        let items = rows.compactMap { r -> CSSearchableItem? in
            guard let id = r.uuid(0) else { return nil }
            let attrs = CSSearchableItemAttributeSet(contentType: .text)
            attrs.title = r.string(1).flatMap { URL(string: $0)?.lastPathComponent } ?? "Document"
            attrs.contentDescription = r.string(2).map { String($0.prefix(240)) }
            return CSSearchableItem(uniqueIdentifier: id.uuidString, domainIdentifier: Self.spotlightDomain, attributeSet: attrs)
        }
        do { try await CSSearchableIndex.default().indexSearchableItems(items) }
        catch { KalsmritikoshLog.app.error("Spotlight index failed: \(error.localizedDescription, privacy: .public)") }
    }

    /// A Spotlight result was opened.
    public func openSpotlightItem(_ identifier: String) async {
        guard let id = UUID(uuidString: identifier), let url = DeepLink.document(id: id, quote: nil).url else { return }
        await handleDeepLink(url)
    }
}
