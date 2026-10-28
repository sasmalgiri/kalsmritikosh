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
    public init(title: String, detail: String? = nil, date: String? = nil, flags: [String] = [], refs: [StudioEvidenceRef] = [],
                decision: JobRowDecision? = nil, note: String? = nil, fields: [String: String]? = nil) {
        self.title = title; self.detail = detail; self.date = date; self.flags = flags; self.refs = refs
        self.decision = decision; self.note = note; self.fields = fields
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
    public var errorDescription: String? {
        switch self {
        case .blockedCannotComplete: return "A blocked result cannot be completed: give the job what it is missing and run it again."
        case .noteRequired: return "Completing a result needs your note (what you checked and why it is complete)."
        case .undecidedRows(let n): return "\(n) row(s) are still undecided. Accept or reject each one before completing."
        case .notCurrent: return "This is an earlier revision. Restore it as current first, or review the current one."
        case .missingFields(let row, let fields): return "Row \(row + 1) is accepted but still needs: \(fields.joined(separator: ", "))."
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

    /// Save a run; the case's earlier current result for the same job becomes superseded.
    @discardableResult
    public func save(caseID: UUID, jobID: String, family: JobResultFamily, state: JobResultState,
                     content: JobResultContent, actor: String, at date: Date = Date()) async throws -> UUID {
        let who = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !who.isEmpty else { throw StudioRecordError.blankActor }
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let payload = try enc.encode(content)
        let id = UUID()
        try await database.withSavepoint("job_result_\(id.uuidString.prefix(8))") { db in
            // T1 — a result that finishes after its case was erased (or never existed) writes nothing:
            // checked inside the savepoint, so it cannot interleave with an erase.
            guard try db.query("SELECT 1 FROM investigation_cases WHERE id = ? LIMIT 1;", [.uuid(caseID)]).first != nil else {
                throw JobResultError.caseGone
            }
            try db.exec("UPDATE job_results SET state = 'superseded', superseded_by = ? WHERE case_id = ? AND job_id = ? AND state <> 'superseded';",
                        [.uuid(id), .uuid(caseID), .text(jobID)])
            try db.exec("""
                INSERT INTO job_results (id, case_id, job_id, family, state, payload_json, payload_sha256, created_by, created_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .text(jobID), .text(family.rawValue), .text(state.rawValue),
                      .text(String(decoding: payload, as: UTF8.self)), .text(StudioRecordRepository.sha256(payload)), .text(who), .date(date)])
        }
        return id
    }

    /// A1 — save the person's reviewed revision of the current result (row decisions, notes and
    /// corrections). It becomes current; every earlier revision stays in the history. Completing
    /// needs a note, no undecided row, and a result that was not blocked.
    @discardableResult
    public func saveReview(of base: JobResultRecord, rows: [JobResultRow], complete: Bool, note: String?,
                           actor: String, at date: Date = Date()) async throws -> UUID {
        guard try await latest(caseID: base.caseID, jobID: base.jobID)?.id == base.id else { throw JobResultReviewError.notCurrent }
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        if complete {
            guard base.state != .blocked else { throw JobResultReviewError.blockedCannotComplete }
            guard let n = trimmedNote, !n.isEmpty else { throw JobResultReviewError.noteRequired }
            let undecided = rows.filter { $0.decision == nil }.count
            guard undecided == 0 else { throw JobResultReviewError.undecidedRows(undecided) }
            // The contract's columns: every accepted row carries every required field.
            for (i, row) in rows.enumerated() {
                let missing = JobFields.missing(job: base.jobID, row: row)
                if !missing.isEmpty { throw JobResultReviewError.missingFields(row: i, fields: missing.map(\.label)) }
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
        let id = try await save(caseID: base.caseID, jobID: base.jobID, family: family,
                                state: complete ? .completed : (base.state == .blocked ? .blocked : .draft),
                                content: content, actor: who, at: date)
        // An action reviewed as not effective reopens it in its register (a new revision there).
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
                try await save(caseID: base.caseID, jobID: registerJob, family: JobResultFamily(rawValue: register.family) ?? .actionEffectivenessClosure,
                               state: .draft, content: reopened, actor: who, at: date)
            }
        }
        return id
    }

    /// A1 — make an earlier revision current again (saved as a new revision; nothing is overwritten).
    @discardableResult
    public func restore(_ old: JobResultRecord, actor: String, at date: Date = Date()) async throws -> UUID {
        var content = old.content
        content.review = JobResultReview(by: actor, at: date, note: "Restored the revision of \(old.createdAt.formatted())", completed: false)
        return try await save(caseID: old.caseID, jobID: old.jobID, family: JobResultFamily(rawValue: old.family) ?? .chronologyLinkage,
                              // A restored revision is reviewed again: a draft (or blocked when it has no rows),
                              // never the "superseded" or "completed" mark the old revision carries.
                              state: old.content.rows.isEmpty ? .blocked : .draft, content: content, actor: actor, at: date)
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
