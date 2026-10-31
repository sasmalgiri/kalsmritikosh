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
        // A4/B1 — writers are flushed (pending saves are kept and written), never discarded, before the
        // erase decides. A change for this case (or for no case yet) that would not save stops the
        // erase before anything is deleted; a refused erase leaves every studio as it was.
        guard await StudioStorage.flushAll(forCase: caseID, in: db) else {
            throw CaseErasureError.preparationFailed("a studio change that may belong to this case has not been saved. Choose Retry in that studio, then erase again")
        }
        // A5/B1 — the files this erase may remove are recorded BEFORE the ledger commits, so a crash
        // between the commit and the file removal is finished at the next launch. Without that plan
        // (unreadable candidates, unwritable record) nothing is deleted.
        let ledgerURL = db.url
        let record = Self.caseEraseRecordURL(besideLedgerAt: ledgerURL, caseID: caseID)
        let candidates: [String]
        do {
            candidates = eraseExclusiveSources ? try await CaseEraser(database: db).vaultCandidates(sourceVersionIDs: Set(versions)) : []
            try Self.writeCaseEraseRecord(record, vault: candidates, dropVectorCache: eraseExclusiveSources)
        } catch {
            KalsmritikoshLog.app.error("Case erasure not started, plan not saved: \(error.localizedDescription, privacy: .public)")
            throw CaseErasureError.preparationFailed("its file plan could not be saved (\(error.localizedDescription))")
        }
        let report: CaseErasureReport
        do {
            report = try await CaseEraser(database: db).erase(caseID: caseID, sourceVersionIDs: Set(versions),
                                                         eraseExclusiveSources: eraseExclusiveSources,
                                                         reason: reason, legalBasis: legalBasis, actor: actor)
        } catch {
            // The erase rolled back; the plan is dropped only when the case is known to still exist
            // (else the next launch decides, from the ledger, whether there is anything to finish).
            if await Self.caseExists(caseID.uuidString, in: db) == true { try? FileManager.default.removeItem(at: record) }
            throw error
        }
        guard report.refused == nil else {
            try? FileManager.default.removeItem(at: record)
            return ErasureOutcome(report: report, fileResidue: [])
        }
        await StudioStorage.invalidate(forErasedCase: caseID)
        let residue = await Self.finishCaseEraseFiles(record: record, ledgerURL: ledgerURL, database: db,
                                                      only: report.vaultAddresses, dropCache: report.sourcesErased > 0)
        if report.sourcesErased > 0, let hnsw = hnswIndex, let vectors = vectorStore {
            // The live index still held the erased chunks' vectors: rebuild it from the ledger.
            _ = await hnsw.build(from: vectors)
        }
        pendingErasureWork[caseID.uuidString] = residue.isEmpty ? nil : residue
        let defaults = Self.erasePreferences
        for key in defaults.dictionaryRepresentation().keys where key.contains(caseID.uuidString) || key.contains(caseID.uuidString.lowercased()) {
            defaults.removeObject(forKey: key)
        }
        return ErasureOutcome(report: report, fileResidue: residue)
    }

    /// Erase one person's derived record (their documents are not edited; see the report).
    public func erasePerson(_ entityID: UUID, reason: String, legalBasis: String?, actor: String) async throws -> ErasureOutcome {
        guard let db = database else { throw CaseErasureError.entityNotFound }
        guard await StudioStorage.flushAll(forCase: nil, in: db) else {
            throw CaseErasureError.preparationFailed("a studio change has not been saved. Choose Retry in that studio, then erase again")
        }
        let report = try await CaseEraser(database: db).erasePerson(entityID: entityID, reason: reason, legalBasis: legalBasis, actor: actor)
        return ErasureOutcome(report: report, fileResidue: [])
    }

    // MARK: - A5 — resumable file steps of a case erasure

    nonisolated static func caseEraseRecordURL(besideLedgerAt ledgerURL: URL, caseID: UUID) -> URL {
        ledgerURL.deletingLastPathComponent().appendingPathComponent(".case-erase-\(caseID.uuidString).json")
    }

    /// B1 — throws when the plan cannot be made durable; the caller then deletes nothing.
    nonisolated static func writeCaseEraseRecord(_ url: URL, vault: [String], dropVectorCache: Bool) throws {
        let data = try JSONSerialization.data(withJSONObject: ["vault": vault, "dropVectorCache": dropVectorCache,
                                                               "startedAt": Date().timeIntervalSince1970])
        try data.write(to: url, options: .atomic)
    }

    /// Remove the recorded vault copies that no remaining source version uses (and the vector cache,
    /// when recorded and asked), then drop the record — or keep it, naming what is left, for the next
    /// launch. B1: an unreadable record and an unanswerable "is this copy still used?" are unfinished
    /// work, never success; the file and the record are kept.
    nonisolated static func finishCaseEraseFiles(record: URL, ledgerURL: URL, database: Database, only: [String]? = nil,
                                                 dropCache: Bool = true,
                                                 isUsed: (@Sendable (String) async throws -> Bool)? = nil) async -> [String] {
        let obj: [String: Any]
        do {
            let data = try Data(contentsOf: record)
            guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            obj = o
        } catch {
            KalsmritikoshLog.app.error("Case-erase operation record unreadable: \(error.localizedDescription, privacy: .public)")
            return ["the file steps of an erasure (\(record.lastPathComponent)) could not be read; the record is kept and nothing was removed"]
        }
        let recorded = (obj["vault"] as? [String]) ?? []
        let hashes = only.map { Set($0).intersection(recorded).union($0) }.map(Array.init) ?? recorded
        var left: [String] = []
        let vault = EvidenceVault(root: ledgerURL.deletingLastPathComponent().appendingPathComponent("EvidenceVault", isDirectory: true))
        for hash in hashes.sorted() {
            // Never remove a copy a remaining version still uses — nor one whose use cannot be checked.
            let used: Bool
            do {
                if let isUsed { used = try await isUsed(hash) } else {
                    used = try await database.query("SELECT 1 FROM source_versions WHERE lower(content_hash) = lower(?) LIMIT 1;", [.text(hash)]).first != nil
                }
            } catch {
                KalsmritikoshLog.app.error("Case erasure: shared-use check failed, copy kept: \(error.localizedDescription, privacy: .public)")
                left.append("vault copy \(hash.prefix(12))… (kept: could not check whether another document uses it)")
                continue
            }
            guard !used, await vault.contains(hash) else { continue }
            do { try await vault.remove(hash) } catch {
                KalsmritikoshLog.app.error("Case erasure: vault copy not removed: \(error.localizedDescription, privacy: .public)")
            }
            if await vault.contains(hash) { left.append("vault copy \(hash.prefix(12))…") }
        }
        if dropCache, (obj["dropVectorCache"] as? Bool) == true { left += dropVectorCache(besideLedgerAt: ledgerURL) }
        if left.isEmpty {
            do { try FileManager.default.removeItem(at: record) } catch {
                KalsmritikoshLog.app.error("Case-erase record not removed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return left
    }

    /// Whether a case row exists; nil when the ledger could not answer.
    nonisolated static func caseExists(_ caseID: String, in database: Database) async -> Bool? {
        do {
            return try await database.query("SELECT 1 FROM investigation_cases WHERE id = ? OR id = ? LIMIT 1;",
                                            [.text(caseID), .text(caseID.lowercased())]).first != nil
        } catch {
            KalsmritikoshLog.app.error("Case-existence check failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// At launch, after the ledger opens: finish any case erasure whose file steps were interrupted.
    /// Returns the unfinished work per case (shown in Settings and retried at the next launch).
    @discardableResult
    nonisolated static func resumePendingCaseErasures(besideLedgerAt ledgerURL: URL, database: Database) async -> [String: [String]] {
        let dir = ledgerURL.deletingLastPathComponent()
        var pending: [String: [String]] = [:]
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: dir.path) } catch {
            KalsmritikoshLog.app.error("Erasure records not listed: \(error.localizedDescription, privacy: .public)")
            return ["?": ["the folder holding unfinished erasures could not be read"]]
        }
        for name in names where name.hasPrefix(".case-erase-") && name.hasSuffix(".json") {
            let record = dir.appendingPathComponent(name)
            let caseID = String(name.dropFirst(".case-erase-".count).dropLast(".json".count))
            switch await caseExists(caseID, in: database) {
            case .some(true):
                // The case still exists: its erase never committed, so there is nothing to finish.
                try? FileManager.default.removeItem(at: record)
            case .none:
                // Unknown: keep the record and every file; retried next launch.
                pending[caseID] = ["could not check whether this erasure finished; its files are kept"]
            case .some(false):
                let left = await finishCaseEraseFiles(record: record, ledgerURL: ledgerURL, database: database)
                if !left.isEmpty {
                    pending[caseID] = left
                    KalsmritikoshLog.app.error("Case erasure files still pending: \(left.joined(separator: ", "), privacy: .public)")
                }
            }
        }
        return pending
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
    /// B2 — the cited sources of `refs` that do not resolve in the case for `purpose` (not in its
    /// current scope, privileged, or above the purpose's sensitivity). One rule for completion and export.
    public func unresolvedJobRefs(caseID: UUID, refs: [StudioEvidenceRef], purpose: SensitiveUsePurpose = .export) async throws -> [StudioEvidenceRef] {
        guard let dataLab = investigationDataLab, let cases = investigationCases, let objects else { throw JobResultError.caseGone }
        guard let c = try await cases.fetch(caseID: caseID) else { throw JobResultError.caseGone }
        let access = SensitiveAccessContext(scope: SensitiveScope(
            workspaceID: c.caseHeader.workspaceID, maximumSensitivity: .restricted,
            permitsPrivilegedMaterial: false, purpose: purpose))
        let (included, _) = try await dataLab.eligibleSourceVersions(caseID: caseID, access: access)
        let versions = Set(included)
        let objectsOK = Set(try await objects.objectIDs(inSourceVersionIDs: versions))
        return refs.filter { ref in
            if let v = ref.sourceVersionID, !versions.contains(v) { return true }
            if let o = ref.objectID, !objectsOK.contains(o) { return true }
            return false
        }
    }

    /// The completion check the review save runs (B2).
    public func jobResultEvidenceCheck(caseID: UUID) -> JobResultRepository.EvidenceCheck {
        { [weak self] refs in
            guard let self else { throw JobResultError.caseGone }
            return try await self.unresolvedJobRefs(caseID: caseID, refs: refs)
        }
    }

    /// A1/K5 — a job result is exported only while every source it cites is still cleared for export
    /// in its case (not privileged, not above export sensitivity, still in scope). Nil = clear to export.
    public func jobResultExportCheck(_ record: JobResultRecord) async -> String? {
        do {
            let withdrawn = try await unresolvedJobRefs(caseID: record.caseID, refs: record.content.rows.flatMap(\.refs)).count
            return withdrawn == 0 ? nil : "\(withdrawn) cited source(s) are no longer cleared for export (privileged, above export sensitivity, or out of the case)."
        } catch JobResultError.caseGone { return "its case no longer exists" }
        catch { return "the sources could not be re-checked (\(error.localizedDescription))" }
    }

    /// B2 — the one export path for a job result, run AFTER the destination is chosen: the revision
    /// must still be the case's current one, every cited source is re-checked immediately before the
    /// write, the text is rendered once, written, read back and only then recorded with its digest.
    public func exportJobResult(_ record: JobResultRecord, title: String, to url: URL, actor: String) async throws -> JobResultRepository.ExportReceipt {
        guard let db = database else { throw JobResultError.caseGone }
        let repo = JobResultRepository(database: db)
        guard try await repo.latest(caseID: record.caseID, jobID: record.jobID)?.id == record.id else { throw JobResultReviewError.notCurrent }
        if let why = await jobResultExportCheck(record) { throw JobResultExportError.sourcesWithdrawn(why) }
        // Release-block directive item 1 — a protected source's name (jrn.source-vault) never appears
        // in an export: scrubbed from the rendered text and verified gone; a name that survives stops
        // the export (nothing is written).
        let protected = try await repo.protectedIdentityNames()
        let scrubbed = ProtectedIdentities.scrub(JobResultMarkdown.render(record, title: title), names: protected)
        guard scrubbed.leaks.isEmpty else {
            throw JobResultExportError.sourcesWithdrawn("\(scrubbed.leaks.count) protected source identity(ies) would remain recoverable in the file; nothing was written")
        }
        let text = scrubbed.text
        try Data(text.utf8).write(to: url, options: .atomic)
        return try await repo.recordExport(resultID: record.id, caseID: record.caseID, jobID: record.jobID, text: text, file: url, actor: actor)
    }
}

extension AppState {
    /// B3 — a method job's completion saves each accepted method as an actual MethodRun in the case
    /// (the shared method engine): its evidence is the case documents the person named as inputs
    /// (exact source versions), its steps and outcome are the person's worksheet. A row that already
    /// has a run reuses it (a failed or retried completion never makes a second run). Returns the run
    /// id per row index; a method the engine refuses, or inputs that name no case document, is
    /// reported, never silently skipped.
    public func startMethodRuns(caseID: UUID, rows: [JobResultRow], actor: String) async -> (runs: [Int: UUID], problems: [String]) {
        guard let methods = investigationMethods, let answers = investigationAnswers else { return ([:], ["The method engine is not available."]) }
        var runs: [Int: UUID] = [:], problems: [String] = []
        let versions = (try? await answers.scopeContext(caseID: caseID).scope.authorizedSourceVersionIDs) ?? []
        // Each authorised version's document name, to resolve the inputs the person named.
        var names: [UUID: String] = [:]
        for v in versions {
            if let n = try? await database?.query("SELECT f.url FROM source_versions sv JOIN files f ON f.id = sv.logical_source_id WHERE sv.id = ?;", [.uuid(v)]).first?.string(0) {
                names[v] = (URL(string: n)?.lastPathComponent ?? (n as NSString).lastPathComponent).removingPercentEncoding ?? n
            }
        }
        for (i, row) in rows.enumerated() where row.decision == .accepted {
            guard let methodID = row.fields?["methodID"] else { continue }
            let inputs = row.fields?["inputs"] ?? ""
            let chosen = names.filter { !$0.value.isEmpty && inputs.localizedCaseInsensitiveContains($0.value) }.keys.sorted { $0.uuidString < $1.uuidString }
            guard !chosen.isEmpty else {
                problems.append("\(row.title): name at least one of the case's documents under Inputs selected"); continue
            }
            let steps = (row.fields?["steps"] ?? "").split(whereSeparator: { $0 == "\n" || $0 == ";" })
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            do {
                let runID: UUID
                if let existing = row.fields?["run"].flatMap(UUID.init(uuidString:)) { runID = existing } else {
                    let specs = chosen.enumerated().map { InvestigationMethodEvidenceSpec(targetKind: .sourceVersion, targetID: $0.element, ordinal: $0.offset) }
                    runID = try await methods.startMethod(caseID: caseID, methodDefinitionID: methodID, evidenceSpecs: specs,
                                                          createdBy: actor, now: Date()).run.id
                }
                runs[i] = runID
                _ = try await methods.recordWorksheet(caseID: caseID, runID: runID, steps: steps, outcome: row.fields?["outcome"] ?? "inconclusive",
                                                      inputs: inputs, actor: actor, now: Date())
            } catch { problems.append("\(row.title): \(error.localizedDescription)") }
        }
        return (runs, problems)
    }
}

extension AppState {
    /// B3 — check one produced file for the case's protected identifiers (its own bytes: hash, PDF
    /// text layer, metadata, annotations, OCR of image pages). Returns the result row to add.
    public func checkProducedFile(caseID: UUID, at url: URL) async throws -> JobResultRow {
        guard let service = personaJobs, let cases = investigationCases,
              let c = try await cases.fetch(caseID: caseID) else { throw JobResultError.caseGone }
        let access = SensitiveAccessContext(scope: SensitiveScope(workspaceID: c.caseHeader.workspaceID, maximumSensitivity: .restricted,
                                                                  permitsPrivilegedMaterial: false, purpose: .export))
        guard let evidence = try await service.evidence(caseID: caseID, access: access) else { throw JobResultError.caseGone }
        let terms = RedactionValidationExecutor.protectedTerms(evidence)
        let check = try await Task.detached { try ProducedFileRedactionCheck.check(fileAt: url, protectedTerms: terms) }.value
        var row = RedactionValidationExecutor.row(for: check, terms: terms.count)
        row.sourced = row.generatedValues
        return row
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
