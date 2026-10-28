//
//  AppState+Erasure.swift
//  Kalsmritikosh
//
//  K10 — the app's entry points for erasing one case or one person (see CaseErasure.swift). After the
//  ledger erase commits: open studios stop writing (a queued save cannot recreate erased work), vault
//  copies used only by erased documents are removed, the vector cache is dropped so it rebuilds
//  without the erased chunks, and preferences that name the case are cleared. Anything that could not
//  be removed is reported, never assumed gone.
//

import Foundation
import os

extension AppState {

    public struct ErasureOutcome: Sendable {
        public let report: CaseErasureReport
        /// Managed files that could not be removed (reported to the person).
        public let fileResidue: [String]
        public var summary: String {
            if let refused = report.refused { return refused }
            var parts = ["Erased \(report.rowsErased.values.reduce(0, +)) record(s)."]
            if report.sourcesErased > 0 { parts.append("\(report.sourcesErased) document(s) used only by this case were erased.") }
            if report.sourcesKeptShared > 0 { parts.append("\(report.sourcesKeptShared) document(s) are kept because another case or workspace uses them.") }
            if report.sourcesKeptInLibrary > 0 { parts.append("\(report.sourcesKeptInLibrary) document(s) stay in your library; erase them from Sources to remove their content.") }
            if report.documentsStillNaming > 0 { parts.append("\(report.documentsStillNaming) original document(s) still name this person; erase or redact them to remove the name.") }
            if !fileResidue.isEmpty { parts.append("Not removed: \(fileResidue.joined(separator: ", ")).") }
            return parts.joined(separator: " ")
        }
    }

    /// Erase one case (and, when asked, the documents no other case or workspace uses).
    public func eraseCase(_ caseID: UUID, eraseExclusiveSources: Bool, reason: String, legalBasis: String?,
                          actor: String) async throws -> ErasureOutcome {
        guard let db = database, let answers = investigationAnswers else { throw CaseErasureError.caseNotFound }
        let versions = try await answers.scopeContext(caseID: caseID).scope.authorizedSourceVersionIDs
        // Writers first: an open studio's pending save must not land after the erase.
        await StudioStorage.invalidateAllForErase()
        let report = try await CaseEraser(database: db).erase(caseID: caseID, sourceVersionIDs: Set(versions),
                                                             eraseExclusiveSources: eraseExclusiveSources,
                                                             reason: reason, legalBasis: legalBasis, actor: actor)
        guard report.refused == nil else { return ErasureOutcome(report: report, fileResidue: []) }
        var residue: [String] = []
        let dir = db.url.deletingLastPathComponent()
        if !report.vaultAddresses.isEmpty {
            let vault = EvidenceVault(root: dir.appendingPathComponent("EvidenceVault", isDirectory: true))
            for hash in report.vaultAddresses where await vault.contains(hash) {
                do { try await vault.remove(hash) } catch {
                    KalsmritikoshLog.app.error("Case erasure: vault copy not removed: \(error.localizedDescription, privacy: .public)")
                }
                if await vault.contains(hash) { residue.append("vault copy \(hash.prefix(12))…") }
            }
        }
        if report.sourcesErased > 0 { residue += Self.dropVectorCache(besideLedgerAt: db.url) }
        let defaults = Self.erasePreferences
        for key in defaults.dictionaryRepresentation().keys where key.contains(caseID.uuidString) || key.contains(caseID.uuidString.lowercased()) {
            defaults.removeObject(forKey: key)
        }
        return ErasureOutcome(report: report, fileResidue: residue)
    }

    /// Erase one person's derived record (their documents are not edited; see the report).
    public func erasePerson(_ entityID: UUID, reason: String, legalBasis: String?, actor: String) async throws -> ErasureOutcome {
        guard let db = database else { throw CaseErasureError.entityNotFound }
        await StudioStorage.invalidateAllForErase()
        let report = try await CaseEraser(database: db).erasePerson(entityID: entityID, reason: reason, legalBasis: legalBasis, actor: actor)
        return ErasureOutcome(report: report, fileResidue: [])
    }

    /// The vector cache holds every chunk's vector; after documents are erased it is dropped and rebuilt.
    nonisolated static func dropVectorCache(besideLedgerAt ledgerURL: URL) -> [String] {
        let url = ledgerURL.deletingLastPathComponent().appendingPathComponent("hnsw-index.bin")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do { try FileManager.default.removeItem(at: url) } catch {
            KalsmritikoshLog.app.error("Vector cache not removed after erasure: \(error.localizedDescription, privacy: .public)")
        }
        return FileManager.default.fileExists(atPath: url.path) ? ["vector cache"] : []
    }
}
