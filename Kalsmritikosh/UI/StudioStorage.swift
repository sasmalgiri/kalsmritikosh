//
//  StudioStorage.swift
//  Kalsmritikosh
//
//  Final brief §3.1 — every studio's drafts live in the encrypted ledger (StudioRecordRepository),
//  not in app preferences. One helper per studio screen:
//    • first open: the old preference store is kept byte for byte in the ledger, then imported once,
//      record by record, every element with a recorded outcome (conflicts quarantined, never
//      skipped); the preference copy is cleared only when every element is accounted for, the kept
//      copy matches its digest and every imported record reads back intact;
//    • edits save in order (one chain per screen), so a slower earlier write can never land after a
//      later one; a failed write is shown, not swallowed;
//    • removing a draft retracts it — the record and its history stay;
//    • "Fill from case" binds the draft to that case; a draft bound to another case is refused;
//    • an export is recorded (text + SHA-256 + revision) only after the file was written.
//  Nothing is ever written back to UserDefaults.
//

import Foundation
import os

/// A studio model the ledger can hold.
public protocol StudioPersisted: Codable, Identifiable where ID == UUID {
    var title: String { get }
    var updatedAt: Date { get }
    var completionFraction: Double { get }
}

/// Review R2: what one export is — rendered and sealed ONCE, from one frozen revision. The same bytes
/// go to the file (or clipboard / printer) and into the ledger's export record.
struct StudioExportPackage: Sendable, Equatable {
    let recordID: UUID
    let revision: Int
    let payloadSHA256: String
    let approved: Bool
    let text: String
    /// K5 — digest of the case's accessible source versions at the final check (nil: not checked).
    var scopeFingerprint: String? = nil
    var digest: String { StudioRecordRepository.sha256(Data(text.utf8)) }
}

extension SIUReferral: StudioPersisted {}
extension WorkplaceInvestigation: StudioPersisted {}
extension FactCheckMemo: StudioPersisted {}
extension ForensicEngagement: StudioPersisted {}
extension PrivilegeLog: StudioPersisted {}
extension RootCauseAnalysis: StudioPersisted {}

/// A copy of the ledger was refused because a studio change has not been saved (review R5).
struct StudioUnsavedChangesError: LocalizedError {
    var errorDescription: String? { "A studio change has not been saved yet. Choose Retry in that studio, then try again." }
}

@MainActor @Observable
final class StudioStorage {
    let studio: String
    let legacyKey: String
    /// Import results, quarantined records, drafts not yet assigned to a case.
    var notice: String?
    /// A failed read or write — shown on the screen.
    var problem: String?
    /// The case each draft belongs to (nil: not assigned yet).
    private(set) var caseOf: [UUID: UUID] = [:]

    /// What the ledger is KNOWN to hold (review R5): updated only after a write succeeds.
    private var committed: [UUID: Data] = [:]
    /// Writes sent and not yet confirmed, so identical edits are not queued twice.
    private var inFlight: [UUID: Data] = [:]
    /// The last full list handed to `persist`, so `retry()` can re-send what failed.
    private var lastItems: [(UUID, String, Data)] = []
    /// True while a write has failed and not yet been retried successfully.
    private(set) var hasUnsavedChanges = false
    private var chain: Task<Void, Never>?

    /// Tests: the repository to use instead of the app's, and a fault to inject before each write.
    var repositoryOverride: StudioRecordRepository?
    /// Test hook: the evidence context the final export check uses (else the app's).
    var evidenceContextOverride: ((UUID?) async -> StudioEvidenceContext?)?
    var writeFault: (@Sendable () throws -> Void)?

    /// Every open studio screen, so a backup can flush their pending writes first.
    private static var live: [WeakStorage] = []
    private struct WeakStorage { weak var storage: StudioStorage? }

    init(studio: String, legacyKey: String) {
        self.studio = studio; self.legacyKey = legacyKey
        Self.live.removeAll { $0.storage == nil }
        Self.live.append(WeakStorage(storage: self))
    }

    private var actor: String { InvestigatorProfile.name }

