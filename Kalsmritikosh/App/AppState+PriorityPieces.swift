//
//  AppState+PriorityPieces.swift
//  Kalsmritikosh
//
//  Speed PERF-36 torrent (owner 2026-11-23) — not tested yet. Sets the priority signal (PriorityPieces): the open case's
//  authorised documents when a case opens, the documents a question's answer cited when a question is asked. Every import
//  and drain queue then takes those first.
//

import Foundation
import os

extension AppState {
    /// A case was opened (nil: no case open). Its authorised source versions, their knowledge objects and the original files.
    func notePriorityCase(_ caseID: UUID?) async {
        guard let caseID, let database, let objects else { PriorityPieces.setOpenCase(nil); return }
        do {
            guard let record = try await InvestigationCaseRepository(database: database).fetch(caseID: caseID) else {
                PriorityPieces.setOpenCase(nil); return
            }
            let versions = try await CaseRetrievalScopeResolver(evidence: EvidenceStore(database: database))
                .scope(for: record).authorizedSourceVersionIDs
            let byObject = try await objects.sourceVersionsByObject(inSourceVersionIDs: versions)
            let files = try await Self.originalFiles(database, versions: versions)
            PriorityPieces.setOpenCase(caseID, sourceVersions: versions, objects: Set(byObject.keys), files: files)
        } catch {
            KalsmritikoshLog.app.error("priority pieces: the open case's documents unreadable (no priority): \(String(describing: error), privacy: .public)")
            PriorityPieces.setOpenCase(nil)
        }
    }

    /// A question was answered: the documents it cited come first in the drains (their vectors, their upgrades).
    func notePriorityAnswer(_ answer: VerifiedAnswer) {
        PriorityPieces.setQuestion(objects: Set(answer.citations.map(\.objectID)))
    }

    /// The original files of `versions` (their logical sources' recorded locations).
    nonisolated static func originalFiles(_ db: Database, versions: Set<UUID>) async throws -> [URL] {
        guard !versions.isEmpty else { return [] }
        let json = String(data: try JSONSerialization.data(withJSONObject: versions.map(\.uuidString)), encoding: .utf8) ?? "[]"
        return try await db.query("""
            SELECT DISTINCT f.url FROM files f JOIN source_versions sv ON upper(sv.logical_source_id) = upper(f.id)
            WHERE upper(sv.id) IN (SELECT upper(value) FROM json_each(?));
            """, [.text(json)]).compactMap { $0.string(0) }.compactMap { s in
                s.hasPrefix("file://") ? URL(string: s) : URL(fileURLWithPath: s)
            }
    }
}
