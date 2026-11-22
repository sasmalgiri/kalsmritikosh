//
//  SimulatedIdentityProvider.swift
//  Kalsmritikosh
//
//  Unified path R2-E (owner 2026-11-22 round 2: "the rows that need people, accounts or a server are finished as
//  labelled simulations") — not tested yet. ACCESS-01, ACCESS-07, PEOPLE-05, QA-07, SHIP-03.
//
//  A LOCAL SIMULATED identity provider: accounts, strong second factor (time-based one-time codes), sessions, account
//  recovery with single-use codes, and scoped, expiring, single-use, revocable invitation tokens bound to a case and a
//  role. Everything sits behind `TeamIdentityService`, so a real hosted service replaces this actor without changing
//  callers. Nothing here opens a connection; nothing is shown in the release UI. Every report it produces says
//  SIMULATED. A display name or an e-mail field is never treated as proof of identity: a session token is.
//

import Foundation
import CryptoKit
import os

public nonisolated enum SimulationLabel {
    public static let banner = "SIMULATED — a local simulation, not a real service. Real people, accounts and a server are still needed for release."
    public static let agentParticipants = "Agent participants (simulated), not human"
}

// MARK: - Roles

public nonisolated enum TeamRole: String, Sendable, Codable, CaseIterable {
    case lead, examiner, reviewer, contributor
    /// Privileged remote roles must hold a session made with the strong second factor (ACCESS-01 policy).
    public var isPrivileged: Bool { self == .lead || self == .examiner }
    public var canInvite: Bool { self == .lead }
    public var canWrite: Bool { self != .reviewer }
    public var canExport: Bool { self == .lead || self == .examiner }
    public var canRead: Bool { self != .contributor }   // a contributor submits; it does not browse the case
}

// MARK: - Values

public nonisolated struct SimAccountID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let raw: String
    public var description: String { raw }
}

public nonisolated struct SimSession: Sendable, Equatable {
    public let token: String
    public let account: SimAccountID
    public let expiresAt: Date
    public let strong: Bool
}

public nonisolated struct SimInvitation: Sendable, Equatable {
    public let id: UUID
    /// The bearer secret — returned to the inviter once; the provider keeps only its SHA-256.
    public let token: String
    public let caseID: UUID
    public let role: TeamRole
    public let expiresAt: Date
    public let intendedEmail: String?
}

public nonisolated struct SimMembership: Sendable, Codable, Equatable {
    public let account: SimAccountID
    public let caseID: UUID
    public let role: TeamRole
    public let boundAt: Date
    /// The member's Curve25519 key-agreement public key (shared-data encryption, SimulatedSharedCaseVault).
    public let encryptionPublicKey: Data
}

public nonisolated enum SimIdentityError: Error, Equatable, LocalizedError {
    case accountExists, unknownAccount, badCredentials, strongFactorRequired, sessionExpired, sessionUnknown
    case invitationUnknown, invitationExpired, invitationRevoked, invitationUsed, wrongIdentity
    case notPermitted(String), lastLead, recoveryRejected, notMember, caseExists, unknownCase
    public var errorDescription: String? {
        switch self {
        case .accountExists: return "SIMULATED: an account with this e-mail address already exists."
        case .unknownAccount, .badCredentials: return "SIMULATED: the e-mail address or password is not right."
        case .strongFactorRequired: return "SIMULATED: this role needs a sign-in with the second factor."
        case .sessionExpired: return "SIMULATED: the session expired; sign in again."
        case .sessionUnknown: return "SIMULATED: not signed in (unknown or ended session)."
        case .invitationUnknown: return "SIMULATED: this invitation does not exist."
        case .invitationExpired: return "SIMULATED: this invitation expired."
        case .invitationRevoked: return "SIMULATED: this invitation was withdrawn."
        case .invitationUsed: return "SIMULATED: this invitation was already used."
        case .wrongIdentity: return "SIMULATED: this invitation is for someone else."
        case .notPermitted(let why): return "SIMULATED: not permitted — \(why)."
        case .lastLead: return "SIMULATED: the last lead cannot be removed."
        case .recoveryRejected: return "SIMULATED: that recovery code is not valid."
        case .notMember: return "SIMULATED: not a member of this case."
        case .caseExists: return "SIMULATED: the case already exists."
        case .unknownCase: return "SIMULATED: unknown case."
        }
    }
}

