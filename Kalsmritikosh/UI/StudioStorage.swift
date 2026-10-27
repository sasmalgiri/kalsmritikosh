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

    static func flushAll() async -> Bool {
        var allSaved = true
        for w in live { if let s = w.storage { await s.flush(); if s.hasUnsavedChanges { allSaved = false } } }
        return allSaved
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
                    try await repo.save(studio: studio, id: id, title: title, payload: data, actor: who)
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
            problem = "This draft belongs to another case, so it was not filled from \u{201C}\(choice.title)\u{201D}. Start a new draft for that case."
            return false
        } catch {
            problem = "The draft could not be assigned to the case: \(error.localizedDescription)"
            return false
        }
    }

    /// Record an export that was written successfully.
    func exported(_ id: UUID, format: String, text: String, app: AppState) {
        guard let repo = repository(app) else { return }
        let who = actor, previous = chain
        chain = Task { [weak self] in
            await previous?.value
            do { try await repo.recordExport(recordID: id, format: format, text: text, actor: who) } catch {
                KalsmritikoshLog.storage.error("Studio export record failed: \(error.localizedDescription, privacy: .public)")
                self?.problem = "The export was written, but its record could not be saved: \(error.localizedDescription)"
            }
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
