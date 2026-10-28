//
//  JobResult.swift
//  Kalsmritikosh
//
//  Final completion instructions §3 — the typed, persisted result of a job run by a shared executor:
//  rows (each with its exact source references and flags such as "disputed date"), the limitations
//  of the run (what was missing or not covered) and the next actions it leaves for the person.
//

import Foundation

public nonisolated enum JobResultError: Error, Equatable, LocalizedError {
    case caseGone
    public var errorDescription: String? { "The case no longer exists, so this result was not saved." }
}

public nonisolated enum JobResultExportError: Error, Equatable, LocalizedError {
    case writtenBytesDiffer, unsavedEdits, sourcesWithdrawn(String)
    public var errorDescription: String? {
        switch self {
        case .writtenBytesDiffer: return "The written file does not hold exactly the exported text, so the export was not recorded. Export again."
        case .unsavedEdits: return "This result has unsaved edits. Save your review first — an export is always of a saved revision."
        case .sourcesWithdrawn(let why): return "Not exported: \(why)"
        }
    }
}

public nonisolated enum JobResultState: String, Codable, Sendable { case draft, blocked, completed, superseded }

public nonisolated struct JobResultRow: Codable, Sendable, Hashable {
    public var title: String
    public var detail: String?
    /// ISO day ("2026-01-05"), or nil when the row is undated.
    public var date: String?
    public var flags: [String]
    public let refs: [StudioEvidenceRef]
    /// A1 — the person's decision on this row (accepted / rejected), nil while undecided.
    public var decision: JobRowDecision?
    /// A1 — the person's note on this row.
    public var note: String?
    /// The contract fields of this row (`JobFields.specs`): pre-filled where the ledger states them,
    /// recorded by the person otherwise.
    public var fields: [String: String]?
    /// B2 — the values the run took from the ledger ("title" and each pre-filled field), frozen when
    /// the run was saved. A value that differs from it is the person's entry, never the source's.
    public var sourced: [String: String]?
    /// B2 — the keys whose current value is the person's entry (set at each review save).
    public var assertions: [String]?
    /// B2 — a row the person added by hand (no run produced it).
    public var manual: Bool?
    public init(title: String, detail: String? = nil, date: String? = nil, flags: [String] = [], refs: [StudioEvidenceRef] = [],
                decision: JobRowDecision? = nil, note: String? = nil, fields: [String: String]? = nil) {
        self.title = title; self.detail = detail; self.date = date; self.flags = flags; self.refs = refs
        self.decision = decision; self.note = note; self.fields = fields
    }

    /// The run's own values for this row (what the cited sources were matched to).
    var generatedValues: [String: String] {
        var v = fields ?? [:]
        v["title"] = title
        return v.filter { !$0.value.isEmpty }
    }

    /// Keys whose value is not the one the run took from the ledger.
    public func personEntries() -> [String] {
        guard manual != true else { return (["title"] + (fields ?? [:]).filter { !$0.value.isEmpty && $0.key != "run" }.map(\.key)).sorted() }
        let base = sourced ?? [:]
        var keys: [String] = []
        if title != base["title"] { keys.append("title") }
        // "run" is the method engine's run id, written by the app, not a statement.
        for (k, v) in fields ?? [:] where !v.isEmpty && v != base[k] && k != "run" { keys.append(k) }
        return keys.sorted()
    }

    /// True when a value the source supplied was changed (the citation no longer shows the new words).
    public var changedSourcedValue: Bool {
        guard manual != true, let base = sourced else { return false }
        return base.contains { k, v in (k == "title" ? title : (fields?[k] ?? "")) != v }
    }
}

public nonisolated enum JobRowDecision: String, Codable, Sendable, Hashable, CaseIterable { case accepted, rejected }

/// A1 — who reviewed a result revision, when, and (for a completion) their note.
public nonisolated struct JobResultReview: Codable, Sendable, Hashable {
    public let by: String
    public let at: Date
    public let note: String?
    public let completed: Bool
    /// The SHA-256 of the completed rows, frozen at completion (a publication package's digest).
    public var digest: String?
}

public nonisolated struct JobResultContent: Codable, Sendable, Hashable {
    public var rows: [JobResultRow]
    public let limitations: [String]
    public let nextActions: [String]
    /// A1 — set on a revision the person saved (review or completion); nil on a generated result.
    public var review: JobResultReview?
    public init(rows: [JobResultRow], limitations: [String] = [], nextActions: [String] = [], review: JobResultReview? = nil) {
        self.rows = rows; self.limitations = limitations; self.nextActions = nextActions; self.review = review
    }
}

