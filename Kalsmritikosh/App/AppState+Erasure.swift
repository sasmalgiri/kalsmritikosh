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
        /// SEC-07 — when the erasure was made (seconds since 1970), and the backups this Mac recorded before it.
        public var erasedAt: Double = 0
        public var backupsBefore: [BackupLog.Entry] = []
        /// Set when the list of backups could not be read (the backups are then not named, and that is said).
        public var backupListProblem: String? = nil
        /// Deep dive 2 (#6) — the other copy of this ledger (this Mac's copy, or the copy on the disk the ledger was moved to).
        public var otherLedgerCopies: [String] = []
        public var summary: String {
            if let refused = report.refused { return refused }
            return ([coreSummary] + outsideCopiesLines).joined(separator: " ")
        }

        /// SEC-07 — what the erasure cannot reach, said plainly: backups made before it, files already exported, other
        /// cases' references to an erased case.
        public var outsideCopiesLines: [String] {
            guard report.refused == nil else { return [] }
            var lines: [String] = []
            lines.append("Backups made before this erasure still hold what was erased until they are deleted. If one is restored on this Mac, the erasure is applied again before the ledger is shown; restored on another Mac, it is not.")
            if !backupsBefore.isEmpty {
                lines.append("Backups this Mac made before it: \(backupsBefore.map(BackupLog.line).joined(separator: "; ")). You can delete them with “Delete backups made before this erasure”; nothing is deleted unless you choose it.")
            }
            if let backupListProblem { lines.append(backupListProblem) }
            if !otherLedgerCopies.isEmpty {
                lines.append("Another copy of this ledger is kept at \(otherLedgerCopies.joined(separator: "; ")). It still holds what was erased until it is opened on this Mac: the erasure is then applied to it before it is shown. Opened on another Mac, it is not.")
            }
            if !report.exportsOutside.isEmpty {
                let isCase = report.rowsErased["investigation_cases"] != nil
                let whose = isCase ? "this case" : "the cases this person is part of (they may name them)"
                lines.append("Exported from \(whose) before the erasure, outside the app and not erased: \(report.exportsOutside.map(\.line).joined(separator: "; ")). Delete those files yourself if they must go.")
            }
            if report.otherCaseReferences > 0 {
                lines.append("\(report.otherCaseReferences) reference(s) in other cases now read only “erased case”.")
            }
            if report.otherCaseFindingsKept > 0 {
                lines.append("\(report.otherCaseFindingsKept) review finding(s) in other cases about this case's records are kept: they are those cases' own work. Each case's own action log keeps the wording typed when a reference was added.")
            }
            return lines
        }

        private var coreSummary: String {
            var parts = ["Erased \(report.rowsErased.values.reduce(0, +)) record(s)."]
            if report.sourcesErased > 0 { parts.append("\(report.sourcesErased) document(s) used only by this case were erased.") }
            if report.sourcesKeptShared > 0 { parts.append("\(report.sourcesKeptShared) document(s) are kept because another case or workspace uses them.") }
            if report.sourcesKeptInLibrary > 0 { parts.append("\(report.sourcesKeptInLibrary) document(s) stay in your library; erase them from Sources to remove their content.") }
            if report.answersRemoved > 0 { parts.append("\(report.answersRemoved) saved answer(s) asked in this case or quoting the erased documents were removed.") }
            if report.documentsStillNaming > 0 { parts.append("\(report.documentsStillNaming) original document(s) still name this person; erase or redact them to remove the name.") }
            if !report.stillNamedIn.isEmpty {
                parts.append("Still naming them (not erased): " + report.stillNamedIn.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ") + ".")
            }
            if !fileResidue.isEmpty { parts.append("Not removed: \(fileResidue.joined(separator: ", ")).") }
            return parts.joined(separator: " ")
        }
    }

    // MARK: - SEC-07 — backups made before an erasure

    /// The backups this Mac recorded before `erasedAt`, or the problem to tell the person.
    nonisolated static func backupsBefore(_ erasedAt: Double, besideLedgerAt ledgerURL: URL,
                                          otherCopies: [URL] = []) -> (entries: [BackupLog.Entry], problem: String?) {
        do { return (try BackupLog.madeBefore(erasedAt, besideLedgerAt: ledgerURL, otherCopies: otherCopies), nil) } catch {
            KalsmritikoshLog.app.error("Backups before an erasure not listed: \(error.localizedDescription, privacy: .public)")
            return ([], "The list of backups this Mac made could not be read, so backups made before this erasure are not named here.")
        }
    }

    /// Record a backup folder this Mac just made (the list an erasure reads). Returns a problem for the person, or nil.
    @discardableResult
    public func recordBackup(folder: URL, kind: BackupLog.Kind, createdAt: Double) -> String? {
        guard let ledgerURL = database?.url else { return "The backup could not be added to this Mac's list of backups (the ledger is not open)." }
        return BackupLog.record(folder: folder, kind: kind, createdAt: createdAt, besideLedgerAt: ledgerURL)
    }

    /// SEC-07 — delete the backups this Mac recorded before an erasure. Runs only when the person chooses it.
    public func deleteBackups(madeBefore erasedAt: Double) -> BackupLog.DeletionResult {
        guard let ledgerURL = database?.url else {
            var r = BackupLog.DeletionResult()
            r.kept.append("the ledger is not open, so nothing was deleted")
            return r
        }
        return BackupLog.deleteBackups(madeBefore: erasedAt, besideLedgerAt: ledgerURL, otherCopies: LedgerRelocation.otherCopies(of: ledgerURL))
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
        // Deep dive 2 (#10) — the erasure's own time: the date the ledger records for it, decided before it runs (not after
        // the file steps), so a backup made while the file steps ran is never counted as made before it.
        let erasedDate = Date()
        let erasedAt = erasedDate.timeIntervalSince1970
        let candidates: [String]
        do {
            candidates = eraseExclusiveSources ? try await CaseEraser(database: db).vaultCandidates(sourceVersionIDs: Set(versions)) : []
            // Deep dive 2 (#4) — the plan also says this erasure goes on the register, so a crash between the ledger commit
            // and the register write is finished at the next launch (`resumePendingCaseErasures`).
            try Self.writeCaseEraseRecord(record, vault: candidates, dropVectorCache: eraseExclusiveSources,
                                          register: .init(erasedAt: erasedAt, eraseSources: eraseExclusiveSources))
        } catch {
            KalsmritikoshLog.app.error("Case erasure not started, plan not saved: \(error.localizedDescription, privacy: .public)")
            throw CaseErasureError.preparationFailed("its file plan could not be saved (\(error.localizedDescription))")
        }
        let report: CaseErasureReport
        do {
            report = try await CaseEraser(database: db).erase(caseID: caseID, sourceVersionIDs: Set(versions),
                                                         eraseExclusiveSources: eraseExclusiveSources,
                                                         reason: reason, legalBasis: legalBasis, actor: actor, at: erasedDate)
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
        // RECOVERY-06 — remembered outside the ledger, so a restored older backup cannot bring it back. Written right after
        // the commit and before the file steps (whose success removes the plan the next launch would finish it from).
        var residue: [String] = []
        let otherCopies = LedgerRelocation.otherCopies(of: ledgerURL)
        let registerProblem = ErasureRegister.recordReporting(.init(kind: .case, idHash: ErasureRegister.hash(caseID), eraseSources: eraseExclusiveSources,
                                                                    erasedAt: erasedAt), besideLedgerAt: ledgerURL, otherCopies: otherCopies)
        if let registerProblem { residue.append(registerProblem) }
        residue += await Self.finishCaseEraseFiles(record: record, ledgerURL: ledgerURL, database: db,
                                                   only: report.vaultAddresses, dropCache: report.sourcesErased > 0)
        if registerProblem != nil { Self.keepRegisterPlan(record, erasedAt: erasedAt, eraseSources: eraseExclusiveSources) }
        // SEC-07 / TEAM-08 — the case's reminders (pending and already shown) go with it.
        await CaseReminders.remove(caseID: caseID)
        // SEC-07 — erased documents leave macOS's Spotlight index too (S14).
        if report.sourcesErased > 0 { await refreshSpotlightAfterErasure() }
        if report.sourcesErased > 0, let hnsw = hnswIndex, let vectors = vectorStore {
            // The live index still held the erased chunks' vectors: rebuild it from the ledger.
            _ = await hnsw.build(from: vectors)
        }
        pendingErasureWork[caseID.uuidString] = residue.isEmpty ? nil : residue
        // LS4 — the case's AI permission ends with the case (also covered by the sweep below in the app).
        if !TestHost.isActive { CaseReadPermissionStore.live.withdraw(caseID: caseID) }
        let defaults = Self.erasePreferences
        for key in defaults.dictionaryRepresentation().keys where key.contains(caseID.uuidString) || key.contains(caseID.uuidString.lowercased()) {
            defaults.removeObject(forKey: key)
        }
        // SEC-07 — the backups made before this erasure are named in the receipt (never deleted here).
        let backups = Self.backupsBefore(erasedAt, besideLedgerAt: ledgerURL, otherCopies: otherCopies)
        return ErasureOutcome(report: report, fileResidue: residue, erasedAt: erasedAt, backupsBefore: backups.entries, backupListProblem: backups.problem,
                              otherLedgerCopies: otherCopies.map(\.path))
    }

    /// Erase one person's derived record (their documents are not edited; see the report).
    public func erasePerson(_ entityID: UUID, reason: String, legalBasis: String?, actor: String) async throws -> ErasureOutcome {
        guard let db = database else { throw CaseErasureError.entityNotFound }
        guard await StudioStorage.flushAll(forCase: nil, in: db) else {
            throw CaseErasureError.preparationFailed("a studio change has not been saved. Choose Retry in that studio, then erase again")
        }
        // Deep dive 2 (#10) — the erasure's own time, decided before it runs (the date the ledger records for it).
        let erasedDate = Date()
        let erasedAt = erasedDate.timeIntervalSince1970
        // Deep dive 2 (#4) — a plan beside the ledger, so a crash between the ledger commit and the register write is
        // finished at the next launch. Without it nothing is erased (B1).
        let plan = Self.personEraseRecordURL(besideLedgerAt: db.url, entityID: entityID)
        do { try Self.writePersonEraseRecord(plan, erasedAt: erasedAt) } catch {
            KalsmritikoshLog.app.error("Person erasure not started, plan not saved: \(error.localizedDescription, privacy: .public)")
            throw CaseErasureError.preparationFailed("its plan could not be saved (\(error.localizedDescription))")
        }
        let report: CaseErasureReport
        do {
            report = try await CaseEraser(database: db).erasePerson(entityID: entityID, reason: reason, legalBasis: legalBasis, actor: actor, at: erasedDate)
        } catch {
            // Not erased (blank reason, or the person is not in the ledger): the plan goes when the person is known to be there
            // or known to be absent; when the ledger cannot answer, the next launch decides.
            if await Self.entityExists(entityID.uuidString, in: db) != nil { Self.removePlan(plan) }
            throw error
        }
        guard report.refused == nil else {
            Self.removePlan(plan)
            return ErasureOutcome(report: report, fileResidue: [])
        }
        var residue: [String] = []
        let otherCopies = LedgerRelocation.otherCopies(of: db.url)
        if let left = ErasureRegister.recordReporting(.init(kind: .person, idHash: ErasureRegister.hash(entityID), eraseSources: nil,
                                                              erasedAt: erasedAt), besideLedgerAt: db.url, otherCopies: otherCopies) {
            residue.append(left)
        } else {
            Self.removePlan(plan)
        }
        // Reminders never name anyone now; any an older build wrote with task and case titles are removed.
        await CaseReminders.removeNamingReminders()
        let backups = Self.backupsBefore(erasedAt, besideLedgerAt: db.url, otherCopies: otherCopies)
        return ErasureOutcome(report: report, fileResidue: residue, erasedAt: erasedAt, backupsBefore: backups.entries, backupListProblem: backups.problem,
                              otherLedgerCopies: otherCopies.map(\.path))
    }

    // MARK: - RECOVERY-06 — the erasure register, applied whenever the ledger opens

    /// What one application of the register did.
    struct RegisterPass: Sendable, Equatable {
        var erased = 0
        /// Re-erased cases that also erased documents (Spotlight and the live vector index follow).
        var documentsErased = 0
        var problems: [String] = []
        var unreadable = false

        mutating func absorb(_ other: RegisterPass) {
            erased += other.erased
            documentsErased += other.documentsErased
            problems += other.problems
            unreadable = unreadable || other.unreadable
        }

        var note: String? {
            if unreadable {
                return "The erasure register beside your ledger could not be read, so it was not checked whether a restored backup brought back something you erased."
            }
            guard erased > 0 || !problems.isEmpty else { return nil }
            var note = erased > 0 ? "\(erased) case(s) or person(s) you had erased came back with a restored backup and were erased again." : ""
            if !problems.isEmpty { note += (note.isEmpty ? "" : " ") + "Not erased again: " + problems.joined(separator: "; ") + "." }
            return note
        }
    }

    /// SEC-07 / RECOVERY-06 — the ledger-level pass of the register, run at boot right after the ledger is migrated and
    /// BEFORE any background worker, index or screen reads it: every case and person on the register is erased again
    /// through the same erasure (legal holds still refuse, and a refusal is reported), with the same file steps.
    nonisolated static func reapplyErasureRegister(database db: Database, otherCopies: [URL] = []) async -> RegisterPass {
        var pass = RegisterPass()
        // Deep dive 2 (#6) — the register beside the other copy of this ledger (this Mac's copy, or the disk copy) is merged
        // in first: an erasure made while that copy was open is applied to this one too.
        pass.problems += ErasureRegister.adoptOtherCopies(besideLedgerAt: db.url, otherCopies: otherCopies)
        let register: ErasureRegister.Register
        do { register = try ErasureRegister.load(besideLedgerAt: db.url) } catch {
            KalsmritikoshLog.app.error("Erasure register unreadable at open: \(error.localizedDescription, privacy: .public)")
            pass.unreadable = true
            return pass
        }
        guard register.entries.contains(where: { $0.kind != .full }) else { return pass }
        let reason = "Erased earlier; it came back with an older backup and is erased again (erasure register)"
        let actor = "Erasure register"
        // Deep dive 2 (#8) — one entry that fails is logged and reported; the others are still erased again.
        let caseIDs: [UUID]
        do {
            caseIDs = try await db.query("SELECT id FROM investigation_cases;", []).compactMap { $0.string(0).flatMap(UUID.init(uuidString:)) }
        } catch {
            KalsmritikoshLog.app.error("Erasure register: cases not listed: \(error.localizedDescription, privacy: .public)")
            pass.problems.append(error.localizedDescription)
            caseIDs = []
        }
        let caseRepo = InvestigationCaseRepository(database: db)
        let resolver = CaseRetrievalScopeResolver(evidence: EvidenceStore(database: db))
        for (id, entry) in ErasureRegister.matches(caseIDs, kind: .case, in: register) {
            do {
                guard let record = try await caseRepo.fetch(caseID: id) else { continue }
                let versions = try await resolver.scope(for: record).authorizedSourceVersionIDs
                let one = await reEraseCase(id, versions: Set(versions), eraseSources: entry.eraseSources ?? false, reason: reason, actor: actor, database: db)
                pass.absorb(one)
            } catch {
                KalsmritikoshLog.app.error("Erasure register: a case not erased again: \(error.localizedDescription, privacy: .public)")
                pass.problems.append(error.localizedDescription)
            }
        }
        if register.entries.contains(where: { $0.kind == .person }) {
            let people: [UUID]
            do {
                people = try await db.query("SELECT id FROM entities;", []).compactMap { $0.string(0).flatMap(UUID.init(uuidString:)) }
            } catch {
                KalsmritikoshLog.app.error("Erasure register: people not listed: \(error.localizedDescription, privacy: .public)")
                pass.problems.append(error.localizedDescription)
                people = []
            }
            for (id, _) in ErasureRegister.matches(people, kind: .person, in: register) {
                do {
                    let report = try await CaseEraser(database: db).erasePerson(entityID: id, reason: reason, legalBasis: nil, actor: actor)
                    if let refused = report.refused { pass.problems.append(refused) } else { pass.erased += 1 }
                } catch {
                    KalsmritikoshLog.app.error("Erasure register: a person not erased again: \(error.localizedDescription, privacy: .public)")
                    pass.problems.append(error.localizedDescription)
                }
            }
        }
        KalsmritikoshLog.app.notice("Erasure register applied at open: \(pass.erased, privacy: .public) re-erased, \(pass.problems.count, privacy: .public) problem(s)")
        return pass
    }

    /// One case on the register, erased again: the file plan first (B1), the ledger erase, the vault step, and the
    /// restored originals beside the ledger that the erase removed from the ledger.
    nonisolated static func reEraseCase(_ id: UUID, versions: Set<UUID>, eraseSources: Bool, reason: String, actor: String,
                                        database db: Database) async -> RegisterPass {
        var pass = RegisterPass()
        let record = caseEraseRecordURL(besideLedgerAt: db.url, caseID: id)
        do {
            let before = restoredFiles(try await db.query("SELECT url FROM files;", []), besideLedgerAt: db.url)
            let candidates = eraseSources ? try await CaseEraser(database: db).vaultCandidates(sourceVersionIDs: versions) : []
            // Deep dive 2 (#9) — a plan the first erasure left unfinished (its vault copies not yet removed) is kept: its list
            // joins this one, so the restored case's return does not drop it.
            let earlier = recordedVault(record)
            let erasedDate = Date()
            try writeCaseEraseRecord(record, vault: Array(Set(candidates + earlier)).sorted(), dropVectorCache: eraseSources,
                                     register: .init(erasedAt: erasedDate.timeIntervalSince1970, eraseSources: eraseSources))
            let report = try await CaseEraser(database: db).erase(caseID: id, sourceVersionIDs: versions, eraseExclusiveSources: eraseSources,
                                                                  reason: reason, legalBasis: nil, actor: actor, at: erasedDate)
            if let refused = report.refused {
                // Refused: the case and its versions stay (they use the copies), so there is nothing to finish.
                do { try FileManager.default.removeItem(at: record) } catch {
                    KalsmritikoshLog.app.error("Re-erase plan not removed after a refusal: \(error.localizedDescription, privacy: .public)")
                }
                pass.problems.append(refused)
                return pass
            }
            pass.erased = 1
            if report.sourcesErased > 0 { pass.documentsErased = 1 }
            pass.problems += await finishCaseEraseFiles(record: record, ledgerURL: db.url, database: db,
                                                        only: Array(Set(report.vaultAddresses + earlier)).sorted(),
                                                        dropCache: report.sourcesErased > 0)
            // A complete backup restores each original beside the ledger; one the erase removed from the ledger is
            // removed from disk too (only copies inside the ledger's folder).
            let after = restoredFiles(try await db.query("SELECT url FROM files;", []), besideLedgerAt: db.url)
            for url in before.subtracting(after) {
                do { try FileManager.default.removeItem(at: url) } catch {
                    KalsmritikoshLog.app.error("Restored original of an erased case not removed: \(error.localizedDescription, privacy: .public)")
                    pass.problems.append("a restored original file could not be removed")
                }
            }
        } catch {
            KalsmritikoshLog.app.error("Case on the erasure register not erased again: \(error.localizedDescription, privacy: .public)")
            pass.problems.append(error.localizedDescription)
        }
        return pass
    }

    /// Erase again every case and person in the ledger that the register says was erased (they came back with an older
    /// backup), then let the app's own stores follow (reminders, Spotlight, the live vector index). Merges the pass run at
    /// open (`registerPassAtOpen`). Returns a note for the person, or nil when nothing was on it.
    @discardableResult
    func applyErasureRegister() async -> String? {
        guard let db = database else { return nil }
        var pass = registerPassAtOpen ?? RegisterPass()
        registerPassAtOpen = nil
        pass.absorb(await Self.reapplyErasureRegister(database: db, otherCopies: LedgerRelocation.otherCopies(of: db.url)))
        if pass.erased > 0 {
            await CaseReminders.removeNamingReminders()
        }
        if pass.documentsErased > 0 {
            await refreshSpotlightAfterErasure()
            if let hnsw = hnswIndex, let vectors = vectorStore { _ = await hnsw.build(from: vectors) }
        }
        return pass.note
    }

    /// File URLs the ledger names that sit inside the ledger's own folder (originals a complete backup restored).
    nonisolated static func restoredFiles(_ rows: [SQLRow], besideLedgerAt ledgerURL: URL) -> Set<URL> {
        let dir = ledgerURL.deletingLastPathComponent().standardizedFileURL.path + "/"
        return Set(rows.compactMap { $0.string(0).flatMap(URL.init(string:)) }.filter { $0.isFileURL && $0.standardizedFileURL.path.hasPrefix(dir) }
                       .map(\.standardizedFileURL))
    }

    // MARK: - A5 — resumable file steps of a case erasure

    nonisolated static func caseEraseRecordURL(besideLedgerAt ledgerURL: URL, caseID: UUID) -> URL {
        ledgerURL.deletingLastPathComponent().appendingPathComponent(".case-erase-\(caseID.uuidString).json")
    }

    /// B1 — throws when the plan cannot be made durable; the caller then deletes nothing.
    /// `forgotten` (LS26): the file ids a "Stop and forget" removed; when present, a copy counts as used only
    /// when a source outside them, or a case, still uses it (see `forgottenFolderUsesCopy`).
    nonisolated static func writeCaseEraseRecord(_ url: URL, vault: [String], dropVectorCache: Bool, forgotten: [String] = [],
                                                 register: RegisterPlan? = nil) throws {
        var obj: [String: Any] = ["vault": vault, "dropVectorCache": dropVectorCache, "startedAt": Date().timeIntervalSince1970]
        if !forgotten.isEmpty { obj["forgotten"] = forgotten }
        if let register {
            obj["register"] = true
            obj["erasedAt"] = register.erasedAt
            if let sources = register.eraseSources { obj["eraseSources"] = sources }
        }
        let data = try JSONSerialization.data(withJSONObject: obj)
        try data.write(to: url, options: .atomic)
    }

    /// Deep dive 2 (#4) — what a plan says about the erasure register: the erasure's time and (cases) whether its documents
    /// went too. A plan with it is a case or person erasure the next launch adds to the register once the ledger shows it done.
    struct RegisterPlan: Sendable, Equatable {
        var erasedAt: Double
        var eraseSources: Bool?
    }

    /// The plan's recorded file data, or nil when it is missing or unreadable.
    nonisolated static func readPlan(_ url: URL) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] } catch {
            KalsmritikoshLog.app.error("Erasure plan unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The vault copies an earlier plan for the same case still lists (empty when there is none).
    nonisolated static func recordedVault(_ url: URL) -> [String] { (readPlan(url)?["vault"] as? [String]) ?? [] }

    /// The register part of a plan, when it has one.
    nonisolated static func registerPlan(_ obj: [String: Any]) -> RegisterPlan? {
        guard (obj["register"] as? Bool) == true else { return nil }
        let at = (obj["erasedAt"] as? Double) ?? (obj["startedAt"] as? Double) ?? Date().timeIntervalSince1970
        return RegisterPlan(erasedAt: at, eraseSources: obj["eraseSources"] as? Bool)
    }

    /// The register write failed after the erase committed: a plan is kept (even once the file steps are done) so the next
    /// launch writes the register entry.
    nonisolated static func keepRegisterPlan(_ record: URL, erasedAt: Double, eraseSources: Bool) {
        var obj = readPlan(record) ?? ["vault": [String](), "dropVectorCache": false, "startedAt": Date().timeIntervalSince1970]
        obj["register"] = true
        obj["erasedAt"] = erasedAt
        obj["eraseSources"] = eraseSources
        do {
            try JSONSerialization.data(withJSONObject: obj).write(to: record, options: .atomic)
        } catch {
            KalsmritikoshLog.app.error("Erasure register retry not planned: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated static func personEraseRecordURL(besideLedgerAt ledgerURL: URL, entityID: UUID) -> URL {
        ledgerURL.deletingLastPathComponent().appendingPathComponent(".person-erase-\(entityID.uuidString).json")
    }

    /// B1 — throws when the plan cannot be made durable; the caller then erases nothing.
    nonisolated static func writePersonEraseRecord(_ url: URL, erasedAt: Double) throws {
        let obj: [String: Any] = ["register": true, "erasedAt": erasedAt, "startedAt": Date().timeIntervalSince1970]
        try JSONSerialization.data(withJSONObject: obj).write(to: url, options: .atomic)
    }

    nonisolated static func removePlan(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { try FileManager.default.removeItem(at: url) } catch {
            KalsmritikoshLog.app.error("Erasure plan not removed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Whether an entity row exists; nil when the ledger could not answer.
    nonisolated static func entityExists(_ entityID: String, in database: Database) async -> Bool? {
        do {
            return try await database.query("SELECT 1 FROM entities WHERE id = ? OR id = ? LIMIT 1;",
                                            [.text(entityID.uppercased()), .text(entityID.lowercased())]).first != nil
        } catch {
            KalsmritikoshLog.app.error("Entity-existence check failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// What one run of the vault file step did: copies removed (with their opened copies), copies kept
    /// because something still uses them, and what is left to finish (named for the person).
    public struct VaultFileStep: Sendable, Equatable {
        public var removed = 0
        public var keptInUse = 0
        public var left: [String] = []
    }

    /// Remove the recorded vault copies that no remaining source version uses (and the vector cache,
    /// when recorded and asked), then drop the record — or keep it, naming what is left, for the next
    /// launch. B1: an unreadable record and an unanswerable "is this copy still used?" are unfinished
    /// work, never success; the file and the record are kept.
    nonisolated static func finishCaseEraseFiles(record: URL, ledgerURL: URL, database: Database, only: [String]? = nil,
                                                 dropCache: Bool = true,
                                                 isUsed: (@Sendable (String) async throws -> Bool)? = nil) async -> [String] {
        await runVaultFileStep(record: record, ledgerURL: ledgerURL, database: database, only: only,
                               dropCache: dropCache, isUsed: isUsed).left
    }

    /// The file step shared by case erasure and "Stop and forget" (LS26), with its count-back.
    nonisolated static func runVaultFileStep(record: URL, ledgerURL: URL, database: Database, only: [String]? = nil,
                                             dropCache: Bool = true,
                                             isUsed: (@Sendable (String) async throws -> Bool)? = nil) async -> VaultFileStep {
        var step = VaultFileStep()
        let obj: [String: Any]
        do {
            let data = try Data(contentsOf: record)
            guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            obj = o
        } catch {
            KalsmritikoshLog.app.error("Case-erase operation record unreadable: \(error.localizedDescription, privacy: .public)")
            step.left = ["the file steps of an erasure (\(record.lastPathComponent)) could not be read; the record is kept and nothing was removed"]
            return step
        }
        let recorded = (obj["vault"] as? [String]) ?? []
        let forgotten = (obj["forgotten"] as? [String]) ?? []
        let hashes = only.map { Set($0).intersection(recorded).union($0) }.map(Array.init) ?? recorded
        let vault = EvidenceVault(root: ledgerURL.deletingLastPathComponent().appendingPathComponent("EvidenceVault", isDirectory: true))
        for hash in hashes.sorted() {
            // Never remove a copy a remaining version still uses — nor one whose use cannot be checked.
            let used: Bool
            do {
                if let isUsed { used = try await isUsed(hash) } else if !forgotten.isEmpty {
                    used = try await forgottenFolderUsesCopy(hash, forgotten: forgotten, database: database)
                } else {
                    used = try await database.query("SELECT 1 FROM source_versions WHERE lower(content_hash) = lower(?) LIMIT 1;", [.text(hash)]).first != nil
                }
            } catch {
                KalsmritikoshLog.app.error("Case erasure: shared-use check failed, copy kept: \(error.localizedDescription, privacy: .public)")
                step.left.append("vault copy \(hash.prefix(12))… (kept: could not check whether another document uses it)")
                continue
            }
            guard await vault.contains(hash) else { continue }
            if used { step.keptInUse += 1; continue }
            do { try await vault.remove(hash) } catch {
                KalsmritikoshLog.app.error("Case erasure: vault copy not removed: \(error.localizedDescription, privacy: .public)")
            }
            if await vault.contains(hash) { step.left.append("vault copy \(hash.prefix(12))…") } else { step.removed += 1 }
        }
        if dropCache, (obj["dropVectorCache"] as? Bool) == true { step.left += dropVectorCache(besideLedgerAt: ledgerURL) }
        if step.left.isEmpty {
            do { try FileManager.default.removeItem(at: record) } catch {
                KalsmritikoshLog.app.error("Case-erase record not removed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return step
    }

    // MARK: - LS26 — "Stop and forget everything from this folder" removes the folder's own vault copies

    /// After a folder is forgotten, a copy is still used when a source version outside the forgotten files
    /// has it, or when a case still names one of its versions (by its file or its version, as case erasure
    /// decides sharing). Versions of forgotten files are otherwise left behind by the forget and do not count.
    nonisolated static func forgottenFolderUsesCopy(_ hash: String, forgotten: [String], database: Database) async throws -> Bool {
        let list = String(decoding: try JSONSerialization.data(withJSONObject: forgotten.map { $0.lowercased() }), as: UTF8.self)
        return try await database.query("""
            SELECT 1 FROM source_versions sv WHERE lower(sv.content_hash) = lower(?) AND (
                lower(sv.logical_source_id) NOT IN (SELECT value FROM json_each(?))
                OR EXISTS (SELECT 1 FROM investigation_case_sources s
                           WHERE lower(s.source_ref) = lower(sv.logical_source_id) OR lower(s.source_ref) = lower(sv.id)))
            LIMIT 1;
            """, [.text(hash), .text(list)]).first != nil
    }

    /// What "Stop and forget" did with a folder: its file rows and the vault copies only it used.
    public struct ForgetFolderOutcome: Sendable, Equatable {
        public var filesForgotten = 0
        public var files = VaultFileStep()
        /// The id under which unfinished file steps are retried at launch (nil when nothing is pending).
        public var pendingID: String?
        public var summary: String {
            var parts = ["Forgot \(filesForgotten) file(s) from this folder."]
            if files.removed > 0 { parts.append("Removed \(files.removed) stored copy(ies) of its files.") }
            if files.keptInUse > 0 { parts.append("Kept \(files.keptInUse) stored copy(ies) that another source or a case still uses.") }
            if !files.left.isEmpty {
                parts.append("Not removed yet: \(files.left.joined(separator: ", ")). This is retried the next time the app opens.")
            }
            return parts.joined(separator: " ")
        }
    }

    /// Forget every file under `rootURL`: plan the vault copies (recorded first, so a crash is finished at
    /// the next launch through `resumePendingCaseErasures`), delete the file rows, then remove the copies no
    /// other remaining source or case uses, with their opened copies, and count them back. No plan → nothing
    /// is deleted (B1).
    nonisolated static func forgetFolder(rootURL: URL, ledgerURL: URL, database: Database, files: FilesRepository,
                                         isUsed: (@Sendable (String) async throws -> Bool)? = nil) async throws -> ForgetFolderOutcome {
        var outcome = ForgetFolderOutcome()
        let ids = try await files.idsUnderRoot(rootURL)
        outcome.filesForgotten = ids.count
        let candidates = try await database.query("""
            SELECT DISTINCT lower(content_hash) FROM source_versions
             WHERE lower(logical_source_id) IN (SELECT value FROM json_each(?));
            """, [.text(String(decoding: try JSONSerialization.data(withJSONObject: ids.map { $0.lowercased() }), as: UTF8.self))])
            .compactMap { $0.string(0) }
        let planID = UUID()
        let record = caseEraseRecordURL(besideLedgerAt: ledgerURL, caseID: planID)
        if !candidates.isEmpty {
            try writeCaseEraseRecord(record, vault: candidates, dropVectorCache: false, forgotten: ids)
        }
        do { try await files.deleteAllUnderRoot(rootURL) } catch {
            KalsmritikoshLog.app.error("Forget folder: file rows not deleted: \(error.localizedDescription, privacy: .public)")
            if !candidates.isEmpty {
                do { try FileManager.default.removeItem(at: record) } catch {
                    KalsmritikoshLog.app.error("Forget folder: plan not removed: \(error.localizedDescription, privacy: .public)")
                }
            }
            throw error
        }
        guard !candidates.isEmpty else { return outcome }
        outcome.files = await runVaultFileStep(record: record, ledgerURL: ledgerURL, database: database, dropCache: false, isUsed: isUsed)
        if !outcome.files.left.isEmpty { outcome.pendingID = planID.uuidString }
        KalsmritikoshLog.app.notice("Forget folder: \(ids.count, privacy: .public) files, \(outcome.files.removed, privacy: .public) copies removed, \(outcome.files.keptInUse, privacy: .public) kept in use, \(outcome.files.left.count, privacy: .public) left")
        return outcome
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
                // Deep dive 2 (#4) — the erase committed: it goes on the register first (a crash may have come before that
                // write), then the file steps finish. A register that cannot be written keeps the plan for the next launch.
                var left: [String] = []
                let plan = readPlan(record)
                if let plan, let reg = registerPlan(plan), let id = UUID(uuidString: caseID),
                   let problem = ErasureRegister.recordReporting(.init(kind: .case, idHash: ErasureRegister.hash(id), eraseSources: reg.eraseSources,
                                                                      erasedAt: reg.erasedAt), besideLedgerAt: ledgerURL) {
                    left.append(problem)
                }
                left += await finishCaseEraseFiles(record: record, ledgerURL: ledgerURL, database: database)
                if !left.isEmpty, let plan, let reg = registerPlan(plan), !FileManager.default.fileExists(atPath: record.path) {
                    keepRegisterPlan(record, erasedAt: reg.erasedAt, eraseSources: reg.eraseSources ?? false)
                }
                if !left.isEmpty {
                    pending[caseID] = left
                    KalsmritikoshLog.app.error("Case erasure files still pending: \(left.joined(separator: ", "), privacy: .public)")
                }
            }
        }
        for name in names where name.hasPrefix(".person-erase-") && name.hasSuffix(".json") {
            let plan = dir.appendingPathComponent(name)
            let entityID = String(name.dropFirst(".person-erase-".count).dropLast(".json".count))
            switch await entityExists(entityID, in: database) {
            case .some(true):
                // The person is still in the ledger: the erase never committed.
                removePlan(plan)
            case .none:
                pending[entityID] = ["could not check whether a person erasure finished; it is checked again at the next launch"]
            case .some(false):
                let reg = readPlan(plan).flatMap(registerPlan)
                if let id = UUID(uuidString: entityID),
                   let problem = ErasureRegister.recordReporting(.init(kind: .person, idHash: ErasureRegister.hash(id), eraseSources: nil,
                                                                      erasedAt: reg?.erasedAt ?? Date().timeIntervalSince1970), besideLedgerAt: ledgerURL) {
                    pending[entityID] = [problem]
                } else {
                    removePlan(plan)
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
        // S11 (OUTPUT-01) — through the case output door: the person's role and the case re-checked, credentials and protected
        // names removed, written, read back and recorded in the case's outputs; then the job result's own export record.
        if let outputs = caseOutputs {
            let pkg = try await outputs.prepareText(caseID: record.caseID, kind: .jobResult, route: .file, actor: actor, citations: [], text: text)
            let receipt = await outputs.write(pkg, to: url)
            guard receipt.status == .written || receipt.status == .recordPending else { throw JobResultExportError.sourcesWithdrawn(receipt.summary) }
            return try await repo.recordExport(resultID: record.id, caseID: record.caseID, jobID: record.jobID, text: pkg.text, file: url, actor: actor)
        }
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
