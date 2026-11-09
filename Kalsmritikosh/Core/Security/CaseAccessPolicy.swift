//
//  CaseAccessPolicy.swift
//  Kalsmritikosh
//
//  Smart-map S9 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md ACCESS-02/03/05/06/09/11/12, TEAM-09/12,
//  SEC-12; plan §17.2; schema v185). The LOCAL access model: per-case roles held by local actors, and ONE policy check
//  (`CaseAccessPolicy.require`) that the case services call inside their own savepoint for every change, and
//  (`requireRead`) for every read of case content. Hiding a control is never the only enforcement.
//
//  • Roles (per case, several per person): owner (everything, including who may do what, policy, closing, erasing),
//    investigator (read, contribute, work, export), reviewer (read, review), contributor (contribute; reads only the
//    requests shared with them), viewer (read). A role never reaches another case.
//  • A case with no grant is a SOLO case: this Mac's owner holds every role and the names recorded on changes are
//    attribution only. The first grant puts the case in team mode: the granting person becomes its owner, and from then
//    on every recorded actor must hold a role that permits the change — read from the ledger at that moment, so a
//    revoked role, a queued job or a cached decision never outlives the revocation.
//  • Principal: `CaseAccessContext.principal` (task-local) names who is acting: nil = this Mac's owner; `.local(name)`
//    a person known on this Mac by name; `.bound(provider:subject:)` an authenticated identity — no identity service
//    exists in this build (ARCH-08 / CloudKit), so a bound principal is refused rather than trusted. A recorded actor that
//    differs from the acting principal is refused (no one records a change in another person's name).
//  • Names are not identity. A local actor is a name on this Mac; its identity columns stay empty until ARCH-08.
//  • Tickets (SEC-12): a long operation (an export, an AI send) takes a ticket and revalidates it before its effect; a
//    role revoked or a case erased in between refuses the effect with the reason, and nothing is disclosed.
//
//  Nothing here calls a model or the network.
//

import Foundation
import CryptoKit
import os

// MARK: - Roles, operations, principals

public nonisolated enum CaseAccessOperation: String, Sendable, CaseIterable, Codable {
    /// Open the case's content: records, documents, map, history, counts.
    case read
    /// Return requested material (a statement, a document, a result) to the case.
    case contribute
    /// Record and change investigative work: tasks, records, links, people, money, time.
    case work
    /// Accept, return or decide: reviews, decisions, approvals.
    case review
    /// Produce an output that leaves the case (an export, a printed or copied report).
    case export
    /// Decide who may do what, the case's policies, holds, closing, reopening and erasing.
    case administer

    public var label: String {
        switch self {
        case .read: return "open the case"
        case .contribute: return "return requested material"
        case .work: return "change the case's work and records"
        case .review: return "review or decide"
        case .export: return "export from the case"
        case .administer: return "manage roles, policies, holds and the case's stage"
        }
    }
}

public nonisolated enum CaseAccessRole: String, Sendable, CaseIterable, Codable, Identifiable {
    case owner, investigator, reviewer, contributor, viewer
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .owner: return "Owner"
        case .investigator: return "Investigator"
        case .reviewer: return "Reviewer"
        case .contributor: return "Contributor"
        case .viewer: return "Viewer"
        }
    }

    /// What the role may do in its case (nothing in any other case).
    public var operations: Set<CaseAccessOperation> {
        switch self {
        case .owner: return Set(CaseAccessOperation.allCases)
        case .investigator: return [.read, .contribute, .work, .export]
        case .reviewer: return [.read, .review]
        case .contributor: return [.contribute]
        case .viewer: return [.read]
        }
    }

    public var explanation: String {
        switch self {
        case .owner: return "Everything in this case, including who may do what, its policies, holds, closing and erasing."
        case .investigator: return "Opens the case, records and changes work and records, returns material and exports."
        case .reviewer: return "Opens the case and reviews, accepts, returns or decides. Does not change the work itself."
        case .contributor: return "Returns requested material. Sees only the requests shared with them, never the rest of the case."
        case .viewer: return "Opens the case and reads it. Changes nothing."
        }
    }
}

/// Who is acting.
public nonisolated enum CaseAccessPrincipal: Sendable, Equatable, Hashable {
    /// The person who owns this Mac and its ledger.
    case deviceOwner
    /// A person known on this Mac by a name (not an account; not authenticated).
    case local(String)
    /// An authenticated identity from an identity service (ARCH-08). This build has none, so it is refused.
    case bound(provider: String, subject: String)

    public var display: String {
        switch self {
        case .deviceOwner: return "this Mac's owner"
        case .local(let n): return n
        case .bound(let p, _): return "an identity from \(p)"
        }
    }
}

