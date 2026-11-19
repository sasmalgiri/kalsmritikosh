//
//  CaseDocumentAdder.swift
//  Kalsmritikosh
//
//  Ease fixes B (AI-off assessment 2026-11-15, friction point 5) — "Add documents…" on the case: the person picks files
//  and they come into the case in one step. Nothing is bypassed; the step simply runs the existing contracts in order:
//
//    1. INTAKE BATCH (IN-12) — one ingest run with the channel "a file chosen with the picker": each file's outcome
//       (received, already held, duplicate, failed) is recorded on the run, which is the batch receipt.
//    2. LIBRARY — each file is read into the archive by the normal pipeline (the caller's `ingest`), exactly as "Add
//       files" does.
//    3. WORKSPACE (QA-15) — the files join the case's workspace through WorkspaceSourceCoordinator; a file the app holds
//       but could not read is admitted in the "not read" state with its reason, never as read.
//    4. CASE (IN-01 / IN-05) — the new documents, and what is inside them, are included through
//       InvestigationWorkspaceIntake as the PERSON's decision: an intake record (channel, provenance, who entered it,
//       when it was received, the ingest run), then the scope, then the decision. A document deliberately excluded from
//       the case before stays excluded.
//
//  The receipt says what came in, what was not read (and why), what could not be taken in at all, and what stayed
//  excluded. No AI, no network.
//

import Foundation
import os

/// What one "Add documents…" did.
public nonisolated struct CaseDocumentsAddReceipt: Sendable, Equatable {
    public struct Line: Sendable, Equatable { public let name: String; public let reason: String }
    /// Files now in the case (read).
    public var added: [String] = []
    /// Files in the case but not read, with why (they count as not read in coverage, search and reports).
    public var notRead: [Line] = []
    /// Files that could not be taken in at all (nothing to account for: no custody record), with why.
    public var notTakenIn: [Line] = []
    /// Files already in the case, or deliberately excluded from it before (left as they are).
    public var alreadyDecided: [String] = []
    /// Case scope decisions recorded (documents and what is inside them).
    public var included = 0
    /// The ingest run that is this batch's receipt (nil when it could not be recorded).
    public var runID: UUID?

    public var summary: String {
        var parts = ["\(added.count + notRead.count) document(s) added to the case (\(included) item(s) included, attachments and archive members counted)"]
        if !notRead.isEmpty { parts.append("\(notRead.count) not read: " + notRead.map { "\($0.name) (\($0.reason))" }.joined(separator: "; ")) }
        if !notTakenIn.isEmpty { parts.append("\(notTakenIn.count) not taken in: " + notTakenIn.map { "\($0.name) (\($0.reason))" }.joined(separator: "; ")) }
        if !alreadyDecided.isEmpty { parts.append("\(alreadyDecided.count) already decided for this case and left as they are: " + alreadyDecided.joined(separator: ", ")) }
        return parts.joined(separator: ". ") + "."
    }
}

public struct CaseDocumentAdder: Sendable {
    /// Read one file into the archive (the app's normal pipeline): its file record, its source version and intake outcome.
    public typealias Ingest = @Sendable (URL) async throws -> (fileID: UUID, sourceVersionID: UUID?, outcome: SourceIntakeOutcome?)

    private let database: Database
    private let cases: InvestigationCaseRepository
    private let intake: InvestigationWorkspaceIntake
    private let coordinator: WorkspaceSourceCoordinator
    private let runs: IngestRunRepository

    public init(database: Database, cases: InvestigationCaseRepository, intake: InvestigationWorkspaceIntake,
                coordinator: WorkspaceSourceCoordinator, runs: IngestRunRepository) {
        self.database = database; self.cases = cases; self.intake = intake; self.coordinator = coordinator; self.runs = runs
    }

