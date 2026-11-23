//
//  CaseTeamSwarmLedger.swift
//  Kalsmritikosh
//
//  Speed PERF-40 torrent (owner 2026-11-23) — not tested yet. The ledger side of a team swarm (v207): the case's opt-in
//  ("Share the work of this import with the team"), the shared imports the case takes part in, and what this Mac did
//  with each piece. The folder side is App/Team/TeamSwarm.swift; the steps that touch both are AppState+TeamSwarm.
//

import Foundation

public nonisolated struct CaseTeamSwarmOptIn: Sendable, Equatable {
    public let caseID: UUID
    public let linkID: UUID
    public let enabled: Bool
    public let changedBy: String
    public let changedAt: Date
    public let announced: Bool
}

public nonisolated struct CaseTeamSwarmProgress: Sendable, Equatable, Identifiable {
    public let id: String
    public let linkID: UUID
    public let title: String
    public let authoredHere: Bool
    public let pieces: Int
    public let files: Int
    public let state: String
    public let lastError: String?
    public let doneByMe: Int
    public let doneByOthers: Int
    public let merged: Int

    /// Plain words for the Team folder tool.
    public var line: String {
        let done = doneByMe + doneByOthers
        var s = "“\(title)”: \(done) of \(pieces) piece(s) done — \(doneByMe) by this Mac, \(doneByOthers) by others; \(merged) joined into this Mac's ledger."
        if let lastError { s += " Last problem: \(lastError)." }
        return s
    }
}

extension CaseFileRepository {

    // MARK: Opt-in

