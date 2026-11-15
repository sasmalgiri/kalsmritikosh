//
//  AppState+CaseDocuments.swift
//  Kalsmritikosh
//
//  Ease fixes B (AI-off assessment 2026-11-15, friction point 5) — the case screen's "Add documents…" (files straight
//  into the case through the intake contracts: CaseDocumentAdder) and "Mark privileged…" (the protection register
//  through SensitiveScopeMutationService, so the export re-checks apply). Errors are logged and returned as plain words.
//

import Foundation
import os

extension AppState {
    /// "Add documents…" — read `urls` into the archive, add them to the case's workspace and include them in the case, in
    /// one step. Returns the receipt, or why nothing could be done.
    func addDocumentsToCase(caseID: UUID, urls: [URL], actor: String) async -> Result<CaseDocumentsAddReceipt, CaseDocumentsAddFailure> {
        guard !urls.isEmpty else { return .failure(.init(reason: "No file was chosen; nothing was added.")) }
        guard let db = database, let ingest, let cases = investigationCases, let intake = investigationWorkspaceIntake,
              let coordinator = workspaceSourceCoordinator else {
            return .failure(.init(reason: "The ledger isn't ready yet; nothing was added."))
        }
        guard PurchaseCenter.shared.allowPaidAction("add documents", importing: true) else {
            return .failure(.init(reason: PaidUse.refusal("add documents", importing: true)?.reason ?? "Adding documents needs a subscription."))
        }
        let activity = beginProcess("Adding \(urls.count) file(s) to the case…", total: urls.count)
        defer { finishProcess(activity) }
        let adder = CaseDocumentAdder(database: db, cases: cases, intake: intake, coordinator: coordinator, runs: ingestRuns ?? IngestRunRepository(database: db))
        do {
            let receipt = try await adder.add(caseID: caseID, urls: urls, actor: actor, at: Date()) { url in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let r = try await ingest.ingest(fileAt: url, intent: .fullAvailable)
                return (r.fileRecord.id, r.sourceVersionID, r.intakeOutcome)
            }
            if let run = receipt.runID { await afterIntakeBatch(run: run) }   // IN-06 / IN-05 — text digests, trusted-source policies
            await runPostIngestChecksSinceLast()
            return .success(receipt)
        } catch {
            KalsmritikoshLog.app.error("Add documents to the case failed: \(error.localizedDescription, privacy: .public)")
            return .failure(.init(reason: "The documents could not be added to the case: \(error.localizedDescription)"))
        }
    }

    /// "Mark privileged…" — the document's exact version is marked privileged in the protection register with the reason
    /// (its history kept), and the case log records it. Returns why not, or nil.
    func markDocumentPrivileged(caseID: UUID, sourceVersionID: UUID, documentName: String, reason: String, actor: String) async -> String? {
        guard let svc = mutationService, let caseFiles else { return "The ledger isn't ready yet; nothing was marked." }
        do {
            try await svc.markPrivileged(sourceVersionID: sourceVersionID, reason: reason, actor: actor, at: Date())
        } catch {
            KalsmritikoshLog.app.error("Mark privileged failed: \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
        do {
            try await caseFiles.file.logAction(caseID: caseID, action: "documentMarkedPrivileged",
                                               detail: "\(documentName) — \(reason.trimmingCharacters(in: .whitespacesAndNewlines))", actor: actor)
        } catch {
            // The mark stands (it is in the register); only the case log line is missing, and that is said.
            KalsmritikoshLog.app.error("Mark privileged: the case log line was not written: \(error.localizedDescription, privacy: .public)")
            return "The document is marked privileged, but the case log could not record it: \(error.localizedDescription)"
        }
        return nil
    }

    /// The versions among `versions` that are privileged now (version, file, record or review code — CaseProtectionNow).
    func privilegedVersions(_ versions: Set<UUID>) async -> Set<UUID> {
        guard let db = database, !versions.isEmpty else { return [] }
        do {
            return try await db.withSavepoint("priv_now_\(UUID().uuidString.prefix(8))") { db in
                var out = Set<UUID>()
                for v in versions where try CaseProtectionNow.versionPrivileged(db, v) { out.insert(v) }
                return out
            }
        } catch {
            KalsmritikoshLog.app.error("Privilege read failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}

/// Why "Add documents…" did nothing.
struct CaseDocumentsAddFailure: Error, Equatable {
    let reason: String
}
