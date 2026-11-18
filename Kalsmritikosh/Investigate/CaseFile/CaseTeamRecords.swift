//
//  CaseTeamRecords.swift
//  Kalsmritikosh
//
//  Shared work over a team folder (TEAM-05 / TEAM-06, v198): assignments and action reviews that the case's members see
//  on each Mac. Each record has a stable id, a revision and the revision it was made from. A change is pending until it
//  is in the folder (then confirmed; error if it could not be written) — a local change is never shown as seen by the
//  team before it is there. Another member's change made from the revision this Mac holds replaces it; two changes made
//  from the same revision by different members are both kept as a conflict for a person to resolve (no last-write-wins).
//

import Foundation
import CryptoKit
import os

public nonisolated enum CaseTeamRecordKind: String, Sendable, CaseIterable {
    case assignment
    case actionReview

    public var label: String {
        switch self {
        case .assignment: return "Assignment"
        case .actionReview: return "Action review"
        }
    }
}

public nonisolated struct CaseTeamRecord: Identifiable, Sendable, Equatable {
    public var id: String { "\(kind.rawValue):\(teamRecordID)" }
    public let linkID: UUID
    public let kind: CaseTeamRecordKind
    public let teamRecordID: String
    public let localID: String?
    public let label: String
    public let revision: Int
    public let baseRevision: Int
    public let payload: [String: String]
    public let authorMember: String
    public let authorName: String
    /// pending · confirmed · error (this Mac's change) · received (another member's)
    public let state: String
    public let stateDetail: String?
    public let updatedAt: Date

    public var stateLine: String {
        switch state {
        case "confirmed": return "In the team folder (revision \(revision))"
        case "received": return "From \(authorName) (revision \(revision))"
        case "error": return "Only on this Mac — not yet in the team folder (\(stateDetail ?? "it could not be written")); tried again on the next read"
        default: return "Only on this Mac — waiting to be written to the team folder"
        }
    }
}

public nonisolated struct CaseTeamConflict: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let linkID: UUID
    public let kind: CaseTeamRecordKind
    public let teamRecordID: String
    public let label: String
    public let baseRevision: Int
    public let localRevision: Int
    public let localPayload: [String: String]
    public let localAuthor: String
    public let remoteRevision: Int
    public let remotePayload: [String: String]
    public let remoteAuthor: String
    public let foundAt: Date
    public let resolution: String?
    public let resolvedBy: String?
    public let resolvedAt: Date?
}

