//
//  SimulatedTeamJourneys.swift
//  Kalsmritikosh
//
//  Unified path R2-E (owner 2026-11-22 round 2) — not tested yet. PEOPLE-05, PEOPLE-10, ACCESS-01, ACCESS-07, SEC-04,
//  QA-07, SHIP-03, PERF-04, PERF-12, SHIP-06 (team entitlements).
//
//  The distinct-user journeys over the SIMULATED identity provider and vault: a lead, an examiner and a reviewer are
//  three different simulated accounts with their own sessions and their own key pairs — not three role labels inside
//  one privileged session. Each step is checked and reported with its result; the report says SIMULATED at the top.
//  Run by KalsmritikoshTests/SimulatedTeamIdentityTests.swift (the test phase) and scripts/sim/run-simulations.sh.
//

import Foundation
import CryptoKit
import os

// MARK: - PEOPLE-05: participants bound to accounts, kept apart from reported performers and case people

public nonisolated enum SimParticipant: Hashable, Sendable {
    /// Someone who acted through an authenticated (simulated) session.
    case account(SimAccountID, role: TeamRole)
    /// Someone a record SAYS performed an action (an outside person) — never an account.
    case reportedPerformer(name: String)
    /// A person the case is about.
    case casePerson(name: String)

    public var isAuthenticated: Bool { if case .account = self { return true }; return false }
    public var label: String {
        switch self {
        case .account(let id, let role): return "\(role.rawValue) (simulated account \(id.raw.prefix(10))…, session-verified)"
        case .reportedPerformer(let n): return "\(n) (reported as performer — not an account, not verified)"
        case .casePerson(let n): return "\(n) (case person)"
        }
    }
}

public actor SimulatedParticipantRegistry {
    public struct Action: Sendable, Equatable {
        public let summary: String
        public let recordedBy: SimParticipant
        public let performedBy: SimParticipant?
    }
    private let identity: any TeamIdentityService
    public private(set) var actions: [Action] = []
    public nonisolated init(identity: any TeamIdentityService) { self.identity = identity }

    /// An action is recorded by the session's account (never by a typed name); who performed it, when an outside
    /// person did, is a reported performer.
    public func record(_ summary: String, caseID: UUID, session token: String, performedBy reported: String?, now: Date) async throws {
        let account = try await identity.account(for: token, now: now)
        let role = try await identity.role(caseID: caseID, for: token, now: now)
        actions.append(Action(summary: summary, recordedBy: .account(account, role: role),
                              performedBy: reported.map { .reportedPerformer(name: $0) }))
    }
}

// MARK: - PEOPLE-10: per-viewer filtering of search, graph links, summaries, history and exports

public nonisolated struct SimViewItem: Sendable, Equatable {
    public enum Surface: String, Sendable, CaseIterable { case search, graphLink, summary, history, export }
    public let surface: Surface
    public let text: String
    /// The people the item names directly or indirectly (aliases, a summary that mentions them).
    public let personRefs: Set<String>
}

public nonisolated struct SimAccessFilter: Sendable {
    /// Restricted person → roles still allowed to see them.
    public var restrictions: [String: Set<TeamRole>] = [:]
    public init() {}

    public func visible(_ items: [SimViewItem], to role: TeamRole) -> (items: [SimViewItem], withheld: [SimViewItem.Surface: Int]) {
        var out: [SimViewItem] = []
        var withheld: [SimViewItem.Surface: Int] = [:]
        for item in items {
            let blocked = item.personRefs.contains { p in restrictions[p].map { !$0.contains(role) } ?? false }
            if blocked { withheld[item.surface, default: 0] += 1 } else { out.append(item) }
        }
        return (out, withheld)
    }
}

// MARK: - SHIP-03: staging and production configuration of the (simulated) service

