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
            if report.answersRemoved > 0 { parts.append("\(report.answersRemoved) saved answer(s) that quoted the erased documents were removed.") }
            if report.documentsStillNaming > 0 { parts.append("\(report.documentsStillNaming) original document(s) still name this person; erase or redact them to remove the name.") }
            if !report.stillNamedIn.isEmpty {
                parts.append("Still naming them (not erased): " + report.stillNamedIn.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ") + ".")
            }
            if !fileResidue.isEmpty { parts.append("Not removed: \(fileResidue.joined(separator: ", ")).") }
            return parts.joined(separator: " ")
        }
    }

    /// Erase one case (and, when asked, the documents no other case or workspace uses).
    public func eraseCase(_ caseID: UUID, eraseExclusiveSources: Bool, reason: String, legalBasis: String?,
                          actor: String) async throws -> ErasureOutcome {
        guard let db = database, let answers = investigationAnswers else { throw CaseErasureError.caseNotFound }
        guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CaseErasureError.blankReason }
        guard !actor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CaseErasureError.blankActor }
        let versions = try await answers.scopeContext(caseID: caseID).scope.authorizedSourceVersionIDs
        // A4 — writers are flushed (pending saves are kept and written), never discarded, before the
        // erase decides. A refused erase leaves every studio as it was.
        _ = await StudioStorage.flushAll()
        // A5 — the files this erase may remove are recorded BEFORE the ledger commits, so a crash
        // between the commit and the file removal is finished at the next launch.
        let record = Self.caseEraseRecordURL(besideLedgerAt: db.url, caseID: caseID)
        let candidates = eraseExclusiveSources ? (try? await CaseEraser(database: db).vaultCandidates(sourceVersionIDs: Set(versions))) ?? [] : []
        Self.writeCaseEraseRecord(record, vault: candidates, dropVectorCache: eraseExclusiveSources)
        let report = try await CaseEraser(database: db).erase(caseID: caseID, sourceVersionIDs: Set(versions),
                                                             eraseExclusiveSources: eraseExclusiveSources,
                                                             reason: reason, legalBasis: legalBasis, actor: actor)
        guard report.refused == nil else {
            try? FileManager.default.removeItem(at: record)
            return ErasureOutcome(report: report, fileResidue: [])
        }
        await StudioStorage.invalidate(forErasedCase: caseID)
        var residue = await Self.finishCaseEraseFiles(record: record, ledgerURL: db.url, database: db, only: report.vaultAddresses)
        if report.sourcesErased > 0, let hnsw = hnswIndex, let vectors = vectorStore {
            // The live index still held the erased chunks' vectors: rebuild it from the ledger.
            _ = await hnsw.build(from: vectors)
        } else if report.sourcesErased == 0 { residue = [] }
        let defaults = Self.erasePreferences
        for key in defaults.dictionaryRepresentation().keys where key.contains(caseID.uuidString) || key.contains(caseID.uuidString.lowercased()) {
            defaults.removeObject(forKey: key)
        }
        return ErasureOutcome(report: report, fileResidue: residue)
    }

    /// Erase one person's derived record (their documents are not edited; see the report).
    public func erasePerson(_ entityID: UUID, reason: String, legalBasis: String?, actor: String) async throws -> ErasureOutcome {
        guard let db = database else { throw CaseErasureError.entityNotFound }
        _ = await StudioStorage.flushAll()
        let report = try await CaseEraser(database: db).erasePerson(entityID: entityID, reason: reason, legalBasis: legalBasis, actor: actor)
        return ErasureOutcome(report: report, fileResidue: [])
    }

    // MARK: - A5 — resumable file steps of a case erasure

    nonisolated static func caseEraseRecordURL(besideLedgerAt ledgerURL: URL, caseID: UUID) -> URL {
        ledgerURL.deletingLastPathComponent().appendingPathComponent(".case-erase-\(caseID.uuidString).json")
    }

    nonisolated static func writeCaseEraseRecord(_ url: URL, vault: [String], dropVectorCache: Bool) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["vault": vault, "dropVectorCache": dropVectorCache,
                                                                     "startedAt": Date().timeIntervalSince1970]) else { return }
        do { try data.write(to: url, options: .atomic) } catch {
            KalsmritikoshLog.app.error("Case-erase operation record not written: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Remove the recorded vault copies that no remaining source version uses (and the vector cache,
    /// when recorded), then drop the record — or keep it, naming what is left, for the next launch.
    nonisolated static func finishCaseEraseFiles(record: URL, ledgerURL: URL, database: Database, only: [String]? = nil) async -> [String] {
        guard let data = try? Data(contentsOf: record),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let recorded = (obj["vault"] as? [String]) ?? []
        let hashes = only.map { Set($0).intersection(recorded).union($0) }.map(Array.init) ?? recorded
        var left: [String] = []
        let vault = EvidenceVault(root: ledgerURL.deletingLastPathComponent().appendingPathComponent("EvidenceVault", isDirectory: true))
        for hash in hashes {
            // Never remove a copy a remaining version still uses.
            let used = (try? await database.query("SELECT 1 FROM source_versions WHERE lower(content_hash) = lower(?) LIMIT 1;", [.text(hash)]).first) != nil
            guard !used, await vault.contains(hash) else { continue }
            do { try await vault.remove(hash) } catch {
                KalsmritikoshLog.app.error("Case erasure: vault copy not removed: \(error.localizedDescription, privacy: .public)")
            }
            if await vault.contains(hash) { left.append("vault copy \(hash.prefix(12))…") }
        }
        if (obj["dropVectorCache"] as? Bool) == true { left += dropVectorCache(besideLedgerAt: ledgerURL) }
        if left.isEmpty { try? FileManager.default.removeItem(at: record) }
        return left
    }

    /// At launch, after the ledger opens: finish any case erasure whose file steps were interrupted.
    nonisolated static func resumePendingCaseErasures(besideLedgerAt ledgerURL: URL, database: Database) async {
        let dir = ledgerURL.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where name.hasPrefix(".case-erase-") && name.hasSuffix(".json") {
            let record = dir.appendingPathComponent(name)
            // The case still existing means its erase never committed: nothing to finish.
            let caseID = String(name.dropFirst(".case-erase-".count).dropLast(".json".count))
            if (try? await database.query("SELECT 1 FROM investigation_cases WHERE id = ? OR id = ? LIMIT 1;", [.text(caseID), .text(caseID.lowercased())]).first) != nil {
                try? FileManager.default.removeItem(at: record); continue
            }
            let left = await finishCaseEraseFiles(record: record, ledgerURL: ledgerURL, database: database)
            if !left.isEmpty { KalsmritikoshLog.app.error("Case erasure files still pending: \(left.joined(separator: ", "), privacy: .public)") }
        }
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

    // MARK: - K5 — case report export re-authorisation

    /// The check a case report export runs immediately before writing: the findings are this case's,
    /// the scope is unchanged and the receipt intact (`requireCurrent`), and every source the findings
    /// use is still cleared for export (a source labelled privileged, or above export sensitivity,
    /// since the build stops the export).
    public func findingsExportCheck() -> (@Sendable (InvestigationFindings) async throws -> Void)? {
        guard let findings = investigationFindings, let dataLab = investigationDataLab, let cases = investigationCases else { return nil }
        return { f in
            try await findings.requireCurrent(f, caseID: f.caseID)
            guard let record = try await cases.fetch(caseID: f.caseID) else { throw InvestigationFindingsError.caseNotFound(f.caseID) }
            let access = SensitiveAccessContext(scope: SensitiveScope(
                workspaceID: record.caseHeader.workspaceID, maximumSensitivity: .restricted,
                permitsPrivilegedMaterial: false, purpose: .export))
            let (included, _) = try await dataLab.eligibleSourceVersions(caseID: f.caseID, access: access)
            let withdrawn = Set(f.authorizedSourceVersionIDs).subtracting(included)
            if !withdrawn.isEmpty { throw ReportExportRefusal.sourcesWithdrawn(withdrawn.count) }
        }
    }
}

extension AppState {
    /// A1/K5 — a job result is exported only while every source it cites is still cleared for export
    /// in its case (not privileged, not above export sensitivity, still in scope). Nil = clear to export.
    public func jobResultExportCheck(_ record: JobResultRecord) async -> String? {
        guard let dataLab = investigationDataLab, let cases = investigationCases, let objects else { return "the ledger is not open" }
        do {
            guard let c = try await cases.fetch(caseID: record.caseID) else { return "its case no longer exists" }
            let access = SensitiveAccessContext(scope: SensitiveScope(
                workspaceID: c.caseHeader.workspaceID, maximumSensitivity: .restricted,
                permitsPrivilegedMaterial: false, purpose: .export))
            let (included, _) = try await dataLab.eligibleSourceVersions(caseID: record.caseID, access: access)
            let versions = Set(included)
            let objectsOK = Set(try await objects.objectIDs(inSourceVersionIDs: versions))
            let refs = record.content.rows.flatMap(\.refs)
            let withdrawn = refs.filter { ref in
                if let v = ref.sourceVersionID { return !versions.contains(v) }
                if let o = ref.objectID { return !objectsOK.contains(o) }
                return false
            }.count
            return withdrawn == 0 ? nil : "\(withdrawn) cited source(s) are no longer cleared for export (privileged, above export sensitivity, or out of the case)."
        } catch { return "the sources could not be re-checked (\(error.localizedDescription))" }
    }
}

/// K5 — why a case report was not exported.
public nonisolated enum ReportExportRefusal: Error, Equatable, LocalizedError {
    case sourcesWithdrawn(Int)
    public var errorDescription: String? {
        switch self {
        case .sourcesWithdrawn(let n):
            return "\(n) source(s) these findings use are no longer cleared for export (privileged, or above export sensitivity)."
        }
    }
}