private nonisolated func payloadJSON(_ p: [String: String]) -> String {
    (try? JSONSerialization.data(withJSONObject: p, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
}
private nonisolated func payloadFrom(_ s: String?) -> [String: String] {
    guard let s, let d = s.data(using: .utf8) else { return [:] }
    return ((try? JSONSerialization.jsonObject(with: d)) as? [String: String]) ?? [:]
}

extension CaseFileRepository {

    public func teamRecords(caseID: UUID) async throws -> [CaseTeamRecord] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT link_id, record_kind, team_record_id, local_id, label, revision, base_revision, payload_json, author_member, author_name,
                   state, state_detail, updated_at
            FROM case_team_records WHERE case_id = ? ORDER BY updated_at DESC, rowid;
            """, [.uuid(caseID)]).compactMap { r in
            guard let link = r.uuid(0), let k = r.string(1).flatMap(CaseTeamRecordKind.init(rawValue:)), let tid = r.string(2), let label = r.string(4),
                  let rev = r.int(5), let base = r.int(6), let am = r.string(8), let an = r.string(9), let st = r.string(10), let at = r.date(12) else { return nil }
            return CaseTeamRecord(linkID: link, kind: k, teamRecordID: tid, localID: r.string(3), label: label, revision: Int(rev), baseRevision: Int(base),
                                  payload: payloadFrom(r.string(7)), authorMember: am, authorName: an, state: st, stateDetail: r.string(11), updatedAt: at)
        }
    }

    /// Store a record as this Mac now holds it (a local change: pending; another member's: received).
    func putTeamRecord(caseID: UUID, linkID: UUID, kind: CaseTeamRecordKind, teamRecordID: String, localID: String?, label: String,
                       revision: Int, base: Int, payload: [String: String], authorMember: String, authorName: String, state: String,
                       at date: Date) async throws {
        try await CaseAccessPolicy.requireChange(database, caseID: caseID, actor: nil, .contribute)
        try await database.exec("""
            INSERT INTO case_team_records (case_id, link_id, record_kind, team_record_id, local_id, label, revision, base_revision, payload_json,
                                           author_member, author_name, state, state_detail, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,NULL,?)
            ON CONFLICT (case_id, link_id, record_kind, team_record_id) DO UPDATE SET
                local_id = coalesce(excluded.local_id, local_id), label = excluded.label, revision = excluded.revision,
                base_revision = excluded.base_revision, payload_json = excluded.payload_json, author_member = excluded.author_member,
                author_name = excluded.author_name, state = excluded.state, state_detail = NULL, updated_at = excluded.updated_at;
            """, [.uuid(caseID), .uuid(linkID), .text(kind.rawValue), .text(teamRecordID), .optionalText(localID), .text(label),
                  .integer(Int64(revision)), .integer(Int64(base)), .text(payloadJSON(payload)), .text(authorMember), .text(authorName),
                  .text(state), .date(date)])
    }

    func setTeamRecordState(caseID: UUID, linkID: UUID, kind: CaseTeamRecordKind, teamRecordID: String, revision: Int, state: String, detail: String?) async throws {
        try await CaseAccessPolicy.requireChange(database, caseID: caseID, actor: nil, .contribute)
        try await database.exec("""
            UPDATE case_team_records SET state = ?, state_detail = ?
            WHERE case_id = ? AND link_id = ? AND record_kind = ? AND team_record_id = ? AND revision = ?;
            """, [.text(state), .optionalText(detail), .uuid(caseID), .uuid(linkID), .text(kind.rawValue), .text(teamRecordID), .integer(Int64(revision))])
    }

    /// Keep both sides of two edits made from the same revision (once per pair). Returns whether it is new.
    func keepTeamConflict(caseID: UUID, linkID: UUID, local: CaseTeamRecord, remote: TeamSigned<TeamWorkRecord>, at date: Date) async throws -> Bool {
        try await CaseAccessPolicy.requireChange(database, caseID: caseID, actor: nil, .contribute)
        guard try await database.query("""
            SELECT 1 FROM case_team_conflicts WHERE case_id = ? AND record_kind = ? AND team_record_id = ? AND local_revision = ?
              AND remote_revision = ? AND remote_author = ? LIMIT 1;
            """, [.uuid(caseID), .text(local.kind.rawValue), .text(local.teamRecordID), .integer(Int64(local.revision)),
                  .integer(Int64(remote.value.revision)), .text(remote.memberName)]).isEmpty else { return false }
        try await database.exec("""
            INSERT OR IGNORE INTO case_team_conflicts (id, case_id, link_id, record_kind, team_record_id, label, base_revision, local_revision,
                local_payload, local_author, remote_revision, remote_payload, remote_author, found_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(caseID), .uuid(linkID), .text(local.kind.rawValue), .text(local.teamRecordID), .text(local.label),
                  .integer(Int64(remote.value.base)), .integer(Int64(local.revision)), .text(payloadJSON(local.payload)), .text(local.authorName),
                  .integer(Int64(remote.value.revision)), .text(payloadJSON(remote.value.payload)), .text(remote.memberName), .date(date)])
        return true
    }

    public func teamConflicts(caseID: UUID) async throws -> [CaseTeamConflict] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT id, link_id, record_kind, team_record_id, label, base_revision, local_revision, local_payload, local_author,
                   remote_revision, remote_payload, remote_author, found_at, resolution, resolved_by, resolved_at
            FROM case_team_conflicts WHERE case_id = ? ORDER BY found_at, rowid;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let link = r.uuid(1), let k = r.string(2).flatMap(CaseTeamRecordKind.init(rawValue:)), let tid = r.string(3),
                  let label = r.string(4), let base = r.int(5), let lr = r.int(6), let la = r.string(8), let rr = r.int(9), let ra = r.string(11),
                  let at = r.date(12) else { return nil }
            return CaseTeamConflict(id: id, linkID: link, kind: k, teamRecordID: tid, label: label, baseRevision: Int(base), localRevision: Int(lr),
                                    localPayload: payloadFrom(r.string(7)), localAuthor: la, remoteRevision: Int(rr), remotePayload: payloadFrom(r.string(10)),
                                    remoteAuthor: ra, foundAt: at, resolution: r.string(13), resolvedBy: r.string(14), resolvedAt: r.date(15))
        }
    }

    func recordTeamConflictResolution(caseID: UUID, conflictID: UUID, resolution: String, payload: [String: String], note: String?,
                                      actor: String, at date: Date) async throws {
        let who = try Self.clean(actor, "Actor")
        try await write("cf_tconf", caseID: caseID, actor: who, action: "teamConflictResolved", detail: resolution, at: date) { db in
            try db.exec("""
                UPDATE case_team_conflicts SET resolution = ?, resolved_payload = ?, resolved_by = ?, resolved_at = ?, note = ?
                WHERE id = ? AND case_id = ? AND resolved_at IS NULL;
                """, [.text(resolution), .text(payloadJSON(payload)), .text(who), .date(date), .optionalText(Self.blankToNil(note)),
                      .uuid(conflictID), .uuid(caseID)])
        }
    }
}