    public func swarmOptIn(caseID: UUID, linkID: UUID) async throws -> CaseTeamSwarmOptIn? {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT enabled, changed_by, changed_at, announced FROM case_team_swarm_optins WHERE case_id = ? AND link_id = ?;
            """, [.uuid(caseID), .uuid(linkID)]).first.flatMap { r in
            guard let by = r.string(1), let at = r.date(2) else { return nil }
            return CaseTeamSwarmOptIn(caseID: caseID, linkID: linkID, enabled: (r.int(0) ?? 0) == 1, changedBy: by, changedAt: at,
                                      announced: (r.int(3) ?? 0) == 1)
        }
    }

    /// Every case link with sharing turned on (the background swarm pass walks these).
    public func swarmOptInsEnabled() async throws -> [CaseTeamSwarmOptIn] {
        try await database.query("""
            SELECT o.case_id, o.link_id, o.changed_by, o.changed_at, o.announced FROM case_team_swarm_optins o
            JOIN case_team_links l ON l.id = o.link_id AND l.case_id = o.case_id AND l.unlinked_at IS NULL
            WHERE o.enabled = 1 ORDER BY o.changed_at;
            """, []).compactMap { r in
            guard let c = r.uuid(0), let l = r.uuid(1), let by = r.string(2), let at = r.date(3) else { return nil }
            return CaseTeamSwarmOptIn(caseID: c, linkID: l, enabled: true, changedBy: by, changedAt: at, announced: (r.int(4) ?? 0) == 1)
        }
    }

    public func setSwarmOptIn(caseID: UUID, linkID: UUID, enabled: Bool, actor: String, at date: Date = Date()) async throws {
        let who = try Self.clean(actor, "Actor")
        try await write("cf_swarm", caseID: caseID, actor: who, action: enabled ? "teamSwarmOn" : "teamSwarmOff",
                        detail: enabled ? "shares the work of team imports" : "stopped sharing the work of team imports", at: date) { db in
            try db.exec("""
                INSERT INTO case_team_swarm_optins (case_id, link_id, enabled, changed_by, changed_at, announced) VALUES (?,?,?,?,?,0)
                ON CONFLICT (case_id, link_id) DO UPDATE SET enabled = excluded.enabled, changed_by = excluded.changed_by,
                    changed_at = excluded.changed_at, announced = 0;
                """, [.uuid(caseID), .uuid(linkID), .integer(enabled ? 1 : 0), .text(who), .date(date)])
        }
    }

    public func markSwarmOptInAnnounced(caseID: UUID, linkID: UUID) async throws {
        try await database.exec("UPDATE case_team_swarm_optins SET announced = 1 WHERE case_id = ? AND link_id = ?;", [.uuid(caseID), .uuid(linkID)])
    }

    // MARK: Swarms and pieces

    /// Record a swarm this case takes part in (idempotent).
    public func noteSwarm(caseID: UUID, linkID: UUID, id: String, title: String, authoredHere: Bool, authorMember: String,
                          pieces: Int, files: Int, manifestSHA256: String, at date: Date = Date()) async throws {
        try await CaseAccessPolicy.requireChange(database, caseID: caseID, actor: nil, .contribute)
        try await database.exec("""
            INSERT OR IGNORE INTO case_team_swarms (id, case_id, link_id, title, authored_here, author_member, pieces, files,
                manifest_sha256, state, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,'running',?,?);
            """, [.text(id), .uuid(caseID), .uuid(linkID), .text(title), .integer(authoredHere ? 1 : 0), .text(authorMember),
                  .integer(Int64(pieces)), .integer(Int64(files)), .text(manifestSHA256), .date(date), .date(date)])
    }

    public func setSwarmState(caseID: UUID, id: String, state: String, error: String?, at date: Date = Date()) async throws {
        try await database.exec("UPDATE case_team_swarms SET state = ?, last_error = ?, updated_at = ? WHERE id = ? AND case_id = ?;",
                                [.text(state), error.map(SQLValue.text) ?? .null, .date(date), .text(id), .uuid(caseID)])
    }

    /// Set a piece's state here (open / claimed / published / merged / failed).
    public func setSwarmPiece(caseID: UUID, swarmID: String, piece: Int, state: String, byMember: String?, byMe: Bool,
                              claimedHere: Bool = false, publishedHere: Bool = false, detail: String? = nil, at date: Date = Date()) async throws {
        try await database.exec("""
            INSERT INTO case_team_swarm_pieces (swarm_id, case_id, piece, state, by_member, by_me, claimed_here, published_here,
                merged_at, detail, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT (swarm_id, piece) DO UPDATE SET state = excluded.state,
                by_member = COALESCE(excluded.by_member, case_team_swarm_pieces.by_member),
                by_me = MAX(case_team_swarm_pieces.by_me, excluded.by_me),
                claimed_here = MAX(case_team_swarm_pieces.claimed_here, excluded.claimed_here),
                published_here = MAX(case_team_swarm_pieces.published_here, excluded.published_here),
                merged_at = COALESCE(case_team_swarm_pieces.merged_at, excluded.merged_at),
                detail = excluded.detail, updated_at = excluded.updated_at;
            """, [.text(swarmID), .uuid(caseID), .integer(Int64(piece)), .text(state), byMember.map(SQLValue.text) ?? .null,
                  .integer(byMe ? 1 : 0), .integer(claimedHere ? 1 : 0), .integer(publishedHere ? 1 : 0),
                  state == "merged" ? .date(date) : .null, detail.map(SQLValue.text) ?? .null, .date(date)])
    }

    /// The pieces this Mac has already merged for a swarm.
    public func mergedSwarmPieces(swarmID: String) async throws -> Set<Int> {
        Set(try await database.query("SELECT piece FROM case_team_swarm_pieces WHERE swarm_id = ? AND merged_at IS NOT NULL;",
                                     [.text(swarmID)]).compactMap { $0.int(0).map(Int.init) })
    }

    /// The pieces this Mac has already published (it never publishes a piece twice).
    public func publishedSwarmPieces(swarmID: String) async throws -> Set<Int> {
        Set(try await database.query("SELECT piece FROM case_team_swarm_pieces WHERE swarm_id = ? AND published_here = 1;",
                                     [.text(swarmID)]).compactMap { $0.int(0).map(Int.init) })
    }

    public func swarmProgress(caseID: UUID) async throws -> [CaseTeamSwarmProgress] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT s.id, s.link_id, s.title, s.authored_here, s.pieces, s.files, s.state, s.last_error,
                (SELECT COUNT(*) FROM case_team_swarm_pieces p WHERE p.swarm_id = s.id AND p.by_member IS NOT NULL AND p.by_me = 1),
                (SELECT COUNT(*) FROM case_team_swarm_pieces p WHERE p.swarm_id = s.id AND p.by_member IS NOT NULL AND p.by_me = 0),
                (SELECT COUNT(*) FROM case_team_swarm_pieces p WHERE p.swarm_id = s.id AND p.merged_at IS NOT NULL)
            FROM case_team_swarms s WHERE s.case_id = ? ORDER BY s.created_at, s.rowid;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.string(0), let l = r.uuid(1), let t = r.string(2), let st = r.string(6) else { return nil }
            return CaseTeamSwarmProgress(id: id, linkID: l, title: t, authoredHere: (r.int(3) ?? 0) == 1, pieces: Int(r.int(4) ?? 0),
                                         files: Int(r.int(5) ?? 0), state: st, lastError: r.string(7), doneByMe: Int(r.int(8) ?? 0),
                                         doneByOthers: Int(r.int(9) ?? 0), merged: Int(r.int(10) ?? 0))
        }
    }

    /// What an erasure of this case must remove from the team folders: per link, its swarms and the ones started here.
    public func swarmFootprint(caseID: UUID) async throws -> [(link: CaseTeamLink, swarms: [String], authored: Set<String>)] {
        let rows = try await database.query("SELECT id, link_id, authored_here FROM case_team_swarms WHERE case_id = ?;", [.uuid(caseID)])
        guard !rows.isEmpty else { return [] }
        let links = try await teamLinks(caseID: caseID)
        var out: [(CaseTeamLink, [String], Set<String>)] = []
        for l in links {
            let mine = rows.filter { $0.uuid(1) == l.id }
            guard !mine.isEmpty else { continue }
            out.append((l, mine.compactMap { $0.string(0) }, Set(mine.filter { ($0.int(2) ?? 0) == 1 }.compactMap { $0.string(0) })))
        }
        return out.map { (link: $0.0, swarms: $0.1, authored: $0.2) }
    }
}