    /// Wait for every open studio's pending writes. False when any studio still has a change that
    /// failed to save — a backup taken then would not hold it, so the caller must say so.
    /// Throws when a studio change is still unsaved — for every path that copies the ledger.
    static func requireAllSaved() async throws {
        guard await flushAll() else { throw StudioUnsavedChangesError() }
    }

    /// K7 — the persona and catalog job each studio's drafts belong to (saved on every record).
    static let identities: [String: (persona: String, jobID: String?)] = [
        "siu": ("com.kalsmritikosh.persona.siu", "siu.referral-report"),
        "forensic": ("com.kalsmritikosh.persona.forensicaccountant", "fa.expert-report"),
        "journalist": ("com.kalsmritikosh.persona.journalist", "jrn.claim-board"),
        "workplace": ("com.kalsmritikosh.persona.compliance", "hr.findings-memo"),
        "privilegeLog": ("com.kalsmritikosh.persona.lawyer", "law.privilege"),
        "reasoning": ("com.kalsmritikosh.persona.investigator", "inv.causal-analysis"),
        "rs": ("com.kalsmritikosh.persona.researcher", "res.protocol"),
        "gn": ("com.kalsmritikosh.persona.genealogist", "gen.proof-argument"),
        "in": ("com.kalsmritikosh.persona.individual", "ind.emergency-pack"),
        "ds": ("com.kalsmritikosh.persona.individual", "ind.applications"),
        "cc": ("com.kalsmritikosh.persona.contentcreator", nil),
    ]
    private var identity: (persona: String?, jobID: String?) {
        Self.identities[studio].map { ($0.persona, $0.jobID) } ?? (nil, nil)
    }

    /// K2 writer barrier: after a full erase, every open studio drops its pending writes and writes
    /// nothing more until it is loaded again — a queued save must not recreate an erased draft.
    static func invalidateAllForErase() async {
        for w in live {
            guard let s = w.storage else { continue }
            await s.flush()
            s.erasedGeneration = true
            s.committed = [:]
            s.lastItems = []
            s.hasUnsavedChanges = false
            s.approvedIDs = []
            s.caseOf = [:]
            s.problem = nil
            s.notice = "All data was erased. Close and reopen this studio; nothing shown here is saved any more."
        }
    }

    /// A4 — after ONE case was erased: only the studios holding that case's drafts stop writing; every
    /// other studio, and every other case's pending save, is untouched. (Called only after the erase
    /// succeeded; a refused erase changes nothing.)
    static func invalidate(forErasedCase caseID: UUID) async {
        for w in live {
            guard let s = w.storage, s.caseOf.values.contains(caseID) else { continue }
            for (record, c) in s.caseOf where c == caseID {
                s.committed[record] = nil
                s.caseOf[record] = nil
            }
            s.erasedGeneration = true
            s.hasUnsavedChanges = false
            s.notice = "This case was erased. Close and reopen this studio; its drafts for that case are gone."
        }
    }

    /// Set by a full erase; cleared by the next load.
    private(set) var erasedGeneration = false

    static func flushAll() async -> Bool {
        var allSaved = true
        for w in live { if let s = w.storage { await s.flush(); if s.hasUnsavedChanges { allSaved = false } } }
        return allSaved
    }

    /// B1 — before ONE case is erased: wait for every studio's writes, then answer whether any change
    /// that may belong to that case (bound to it, or not yet bound to any case) is still unsaved.
    /// Unsaved work for other cases, or for another ledger, does not block this case's erase.
    static func flushAll(forCase caseID: UUID?, in database: Database) async -> Bool {
        var allSaved = true
        for w in live {
            guard let s = w.storage else { continue }
            if let other = s.repositoryOverride?.database, other !== database { continue }
            await s.flush()
            if s.hasUnsavedChanges, s.hasUnsavedWork(touching: caseID) { allSaved = false }
        }
        return allSaved
    }

    /// An edit or removal not yet confirmed saved, on a draft of this case or of no case yet.
    /// nil: any case.
    func hasUnsavedWork(touching caseID: UUID?) -> Bool {
        guard let caseID else { return pendingCount > 0 }
        let liveIDs = Set(lastItems.map(\.0))
        let edited = lastItems.contains { committed[$0.0] != $0.2 && (caseOf[$0.0] == nil || caseOf[$0.0] == caseID) }
        let retracted = committed.keys.contains { !liveIDs.contains($0) && (caseOf[$0] == nil || caseOf[$0] == caseID) }
        return edited || retracted
    }