extension CaseTeamService {

    /// Share a piece of work with the team (a new record, or a change to one this Mac holds): pending in the case, then
    /// written to the folder (confirmed) — or kept with the error and retried on the next read.
    @discardableResult
    func shareWork(caseID: UUID, linkID: UUID, kind: CaseTeamRecordKind, teamRecordID: String? = nil, localID: String?, label: String,
                          payload: [String: String], key: Curve25519.Signing.PrivateKey, actor: String, at date: Date = Date()) async throws -> CaseTeamRecord {
        try await CaseAccessPolicy.requireChange(file.database, caseID: caseID, actor: actor, .work)
        guard let l = try await file.teamLinks(caseID: caseID).first(where: { $0.id == linkID }) else { throw CaseTeamError.notLinked }
        guard TeamIdentity.memberID(key.publicKey) == l.memberID else { throw CaseTeamError.otherInstallation }
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CaseTeamError.blank("What the work is") }
        let tid = teamRecordID ?? localID ?? UUID().uuidString
        let held = try await file.teamRecords(caseID: caseID).first { $0.linkID == linkID && $0.kind == kind && $0.teamRecordID == tid }
        let base = held?.revision ?? 0
        try await file.putTeamRecord(caseID: caseID, linkID: linkID, kind: kind, teamRecordID: tid, localID: localID, label: name,
                                     revision: base + 1, base: base, payload: payload, authorMember: l.memberID, authorName: l.displayName,
                                     state: "pending", at: date)
        try await publish(caseID: caseID, l: l, kind: kind, teamRecordID: tid, key: key)
        guard let r = try await file.teamRecords(caseID: caseID).first(where: { $0.linkID == linkID && $0.kind == kind && $0.teamRecordID == tid }) else {
            throw CaseTeamError.notLinked
        }
        return r
    }

    private func publish(caseID: UUID, l: CaseTeamLink, kind: CaseTeamRecordKind, teamRecordID: String, key: Curve25519.Signing.PrivateKey) async throws {
        guard let r = try await file.teamRecords(caseID: caseID).first(where: { $0.linkID == l.id && $0.kind == kind && $0.teamRecordID == teamRecordID }),
              r.authorMember == l.memberID else { return }
        do {
            guard let (url, scoped) = Self.resolve(l.bookmark) else { throw TeamFolderError.unreachable("its location could not be found") }
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let folder = TeamCase.open(url), folder.reachable() else { throw TeamFolderError.unreachable("it is not available now") }
            try folder.publishRecord(TeamWorkRecord(kind: kind.rawValue, id: teamRecordID, label: r.label, revision: r.revision, base: r.baseRevision,
                                                    payload: r.payload), member: l.memberID, key: key)
            try await file.setTeamRecordState(caseID: caseID, linkID: l.id, kind: kind, teamRecordID: teamRecordID, revision: r.revision, state: "confirmed", detail: nil)
        } catch {
            KalsmritikoshLog.app.error("Shared work not written to the team folder: \(error.localizedDescription, privacy: .private)")
            try await file.setTeamRecordState(caseID: caseID, linkID: l.id, kind: kind, teamRecordID: teamRecordID, revision: r.revision, state: "error",
                                              detail: error.localizedDescription)
        }
    }

    /// This Mac's changes still waiting for the folder, written now. Returns how many reached it.
    func retryRecords(caseID: UUID, l: CaseTeamLink, folder: TeamCase, key: Curve25519.Signing.PrivateKey, at date: Date) async throws -> Int {
        try await CaseAccessPolicy.requireRead(file.database, caseID: caseID)
        var n = 0
        for r in try await file.teamRecords(caseID: caseID) where r.linkID == l.id && r.authorMember == l.memberID && (r.state == "pending" || r.state == "error") {
            do {
                try folder.publishRecord(TeamWorkRecord(kind: r.kind.rawValue, id: r.teamRecordID, label: r.label, revision: r.revision, base: r.baseRevision,
                                                        payload: r.payload), member: l.memberID, key: key)
                try await file.setTeamRecordState(caseID: caseID, linkID: l.id, kind: r.kind, teamRecordID: r.teamRecordID, revision: r.revision, state: "confirmed", detail: nil)
                n += 1
            } catch {
                KalsmritikoshLog.app.error("Shared work still not written: \(error.localizedDescription, privacy: .private)")
                try await file.setTeamRecordState(caseID: caseID, linkID: l.id, kind: r.kind, teamRecordID: r.teamRecordID, revision: r.revision, state: "error",
                                                  detail: error.localizedDescription)
            }
        }
        return n
    }

    /// Take in other members' records, oldest revision first. A change made from the revision held here replaces it; a
    /// change made from an earlier revision than the one held here, by someone else, while this Mac changed it too, is a
    /// conflict (both kept); a revision already held (or older) is skipped.
    func takeInRecords(caseID: UUID, l: CaseTeamLink, folder: TeamCase, entries: [(entry: TeamLogEntry, name: String)], at date: Date) async throws -> (records: Int, conflicts: Int) {
        try await CaseAccessPolicy.requireRead(file.database, caseID: caseID)
        var records = 0, conflicts = 0
        let incoming = folder.records(in: entries).filter { $0.member != l.memberID && CaseTeamRecordKind(rawValue: $0.value.kind) != nil }
            .sorted { ($0.value.revision, $0.at, $0.member) < ($1.value.revision, $1.at, $1.member) }
        for e in incoming {
            guard let kind = CaseTeamRecordKind(rawValue: e.value.kind) else { continue }
            let held = try await file.teamRecords(caseID: caseID).first { $0.linkID == l.id && $0.kind == kind && $0.teamRecordID == e.value.id }
            if let held {
                if held.authorMember == e.member && held.revision >= e.value.revision { continue }     // already have it
                if e.value.revision <= held.baseRevision { continue }                                    // older than what this came from
                if e.value.base == held.revision {
                    try await file.putTeamRecord(caseID: caseID, linkID: l.id, kind: kind, teamRecordID: e.value.id, localID: nil, label: e.value.label,
                                                 revision: e.value.revision, base: e.value.base, payload: e.value.payload, authorMember: e.member,
                                                 authorName: e.memberName, state: "received", at: date)
                    records += 1
                } else if held.authorMember != e.member && e.value.base < held.revision && e.value.payload != held.payload {
                    if try await file.keepTeamConflict(caseID: caseID, linkID: l.id, local: held, remote: e, at: date) { conflicts += 1 }
                }
            } else {
                try await file.putTeamRecord(caseID: caseID, linkID: l.id, kind: kind, teamRecordID: e.value.id, localID: nil, label: e.value.label,
                                             revision: e.value.revision, base: e.value.base, payload: e.value.payload, authorMember: e.member,
                                             authorName: e.memberName, state: "received", at: date)
                records += 1
            }
        }
        return (records, conflicts)
    }

    /// Resolve a conflict: keep this Mac's version, take theirs, or a combined one — shared as a new revision after both.
    func resolveConflict(caseID: UUID, conflictID: UUID, keepOurs: Bool?, combined: [String: String]?, note: String?,
                                key: Curve25519.Signing.PrivateKey, actor: String, at date: Date = Date()) async throws -> CaseTeamRecord {
        try await CaseAccessPolicy.requireChange(file.database, caseID: caseID, actor: actor, .work)
        guard let c = try await file.teamConflicts(caseID: caseID).first(where: { $0.id == conflictID }), c.resolvedAt == nil else {
            throw CaseTeamError.alreadyDecided
        }
        let payload: [String: String], resolution: String
        if let combined { payload = combined; resolution = "combined" }
        else if keepOurs == true { payload = c.localPayload; resolution = "keptOurs" }
        else { payload = c.remotePayload; resolution = "tookTheirs" }
        try await file.recordTeamConflictResolution(caseID: caseID, conflictID: conflictID, resolution: resolution, payload: payload, note: note, actor: actor, at: date)
        // The resolution is a new revision after both sides, so every member takes it in from what they hold.
        let top = max(c.localRevision, c.remoteRevision)
        guard let l = try await file.teamLinks(caseID: caseID).first(where: { $0.id == c.linkID }) else { throw CaseTeamError.notLinked }
        guard TeamIdentity.memberID(key.publicKey) == l.memberID else { throw CaseTeamError.otherInstallation }
        try await file.putTeamRecord(caseID: caseID, linkID: l.id, kind: c.kind, teamRecordID: c.teamRecordID, localID: nil, label: c.label,
                                     revision: top + 1, base: top, payload: payload, authorMember: l.memberID, authorName: l.displayName,
                                     state: "pending", at: date)
        try await publish(caseID: caseID, l: l, kind: c.kind, teamRecordID: c.teamRecordID, key: key)
        guard let r = try await file.teamRecords(caseID: caseID).first(where: { $0.linkID == l.id && $0.kind == c.kind && $0.teamRecordID == c.teamRecordID }) else {
            throw CaseTeamError.notLinked
        }
        return r
    }
}
