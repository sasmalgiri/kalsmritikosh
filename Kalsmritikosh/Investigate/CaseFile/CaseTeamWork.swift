//
//  CaseTeamWork.swift
//  Kalsmritikosh
//
//  The ledger side of team work over a shared folder (v198; owner decision 2026-11-18: no server, no accounts). What a
//  case keeps about the folder it works through, the requests it published, what came back and what became of each file,
//  and the shared work records with their delivery state. The folder side is App/Team/TeamCaseExchange.swift; the steps
//  that touch both (publish, read, admit) are CaseTeamService.
//
//  Nothing here is an account: a member is an installation's signing key in the folder, named by the person who linked it.
//

import Foundation

public nonisolated struct CaseTeamLink: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    public let teamCaseID: String
    /// "team" (case members' work) or "contribution" (requests to outside contributors and what they submit).
    public let purpose: String
    public let folderLabel: String
    public let bookmark: Data?
    public let memberID: String
    public let displayName: String
    public let linkedBy: String
    public let linkedAt: Date
    public let lastReadAt: Date?
    public let lastError: String?
}

public nonisolated struct CaseTeamRequest: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let linkID: UUID
    public let title: String
    public let deliverable: String
    /// A member id of the folder, or "anyone".
    public let recipient: String
    public let due: String?
    public let inputsJSON: String
    public let workRef: String?
    public let createdBy: String
    public let createdAt: Date
    /// pending (not yet in the folder) · published · error (could not be written; tried again later)
    public let state: String
    public let stateDetail: String?
    public let publishedAt: Date?
    public let withdrawnAt: Date?
    public let withdrawnReason: String?

    public var isWithdrawn: Bool { withdrawnAt != nil }
    public var stateLine: String {
        if let r = withdrawnReason { return "Withdrawn — \(r)" }
        switch state {
        case "published": return "In the team folder"
        case "error": return "Not yet in the team folder — \(stateDetail ?? "it could not be written"); it is tried again on the next read"
        default: return "Waiting to be written to the team folder"
        }
    }
}

public nonisolated struct CaseTeamSubmissionFile: Sendable, Equatable, Hashable {
    public let sha256: String
    public let name: String
    public let bytes: Int
    /// waiting · received · duplicate · failed · declined
    public let status: String
    public let sourceVersionID: UUID?
    public let duplicateOf: String?
    public let detail: String?
}

public nonisolated struct CaseTeamSubmission: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let linkID: UUID
    public let requestID: UUID
    public let submitterMember: String
    public let submitterName: String
    public let note: String?
    public let submittedAt: String
    public let seenAt: Date
    /// waiting · received · partial · duplicate · declined
    public let outcome: String
    public let decidedBy: String?
    public let decidedAt: Date?
    /// none · pending · written · error — whether the contributor's receipt reached the folder.
    public let receiptState: String
    public let receiptDetail: String?
    public let files: [CaseTeamSubmissionFile]

    public var outcomeLine: String {
        switch outcome {
        case "received": return "Received into the case"
        case "partial": return "Partly received — some files could not be taken in"
        case "duplicate": return "Already received earlier (the same files)"
        case "declined": return "Declined"
        default: return "Waiting for your decision"
        }
    }
}

public nonisolated enum CaseTeamError: Error, LocalizedError, Equatable {
    case notLinked
    case otherInstallation
    case unknownSubmission
    case alreadyDecided
    case blank(String)

    public var errorDescription: String? {
        switch self {
        case .notLinked: return "This case is not linked to that team folder."
        case .otherInstallation: return "This Mac is not the member that linked the folder (a restored or moved ledger). Link the folder again to join it as this Mac."
        case .unknownSubmission: return "That submission is not known to this case."
        case .alreadyDecided: return "That submission was already decided."
        case .blank(let f): return "\(f) cannot be empty."
        }
    }
}

extension CaseFileRepository {

    // MARK: Links