public nonisolated struct SimServiceEnvironment: Sendable, Equatable {
    public enum Stage: String, Sendable { case staging, production }
    public let stage: Stage
    public let host: String
    public let backupsEnabled: Bool
    public let monitoringEnabled: Bool
    public let stateVersion: Int

    public static let staging = SimServiceEnvironment(stage: .staging, host: "team-staging.simulated.invalid", backupsEnabled: true, monitoringEnabled: true, stateVersion: 2)
    public static let production = SimServiceEnvironment(stage: .production, host: "team.simulated.invalid", backupsEnabled: true, monitoringEnabled: true, stateVersion: 2)

    /// Problems that stop a promotion from staging to production.
    public static func promotionProblems(from s: SimServiceEnvironment, to p: SimServiceEnvironment) -> [String] {
        var out: [String] = []
        if s.host == p.host { out.append("staging and production share a host") }
        if !p.host.hasSuffix(".invalid") { out.append("SIMULATED environments must use a reserved .invalid host") }
        if !p.backupsEnabled { out.append("production has no backups") }
        if !p.monitoringEnabled { out.append("production has no monitoring") }
        if p.stateVersion < s.stateVersion { out.append("production would run an older state version than staging (no downgrade)") }
        return out
    }
}

// MARK: - SHIP-06: team and contributor entitlements (simulated policy)

public nonisolated enum SimTeamEntitlement {
    /// Who needs a paid plan in a team case (simulated policy for the test phase): the lead's subscription covers the
    /// case; examiners need their own Workbench plan; reviewers and contributors need none. A lapsed lead keeps every
    /// member's read access to what is already in the case (no evidence stranded) but no new invitations.
    public static func canInvite(leadSubscribed: Bool) -> Bool { leadSubscribed }
    public static func needsOwnPlan(_ role: TeamRole) -> Bool { role == .lead || role == .examiner }
    public static func keepsReadAccessAfterLapse(_ role: TeamRole) -> Bool { role.canRead }
}

// MARK: - The journeys

public nonisolated struct SimulatedJourneyReport: Sendable {
    public struct Step: Sendable, Equatable {
        public let journey: String
        public let actor: String
        public let check: String
        public let passed: Bool
        public let detail: String
    }
    public let label = SimulationLabel.banner
    public var steps: [Step] = []
    public var healthJSON = Data()
    public var allPassed: Bool { !steps.isEmpty && steps.allSatisfy(\.passed) }

    public var markdown: String {
        var s = "# \(label)\n\nSimulated team journeys (lead, examiner, reviewer as distinct simulated accounts).\n\n"
        s += "| Journey | Actor | Check | Result | Detail |\n|---|---|---|---|---|\n"
        for st in steps { s += "| \(st.journey) | \(st.actor) | \(st.check) | \(st.passed ? "PASS (simulated)" : "FAIL") | \(st.detail) |\n" }
        s += "\n\(SimulatedEncryptionDisclosure.text)\n"
        return s
    }
}