    private func repository(_ app: AppState?) -> StudioRecordRepository? {
        if let repositoryOverride { return repositoryOverride }
        guard let db = app?.database else {
            problem = "The ledger is not open yet, so studio work cannot be loaded or saved. Wait for the app to finish opening."
            return nil
        }
        return StudioRecordRepository(database: db)
    }

    /// Import the old store once (if any), then read every live draft of this studio.
    func load<M: StudioPersisted>(_ type: M.Type, app: AppState?) async -> [M] {
        guard let repo = repository(app) else { return [] }
        erasedGeneration = false
        do {
            if !(try await repo.hasImportedLegacy(sourceKey: legacyKey)) {
                let blob = UserDefaults.standard.string(forKey: legacyKey) ?? ""
                let result = try await repo.importLegacy(studio: studio, sourceKey: legacyKey, blob: blob, actor: actor) { data in
                    guard let m = try? JSONDecoder().decode(M.self, from: data) else { return nil }
                    return StudioLegacyElement(id: m.id, title: m.title, updatedAt: m.updatedAt)
                }
                let intact = try await repo.verifyImported(result.importedIDs) { (try? JSONDecoder().decode(M.self, from: $0)) != nil }
                // Cleared only once every imported record reads back intact. Records that would not
                // decode are in the ledger's quarantine byte for byte, so the preference copy is then
                // no longer the only copy of anything.
                let blobKept = (try? await repo.legacyBlob(sourceKey: legacyKey))??.intact == true || blob.isEmpty
                if intact, result.everyElementAccounted, blobKept { UserDefaults.standard.removeObject(forKey: legacyKey) }
                var parts: [String] = []
                if !result.importedIDs.isEmpty { parts.append("\(result.importedIDs.count) draft(s) moved from this Mac's settings into the encrypted case ledger — assign each to its case with Fill from case") }
                if result.quarantined > 0 { parts.append("\(result.quarantined) saved draft(s) could not be read; they are kept unchanged in the ledger's quarantine so nothing is lost") }
                if !intact || !result.everyElementAccounted || !blobKept { parts.append("the move could not be verified, so the old copy was kept") }
                if !parts.isEmpty { notice = parts.joined(separator: "; ") + "." }
            }
            let rows = try await repo.records(studio: studio)
            var out: [M] = []
            var unreadable = 0
            for r in rows {
                do {
                    out.append(try JSONDecoder().decode(M.self, from: r.payload))
                    committed[r.id] = Self.canonical(r.payload)
                    if let c = r.caseID { caseOf[r.id] = c }
                } catch {
                    unreadable += 1
                    KalsmritikoshLog.storage.error("Studio record \(r.id.uuidString, privacy: .public) unreadable: \(error.localizedDescription, privacy: .public)")
                }
            }
            if unreadable > 0 { problem = "\(unreadable) draft(s) in the ledger could not be read by this version; they are kept, not changed." }
            return out
        } catch {
            KalsmritikoshLog.storage.error("Studio load failed: \(error.localizedDescription, privacy: .public)")
            problem = "Studio work could not be loaded: \(error.localizedDescription)"
            return []
        }
    }