    @discardableResult
    public func linkTeamFolder(caseID: UUID, teamCaseID: String, purpose: String, folderLabel: String, bookmark: Data?,
                               memberID: String, displayName: String, actor: String, at date: Date = Date()) async throws -> UUID {
        let who = try Self.clean(actor, "Actor"), label = try Self.clean(folderLabel, "Folder name"), name = try Self.clean(displayName, "Your name in the folder")
        let id = UUID()
        try await write("cf_tlink", caseID: caseID, actor: who, action: "teamFolderLinked", detail: "\(purpose) folder \(label) as \(name)", at: date) { db in
            try db.exec("""
                INSERT INTO case_team_links (id, case_id, team_case_id, purpose, folder_label, bookmark, member_id, display_name, linked_by, linked_at)
                VALUES (?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .text(teamCaseID), .text(purpose), .text(label), bookmark.map { .blob($0) } ?? .null,
                      .text(memberID), .text(name), .text(who), .date(date)])
        }
        return id
    }

    public func unlinkTeamFolder(caseID: UUID, linkID: UUID, actor: String, at date: Date = Date()) async throws {
        let who = try Self.clean(actor, "Actor")
        try await write("cf_tunlink", caseID: caseID, actor: who, action: "teamFolderUnlinked", detail: nil, at: date, allowedWhenClosed: true) { db in
            try db.exec("UPDATE case_team_links SET unlinked_by = ?, unlinked_at = ? WHERE id = ? AND case_id = ? AND unlinked_at IS NULL;",
                        [.text(who), .date(date), .uuid(linkID), .uuid(caseID)])
        }
    }

    public func teamLinks(caseID: UUID) async throws -> [CaseTeamLink] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT id, team_case_id, purpose, folder_label, bookmark, member_id, display_name, linked_by, linked_at, last_read_at, last_error
            FROM case_team_links WHERE case_id = ? AND unlinked_at IS NULL ORDER BY linked_at, rowid;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let t = r.string(1), let p = r.string(2), let l = r.string(3), let m = r.string(5),
                  let n = r.string(6), let by = r.string(7), let at = r.date(8) else { return nil }
            return CaseTeamLink(id: id, caseID: caseID, teamCaseID: t, purpose: p, folderLabel: l, bookmark: r.blob(4), memberID: m,
                                displayName: n, linkedBy: by, linkedAt: at, lastReadAt: r.date(9), lastError: r.string(10))
        }
    }

    /// Reading a folder is not a change to the case: when it was last read, and why it could not be (PERF-09).
    public func noteTeamRead(caseID: UUID, linkID: UUID, error: String?, at date: Date = Date()) async throws {
        try await CaseAccessPolicy.requireChange(database, caseID: caseID, actor: nil, .contribute)
        if let error {
            try await database.exec("UPDATE case_team_links SET last_error = ? WHERE id = ? AND case_id = ?;", [.text(error), .uuid(linkID), .uuid(caseID)])
        } else {
            try await database.exec("UPDATE case_team_links SET last_read_at = ?, last_error = NULL WHERE id = ? AND case_id = ?;",
                                    [.date(date), .uuid(linkID), .uuid(caseID)])
        }
    }

    // MARK: Requests (TEAM-02)

    @discardableResult
    public func createTeamRequest(caseID: UUID, linkID: UUID, title: String, deliverable: String, recipient: String, due: String?,
                                  inputsJSON: String, workRef: String?, actor: String, at date: Date = Date()) async throws -> UUID {
        let who = try Self.clean(actor, "Actor"), t = try Self.clean(title, "Title"), d = try Self.clean(deliverable, "What is wanted")
        let to = try Self.clean(recipient, "Who it is for")
        let id = UUID()
        try await write("cf_treq", caseID: caseID, actor: who, action: "teamRequestCreated", detail: "\(t) — for \(to)", at: date) { db in
            guard try !db.query("SELECT 1 FROM case_team_links WHERE id = ? AND case_id = ? AND unlinked_at IS NULL;", [.uuid(linkID), .uuid(caseID)]).isEmpty else {
                throw CaseTeamError.notLinked
            }
            try db.exec("""
                INSERT INTO case_team_requests (id, case_id, link_id, title, deliverable, recipient, due_text, inputs_json, work_ref, created_by, created_at, state)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,'pending');
                """, [.uuid(id), .uuid(caseID), .uuid(linkID), .text(t), .text(d), .text(to), .optionalText(Self.blankToNil(due)),
                      .text(inputsJSON), .optionalText(Self.blankToNil(workRef)), .text(who), .date(date)])
        }
        return id
    }

    /// Whether the request reached the folder (published, with its final inputs) or why not.
    public func setTeamRequestState(caseID: UUID, requestID: UUID, published: Bool, detail: String?, at date: Date = Date()) async throws {
        try await CaseAccessPolicy.requireChange(database, caseID: caseID, actor: nil, .work)
        try await database.exec("""
            UPDATE case_team_requests SET state = ?, state_detail = ?, published_at = CASE WHEN ? = 1 THEN coalesce(published_at, ?) ELSE published_at END
            WHERE id = ? AND case_id = ?;
            """, [.text(published ? "published" : "error"), .optionalText(detail), .integer(published ? 1 : 0), .date(date), .uuid(requestID), .uuid(caseID)])
    }

    public func withdrawTeamRequest(caseID: UUID, requestID: UUID, reason: String, actor: String, at date: Date = Date()) async throws {
        let who = try Self.clean(actor, "Actor"), why = try Self.clean(reason, "Reason")
        try await write("cf_treqw", caseID: caseID, actor: who, action: "teamRequestWithdrawn", detail: why, at: date, allowedWhenClosed: true) { db in
            try db.exec("UPDATE case_team_requests SET withdrawn_by = ?, withdrawn_at = ?, withdrawn_reason = ? WHERE id = ? AND case_id = ? AND withdrawn_at IS NULL;",
                        [.text(who), .date(date), .text(why), .uuid(requestID), .uuid(caseID)])
        }
    }

    public func teamRequests(caseID: UUID) async throws -> [CaseTeamRequest] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT id, link_id, title, deliverable, recipient, due_text, inputs_json, work_ref, created_by, created_at, state, state_detail,
                   published_at, withdrawn_at, withdrawn_reason
            FROM case_team_requests WHERE case_id = ? ORDER BY created_at, rowid;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let link = r.uuid(1), let t = r.string(2), let d = r.string(3), let to = r.string(4),
                  let inputs = r.string(6), let by = r.string(8), let at = r.date(9), let state = r.string(10) else { return nil }
            return CaseTeamRequest(id: id, linkID: link, title: t, deliverable: d, recipient: to, due: r.string(5), inputsJSON: inputs,
                                   workRef: r.string(7), createdBy: by, createdAt: at, state: state, stateDetail: r.string(11),
                                   publishedAt: r.date(12), withdrawnAt: r.date(13), withdrawnReason: r.string(14))
        }
    }

    // MARK: Submissions (TEAM-03 / TEAM-07)

    /// Record a submission seen in the folder (once per id; a second read adds nothing). Returns whether it was new.
    @discardableResult
    func noteTeamSubmission(caseID: UUID, linkID: UUID, submissionID: UUID, requestID: UUID, submitterMember: String, submitterName: String,
                                   note: String?, submittedAt: String, files: [TeamFileRef], at date: Date = Date()) async throws -> Bool {
        try await CaseAccessPolicy.requireChange(database, caseID: caseID, actor: nil, .contribute)
        let sp = "cf_tsub_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        return try await database.withSavepoint(sp) { db in
            guard try db.query("SELECT 1 FROM case_team_submissions WHERE id = ?;", [.uuid(submissionID)]).isEmpty else { return false }
            try db.exec("""
                INSERT INTO case_team_submissions (id, case_id, link_id, request_id, submitter_member, submitter_name, note, submitted_at, seen_at, outcome, receipt_state)
                VALUES (?,?,?,?,?,?,?,?,?,'waiting','none');
                """, [.uuid(submissionID), .uuid(caseID), .uuid(linkID), .uuid(requestID), .text(submitterMember), .text(submitterName),
                      .optionalText(Self.blankToNil(note)), .text(submittedAt), .date(date)])
            for f in files {
                try db.exec("""
                    INSERT OR IGNORE INTO case_team_submission_files (submission_id, case_id, sha256, name, bytes, status) VALUES (?,?,?,?,?,'waiting');
                    """, [.uuid(submissionID), .uuid(caseID), .text(f.sha256), .text(f.name), .integer(Int64(f.bytes))])
            }
            return true
        }
    }

    public func teamSubmissions(caseID: UUID) async throws -> [CaseTeamSubmission] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        let fileRows = try await database.query("""
            SELECT submission_id, sha256, name, bytes, status, source_version_id, duplicate_of, detail FROM case_team_submission_files
            WHERE case_id = ? ORDER BY name, sha256;
            """, [.uuid(caseID)])
        var files: [UUID: [CaseTeamSubmissionFile]] = [:]
        for r in fileRows {
            guard let s = r.uuid(0), let sha = r.string(1), let n = r.string(2), let st = r.string(4) else { continue }
            files[s, default: []].append(CaseTeamSubmissionFile(sha256: sha, name: n, bytes: Int(r.int(3) ?? 0), status: st,
                                                                sourceVersionID: r.uuid(5), duplicateOf: r.string(6), detail: r.string(7)))
        }
        return try await database.query("""
            SELECT id, link_id, request_id, submitter_member, submitter_name, note, submitted_at, seen_at, outcome, decided_by, decided_at,
                   receipt_state, receipt_detail
            FROM case_team_submissions WHERE case_id = ? ORDER BY seen_at, rowid;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let link = r.uuid(1), let req = r.uuid(2), let m = r.string(3), let n = r.string(4),
                  let sub = r.string(6), let seen = r.date(7), let o = r.string(8), let rs = r.string(11) else { return nil }
            return CaseTeamSubmission(id: id, linkID: link, requestID: req, submitterMember: m, submitterName: n, note: r.string(5),
                                      submittedAt: sub, seenAt: seen, outcome: o, decidedBy: r.string(9), decidedAt: r.date(10),
                                      receiptState: rs, receiptDetail: r.string(12), files: files[id] ?? [])
        }
    }