public nonisolated enum CaseAccessContext {
    /// The acting principal for guarded reads and changes; nil = this Mac's owner.
    @TaskLocal public static var principal: CaseAccessPrincipal?
}

public nonisolated struct CaseAccessDecision: Sendable, Equatable {
    public let allowed: Bool
    public let principal: CaseAccessPrincipal
    public let operation: CaseAccessOperation
    /// The roles the principal holds in the case now.
    public let roles: [CaseAccessRole]
    /// Why — always stated, allowed or not.
    public let basis: String
    /// What would make it allowed (nil when allowed).
    public let remedy: String?
    /// The case's access generation the decision was read at.
    public let generation: Int
    public let soloCase: Bool
}

public nonisolated enum CaseAccessError: Error, Equatable, LocalizedError {
    case denied(operation: CaseAccessOperation, who: String, reason: String, remedy: String)
    case forgedActor(recorded: String, acting: String)
    case invalidName(String)
    case invalidScope(String)
    case selfGrant
    case alreadyHeld(String)
    case lastOwner
    case notFound
    case alreadyRevoked
    case pendingWorkNeedsTransfer([String])
    case transferTargetCannotWork(String)
    case stale(String)

    public var errorDescription: String? {
        switch self {
        case .denied(let op, let who, let reason, let remedy):
            return "\(who) may not \(op.label) in this case: \(reason) \(remedy)"
        case .forgedActor(let recorded, let acting):
            return "A change cannot be recorded as \(recorded) while \(acting) is acting. Record it under your own name."
        case .invalidName(let why): return "That name cannot be used: \(why)"
        case .invalidScope(let why): return "That share cannot be recorded: \(why)"
        case .selfGrant: return "No one can give themselves a role. Ask the case's owner."
        case .alreadyHeld(let what): return "They already hold that role (\(what))."
        case .lastOwner: return "The case's last owner cannot be removed. Give the owner role to someone else first."
        case .notFound: return "That role is not recorded in this case."
        case .alreadyRevoked: return "That role was already removed."
        case .pendingWorkNeedsTransfer(let items):
            return "They still hold open work (\(items.count)): \(items.prefix(5).joined(separator: "; ")). Choose who takes it over."
        case .transferTargetCannotWork(let who): return "\(who) cannot take over the work: they hold no role that changes work in this case."
        case .stale(let why): return "Not done: \(why) Nothing was written or disclosed."
        }
    }
}

// MARK: - The policy