    /// Save every draft whose content differs from what the ledger is known to hold; retract the
    /// ones no longer in `items`. The known state moves only when a write succeeds (review R5), so a
    /// failed change stays pending and `retry()` (or the next edit) sends it again.
    func persist<M: StudioPersisted>(_ items: [M], app: AppState?) {
        guard !erasedGeneration else { return }   // K2: nothing erased is written back
        // §11 — editing a studio draft is a paid action; without a standing subscription the draft is
        // read-only: nothing is written, the person is told why, and the subscription screen opens.
        guard PurchaseCenter.shared.allowPaidAction("edit studio drafts") else {
            problem = "Read-only: this draft is not saved because no subscription stands. Its last saved version is kept; subscribe to edit it."
            return
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var list: [(UUID, String, Data)] = []
        for m in items {
            do { list.append((m.id, m.title, try encoder.encode(m))) } catch {
                problem = "A draft could not be prepared for saving: \(error.localizedDescription)"
            }
        }
        lastItems = list
        send(list, app: app)
    }

    /// Send again whatever has not been confirmed saved.
    func retry(app: AppState?) { send(lastItems, app: app) }

    private func send(_ list: [(UUID, String, Data)], app: AppState?) {
        guard let repo = repository(app) else { hasUnsavedChanges = true; return }
        let changed = list.filter { committed[$0.0] != $0.2 && inFlight[$0.0] != $0.2 }
        let live = Set(list.map(\.0))
        let removed = committed.keys.filter { !live.contains($0) }
        guard !changed.isEmpty || !removed.isEmpty else { return }
        for c in changed { inFlight[c.0] = c.2 }
        let studio = self.studio, who = actor, previous = chain, fault = writeFault
        chain = Task { [weak self] in
            await previous?.value
            var failure: Error?
            for (id, title, data) in changed {
                do {
                    try fault?()
                    try await repo.save(studio: studio, id: id, title: title, payload: data, persona: identity.persona, jobID: identity.jobID, actor: who)
                    self?.committed[id] = data
                } catch { failure = error }
                if self?.inFlight[id] == data { self?.inFlight[id] = nil }
            }
            for id in removed {
                do {
                    try fault?()
                    try await repo.retract(recordID: id, actor: who)
                    self?.committed[id] = nil; self?.caseOf[id] = nil
                } catch { failure = error }
            }
            guard let self else { return }
            if let failure {
                KalsmritikoshLog.storage.error("Studio save failed: \(failure.localizedDescription, privacy: .public)")
                self.hasUnsavedChanges = true
                self.problem = "A change was NOT saved (\(failure.localizedDescription)). It is kept here — choose Retry, or keep working and it will be sent again."
            } else if self.hasUnsavedChanges, self.pendingCount == 0 {
                self.hasUnsavedChanges = false
                self.problem = nil
            }
        }
    }

    /// Drafts whose current content the ledger is not yet known to hold.
    var pendingCount: Int {
        let live = Set(lastItems.map(\.0))
        return lastItems.filter { committed[$0.0] != $0.2 }.count + committed.keys.filter { !live.contains($0) }.count
    }

    static func canonical(_ payload: Data) -> Data {
        guard let obj = try? JSONSerialization.jsonObject(with: payload),
              let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return payload }
        return d
    }

    // MARK: - Exports (review R2)

    /// The banner a report carries when no current approval covers exactly this content.
    static let draftBanner = "> **DRAFT — not approved.** This version has not been approved; it is not a final work product.\n\n"

    /// Freeze `model` (the exact value that was validated) and render it once. Pending writes land
    /// first; the draft's stored content must equal `model`, or nothing is exported.
    /// What the final check before output re-authorises: the draft's provenance and gate values.
    struct ExportAuthorisation {
        let provenance: StudioProvenance?
        let values: [String: String]
        let privileged: Bool
    }