// MARK: - The service boundary (a real hosted service implements the same protocol)

public protocol TeamIdentityService: Sendable {
    func createAccount(email: String, displayName: String, password: String, now: Date) async throws -> SimAccountID
    func enrolStrongFactor(_ account: SimAccountID, password: String) async throws -> (secret: Data, recoveryCodes: [String])
    func signIn(email: String, password: String, oneTimeCode: String?, now: Date) async throws -> SimSession
    func recover(email: String, recoveryCode: String, newPassword: String, now: Date) async throws -> SimSession
    func signOut(_ token: String) async
    func account(for token: String, now: Date) async throws -> SimAccountID
    func createCase(_ caseID: UUID, by token: String, encryptionPublicKey: Data, now: Date) async throws
    func invite(caseID: UUID, role: TeamRole, intendedEmail: String?, ttl: TimeInterval, by token: String, now: Date) async throws -> SimInvitation
    func revokeInvitation(_ id: UUID, by token: String, now: Date) async throws
    func redeem(invitation: String, by token: String, encryptionPublicKey: Data, now: Date) async throws -> SimMembership
    func revokeMember(_ member: SimAccountID, caseID: UUID, by token: String, now: Date) async throws
    func role(caseID: UUID, for token: String, now: Date) async throws -> TeamRole
    func members(caseID: UUID) async -> [SimMembership]
    func permissionEpoch(caseID: UUID) async -> Int
}

// MARK: - One-time codes (the simulated strong factor)

public nonisolated enum SimOneTimeCode {
    public static let step: TimeInterval = 30
    /// RFC 6238 shape over HMAC-SHA256: 6 digits for the 30-second window containing `date`.
    public static func code(secret: Data, at date: Date) -> String {
        var counter = UInt64(date.timeIntervalSince1970 / step).bigEndian
        let msg = withUnsafeBytes(of: &counter) { Data($0) }
        let mac = Data(HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: secret)))
        let offset = Int(mac[mac.count - 1] & 0x0f)
        let bin = (UInt32(mac[offset] & 0x7f) << 24) | (UInt32(mac[offset + 1]) << 16) | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
        return String(format: "%06d", bin % 1_000_000)
    }
    /// Accepts the current window and the one before (clock skew).
    public static func verify(_ code: String, secret: Data, at date: Date) -> Bool {
        code == Self.code(secret: secret, at: date) || code == Self.code(secret: secret, at: date.addingTimeInterval(-step))
    }
}