    /// The earlier submission of this case that already brought a file with this content, if any (TEAM-07 dedupe).
    public func teamFileAlreadyReceived(caseID: UUID, sha256: String, except submissionID: UUID) async throws -> (submission: UUID, version: UUID)? {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        guard let r = try await database.query("""
            SELECT submission_id, source_version_id FROM case_team_submission_files
            WHERE case_id = ? AND sha256 = ? AND status = 'received' AND submission_id <> ? LIMIT 1;
            """, [.uuid(caseID), .text(sha256), .uuid(submissionID)]).first, let s = r.uuid(0), let v = r.uuid(1) else { return nil }
        return (s, v)
    }

    /// What became of one submitted file.
    public func setTeamFileOutcome(caseID: UUID, submissionID: UUID, sha256: String, status: String, sourceVersionID: UUID?,
                                   duplicateOf: String?, detail: String?) async throws {
        try await CaseAccessPolicy.requireChange(database, caseID: caseID, actor: nil, .work)
        try await database.exec("""
            UPDATE case_team_submission_files SET status = ?, source_version_id = ?, duplicate_of = ?, detail = ?
            WHERE submission_id = ? AND case_id = ? AND sha256 = ?;
            """, [.text(status), sourceVersionID.map { .uuid($0) } ?? .null, .optionalText(duplicateOf), .optionalText(detail),
                  .uuid(submissionID), .uuid(caseID), .text(sha256)])
    }