    func package<M: StudioPersisted>(_ model: M, app: AppState?, authorise: ExportAuthorisation? = nil,
                                     render: (_ approved: Bool) -> String) async -> StudioExportPackage? {
        guard let repo = repository(app) else { return nil }
        // K5 — re-authorise immediately before output: every cited source must still resolve in the
        // draft's case under the current access policy (a source that became privileged or left the
        // case since the person pressed Export stops the export). The scope it was checked against
        // is recorded with the export.
        var fingerprint: String?
        if let authorise, app != nil || evidenceContextOverride != nil {
            let context: StudioEvidenceContext?
            if let evidenceContextOverride { context = await evidenceContextOverride(caseOf[model.id]) }
            else { context = await app?.studioEvidenceContext(caseID: caseOf[model.id], workspaceID: nil, includePrivileged: authorise.privileged) }
            let unresolved = await StudioEvidenceResolver.unresolved(values: authorise.values, provenance: authorise.provenance, context: context)
            if !unresolved.isEmpty {
                problem = "Nothing was exported: \(unresolved.count) cited source(s) no longer check out (\(unresolved.keys.sorted().prefix(3).joined(separator: ", "))) — the case or its access changed. Check the draft and export again."
                return nil
            }
            if let context {
                fingerprint = StudioRecordRepository.sha256(Data(context.eligibleSourceVersions.map(\.uuidString).sorted().joined(separator: ",").utf8))
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(model)
            await flush()
            if committed[model.id] != data {
                // Never write a stale value over newer work: the screen moved on since validation.
                if let live = lastItems.first(where: { $0.0 == model.id })?.2, live != data {
                    throw StudioRecordError.changedSinceValidation(model.id)
                }
                try writeFault?()
                try await repo.save(studio: studio, id: model.id, title: model.title, payload: data, persona: identity.persona, jobID: identity.jobID, actor: actor)
                committed[model.id] = data
            }
            let frozen = try await repo.freezeForExport(recordID: model.id, expectedPayloadSHA256: StudioRecordRepository.sha256(data), actor: actor)
            // Release-block directive item 1 — a protected source's name (jrn.source-vault) never appears
            // in a studio export either: scrubbed and verified gone, else nothing is exported.
            var text = render(frozen.approved)
            if let db = app?.database {
                let scrubbed = ProtectedIdentities.scrub(text, names: try await JobResultRepository(database: db).protectedIdentityNames())
                guard scrubbed.leaks.isEmpty else {
                    problem = "Nothing was exported: \(scrubbed.leaks.count) protected source identity(ies) would remain recoverable in the file."
                    return nil
                }
                text = scrubbed.text
            }
            return StudioExportPackage(recordID: model.id, revision: frozen.revision, payloadSHA256: StudioRecordRepository.sha256(data),
                                       approved: frozen.approved, text: text, scopeFingerprint: fingerprint)
        } catch {
            KalsmritikoshLog.storage.error("Studio export not prepared: \(error.localizedDescription, privacy: .public)")
            problem = "Nothing was exported: \(error.localizedDescription)"
            return nil
        }
    }

    /// Record an export that completed: the file at `url` is read back and must hold exactly the
    /// package's bytes; then those bytes are recorded against the frozen revision.
    func exported(_ pkg: StudioExportPackage, format: String, writtenTo url: URL?, app: AppState?) {
        if let url {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let written = try? Data(contentsOf: url), StudioRecordRepository.sha256(written) == pkg.digest else {
                problem = "The saved file does not match the report that was prepared (its SHA-256 differs), so it was not recorded as an export. Export again."
                return
            }
        }
        guard let repo = repository(app) else { return }
        let who = actor, previous = chain
        chain = Task { [weak self] in
            await previous?.value
            do { try await repo.recordExport(recordID: pkg.recordID, format: format, text: pkg.text, revision: pkg.revision, scopeFingerprint: pkg.scopeFingerprint, actor: who) } catch {
                KalsmritikoshLog.storage.error("Studio export record failed: \(error.localizedDescription, privacy: .public)")
                self?.problem = "The export was written, but its record could not be saved: \(error.localizedDescription)"
            }
        }
    }

    /// Approve the exact current content of `model`. Refused (with the reason) unless every stage is
    /// complete, every cited source resolves, and no field whose citation failed was relabelled as
    /// the investigator's own entry (mandatory documentary support cannot be waived by a label).
    func approve<M: StudioPersisted>(_ model: M, provenance: StudioProvenance?, values: [String: String],
                                     privileged: Bool, mandatory: [String] = [], app: AppState) async -> String? {
        guard model.completionFraction >= 1 else { return "Not approved: every stage must be complete first." }
        // K6: a field the work product must rest on a document for cannot be approved as the
        // investigator's own entry.
        let undocumented = StudioMandatoryEvidence.missing(values: values, provenance: provenance, patterns: mandatory)
        if !undocumented.isEmpty {
            return "Not approved: \(undocumented.count) field(s) must come from the case's documents, not be typed in (\(undocumented.prefix(4).joined(separator: ", ")))."
        }
        let relabelled = (provenance ?? [:]).filter { $0.value.relabelledFromUnresolved == true }.map(\.key)
        if !relabelled.isEmpty {
            return "Not approved: \(relabelled.count) field(s) whose cited source did not check out were marked as your own entries. An approved report needs their documentary support resolved (\(relabelled.sorted().prefix(4).joined(separator: ", ")))."
        }
        let context = await app.studioEvidenceContext(caseID: caseOf[model.id], workspaceID: nil, includePrivileged: privileged)
        let unresolved = await StudioEvidenceResolver.unresolved(values: values, provenance: provenance, context: context)
        if !unresolved.isEmpty { return "Not approved: \(unresolved.count) field(s) cite a source that does not check out." }
        guard let repo = repository(app) else { return "Not approved: the ledger is not open." }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(model)
            await flush()
            if committed[model.id] != data {
                if let live = lastItems.first(where: { $0.0 == model.id })?.2, live != data {
                    throw StudioRecordError.changedSinceValidation(model.id)
                }
                try await repo.save(studio: studio, id: model.id, title: model.title, payload: data, persona: identity.persona, jobID: identity.jobID, actor: actor)
                committed[model.id] = data
            }
            try await repo.setReviewState(recordID: model.id, .approved, actor: actor)
            approvedIDs.insert(model.id)
            return nil
        } catch {
            return "Not approved: \(error.localizedDescription)"
        }
    }