nonisolated enum SimSecrets {
    static func random(_ bytes: Int = 32) -> Data {
        SymmetricKey(size: SymmetricKeySize(bitCount: bytes * 8)).withUnsafeBytes { Data($0) }
    }
    static func token(_ bytes: Int = 32) -> String {
        random(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    static func digest(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
    /// A SIMULATED password hash (iterated salted HMAC-SHA256); a real service uses its own vetted KDF.
    static func passwordHash(_ password: String, salt: Data) -> String {
        var h = Data(password.utf8)
        let key = SymmetricKey(data: salt)
        for _ in 0..<2_000 { h = Data(HMAC<SHA256>.authenticationCode(for: h, using: key)) }
        return h.base64EncodedString()
    }
}

// MARK: - The simulated provider

public actor SimulatedIdentityProvider: TeamIdentityService {
    struct Account: Codable {
        let id: SimAccountID
        let email: String
        let displayName: String
        var salt: Data
        var passwordHash: String
        var totpSecret: Data?
        var recoveryCodeDigests: [String]
        let createdAt: Date
    }
    struct Session: Codable { let account: SimAccountID; let expiresAt: Date; let strong: Bool }
    struct Invitation: Codable {
        let id: UUID; let tokenDigest: String; let caseID: UUID; let role: TeamRole
        let expiresAt: Date; let intendedEmail: String?; let createdBy: SimAccountID
        var revoked: Bool; var usedBy: SimAccountID?
    }
    struct State: Codable {
        var version = 2
        var accounts: [String: Account] = [:]              // key: case-folded e-mail
        var sessions: [String: Session] = [:]              // key: SHA-256 of the token
        var invitations: [UUID: Invitation] = [:]
        var memberships: [UUID: [SimMembership]] = [:]
        var permissionEpochs: [UUID: Int] = [:]
    }

    public nonisolated static let sessionLifetime: TimeInterval = 8 * 3600
    private var state = State()
    public let monitor: ContentFreeHealthMonitor?

    public nonisolated init(monitor: ContentFreeHealthMonitor? = nil) { self.monitor = monitor }

    // MARK: Accounts

    public func createAccount(email: String, displayName: String, password: String, now: Date) async throws -> SimAccountID {
        let key = email.lowercased().trimmingCharacters(in: .whitespaces)
        guard state.accounts[key] == nil else { await note("account.create", .refused, .conflict); throw SimIdentityError.accountExists }
        let salt = SimSecrets.random(16)
        let id = SimAccountID(raw: "acct_" + SimSecrets.token(12))
        state.accounts[key] = Account(id: id, email: key, displayName: displayName, salt: salt,
                                      passwordHash: SimSecrets.passwordHash(password, salt: salt), totpSecret: nil,
                                      recoveryCodeDigests: [], createdAt: now)
        await note("account.create", .ok, nil)
        return id
    }

    public func enrolStrongFactor(_ account: SimAccountID, password: String) async throws -> (secret: Data, recoveryCodes: [String]) {
        guard let key = state.accounts.first(where: { $0.value.id == account })?.key, var a = state.accounts[key] else {
            throw SimIdentityError.unknownAccount
        }
        guard SimSecrets.passwordHash(password, salt: a.salt) == a.passwordHash else { await note("factor.enrol", .refused, .authentication); throw SimIdentityError.badCredentials }
        let secret = SimSecrets.random(20)
        let codes = (0..<8).map { _ in SimSecrets.token(9) }
        a.totpSecret = secret
        a.recoveryCodeDigests = codes.map(SimSecrets.digest)
        state.accounts[key] = a
        await note("factor.enrol", .ok, nil)
        return (secret, codes)
    }

    public func signIn(email: String, password: String, oneTimeCode: String?, now: Date) async throws -> SimSession {
        let key = email.lowercased().trimmingCharacters(in: .whitespaces)
        guard let a = state.accounts[key], SimSecrets.passwordHash(password, salt: a.salt) == a.passwordHash else {
            await note("session.signin", .refused, .authentication); throw SimIdentityError.badCredentials
        }
        var strong = false
        if let code = oneTimeCode {
            guard let secret = a.totpSecret, SimOneTimeCode.verify(code, secret: secret, at: now) else {
                await note("session.signin", .refused, .authentication); throw SimIdentityError.badCredentials
            }
            strong = true
        }
        return await issue(a.id, strong: strong, now: now)
    }

    /// Recovery: a single-use code; every earlier session of the account ends; the new session is not strong (the
    /// person signs in again with the second factor before a privileged role works).
    public func recover(email: String, recoveryCode: String, newPassword: String, now: Date) async throws -> SimSession {
        let key = email.lowercased().trimmingCharacters(in: .whitespaces)
        guard var a = state.accounts[key], let i = a.recoveryCodeDigests.firstIndex(of: SimSecrets.digest(recoveryCode)) else {
            await note("account.recover", .refused, .authentication); throw SimIdentityError.recoveryRejected
        }
        a.recoveryCodeDigests.remove(at: i)
        a.salt = SimSecrets.random(16)
        a.passwordHash = SimSecrets.passwordHash(newPassword, salt: a.salt)
        state.accounts[key] = a
        state.sessions = state.sessions.filter { $0.value.account != a.id }
        await note("account.recover", .ok, nil)
        return await issue(a.id, strong: false, now: now)
    }

    public func signOut(_ token: String) async { state.sessions[SimSecrets.digest(token)] = nil }

    public func account(for token: String, now: Date) async throws -> SimAccountID { try session(token, now: now).account }

    // MARK: Cases, invitations, membership

    public func createCase(_ caseID: UUID, by token: String, encryptionPublicKey: Data, now: Date) async throws {
        let s = try session(token, now: now)
        guard s.strong else { throw SimIdentityError.strongFactorRequired }
        guard state.memberships[caseID] == nil else { throw SimIdentityError.caseExists }
        state.memberships[caseID] = [SimMembership(account: s.account, caseID: caseID, role: .lead, boundAt: now, encryptionPublicKey: encryptionPublicKey)]
        state.permissionEpochs[caseID] = 1
        await note("case.create", .ok, nil)
    }

    public func invite(caseID: UUID, role: TeamRole, intendedEmail: String?, ttl: TimeInterval, by token: String, now: Date) async throws -> SimInvitation {
        let actor = try await requireRole(caseID: caseID, token: token, now: now)
        guard actor.canInvite else { await note("invite.create", .refused, .permission); throw SimIdentityError.notPermitted("only a lead invites") }
        let secret = SimSecrets.token(32)                    // 256 bits: not guessable
        let inv = Invitation(id: UUID(), tokenDigest: SimSecrets.digest(secret), caseID: caseID, role: role,
                             expiresAt: now.addingTimeInterval(max(60, min(ttl, 7 * 86_400))),
                             intendedEmail: intendedEmail?.lowercased(), createdBy: try session(token, now: now).account,
                             revoked: false, usedBy: nil)
        state.invitations[inv.id] = inv
        await note("invite.create", .ok, nil)
        return SimInvitation(id: inv.id, token: secret, caseID: caseID, role: role, expiresAt: inv.expiresAt, intendedEmail: inv.intendedEmail)
    }

    public func revokeInvitation(_ id: UUID, by token: String, now: Date) async throws {
        guard var inv = state.invitations[id] else { throw SimIdentityError.invitationUnknown }
        let actor = try await requireRole(caseID: inv.caseID, token: token, now: now)
        guard actor.canInvite else { throw SimIdentityError.notPermitted("only a lead withdraws an invitation") }
        inv.revoked = true
        state.invitations[id] = inv
        await note("invite.revoke", .ok, nil)
    }

    public func redeem(invitation secret: String, by token: String, encryptionPublicKey: Data, now: Date) async throws -> SimMembership {
        let s = try session(token, now: now)
        let digest = SimSecrets.digest(secret)
        guard let hit = state.invitations.first(where: { $0.value.tokenDigest == digest }) else {
            await note("invite.redeem", .refused, .notFound); throw SimIdentityError.invitationUnknown
        }
        let id = hit.key, inv = hit.value
        if inv.revoked { await note("invite.redeem", .refused, .permission); throw SimIdentityError.invitationRevoked }
        if inv.usedBy != nil { await note("invite.redeem", .refused, .conflict); throw SimIdentityError.invitationUsed }
        if now >= inv.expiresAt { await note("invite.redeem", .refused, .expired); throw SimIdentityError.invitationExpired }
        if let intended = inv.intendedEmail {
            guard state.accounts[intended]?.id == s.account else { await note("invite.redeem", .refused, .permission); throw SimIdentityError.wrongIdentity }
        }
        if inv.role.isPrivileged, !s.strong { throw SimIdentityError.strongFactorRequired }
        var used = inv; used.usedBy = s.account
        state.invitations[id] = used
        let m = SimMembership(account: s.account, caseID: inv.caseID, role: inv.role, boundAt: now, encryptionPublicKey: encryptionPublicKey)
        state.memberships[inv.caseID, default: []].removeAll { $0.account == s.account }
        state.memberships[inv.caseID, default: []].append(m)
        state.permissionEpochs[inv.caseID, default: 0] += 1
        await note("invite.redeem", .ok, nil)
        return m
    }

    public func revokeMember(_ member: SimAccountID, caseID: UUID, by token: String, now: Date) async throws {
        let actor = try await requireRole(caseID: caseID, token: token, now: now)
        guard actor.canInvite else { throw SimIdentityError.notPermitted("only a lead removes a member") }
        var list = state.memberships[caseID] ?? []
        guard let target = list.first(where: { $0.account == member }) else { throw SimIdentityError.notMember }
        if target.role == .lead, list.filter({ $0.role == .lead }).count == 1 { throw SimIdentityError.lastLead }
        list.removeAll { $0.account == member }
        state.memberships[caseID] = list
        state.permissionEpochs[caseID, default: 0] += 1
        await note("member.revoke", .ok, nil)
    }

    /// The role checked at every call (a removed member's next call is refused; a privileged role needs a strong session).
    public func role(caseID: UUID, for token: String, now: Date) async throws -> TeamRole {
        try await requireRole(caseID: caseID, token: token, now: now)
    }

    public func members(caseID: UUID) async -> [SimMembership] { state.memberships[caseID] ?? [] }
    public func permissionEpoch(caseID: UUID) async -> Int { state.permissionEpochs[caseID] ?? 0 }

    // MARK: Service operations (SHIP-03, simulated): backup and restore of the service state

    /// The service state as JSON (hashes only: no password, token or recovery code is in it).
    public func exportState() throws -> Data {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        return try enc.encode(state)
    }

    /// Restore a state written by `exportState()`; an older state version is migrated forward, a newer one refused.
    public func importState(_ data: Data) throws {
        var s = try JSONDecoder().decode(State.self, from: data)
        guard s.version <= 2 else { throw SimIdentityError.notPermitted("the backup was written by a newer service version") }
        if s.version < 2 { s.permissionEpochs = s.memberships.mapValues { _ in 1 }; s.version = 2 }
        state = s
    }

    // MARK: Private

    private func issue(_ account: SimAccountID, strong: Bool, now: Date) async -> SimSession {
        let token = SimSecrets.token(32)
        let s = Session(account: account, expiresAt: now.addingTimeInterval(Self.sessionLifetime), strong: strong)
        state.sessions[SimSecrets.digest(token)] = s
        await note("session.signin", .ok, nil)
        return SimSession(token: token, account: account, expiresAt: s.expiresAt, strong: strong)
    }

    private func session(_ token: String, now: Date) throws -> Session {
        guard let s = state.sessions[SimSecrets.digest(token)] else { throw SimIdentityError.sessionUnknown }
        guard now < s.expiresAt else { throw SimIdentityError.sessionExpired }
        return s
    }

    private func requireRole(caseID: UUID, token: String, now: Date) async throws -> TeamRole {
        let s: Session
        do { s = try session(token, now: now) } catch {
            await note("role.check", .refused, .authentication)
            throw error
        }
        guard let m = state.memberships[caseID]?.first(where: { $0.account == s.account }) else {
            await note("role.check", .refused, .permission); throw SimIdentityError.notMember
        }
        if m.role.isPrivileged, !s.strong { await note("role.check", .refused, .authentication); throw SimIdentityError.strongFactorRequired }
        return m.role
    }

    private func note(_ route: String, _ outcome: HealthOutcome, _ error: HealthErrorClass?) async {
        await monitor?.record(route: route, outcome: outcome, errorClass: error, latencyMs: 1)
    }
}