    /// The decision on a submission (recorded once), from what became of its files.
    public func decideTeamSubmission(caseID: UUID, submissionID: UUID, outcome: String, actor: String, at date: Date = Date()) async throws {
        let who = try Self.clean(actor, "Actor")
        try await write("cf_tsubd", caseID: caseID, actor: who, action: "teamSubmissionDecided", detail: outcome, at: date) { db in
            guard let row = try db.query("SELECT decided_at FROM case_team_submissions WHERE id = ? AND case_id = ?;", [.uuid(submissionID), .uuid(caseID)]).first else {
                throw CaseTeamError.unknownSubmission
            }
            guard row.date(0) == nil else { throw CaseTeamError.alreadyDecided }
            try db.exec("UPDATE case_team_submissions SET outcome = ?, decided_by = ?, decided_at = ?, receipt_state = 'pending' WHERE id = ? AND case_id = ?;",
                        [.text(outcome), .text(who), .date(date), .uuid(submissionID), .uuid(caseID)])
        }
    }

    /// Whether the contributor's receipt reached the folder.
    public func setTeamReceiptState(caseID: UUID, submissionID: UUID, written: Bool, detail: String?) async throws {
        try await CaseAccessPolicy.requireChange(database, caseID: caseID, actor: nil, .work)
        try await database.exec("UPDATE case_team_submissions SET receipt_state = ?, receipt_detail = ? WHERE id = ? AND case_id = ?;",
                                [.text(written ? "written" : "error"), .optionalText(detail), .uuid(submissionID), .uuid(caseID)])
    }
}
