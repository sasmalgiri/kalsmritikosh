//
//  CaseAccessModel.swift
//  Kalsmritikosh
//
//  Smart-map S9 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md ACCESS-02/04/05/09/11, TEAM-09/12; plan
//  §17.2; schema v185). Who may do what in a case, recorded through the case file repository's one savepoint — so every
//  change of a role is itself checked by `CaseAccessPolicy` (only an owner manages roles), logged in the case's action
//  log, and kept as an append-only grant row with the access generation it moved.
//
//  • A grant gives a local actor (a name on this Mac — never an account) one role in one case; a person may hold several.
//  • The first grant puts a solo case in team mode and records the granting person as its owner (this Mac's owner).
//  • No one gives themselves a role; the last owner cannot be removed; removing someone's last role with open work needs
//    a person to take the work over (transferred in the same savepoint; attribution is never rewritten).
//  • A contributor's grant may name the requests shared with them; they read those and nothing else of the case.
//  • Roles are not case evidence: granting a role never touches the case's people (subjects, witnesses) or their roles.
//

import Foundation
import os

public nonisolated struct CaseAccessGrant: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    public let actorID: UUID
    public let actorName: String
    public let role: CaseAccessRole
    /// For a contributor: the requests shared with them (empty = none named).
    public let scope: [String]
    public let reason: String
    public let grantedBy: String
    public let grantedAt: Date
    public let generation: Int
    public let revokedBy: String?
    public let revokedAt: Date?
    public let revokeReason: String?
    public let transferredTo: String?
    public var isActive: Bool { revokedAt == nil }
    /// One line for the access history (ACCESS-11).
    public var line: String {
        var s = "\(actorName): \(role.label) — given by \(grantedBy) (\(reason))"
        if !scope.isEmpty { s += "; shared: \(scope.joined(separator: ", "))" }
        if let revokedAt, let revokedBy {
            s += "; removed by \(revokedBy) on \(ISO8601DateFormatter().string(from: revokedAt)) (\(revokeReason ?? "no reason"))"
            if let transferredTo { s += ", open work to \(transferredTo)" }
        }
        return s
    }
}

/// A local actor: a name standing for a person on this Mac. `identityBound` stays false until an identity service binds
/// an authenticated identity to it (ARCH-08).
public nonisolated struct CaseLocalActor: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let isDeviceOwner: Bool
    public let identityBound: Bool
}

extension CaseFileRepository {

    static let grantColumns = """
        g.id, g.case_id, g.actor_id, a.display_name, g.role, g.scope_json, g.reason, g.granted_by, g.granted_at, g.generation,
        g.revoked_by, g.revoked_at, g.revoke_reason, g.transferred_to
        """