public nonisolated enum JobResultReviewError: Error, Equatable, LocalizedError {
    case blockedCannotComplete, noteRequired, undecidedRows(Int), notCurrent, missingFields(row: Int, fields: [String])
    case caseClosed, unresolvedEvidence(Int), correctionNeedsReason(row: Int)
    public var errorDescription: String? {
        switch self {
        case .blockedCannotComplete: return "A blocked result cannot be completed: give the job what it is missing and run it again."
        case .noteRequired: return "Completing a result needs your note (what you checked and why it is complete)."
        case .undecidedRows(let n): return "\(n) row(s) are still undecided. Accept or reject each one before completing."
        case .notCurrent: return "This is an earlier revision. Restore it as current first, or review the current one."
        case .missingFields(let row, let fields): return "Row \(row + 1) is accepted but still needs a valid: \(fields.joined(separator: ", "))."
        case .caseClosed: return "The case is closed, so its results can be read and exported but not changed. Reopen the case to edit."
        case .unresolvedEvidence(let n): return "\(n) cited source(s) no longer resolve in this case (removed, privileged or above its sensitivity). Re-run the job, or reject those rows."
        case .correctionNeedsReason(let row): return "Row \(row + 1) changes what its source states. Add a note saying why, or reject the row."
        }
    }
}

public nonisolated struct JobResultRecord: Sendable, Identifiable {
    public let id: UUID
    public let caseID: UUID
    public let jobID: String
    public let family: String
    public let state: JobResultState
    public let content: JobResultContent
    public let createdBy: String
    public let createdAt: Date
}