public nonisolated enum SimulatedTeamJourneys {

    struct Person {
        let name: String, email: String, password: String
        let key = Curve25519.KeyAgreement.PrivateKey()
        var id = SimAccountID(raw: "")
        var secret = Data()
        var recovery: [String] = []
        var session: SimSession?
    }

    /// Run every journey against `identity` (default: a fresh simulated provider). `now` is the simulated clock.
    public static func run(identity given: (any TeamIdentityService)? = nil, now start: Date = Date()) async -> SimulatedJourneyReport {
        let monitor = ContentFreeHealthMonitor(now: start)
        let identity: any TeamIdentityService = given ?? SimulatedIdentityProvider(monitor: monitor)
        let vault = SimulatedSharedCaseVault()
        var report = SimulatedJourneyReport()
        func check(_ journey: String, _ actor: String, _ what: String, _ ok: Bool, _ detail: String = "") {
            report.steps.append(.init(journey: journey, actor: actor, check: what, passed: ok, detail: detail))
            if !ok { KalsmritikoshLog.app.error("SIMULATED team journey failed: \(journey, privacy: .public) — \(what, privacy: .public)") }
        }
        func refused<T>(_ expected: SimIdentityError, _ body: () async throws -> T) async -> (Bool, String) {
            do { _ = try await body(); return (false, "was allowed") } catch {
                KalsmritikoshLog.app.debug("SIMULATED journey: refused as checked: \(error.localizedDescription, privacy: .public)")
                guard let e = error as? SimIdentityError else { return (false, "\(error)") }
                return (e == expected, e.errorDescription ?? "\(e)")
            }
        }

        var lead = Person(name: "Lead L.", email: "lead@sim.invalid", password: "lead-pass-1")
        var examiner = Person(name: "Examiner E.", email: "examiner@sim.invalid", password: "exam-pass-1")
        var reviewer = Person(name: "Reviewer R.", email: "reviewer@sim.invalid", password: "rev-pass-1")
        let caseID = UUID()
        var now = start

        do {
            // J1 — accounts and strong sign-in (ACCESS-01)
            lead.id = try await identity.createAccount(email: lead.email, displayName: lead.name, password: lead.password, now: now)
            examiner.id = try await identity.createAccount(email: examiner.email, displayName: examiner.name, password: examiner.password, now: now)
            reviewer.id = try await identity.createAccount(email: reviewer.email, displayName: reviewer.name, password: reviewer.password, now: now)
            check("J1 accounts", "all", "three distinct simulated accounts", Set([lead.id, examiner.id, reviewer.id]).count == 3)
            let dup = await refused(.accountExists) { try await identity.createAccount(email: "LEAD@sim.invalid", displayName: "Lead L.", password: "x", now: now) }
            check("J1 accounts", "anyone", "a display name / e-mail is not identity: a second account on the same address is refused", dup.0, dup.1)
            (lead.secret, lead.recovery) = try await identity.enrolStrongFactor(lead.id, password: lead.password)
            (examiner.secret, examiner.recovery) = try await identity.enrolStrongFactor(examiner.id, password: examiner.password)
            lead.session = try await identity.signIn(email: lead.email, password: lead.password,
                                                     oneTimeCode: SimOneTimeCode.code(secret: lead.secret, at: now), now: now)
            check("J1 accounts", "lead", "strong sign-in with the second factor", lead.session?.strong == true)
            let badCode = await refused(.badCredentials) { try await identity.signIn(email: examiner.email, password: examiner.password, oneTimeCode: "000000", now: now) }
            check("J1 accounts", "examiner", "a wrong one-time code is refused", badCode.0, badCode.1)
            let leadToken = lead.session?.token ?? ""

            // J2 — the lead opens the case and invites (ACCESS-07)
            try await identity.createCase(caseID, by: leadToken, encryptionPublicKey: lead.key.publicKey.rawRepresentation, now: now)
            _ = try await vault.open(caseID: caseID, lead: lead.id, members: [(lead.id, lead.key.publicKey)])
            let invExaminer = try await identity.invite(caseID: caseID, role: .examiner, intendedEmail: examiner.email, ttl: 86_400, by: leadToken, now: now)
            let invReviewer = try await identity.invite(caseID: caseID, role: .reviewer, intendedEmail: nil, ttl: 86_400, by: leadToken, now: now)
            let invShort = try await identity.invite(caseID: caseID, role: .reviewer, intendedEmail: nil, ttl: 60, by: leadToken, now: now)
            let invWithdrawn = try await identity.invite(caseID: caseID, role: .reviewer, intendedEmail: nil, ttl: 86_400, by: leadToken, now: now)
            try await identity.revokeInvitation(invWithdrawn.id, by: leadToken, now: now)
            check("J2 invite", "lead", "invitation tokens are 256-bit and distinct", invExaminer.token.count >= 43 && invExaminer.token != invReviewer.token)

            // J3 — examiner: a weak session cannot take a privileged role; a strong one can
            examiner.session = try await identity.signIn(email: examiner.email, password: examiner.password, oneTimeCode: nil, now: now)
            let weak = await refused(.strongFactorRequired) {
                try await identity.redeem(invitation: invExaminer.token, by: examiner.session?.token ?? "", encryptionPublicKey: examiner.key.publicKey.rawRepresentation, now: now)
            }
            check("J3 examiner", "examiner", "a privileged role needs a strong session", weak.0, weak.1)
            examiner.session = try await identity.signIn(email: examiner.email, password: examiner.password,
                                                         oneTimeCode: SimOneTimeCode.code(secret: examiner.secret, at: now), now: now)
            let mExaminer = try await identity.redeem(invitation: invExaminer.token, by: examiner.session?.token ?? "",
                                                      encryptionPublicKey: examiner.key.publicKey.rawRepresentation, now: now)
            try await vault.addMember(caseID: caseID, member: examiner.id, publicKey: examiner.key.publicKey, leadKey: lead.key)
            check("J3 examiner", "examiner", "joined as examiner with their own account", mExaminer.role == .examiner && mExaminer.account == examiner.id)

            // J4 — reviewer; invitation misuse
            reviewer.session = try await identity.signIn(email: reviewer.email, password: reviewer.password, oneTimeCode: nil, now: now)
            let revToken = reviewer.session?.token ?? ""
            let wrong = await refused(.wrongIdentity) {
                try await identity.redeem(invitation: invExaminer.token, by: revToken, encryptionPublicKey: reviewer.key.publicKey.rawRepresentation, now: now)
            }
            check("J4 reviewer", "reviewer", "an invitation for someone else (or already used) grants nothing", wrong.0 || wrong.1.contains("already used"), wrong.1)
            let guessed = await refused(.invitationUnknown) {
                try await identity.redeem(invitation: SimSecrets.token(32), by: revToken, encryptionPublicKey: reviewer.key.publicKey.rawRepresentation, now: now)
            }
            check("J4 reviewer", "reviewer", "a guessed token grants nothing", guessed.0, guessed.1)
            let withdrawn = await refused(.invitationRevoked) {
                try await identity.redeem(invitation: invWithdrawn.token, by: revToken, encryptionPublicKey: reviewer.key.publicKey.rawRepresentation, now: now)
            }
            check("J4 reviewer", "reviewer", "a withdrawn invitation grants nothing", withdrawn.0, withdrawn.1)
            let expired = await refused(.invitationExpired) {
                try await identity.redeem(invitation: invShort.token, by: revToken, encryptionPublicKey: reviewer.key.publicKey.rawRepresentation, now: now.addingTimeInterval(120))
            }
            check("J4 reviewer", "reviewer", "an expired invitation grants nothing", expired.0, expired.1)
            let mReviewer = try await identity.redeem(invitation: invReviewer.token, by: revToken, encryptionPublicKey: reviewer.key.publicKey.rawRepresentation, now: now)
            try await vault.addMember(caseID: caseID, member: reviewer.id, publicKey: reviewer.key.publicKey, leadKey: lead.key)
            check("J4 reviewer", "reviewer", "joined as reviewer", mReviewer.role == .reviewer)
            let reuse = await refused(.invitationUsed) {
                try await identity.redeem(invitation: invReviewer.token, by: examiner.session?.token ?? "", encryptionPublicKey: examiner.key.publicKey.rawRepresentation, now: now)
            }
            check("J4 reviewer", "examiner", "a used invitation cannot be used again", reuse.0, reuse.1)

            // J5 — shared encrypted work (SEC-04) and participant binding (PEOPLE-05)
            let secretNote = "Interview note: the cash was moved on 3 May (SIMULATED)."
            let item = try await vault.put(caseID: caseID, plaintext: Data(secretNote.utf8), author: examiner.id, authorKey: examiner.key)
            let readBack = try await vault.read(caseID: caseID, itemID: item, as: reviewer.id, key: reviewer.key)
            check("J5 shared work", "reviewer", "reads the examiner's encrypted note with their own key", String(decoding: readBack, as: UTF8.self) == secretNote)
            let server = await vault.serverVisibleBytes(caseID: caseID)
            check("J5 shared work", "service", "the service holds no plaintext", server.range(of: Data("cash was moved".utf8)) == nil)
            let registry = SimulatedParticipantRegistry(identity: identity)
            try await registry.record("Recorded the interview", caseID: caseID, session: examiner.session?.token ?? "", performedBy: "J. Outside (bank clerk)", now: now)
            let acts = await registry.actions
            check("J5 shared work", "examiner", "the recorder is the session's account; the reported performer is not an account",
                  acts.first?.recordedBy == .account(examiner.id, role: .examiner) && acts.first?.performedBy?.isAuthenticated == false)
            let reviewerWrite = TeamRole.reviewer.canWrite
            check("J5 shared work", "reviewer", "a reviewer has no write permission", !reviewerWrite)

            // J6 — restricted profile across every surface (PEOPLE-10)
            var filter = SimAccessFilter()
            filter.restrictions["P-1"] = [.lead]
            let items: [SimViewItem] = SimViewItem.Surface.allCases.map { SimViewItem(surface: $0, text: "mentions the protected witness", personRefs: ["P-1"]) }
                + [SimViewItem(surface: .search, text: "unrelated", personRefs: ["P-2"])]
            let seen = filter.visible(items, to: .reviewer)
            check("J6 restriction", "reviewer", "search, graph links, summaries, history and exports all withhold the restricted profile",
                  seen.items.count == 1 && SimViewItem.Surface.allCases.allSatisfy { seen.withheld[$0] == 1 })
            check("J6 restriction", "lead", "the lead still sees it", filter.visible(items, to: .lead).items.count == items.count)

            // J7 — cache by identity and revision; revocation; rotation (PERF-04, ACCESS-07, SEC-04)
            let cache = IdentityRevisionCache<Int>()
            func key(_ who: SimAccountID, revision: Int) async -> IdentityRevisionKey {
                IdentityRevisionKey(caseID: caseID, derivedKind: "branch", scopeFingerprint: "s1", revision: revision, principal: who.raw,
                                    permissionEpoch: await identity.permissionEpoch(caseID: caseID), connectionEpoch: await cache.connectionEpoch)
            }
            _ = await cache.value(for: await key(reviewer.id, revision: 1)) { 7 }
            _ = await cache.value(for: await key(reviewer.id, revision: 1)) { 7 }
            let hitsBefore = await cache.hits
            try await identity.revokeMember(reviewer.id, caseID: caseID, by: leadToken, now: now)
            await cache.notePermissionChange(caseID: caseID, principal: reviewer.id.raw)
            let revoked = await refused(.notMember) { try await identity.role(caseID: caseID, for: revToken, now: now) }
            check("J7 revoke", "reviewer", "the removed reviewer's next call is refused", revoked.0, revoked.1)
            _ = await cache.value(for: await key(reviewer.id, revision: 1)) { 7 }
            check("J7 revoke", "cache", "a revoked principal's cached view is not reused (permission epoch moved)", await cache.hits == hitsBefore)
            try await vault.removeAndRotate(caseID: caseID, removed: reviewer.id,
                                            remaining: [(lead.id, lead.key.publicKey), (examiner.id, examiner.key.publicKey)], leadKey: lead.key)
            var reviewerLocked = false
            do { _ = try await vault.read(caseID: caseID, itemID: item, as: reviewer.id, key: reviewer.key) } catch { reviewerLocked = true }
            check("J7 revoke", "reviewer", "after rotation the removed reviewer cannot open re-encrypted items", reviewerLocked)
            let examinerStill = try await vault.read(caseID: caseID, itemID: item, as: examiner.id, key: examiner.key)
            check("J7 revoke", "examiner", "the remaining examiner still can", String(decoding: examinerStill, as: UTF8.self) == secretNote)
            await cache.noteReconnected()
            _ = await cache.value(for: await key(examiner.id, revision: 2)) { 8 }
            check("J7 reconnect", "cache", "after a reconnection nothing cached before is trusted", await cache.count == 1)
            let lastLead = await refused(.lastLead) { try await identity.revokeMember(lead.id, caseID: caseID, by: leadToken, now: now) }
            check("J7 revoke", "lead", "the last lead cannot be removed", lastLead.0, lastLead.1)

            // J8 — recovery (ACCESS-01)
            now = now.addingTimeInterval(300)
            let code = examiner.recovery.first ?? ""
            let recovered = try await identity.recover(email: examiner.email, recoveryCode: code, newPassword: "exam-pass-2", now: now)
            let oldSession = await refused(.sessionUnknown) { try await identity.account(for: examiner.session?.token ?? "", now: now) }
            check("J8 recovery", "examiner", "recovery ends every earlier session", oldSession.0, oldSession.1)
            let weakAfter = await refused(.strongFactorRequired) { try await identity.role(caseID: caseID, for: recovered.token, now: now) }
            check("J8 recovery", "examiner", "a recovered session needs the second factor again for a privileged role", weakAfter.0, weakAfter.1)
            let reused = await refused(.recoveryRejected) { try await identity.recover(email: examiner.email, recoveryCode: code, newPassword: "x", now: now) }
            check("J8 recovery", "attacker", "a recovery code works once", reused.0, reused.1)
            let lateSession = await refused(.sessionExpired) { try await identity.account(for: leadToken, now: start.addingTimeInterval(SimulatedIdentityProvider.sessionLifetime + 1)) }
            check("J8 recovery", "lead", "a session expires", lateSession.0, lateSession.1)

            // J9 — service operations (SHIP-03): promotion checks, backup and restore of the service state
            let problems = SimServiceEnvironment.promotionProblems(from: .staging, to: .production)
            check("J9 operations", "operator", "staging → production configuration passes the promotion checks", problems.isEmpty, problems.joined(separator: "; "))
            if let sim = identity as? SimulatedIdentityProvider {
                let backup = try await sim.exportState()
                let restored = SimulatedIdentityProvider()
                try await restored.importState(backup)
                let restoredMembers = await restored.members(caseID: caseID).map(\.account)
                check("J9 operations", "operator", "the service backup restores memberships", Set(restoredMembers) == Set([lead.id, examiner.id]))
                let text = String(decoding: backup, as: UTF8.self)
                check("J9 operations", "operator", "the backup holds no password, token or recovery code",
                      !text.contains(lead.password) && !text.contains(leadToken) && !text.contains(code))
            }
            check("J9 operations", "policy", "team entitlements: a lapsed lead invites no one; reviewers need no plan",
                  !SimTeamEntitlement.canInvite(leadSubscribed: false) && !SimTeamEntitlement.needsOwnPlan(.reviewer))
        } catch {
            KalsmritikoshLog.app.error("SIMULATED team journeys stopped: \(error.localizedDescription, privacy: .public)")
            check("journeys", "-", "the journeys ran to the end", false, error.localizedDescription)
        }

        // PERF-12 — content-free monitoring of the simulated service
        let json = await monitor.snapshotJSON(now: now)
        report.healthJSON = json
        check("J10 monitoring", "operator", "health snapshot has routes and no names, e-mail addresses or note text",
              !json.isEmpty && ContentFreeHealthMonitor.isContentFree(json, forbidden: [lead.email, examiner.email, reviewer.email, lead.name, "cash was moved"]))
        return report
    }
}