    static func decodeGrant(_ r: SQLRow) -> CaseAccessGrant? {
        guard let id = r.uuid(0), let c = r.uuid(1), let a = r.uuid(2), let name = r.string(3), let role = r.string(4).flatMap(CaseAccessRole.init(rawValue:)),
              let reason = r.string(6), let by = r.string(7), let at = r.date(8) else { return nil }
        let scope = (r.string(5)?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        return CaseAccessGrant(id: id, caseID: c, actorID: a, actorName: name, role: role, scope: scope, reason: reason, grantedBy: by, grantedAt: at,
                               generation: Int(r.int(9) ?? 0), revokedBy: r.string(10), revokedAt: r.date(11), revokeReason: r.string(12), transferredTo: r.string(13))
    }

    /// The local actor for `name`, created when new (inside the caller's savepoint).
    static func localActor(_ db: isolated Database, name: String, deviceOwner: Bool, at date: Date) throws -> UUID {
        let key = try CaseAccessPolicy.nameKey(name)
        if let id = try CaseAccessPolicy.actorID(db, key: key) { return id }
        let id = UUID()
        let hasOwner = try CaseAccessPolicy.deviceOwnerID(db) != nil
        try db.exec("INSERT INTO local_actors (id, display_name, name_key, kind, created_at) VALUES (?,?,?,?,?);",
                    [.uuid(id), .text(name.trimmingCharacters(in: .whitespacesAndNewlines)), .text(key),
                     .text(deviceOwner && !hasOwner ? "deviceOwner" : "localName"), .date(date)])
        return id
    }

    static func validatedScope(_ scope: [String], caseID: UUID, _ db: isolated Database) throws -> [String] {
        var out: [String] = []
        for raw in scope {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let id = UUID(uuidString: s) else { throw CaseAccessError.invalidScope("“\(String(s.prefix(40)))” is not a request of this case.") }
            guard try !db.query("SELECT 1 FROM investigation_evidence_requests WHERE id = ? AND case_id = ? LIMIT 1;", [.uuid(id), .uuid(caseID)]).isEmpty else {
                throw CaseAccessError.invalidScope("a request named in the share is not in this case.")
            }
            if !out.contains(id.uuidString) { out.append(id.uuidString) }
        }
        return out
    }

    /// ACCESS-02 — give `name` a role in the case. Only an owner may (the policy check of the change itself); the first
    /// grant of a solo case records the granting person as the case's owner. Contributors may be limited to named requests.
    @discardableResult
    public func grantAccess(caseID: UUID, to name: String, role: CaseAccessRole, scope: [String] = [], reason: String, actor: String,
                            at date: Date = Date()) async throws -> UUID {
        let who = try Self.clean(actor, "Actor"), why = try Self.clean(reason, "The reason")
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetKey = try CaseAccessPolicy.nameKey(target)
        _ = try CaseAccessPolicy.nameKey(who)
        if role != .contributor, !scope.isEmpty { throw CaseAccessError.invalidScope("only a contributor's role is limited to named requests.") }
        if case .local(let p)? = CaseAccessContext.principal, try CaseAccessPolicy.nameKey(p) == targetKey { throw CaseAccessError.selfGrant }
        let id = UUID()
        try await write("cf_acg", caseID: caseID, actor: who, action: "accessGranted", detail: "\(target): \(role.rawValue)", at: date, allowedWhenClosed: true) { db in
            let team = try CaseAccessPolicy.isTeamCase(db, caseID: caseID)
            var gen = try CaseAccessPolicy.generation(db, caseID: caseID) + 1
            let granterID: UUID
            if !team {
                // The case leaves solo mode: the person giving the first role is its owner (this Mac's owner).
                granterID = try Self.localActor(db, name: who, deviceOwner: CaseAccessContext.principal == nil, at: date)
                try db.exec("""
                    INSERT INTO case_access_grants (id, case_id, actor_id, role, reason, granted_by, granted_by_actor, granted_at, generation)
                    VALUES (?,?,?, 'owner', ?, ?, ?, ?, ?);
                    """, [.uuid(UUID()), .uuid(caseID), .uuid(granterID), .text("Owner of the case when it became a team case"), .text(who),
                          .uuid(granterID), .date(date), .integer(Int64(gen))])
                gen += 1
            } else {
                granterID = try Self.localActor(db, name: who, deviceOwner: false, at: date)
            }
            // No one gives themselves a role (the bootstrap owner row above is the one recorded exception).
            if try CaseAccessPolicy.nameKey(who) == targetKey {
                if !team && role == .owner { return }
                throw CaseAccessError.selfGrant
            }
            let actorID = try Self.localActor(db, name: target, deviceOwner: false, at: date)
            guard try db.query("SELECT 1 FROM case_access_grants WHERE case_id = ? AND actor_id = ? AND role = ? AND revoked_at IS NULL;",
                               [.uuid(caseID), .uuid(actorID), .text(role.rawValue)]).isEmpty else { throw CaseAccessError.alreadyHeld(role.label) }
            let shared = try Self.validatedScope(scope, caseID: caseID, db)
            try db.exec("""
                INSERT INTO case_access_grants (id, case_id, actor_id, role, scope_json, reason, granted_by, granted_by_actor, granted_at, generation)
                VALUES (?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .uuid(actorID), .text(role.rawValue), shared.isEmpty ? .null : .text(Self.jsonText(shared)), .text(why),
                      .text(who), .uuid(granterID), .date(date), .integer(Int64(gen))])
        }
        return id
    }

    /// ACCESS-07 (local part) / TEAM-09 — remove a role with the reason. The case's last owner stays. When the person loses
    /// their last role that changes work and still holds open work, `transferTo` (who must be able to work in the case) takes
    /// it over in the same savepoint; what they recorded keeps their name. From this moment the policy refuses their
    /// changes and reads, including queued automation they started.
    public func revokeAccess(caseID: UUID, grantID: UUID, reason: String, transferTo: String? = nil, actor: String, at date: Date = Date()) async throws {
        let who = try Self.clean(actor, "Actor"), why = try Self.clean(reason, "The reason")
        let target = Self.blankToNil(transferTo)
        try await write("cf_acr", caseID: caseID, actor: who, action: "accessRevoked", detail: why, at: date, allowedWhenClosed: true) { db in
            guard let r = try db.query("SELECT g.actor_id, g.role, g.revoked_at, a.display_name FROM case_access_grants g JOIN local_actors a ON a.id = g.actor_id WHERE g.id = ? AND g.case_id = ?;",
                                       [.uuid(grantID), .uuid(caseID)]).first,
                  let actorID = r.uuid(0), let role = r.string(1).flatMap(CaseAccessRole.init(rawValue:)), let name = r.string(3) else {
                throw CaseAccessError.notFound
            }
            guard r.isNull(2) else { throw CaseAccessError.alreadyRevoked }
            if role == .owner {
                let owners = try db.query("SELECT COUNT(*) FROM case_access_grants WHERE case_id = ? AND role = 'owner' AND revoked_at IS NULL;", [.uuid(caseID)]).first?.int(0) ?? 0
                if owners <= 1 { throw CaseAccessError.lastOwner }
            }
            let remaining = try db.query("SELECT role FROM case_access_grants WHERE case_id = ? AND actor_id = ? AND revoked_at IS NULL AND id <> ?;",
                                         [.uuid(caseID), .uuid(actorID), .uuid(grantID)]).compactMap { $0.string(0).flatMap(CaseAccessRole.init(rawValue:)) }
            let stillWorks = remaining.contains { $0.operations.contains(.work) }
            var open: [SQLRow] = []
            if !stillWorks {
                open = try db.query("SELECT id, work_kind, work_id, capability, assignee FROM case_work_assignments WHERE case_id = ? AND ended_at IS NULL;",
                                    [.uuid(caseID)]).filter { row in
                    guard let a = row.string(4) else { return false }
                    return (try? CaseAccessPolicy.nameKey(a)) == (try? CaseAccessPolicy.nameKey(name))
                }
            }
            if !open.isEmpty && target == nil {
                throw CaseAccessError.pendingWorkNeedsTransfer(open.compactMap { "\($0.string(1) ?? "work") \(String(($0.string(2) ?? "").prefix(8)))" })
            }
            if let to = target, !open.isEmpty {
                let toKey = try CaseAccessPolicy.nameKey(to)
                let canWork: Bool
                if let toID = try CaseAccessPolicy.actorID(db, key: toKey) {
                    canWork = try CaseAccessPolicy.activeGrants(db, caseID: caseID, actorID: toID).contains { $0.role.operations.contains(.work) }
                } else { canWork = false }
                guard canWork else { throw CaseAccessError.transferTargetCannotWork(to) }
            }
            let gen = try CaseAccessPolicy.generation(db, caseID: caseID) + 1
            try db.exec("UPDATE case_access_grants SET revoked_by = ?, revoked_at = ?, revoke_reason = ?, revoked_generation = ?, transferred_to = ? WHERE id = ?;",
                        [.text(who), .date(date), .text(why), .integer(Int64(gen)), .optionalText(open.isEmpty ? nil : target), .uuid(grantID)])
            if let to = target {
                for o in open {
                    guard let aid = o.string(0), let k = o.string(1), let w = o.string(2) else { continue }
                    try db.exec("UPDATE case_work_assignments SET ended_at = ?, ended_by = ?, end_reason = 'transferred', reassigned_to = ? WHERE id = ?;",
                                [.date(date), .text(who), .text(to), .text(aid)])
                    try db.exec("""
                        INSERT INTO case_work_assignments (id, case_id, work_kind, work_id, assignee, capability, assigned_by, assigned_at, note) VALUES (?,?,?,?,?,?,?,?,?);
                        """, [.uuid(UUID()), .uuid(caseID), .text(k), .text(w), .text(to), .optionalText(o.string(3)), .text(who), .date(date),
                              .text("Transferred from \(name) when their role was removed: \(why)")])
                }
            }
        }
    }

    /// ACCESS-11 — every grant of the case, active and removed, oldest first: who gave which role to whom, when, why,
    /// and who removed it.
    public func accessGrants(caseID: UUID) async throws -> [CaseAccessGrant] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT \(Self.grantColumns) FROM case_access_grants g JOIN local_actors a ON a.id = g.actor_id
            WHERE g.case_id = ? ORDER BY g.generation, g.granted_at;
            """, [.uuid(caseID)]).compactMap(Self.decodeGrant)
    }

    /// ACCESS-11 — the access history as lines (grants and removals in generation order).
    public func accessHistory(caseID: UUID) async throws -> [String] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await accessGrants(caseID: caseID).map(\.line)
    }

    /// The decision for `principal` (nil = whoever is acting) to perform `operation` — for the UI to explain a refusal or
    /// show what a person may do. The service still checks at the moment of the change.
    public func accessDecision(caseID: UUID, principal: CaseAccessPrincipal? = nil, operation: CaseAccessOperation) async throws -> CaseAccessDecision {
        let p = principal ?? CaseAccessContext.principal ?? .deviceOwner
        return try await database.withSavepoint("cf_acd_\(UUID().uuidString.prefix(8))") { db in
            try CaseAccessPolicy.decide(db, caseID: caseID, principal: p, operation: operation)
        }
    }

    /// The local actors known on this Mac (names, never accounts).
    public func localActors() async throws -> [CaseLocalActor] {
        try await database.query("SELECT id, display_name, kind, identity_provider FROM local_actors ORDER BY display_name;", []).compactMap { r in
            guard let id = r.uuid(0), let n = r.string(1) else { return nil }
            return CaseLocalActor(id: id, name: n, isDeviceOwner: r.string(2) == "deviceOwner", identityBound: !r.isNull(3))
        }
    }

    /// TEAM-12 — whether the case is worked alone (no role recorded) or as a team.
    public func isTeamCase(caseID: UUID) async throws -> Bool {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.withSavepoint("cf_team_\(UUID().uuidString.prefix(8))") { db in try CaseAccessPolicy.isTeamCase(db, caseID: caseID) }
    }
}