public actor JobResultRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    /// One write: the expected-current revision and the parent case's state are checked inside the
    /// same savepoint as the insert (B2), so a concurrent review, a restore or a case being closed or
    /// erased cannot interleave.
    struct Write: Sendable {
        let jobID: String
        let family: JobResultFamily
        let state: JobResultState
        let content: JobResultContent
        /// The revision the person was looking at (nil: a new run, which supersedes whatever is current).
        let expectedCurrent: UUID?
    }

    /// Save a run; the case's earlier current result for the same job becomes superseded. A
    /// generated result freezes the values its rows took from the ledger (`sourced`).
    @discardableResult
    public func save(caseID: UUID, jobID: String, family: JobResultFamily, state: JobResultState,
                     content: JobResultContent, actor: String, at date: Date = Date()) async throws -> UUID {
        var content = content
        if content.review == nil {
            content.rows = content.rows.map { r in var r = r; if r.sourced == nil && r.manual != true { r.sourced = r.generatedValues }; return r }
        }
        return try await write(caseID: caseID, [Write(jobID: jobID, family: family, state: state, content: content, expectedCurrent: nil)],
                               requireOpen: false, actor: actor, at: date)[0]
    }

    private func write(caseID: UUID, _ writes: [Write], requireOpen: Bool, actor: String, at date: Date) async throws -> [UUID] {
        let who = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !who.isEmpty else { throw StudioRecordError.blankActor }
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let prepared = try writes.map { w in (w, UUID(), try enc.encode(w.content)) }
        try await database.withSavepoint("job_result_\(prepared[0].1.uuidString.prefix(8))") { db in
            // T1 — a result that finishes after its case was erased (or never existed) writes nothing.
            guard let c = try db.query("SELECT status FROM investigation_cases WHERE id = ? LIMIT 1;", [.uuid(caseID)]).first else {
                throw JobResultError.caseGone
            }
            if requireOpen, c.string(0) == "closed" { throw JobResultReviewError.caseClosed }
            for (w, id, payload) in prepared {
                if let expected = w.expectedCurrent {
                    let current = try db.query("SELECT id FROM job_results WHERE case_id = ? AND job_id = ? AND state <> 'superseded' ORDER BY created_at DESC LIMIT 1;",
                                               [.uuid(caseID), .text(w.jobID)]).first?.uuid(0)
                    guard current == expected else { throw JobResultReviewError.notCurrent }
                }
                try db.exec("UPDATE job_results SET state = 'superseded', superseded_by = ? WHERE case_id = ? AND job_id = ? AND state <> 'superseded';",
                            [.uuid(id), .uuid(caseID), .text(w.jobID)])
                try db.exec("""
                    INSERT INTO job_results (id, case_id, job_id, family, state, payload_json, payload_sha256, created_by, created_at)
                    VALUES (?,?,?,?,?,?,?,?,?);
                    """, [.uuid(id), .uuid(caseID), .text(w.jobID), .text(w.family.rawValue), .text(w.state.rawValue),
                          .text(String(decoding: payload, as: UTF8.self)), .text(StudioRecordRepository.sha256(payload)), .text(who), .date(date)])
            }
        }
        return prepared.map(\.1)
    }

    /// The cited sources of `refs` that no longer resolve in the case (B2): supplied by the app, which
    /// owns scope, privilege and sensitivity.
    public typealias EvidenceCheck = @Sendable ([StudioEvidenceRef]) async throws -> [StudioEvidenceRef]

    /// A1/B2 — save the person's reviewed revision of the current result (row decisions, notes,
    /// corrections and hand-added rows). It becomes current; every earlier revision stays in the
    /// history. Completing needs a note, no undecided row, valid typed fields, a reason for every
    /// change to what a source states, cited sources that still resolve, an open case and a result
    /// that was not blocked. A negative outcome (rows rejected, "inconclusive", "not effective") is a
    /// valid completion.
    @discardableResult
    public func saveReview(of base: JobResultRecord, rows: [JobResultRow], complete: Bool, note: String?,
                           actor: String, at date: Date = Date(), evidenceCheck: EvidenceCheck? = nil) async throws -> UUID {
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Each row's person entries are recomputed from its frozen source values.
        let rows = rows.map { r in var r = r; let p = r.personEntries(); r.assertions = p.isEmpty ? nil : p; return r }
        if complete {
            guard base.state != .blocked else { throw JobResultReviewError.blockedCannotComplete }
            guard let n = trimmedNote, !n.isEmpty else { throw JobResultReviewError.noteRequired }
            let undecided = rows.filter { $0.decision == nil }.count
            guard undecided == 0 else { throw JobResultReviewError.undecidedRows(undecided) }
            for (i, row) in rows.enumerated() {
                let missing = JobFields.missing(job: base.jobID, row: row)
                if !missing.isEmpty { throw JobResultReviewError.missingFields(row: i, fields: missing.map(\.label)) }
                if row.decision == .accepted, row.changedSourcedValue,
                   (row.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw JobResultReviewError.correctionNeedsReason(row: i)
                }
            }
            if let evidenceCheck {
                let unresolved = try await evidenceCheck(rows.filter { $0.decision == .accepted }.flatMap(\.refs))
                if !unresolved.isEmpty { throw JobResultReviewError.unresolvedEvidence(unresolved.count) }
            }
        }
        let who = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        var content = JobResultContent(rows: rows, limitations: base.content.limitations, nextActions: base.content.nextActions)
        content.review = JobResultReview(by: who, at: date, note: trimmedNote?.isEmpty == true ? nil : trimmedNote, completed: complete)
        if complete {
            // Frozen at completion: the digest of exactly the rows that were completed.
            let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
            content.review?.digest = StudioRecordRepository.sha256(try enc.encode(rows))
        }
        let family = JobResultFamily(rawValue: base.family) ?? .chronologyLinkage
        var writes = [Write(jobID: base.jobID, family: family, state: complete ? .completed : (base.state == .blocked ? .blocked : .draft),
                            content: content, expectedCurrent: base.id)]
        // An action reviewed as not effective reopens it in its register (a new revision there), in
        // the same savepoint as the review.
        if complete, let registerJob = JobExecutorKind.reviewedRegister[base.jobID],
           let register = try await latest(caseID: base.caseID, jobID: registerJob) {
            let ineffective = Set(rows.filter { $0.fields?["verdict"] == "not effective" }.map(\.title))
            if !ineffective.isEmpty {
                var reopened = register.content
                reopened.rows = register.content.rows.map { r in
                    guard ineffective.contains(r.title) else { return r }
                    var r = r; var f = r.fields ?? [:]; f["status"] = "reopened"; r.fields = f; r.decision = nil; return r
                }
                reopened.review = JobResultReview(by: who, at: date, note: "Reopened \(ineffective.count) action(s) reviewed as not effective", completed: false)
                writes.append(Write(jobID: registerJob, family: JobResultFamily(rawValue: register.family) ?? .actionEffectivenessClosure,
                                    state: .draft, content: reopened, expectedCurrent: register.id))
            }
        }
        return try await write(caseID: base.caseID, writes, requireOpen: true, actor: who, at: date)[0]
    }

    /// A1 — make an earlier revision current again (saved as a new revision; nothing is overwritten).
    /// `current` is the revision the person saw as current (B2: a newer save in between refuses).
    @discardableResult
    public func restore(_ old: JobResultRecord, over current: UUID? = nil, actor: String, at date: Date = Date()) async throws -> UUID {
        var content = old.content
        content.review = JobResultReview(by: actor, at: date, note: "Restored the revision of \(old.createdAt.formatted())", completed: false)
        let expected: UUID?
        if let current { expected = current } else { expected = try await latest(caseID: old.caseID, jobID: old.jobID)?.id }
        // A restored revision is reviewed again: a draft (or blocked when it has no rows), never the
        // "superseded" or "completed" mark the old revision carries.
        return try await write(caseID: old.caseID, [Write(jobID: old.jobID, family: JobResultFamily(rawValue: old.family) ?? .chronologyLinkage,
                                                         state: old.content.rows.isEmpty ? .blocked : .draft, content: content, expectedCurrent: expected)],
                               requireOpen: true, actor: actor, at: date)[0]
    }

    // MARK: - B2 — export: one frozen revision, rendered once, written, read back, recorded

    public struct ExportReceipt: Sendable, Equatable {
        public let exportID: UUID
        public let fileSHA256: String
        public let resultSHA256: String
    }

    /// Record an export of `resultID` after its bytes were written to `file` and read back equal.
    /// Refused when the revision is no longer current, or the file does not hold exactly `text`.
    public func recordExport(resultID: UUID, caseID: UUID, jobID: String, text: String, file: URL,
                             actor: String, at date: Date = Date()) async throws -> ExportReceipt {
        let who = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !who.isEmpty else { throw StudioRecordError.blankActor }
        let expected = StudioRecordRepository.sha256(Data(text.utf8))
        let written = try Data(contentsOf: file)
        guard StudioRecordRepository.sha256(written) == expected else { throw JobResultExportError.writtenBytesDiffer }
        let id = UUID()
        var resultSHA = ""
        try await database.withSavepoint("job_export_\(id.uuidString.prefix(8))") { db in
            guard let row = try db.query("SELECT payload_sha256, state FROM job_results WHERE id = ? AND case_id = ? LIMIT 1;",
                                         [.uuid(resultID), .uuid(caseID)]).first,
                  let sha = row.string(0) else { throw JobResultError.caseGone }
            guard row.string(1) != "superseded" else { throw JobResultReviewError.notCurrent }
            resultSHA = sha
            try db.exec("""
                INSERT INTO job_result_exports (id, result_id, case_id, job_id, result_sha256, file_name, file_sha256, snapshot_text, exported_by, exported_at)
                VALUES (?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(resultID), .uuid(caseID), .text(jobID), .text(sha), .text(file.lastPathComponent),
                      .text(expected), .text(text), .text(who), .date(date)])
        }
        return ExportReceipt(exportID: id, fileSHA256: expected, resultSHA256: resultSHA)
    }

    /// The recorded exports of a case's job results (newest first): id, result, file name, file digest.
    public func exports(caseID: UUID) async throws -> [(id: UUID, resultID: UUID, jobID: String, fileName: String, fileSHA256: String, text: String)] {
        try await database.query("SELECT id, result_id, job_id, file_name, file_sha256, snapshot_text FROM job_result_exports WHERE case_id = ? ORDER BY exported_at DESC;",
                                 [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let res = r.uuid(1), let job = r.string(2), let name = r.string(3), let sha = r.string(4), let text = r.string(5) else { return nil }
            return (id, res, job, name, sha, text)
        }
    }

    /// A1 — the case's current result for every job that has one.
    public func latestByJob(caseID: UUID) async throws -> [String: JobResultRecord] {
        let all = try await rows("WHERE case_id = ? AND state <> 'superseded' ORDER BY created_at DESC", [.uuid(caseID)])
        var out: [String: JobResultRecord] = [:]
        for r in all where out[r.jobID] == nil { out[r.jobID] = r }
        return out
    }

    /// The case's current result for a job (nil when it was never run).
    public func latest(caseID: UUID, jobID: String) async throws -> JobResultRecord? {
        try await rows("WHERE case_id = ? AND job_id = ? AND state <> 'superseded' ORDER BY created_at DESC LIMIT 1", [.uuid(caseID), .text(jobID)]).first
    }

    /// Every run of a job in the case, newest first (superseded ones included).
    public func history(caseID: UUID, jobID: String) async throws -> [JobResultRecord] {
        try await rows("WHERE case_id = ? AND job_id = ? ORDER BY created_at DESC", [.uuid(caseID), .text(jobID)])
    }

    private func rows(_ clause: String, _ params: [SQLValue]) async throws -> [JobResultRecord] {
        try await database.query("SELECT id, case_id, job_id, family, state, payload_json, created_by, created_at FROM job_results \(clause);", params)
            .compactMap { r in
                guard let id = r.uuid(0), let caseID = r.uuid(1), let job = r.string(2), let family = r.string(3),
                      let state = r.string(4).flatMap(JobResultState.init(rawValue:)), let json = r.string(5),
                      let content = try? JSONDecoder().decode(JobResultContent.self, from: Data(json.utf8)),
                      let by = r.string(6), let at = r.date(7) else { return nil }
                return JobResultRecord(id: id, caseID: caseID, jobID: job, family: family, state: state, content: content, createdBy: by, createdAt: at)
            }
    }
}