    /// Drafts whose current approval covers exactly their content (refreshed by `refreshApproval`).
    private(set) var approvedIDs: Set<UUID> = []

    func refreshApproval(_ id: UUID, app: AppState?) async {
        guard let repo = repository(app) else { return }
        await flush()
        if (try? await repo.approvalIsCurrent(recordID: id)) == true { approvedIDs.insert(id) } else { approvedIDs.remove(id) }
    }

    /// Bind a draft to the case it is being filled from. Returns false (and says why) when the draft
    /// belongs to another case.
    func bind(_ id: UUID, to choice: StudioCaseChoice, app: AppState) async -> Bool {
        guard let repo = repository(app) else { return false }
        await chain?.value   // the draft's first save must land first
        do {
            try await repo.bind(recordID: id, caseID: choice.id, workspaceID: choice.workspaceID, actor: actor)
            caseOf[id] = choice.id
            return true
        } catch StudioRecordError.boundToAnotherCase {
            problem = "This draft belongs to another case, so it was not assigned to or filled from \u{201C}\(choice.title)\u{201D}. Start a new draft for that case."
            return false
        } catch {
            problem = "The draft could not be assigned to the case: \(error.localizedDescription)"
            return false
        }
    }

    /// Review L4 — erase a draft's content (not just remove it). nil on success, else why not. The
    /// caller then drops the draft from its list; nothing more is sent for it.
    func erase(_ id: UUID, reason: String, legalBasis: String?, app: AppState?) async -> String? {
        guard let repo = repository(app) else { return "The ledger is not open." }
        await flush()
        do {
            let r = try await repo.erase(recordID: id, reason: reason, legalBasis: legalBasis, actor: actor)
            committed.removeValue(forKey: id)
            lastItems.removeAll { $0.0 == id }
            approvedIDs.remove(id)
            var note = "Erased: the draft, \(r.revisionsCleared) earlier version(s) and \(r.exportsCleared) export snapshot(s) no longer hold its content; the erasure itself is recorded."
            if r.legacyOriginalsCleared > 0 {
                note += " \(r.legacyOriginalsCleared) captured store(s) from before the move into the ledger held a copy and were cleared too."
            }
            notice = note + " " + StudioErasureResult.outsideTheLedger
            return nil
        } catch {
            KalsmritikoshLog.storage.error("Studio erasure refused: \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
    }

    /// Waits for every pending write (tests, and before a backup).
    func flush() async { await chain?.value }
}

import SwiftUI

extension View {
    /// The storage notice / problem, above a studio screen, with Retry when a change failed to save.
    func studioStorageBanner(_ storage: StudioStorage) -> some View {
        safeAreaInset(edge: .top, spacing: 0) { StudioStorageBanner(storage: storage) }
    }
}

private struct StudioStorageBanner: View {
    let storage: StudioStorage
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let p = storage.problem {
                HStack(spacing: 8) {
                    Label(p, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    if storage.hasUnsavedChanges {
                        Button("Retry") { storage.retry(app: appState) }.controlSize(.small)
                    }
                }
            }
            if let n = storage.notice {
                Label(n, systemImage: "lock.shield").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 24).padding(.vertical, (storage.problem ?? storage.notice) == nil ? 0 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