    /// Take `urls` into the case `caseID` in one step (see the file header for the order of the contracts).
    public func add(caseID: UUID, urls: [URL], actor: String, at date: Date, ingest: Ingest) async throws -> CaseDocumentsAddReceipt {
        guard let record = try await cases.fetch(caseID: caseID) else { throw InvestigationCaseError.caseNotFound(caseID) }
        var receipt = CaseDocumentsAddReceipt()
        let millis = date.timeIntervalSince1970 * 1000
        let receipts = IntakeReceiptRepository(database: database)
        do {
            let run = try await runs.startRun(totalFiles: urls.count, atMillis: millis)
            await receipts.setChannel(run: run, channel: .fileImport)
            receipt.runID = run
        } catch {
            KalsmritikoshLog.ingestion.error("Add documents: the batch receipt could not be started: \(error.localizedDescription, privacy: .public)")
        }
        // 1–2. Read each file; record its outcome on the batch.
        var fileIDs = Set<UUID>()
        var names: [UUID: String] = [:]
        for url in urls {
            let path = url.standardizedFileURL.path, name = url.lastPathComponent
            if let run = receipt.runID { await setState(run, path, .running, nil, millis) }
            do {
                let r = try await ingest(url)
                fileIDs.insert(r.fileID)
                names[r.fileID] = name
                if let run = receipt.runID {
                    await setState(run, path, .done, nil, millis)
                    await receipts.recordReceived(run: run, path: path, channel: .fileImport, sourceVersionID: r.sourceVersionID, intakeOutcome: r.outcome)
                }
            } catch {
                KalsmritikoshLog.ingestion.error("Add documents: a file was not read: \(error.localizedDescription, privacy: .private)")
                if let run = receipt.runID {
                    await setState(run, path, .failed, error.localizedDescription, millis)
                    await receipts.recordFailed(run: run, path: path, channel: .fileImport, timedOut: false)
                }
                // A file the app holds in custody without readable content is still accounted for (QA-15): it joins as not read.
                if let held = try await heldFile(url) {
                    fileIDs.insert(held)
                    names[held] = name
                } else {
                    receipt.notTakenIn.append(.init(name: name, reason: error.localizedDescription))
                }
            }
        }
        if let run = receipt.runID {
            do { try await runs.finish(run: run, status: .completed, atMillis: millis) } catch {
                KalsmritikoshLog.ingestion.error("Add documents: the batch receipt could not be finished: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard !fileIDs.isEmpty else { return receipt }
        // 3. The case's workspace (the library and the workspace still hold them).
        let added: WorkspaceSourceAddResult
        do { added = try await coordinator.addSources(fileIDs, to: record.caseHeader.workspaceID, at: date) } catch WorkspaceSourceError.noEligibleSources {
            KalsmritikoshLog.ingestion.error("Add documents: no file could join the case's workspace")
            for id in fileIDs { receipt.notTakenIn.append(.init(name: names[id] ?? "a file", reason: "the app holds no readable copy or custody record of it")) }
            return receipt
        }
        for id in fileIDs where !added.added.contains(id) {
            receipt.notTakenIn.append(.init(name: names[id] ?? "a file", reason: "the app holds no readable copy or custody record of it"))
        }
        // 4. The case: the new documents and what is inside them, as the person's decision.
        let coverage = CaseCoverageRepository(database: database)
        var roots: [UUID: UUID] = [:]   // root version → file
        for id in added.added {
            if let meta = try await coverage.currentVersion(forFileID: id) { roots[meta.sourceVersionID] = id }
        }
        let preview = try await intake.preview(caseID: caseID)
        var byID: [UUID: PendingCaseSource] = [:]
        for p in preview.pending where byID[p.sourceVersionID] == nil { byID[p.sourceVersionID] = p }
        // A document deliberately excluded from the case stays excluded, and so does what is inside it.
        let excluded = Set(record.sources.filter { !$0.inScope }.map { $0.sourceRef.uppercased() })
        func underNew(_ v: UUID) -> Bool {
            var cur = v
            for _ in 0..<64 {
                if excluded.contains(cur.uuidString.uppercased()) { return false }
                if roots[cur] != nil { return true }
                guard let parent = byID[cur]?.parentVersionID else { return false }
                cur = parent
            }
            return false
        }
        let approved = Set(preview.pending.filter { underNew($0.sourceVersionID) }.map(\.sourceVersionID))
        let decided = Set(record.sources.map { $0.sourceRef.uppercased() })
        for (version, file) in roots where decided.contains(version.uuidString.uppercased()) {
            receipt.alreadyDecided.append(names[file] ?? "a document")
        }
        if !approved.isEmpty {
            receipt.included = try await intake.include(caseID: caseID, approved: approved, actor: actor, at: date).included
        }
        for id in added.added {
            let name = names[id] ?? "a file"
            if let why = added.notRead[id] { receipt.notRead.append(.init(name: name, reason: why)) }
            else if !receipt.alreadyDecided.contains(name) { receipt.added.append(name) }
        }
        receipt.alreadyDecided.sort()
        return receipt
    }

    private func setState(_ run: UUID, _ path: String, _ state: IngestFileState, _ error: String?, _ millis: Double) async {
        do { try await runs.setFileState(run: run, path: path, state: state, error: error, atMillis: millis) } catch {
            KalsmritikoshLog.ingestion.error("Add documents: a batch line was not recorded: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The canonical file record the app holds for `url` (a failed read may still have registered it), nil when none.
    private func heldFile(_ url: URL) async throws -> UUID? {
        let forms = [url.absoluteString, url.standardizedFileURL.absoluteString, url.path]
        return try await database.query("SELECT id FROM files WHERE url IN (?, ?, ?) AND alias_of IS NULL ORDER BY ingested_at DESC LIMIT 1;",
                                        forms.map { .text($0) }).first?.uuid(0)
    }
}