public nonisolated enum CaseAccessPolicy {

    static let maxNameLength = 200

    /// A name's key: trimmed, compatibility-normalised, case-folded, inner whitespace collapsed. Refuses control and
    /// bidirectional-override characters (a hostile name that renders as someone else's) and overlong names.
    public static func nameKey(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CaseAccessError.invalidName("it is blank.") }
        guard trimmed.count <= maxNameLength else { throw CaseAccessError.invalidName("it is longer than \(maxNameLength) characters.") }
        // Checked on the raw text: some invisible characters (U+200B) count as whitespace and would be trimmed unseen.
        for s in raw.unicodeScalars {
            let control = CharacterSet.controlCharacters.contains(s) && !CharacterSet.whitespacesAndNewlines.contains(s)
            if control || (0x202A...0x202E).contains(s.value) || (0x2066...0x2069).contains(s.value)
                || s.value == 0x200E || s.value == 0x200F || s.value == 0xFEFF || (0x200B...0x200D).contains(s.value) {
                throw CaseAccessError.invalidName("it contains an invisible or direction-changing character.")
            }
        }
        if trimmed.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) || $0.value == 0x09 }) {
            throw CaseAccessError.invalidName("it spans several lines.")
        }
        let folded = trimmed.precomposedStringWithCompatibilityMapping.lowercased()
        return folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The operation a recorded case action needs. Unknown actions need `.work` (fail closed: never `.read`). Nil only for
    /// the system's own records of a refused or failed attempt, which are written whoever attempted it.
    public static func operation(forAction action: String) -> CaseAccessOperation? {
        if auditActions.contains(action) { return nil }
        if administerActions.contains(action) { return .administer }
        if exportActions.contains(action) { return .export }
        if reviewActions.contains(action) { return .review }
        if contributeActions.contains(action) { return .contribute }
        if readActions.contains(action) { return .read }
        return .work
    }

    static let administerActions: Set<String> = [
        "accessGranted", "accessRevoked", "teamMemberAdded", "teamMembershipEnded", "profileRestricted", "profileRestrictionLifted",
        "holdIssued", "holdReleased", "stage", "closed", "reopened", "archived", "unarchived", "automationPolicySet", "recipientAuthorized",
        "reviewPolicySet", "retentionSet",
    ]
    static let auditActions: Set<String> = ["exportRefused", "exportFailed"]
    static let exportActions: Set<String> = ["exported", "printed", "copied", "reportExported", "mapExported", "outputExported"]
    static let reviewActions: Set<String> = [
        "allegationDecided", "pointReviewed", "proposalDecided", "factVerified", "factVerificationWithdrawn", "reviewFlagCleared",
        "conflictFollowUpOutcome", "lateContributionDecided", "actionAccepted", "actionReturned", "reviewFindingRecorded", "reviewStarted",
        "identityDecided", "identityDecisionWithdrawn", "briefAccepted",
        // S10 — accepting, rejecting or deferring an AI proposal is a decision on it (applying a structural one is also work,
        // checked by the assistant before anything changes).
        "aiProposalDecided",
    ]
    static let contributeActions: Set<String> = ["lateContributionQueued", "reportItemSupplied", "intakeReceived", "requestResponseReceived"]
    /// The person's own working aids about a case they may open (layout, saved views, seen positions).
    static let readActions: Set<String> = ["viewed", "layoutSaved", "layoutReset", "viewSaved", "viewDeleted", "changeAcknowledged", "seenMarked"]

    // MARK: Reading the grants

    struct Grant { let id: UUID; let role: CaseAccessRole; let scope: [String] }

    static func tableExists(_ db: isolated Database) throws -> Bool {
        !(try db.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'case_access_grants';", []).isEmpty)
    }

    /// Whether the case has ever had a grant (team mode). A solo case has none.
    public static func isTeamCase(_ db: isolated Database, caseID: UUID) throws -> Bool {
        guard try tableExists(db) else { return false }
        return !(try db.query("SELECT 1 FROM case_access_grants WHERE case_id = ? LIMIT 1;", [.uuid(caseID)]).isEmpty)
    }

    /// The case's access generation: it moves with every grant and every revocation.
    public static func generation(_ db: isolated Database, caseID: UUID) throws -> Int {
        guard try tableExists(db) else { return 0 }
        return Int(try db.query("SELECT COALESCE(MAX(MAX(generation, COALESCE(revoked_generation, 0))), 0) FROM case_access_grants WHERE case_id = ?;",
                                [.uuid(caseID)]).first?.int(0) ?? 0)
    }

    static func actorID(_ db: isolated Database, key: String) throws -> UUID? {
        try db.query("SELECT id FROM local_actors WHERE name_key = ?;", [.text(key)]).first?.uuid(0)
    }

    static func deviceOwnerID(_ db: isolated Database) throws -> UUID? {
        try db.query("SELECT id FROM local_actors WHERE kind = 'deviceOwner' LIMIT 1;", []).first?.uuid(0)
    }

    static func activeGrants(_ db: isolated Database, caseID: UUID, actorID: UUID) throws -> [Grant] {
        try db.query("SELECT id, role, scope_json FROM case_access_grants WHERE case_id = ? AND actor_id = ? AND revoked_at IS NULL ORDER BY granted_at;",
                     [.uuid(caseID), .uuid(actorID)]).compactMap { r in
            guard let id = r.uuid(0), let role = r.string(1).flatMap(CaseAccessRole.init(rawValue:)) else { return nil }
            let scope = (r.string(2)?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
            return Grant(id: id, role: role, scope: scope)
        }
    }

    // MARK: The decision

    /// The decision for `principal` to perform `operation` in the case now. `target` names the record a contributor's
    /// share is checked against (an evidence request id).
    public static func decide(_ db: isolated Database, caseID: UUID, principal: CaseAccessPrincipal, operation: CaseAccessOperation,
                              target: String? = nil) throws -> CaseAccessDecision {
        let team = try isTeamCase(db, caseID: caseID)
        let gen = try generation(db, caseID: caseID)
        func out(_ ok: Bool, _ roles: [CaseAccessRole], _ basis: String, _ remedy: String?) -> CaseAccessDecision {
            CaseAccessDecision(allowed: ok, principal: principal, operation: operation, roles: roles, basis: basis, remedy: ok ? nil : remedy,
                               generation: gen, soloCase: !team)
        }
        let actor: UUID?
        switch principal {
        case .bound(let provider, _):
            return out(false, [], "authenticated identities (\(provider)) are not available in this version.",
                       "Signing in needs the team service (ARCH-08 / CloudKit), which this version does not have.")
        case .deviceOwner:
            // The ledger is this Mac's owner's: they hold every role in a solo case and keep the owner's powers in a team
            // case (local roles restrict the OTHER people recorded or replayed on this Mac).
            return out(true, team ? [.owner] : CaseAccessRole.allCases,
                       team ? "This Mac's owner keeps the owner's role in cases kept on this Mac." : "Solo case: this Mac's owner holds every role.", nil)
        case .local(let name):
            let key = try nameKey(name)
            guard team else {
                return out(false, [], "this is a solo case: only this Mac's owner works in it.",
                           "The case's owner can give \(name) a role (Case → People and roles).")
            }
            actor = try actorID(db, key: key)
        }
        guard let actorID = actor else {
            return out(false, [], "\(principal.display) holds no role in this case.", "The case's owner can give them a role.")
        }
        let grants = try activeGrants(db, caseID: caseID, actorID: actorID)
        let roles = Array(Set(grants.map(\.role))).sorted { $0.rawValue < $1.rawValue }
        guard !grants.isEmpty else {
            let ended = try !db.query("SELECT 1 FROM case_access_grants WHERE case_id = ? AND actor_id = ? AND revoked_at IS NOT NULL LIMIT 1;",
                                      [.uuid(caseID), .uuid(actorID)]).isEmpty
            return out(false, [], ended ? "their role in this case was removed." : "\(principal.display) holds no role in this case.",
                       "The case's owner can give them a role.")
        }
        // A contributor reads only what was shared with them.
        let full = grants.filter { $0.role != .contributor }
        if full.contains(where: { $0.role.operations.contains(operation) }) {
            return out(true, roles, "Allowed by their role: \(roles.map(\.label).joined(separator: ", ")).", nil)
        }
        let contributor = grants.filter { $0.role == .contributor }
        if !contributor.isEmpty {
            if operation == .contribute {
                let scope = contributor.flatMap(\.scope)
                if scope.isEmpty || target == nil || scope.contains(where: { $0.caseInsensitiveCompare(target ?? "") == .orderedSame }) {
                    return out(true, roles, "A contributor may return requested material.", nil)
                }
                return out(false, roles, "that request was not shared with them.", "The case's owner can share the request with them.")
            }
            if operation == .read, let target, contributor.flatMap(\.scope).contains(where: { $0.caseInsensitiveCompare(target) == .orderedSame }) {
                return out(true, roles, "Shared with them as a contributor.", nil)
            }
        }
        let needed = CaseAccessRole.allCases.filter { $0.operations.contains(operation) }.map(\.label).joined(separator: " or ")
        return out(false, roles, "their role (\(roles.map(\.label).joined(separator: ", "))) does not allow it.",
                   "It needs the \(needed) role; the case's owner can give it.")
    }

    /// THE policy check, inside the caller's savepoint. `actor` is the name the change is recorded under. In a solo case
    /// every change is allowed (this Mac's owner holds every role). In a team case the acting principal — the task-local
    /// one, or else the recorded actor — must hold a role that allows `operation`.
    public static func require(_ db: isolated Database, caseID: UUID, actor: String?, _ operation: CaseAccessOperation, target: String? = nil) throws {
        let acting = CaseAccessContext.principal
        if case .local(let p)? = acting, let actor, try nameKey(actor) != nameKey(p) {
            throw CaseAccessError.forgedActor(recorded: actor, acting: p)
        }
        guard try isTeamCase(db, caseID: caseID) || acting != nil else { return }
        var principal = acting ?? .deviceOwner
        if acting == nil, let actor {
            // The recorded name acts: this Mac's owner under their own name, or the person named.
            let key = try nameKey(actor)
            let owner = try db.query("SELECT name_key FROM local_actors WHERE kind = 'deviceOwner' LIMIT 1;", []).first?.string(0)
            principal = owner == key ? .deviceOwner : .local(actor)
        }
        let d = try decide(db, caseID: caseID, principal: principal, operation: operation, target: target)
        guard d.allowed else {
            KalsmritikoshLog.app.notice("Case access refused: \(operation.rawValue, privacy: .public)")
            throw CaseAccessError.denied(operation: operation, who: principal == .deviceOwner ? (actor ?? principal.display) : principal.display,
                                         reason: d.basis, remedy: d.remedy ?? "")
        }
    }

    /// The read check for a case's content. This Mac's owner (no principal set) reads without a query; a named or bound
    /// principal is checked against the case's grants now.
    public static func requireRead(_ database: Database, caseID: UUID, target: String? = nil) async throws {
        guard CaseAccessContext.principal != nil else { return }
        // Task-local values travel with the task onto the database actor.
        try await database.withSavepoint("cap_r_\(UUID().uuidString.prefix(8))") { db in
            try require(db, caseID: caseID, actor: nil, .read, target: target)
        }
    }

    /// The change check for a service entry point that changes the case through more than one store (the task engine and
    /// the case file, say): checked BEFORE the first store is touched, so a refused change leaves nothing behind. The
    /// case file's own savepoint checks again with the exact action.
    public static func requireChange(_ database: Database, caseID: UUID, actor: String?, _ operation: CaseAccessOperation) async throws {
        try await database.withSavepoint("cap_c_\(UUID().uuidString.prefix(8))") { db in
            try require(db, caseID: caseID, actor: actor, operation)
        }
    }

    /// Whether the acting principal may open the case (lists, counts and titles use this to leave a case out entirely).
    public static func mayRead(_ database: Database, caseID: UUID) async -> Bool {
        do { try await requireRead(database, caseID: caseID); return true } catch {
            KalsmritikoshLog.app.notice("Case left out of a list: \(String(describing: type(of: error)), privacy: .public)")
            return false
        }
    }
}

// MARK: - Tickets (SEC-12): revalidated before a long operation's effect

public nonisolated struct CaseAccessTicket: Sendable, Equatable {
    public let caseID: UUID
    /// The task-local principal the ticket was taken under (nil = this Mac's owner / the recorded actor).
    public let acting: CaseAccessPrincipal?
    public let actor: String?
    public let operation: CaseAccessOperation
    public let accessGeneration: Int
    public let erasureGeneration: Int

    /// Take a ticket now (refused when the operation is not allowed now).
    public static func take(_ db: isolated Database, caseID: UUID, actor: String?, _ operation: CaseAccessOperation) throws -> CaseAccessTicket {
        try CaseAccessPolicy.require(db, caseID: caseID, actor: actor, operation)
        return CaseAccessTicket(caseID: caseID, acting: CaseAccessContext.principal, actor: actor, operation: operation,
                                accessGeneration: try CaseAccessPolicy.generation(db, caseID: caseID),
                                erasureGeneration: try ErasureGenerations.current(db))
    }

    /// Before the effect: the case still exists, and — when roles or erasures changed since — the operation is still allowed.
    public func revalidate(_ db: isolated Database) throws {
        guard try !db.query("SELECT 1 FROM investigation_cases WHERE id = ? LIMIT 1;", [.uuid(caseID)]).isEmpty else {
            throw CaseAccessError.stale("the case was erased while this was being prepared.")
        }
        if try ErasureGenerations.isErased(db, caseID: caseID) {
            throw CaseAccessError.stale("the case was erased while this was being prepared.")
        }
        let now = try CaseAccessPolicy.generation(db, caseID: caseID)
        let erasures = try ErasureGenerations.current(db)
        guard now != accessGeneration || erasures != erasureGeneration else { return }
        do {
            try CaseAccessContext.$principal.withValue(acting) {
                try CaseAccessPolicy.require(db, caseID: caseID, actor: actor, operation)
            }
        } catch let e as CaseAccessError {
            if case .denied(_, _, let reason, _) = e { throw CaseAccessError.stale("roles changed while this was being prepared — \(reason)") }
            throw e
        }
    }
}

// MARK: - Erasure generations and tombstones (SEC-08)

/// Every case or person erasure takes the next erasure generation; while it runs, the user-layer rows it removes leave a
/// content-free tombstone (table + identifiers), so a replica's batch, a late writer or an old copy cannot re-create them.
/// A generation's `propagation` says whether it has been passed to other devices (always `localOnly` in this version:
/// there is no team service to pass it to — TEAM-01 / CloudKit).
public nonisolated enum ErasureGenerations {

    public static func scopeHash(_ id: UUID) -> String {
        SHA256.hash(data: Data("kals-erasure-register:\(id.uuidString.lowercased())".utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func scopeHash(personName: String) -> String {
        SHA256.hash(data: Data("kals-erasure-person:\(personName.lowercased())".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func available(_ db: isolated Database) throws -> Bool {
        !(try db.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'erasure_generations';", []).isEmpty)
    }

    /// Open a generation for an erasure (inside its savepoint). Nil on a ledger older than v185.
    @discardableResult
    static func begin(_ db: isolated Database, kind: String, scopeHash: String, erasureID: UUID, at date: Date) throws -> Int? {
        guard try available(db) else { return nil }
        try db.exec("INSERT INTO erasure_generations (kind, scope_hash, erasure_id, state, erased_at) VALUES (?,?,?, 'running', ?);",
                    [.text(kind), .text(scopeHash), .uuid(erasureID), .date(date)])
        return Int(try db.query("SELECT last_insert_rowid();", []).first?.int(0) ?? 0)
    }

    static func finish(_ db: isolated Database, erasureID: UUID) throws {
        guard try available(db) else { return }
        try db.exec("UPDATE erasure_generations SET state = 'done' WHERE erasure_id = ? AND state = 'running';", [.uuid(erasureID)])
    }

    public static func current(_ db: isolated Database) throws -> Int {
        guard try available(db) else { return 0 }
        return Int(try db.query("SELECT COALESCE(MAX(generation), 0) FROM erasure_generations WHERE state = 'done';", []).first?.int(0) ?? 0)
    }

    /// Whether the case was erased in this ledger (a stale writer holding its id must not write).
    public static func isErased(_ db: isolated Database, caseID: UUID) throws -> Bool {
        guard try available(db) else { return false }
        return !(try db.query("SELECT 1 FROM erasure_generations WHERE kind = 'case' AND scope_hash = ? LIMIT 1;", [.text(scopeHash(caseID))]).isEmpty)
    }

    /// Whether the row was removed by an erasure (the sync engine refuses to re-create it).
    public static func isTombstoned(_ db: isolated Database, table: String, rowKey: String) throws -> Bool {
        guard try available(db) else { return false }
        return !(try db.query("SELECT 1 FROM erasure_tombstones WHERE tbl = ? AND row_key = ? LIMIT 1;", [.text(table), .text(rowKey)]).isEmpty)
    }

    /// The generations not yet passed to other devices — what a team service would send (ready for TEAM-01).
    public static func pendingPropagation(_ database: Database) async throws -> [(generation: Int, kind: String, scopeHash: String, tombstones: Int)] {
        try await database.query("""
            SELECT g.generation, g.kind, g.scope_hash, (SELECT COUNT(*) FROM erasure_tombstones t WHERE t.generation = g.generation)
            FROM erasure_generations g WHERE g.state = 'done' AND g.propagation <> 'propagated' ORDER BY g.generation;
            """, []).compactMap { r in
            guard let g = r.int(0), let k = r.string(1), let h = r.string(2) else { return nil }
            return (Int(g), k, h, Int(r.int(3) ?? 0))
        }
    }
}

// MARK: - Credentials never leave in a log line or an export (SEC-05 / SEC-11)

/// Masks credential-shaped text — provider API keys, bearer tokens, signed tokens (JWS/JWT), PEM private keys, cloud
/// access keys — wherever case text leaves the ledger as an export or enters the case's action log. A pasted key is
/// replaced by "[credential removed]"; ordinary words, numbers and identifiers are untouched.
public nonisolated enum SecretRedactor {
    public static let marker = "[credential removed]"
    static let patterns: [NSRegularExpression] = [
        #"sk-ant-[A-Za-z0-9_\-]{10,}"#,
        #"\bsk-[A-Za-z0-9]{20,}\b"#,
        #"(?i)\bbearer\s+[A-Za-z0-9._~+/=\-]{16,}"#,
        #"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#,
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#,
        #"\bAKIA[0-9A-Z]{16}\b"#,
        #"\bgh[pousr]_[A-Za-z0-9]{30,}\b"#,
    ].compactMap { p in
        do { return try NSRegularExpression(pattern: p) } catch {
            KalsmritikoshLog.app.error("SecretRedactor pattern invalid: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    public static func redact(_ text: String) -> String {
        var out = text
        for re in patterns {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: marker)
        }
        return out
    }

    public static func containsCredential(_ text: String) -> Bool { redact(text) != text }
}
