//
//  AppState+LivingDossier.swift
//  Kalsmritikosh
//
//  I-12 — living dossiers: when a dossier is opened, say what arrived about
//  that subject since it was last opened — documents added that mention it and
//  the dated events they contributed. "Added" is measured by when the document
//  entered the ledger, which is what "since you last looked" means.
//

import Foundation
import os

public struct DossierChanges: Sendable {
    public let since: Date?
    public let newDocuments: [String]
    public let newEvents: Int

    public var summary: String {
        guard let since else { return "First time you opened this dossier." }
        if newDocuments.isEmpty { return "Nothing new since you last looked (\(since.formatted(date: .abbreviated, time: .shortened)))." }
        return "Since \(since.formatted(date: .abbreviated, time: .shortened)): \(newDocuments.count) new document\(newDocuments.count == 1 ? "" : "s") and \(newEvents) dated event\(newEvents == 1 ? "" : "s")."
    }
}

extension AppState {

    private static let lastViewedKey = "kalsmritikosh.dossier.lastViewed"

    /// Changes for `name` since the last call for that name; records this view.
    public func dossierChanges(for name: String) async -> DossierChanges? {
        guard ProductModuleFlags.isEnabled(.livingDossiers), let database else { return nil }
        let key = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = UserDefaults.standard.dictionary(forKey: Self.lastViewedKey) as? [String: Double] ?? [:]
        let since = seen[key].map { Date(timeIntervalSince1970: $0) }
        seen[key] = Date().timeIntervalSince1970
        UserDefaults.standard.set(seen, forKey: Self.lastViewedKey)
        guard let since else { return DossierChanges(since: nil, newDocuments: [], newEvents: 0) }
        do {
            let pattern = "%" + key + "%"
            let docs = try await database.query("""
                SELECT DISTINCT ko.id, f.url FROM entity_mentions m
                JOIN entities e ON e.id = m.entity_id
                JOIN knowledge_objects ko ON ko.id = m.source_object_id
                JOIN files f ON f.id = ko.file_id
                WHERE (LOWER(e.value) LIKE ? OR m.normalized LIKE ?) AND ko.created_at > ?
                LIMIT 200;
                """, [.text(pattern), .text(pattern), .real(since.timeIntervalSince1970)])
            let ids = docs.compactMap { $0.uuid(0) }
            var events = 0
            if !ids.isEmpty {
                let marks = ids.map { _ in "?" }.joined(separator: ",")
                events = Int(try await database.query(
                    "SELECT COUNT(*) FROM events WHERE source_object_id IN (\(marks));",
                    ids.map { .uuid($0) }).first?.int(0) ?? 0)
            }
            let names = docs.compactMap { $0.string(1) }.map { URL(string: $0)?.lastPathComponent ?? $0 }
            return DossierChanges(since: since, newDocuments: names, newEvents: events)
        } catch {
            KalsmritikoshLog.app.error("Dossier changes failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
