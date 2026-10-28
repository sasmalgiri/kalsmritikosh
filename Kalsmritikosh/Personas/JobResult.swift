//
//  JobResult.swift
//  Kalsmritikosh
//
//  Final completion instructions §3 — the typed, persisted result of a job run by a shared executor:
//  rows (each with its exact source references and flags such as "disputed date"), the limitations
//  of the run (what was missing or not covered) and the next actions it leaves for the person.
//

import Foundation

public nonisolated enum JobResultState: String, Codable, Sendable { case draft, blocked, completed, superseded }

public nonisolated struct JobResultRow: Codable, Sendable, Hashable {
    public let title: String
    public let detail: String?
    /// ISO day ("2026-01-05"), or nil when the row is undated.
    public let date: String?
    public let flags: [String]
    public let refs: [StudioEvidenceRef]
    public init(title: String, detail: String? = nil, date: String? = nil, flags: [String] = [], refs: [StudioEvidenceRef] = []) {
        self.title = title; self.detail = detail; self.date = date; self.flags = flags; self.refs = refs
    }
}

public nonisolated struct JobResultContent: Codable, Sendable, Hashable {
    public let rows: [JobResultRow]
    public let limitations: [String]
    public let nextActions: [String]
    public init(rows: [JobResultRow], limitations: [String] = [], nextActions: [String] = []) {
        self.rows = rows; self.limitations = limitations; self.nextActions = nextActions
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
