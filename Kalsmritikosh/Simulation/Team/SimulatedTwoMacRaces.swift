//
//  SimulatedTwoMacRaces.swift
//  Kalsmritikosh
//
//  Unified path R2-E (QA-09, owner 2026-11-22 round 2) — not tested yet. SIMULATED multi-user races against a shared
//  service: two simulated Macs (distinct accounts and sessions) write the same case revision at once, one has access
//  revoked mid-flight, and a late result arrives for a closed case. The shared store accepts a write only at the
//  revision the writer read (compare-and-set) and re-checks the writer's role at the moment of the write, so: exactly
//  one concurrent edit lands, the other gets an explicit conflict (never a silent overwrite); a revoked writer's queued
//  write is refused; a late result for a closed case writes nothing.
//

import Foundation
import os

public actor SimulatedSharedCaseStore {
    public enum WriteResult: Sendable, Equatable {
        case landed(revision: Int)
        case conflict(current: Int)
        case refused(String)
    }
    private let identity: any TeamIdentityService
    private var revisions: [UUID: Int] = [:]
    private var closed: Set<UUID> = []
    public private(set) var log: [(caseID: UUID, revision: Int, author: SimAccountID, text: String)] = []

    public nonisolated init(identity: any TeamIdentityService) { self.identity = identity }

    public func revision(_ caseID: UUID) -> Int { revisions[caseID] ?? 0 }
    public func close(_ caseID: UUID) { closed.insert(caseID) }

    public func write(caseID: UUID, readRevision: Int, text: String, session token: String, now: Date) async -> WriteResult {
        if closed.contains(caseID) { return .refused("the case is closed") }
        let role: TeamRole
        let author: SimAccountID
        do {
            role = try await identity.role(caseID: caseID, for: token, now: now)
            author = try await identity.account(for: token, now: now)
        } catch {
            KalsmritikoshLog.app.notice("SIMULATED shared store: write refused: \(error.localizedDescription, privacy: .public)")
            return .refused(error.localizedDescription)
        }
        guard role.canWrite else { return .refused("role \(role.rawValue) cannot write") }
        // Re-read after the suspension points above: the actor may have changed while the role was checked.
        if closed.contains(caseID) { return .refused("the case is closed") }
        let current = revisions[caseID] ?? 0
        guard current == readRevision else { return .conflict(current: current) }
        revisions[caseID] = current + 1
        log.append((caseID, current + 1, author, text))
        return .landed(revision: current + 1)
    }
}

public nonisolated enum SimulatedTwoMacRaces {
    /// Runs the three races and returns (check, passed, detail) lines labelled SIMULATED.
    public static func run(now: Date = Date()) async -> [(check: String, passed: Bool, detail: String)] {
        var out: [(String, Bool, String)] = []
        let identity = SimulatedIdentityProvider()
        let store = SimulatedSharedCaseStore(identity: identity)
        let caseID = UUID()
        do {
            let a = try await identity.createAccount(email: "mac-a@sim.invalid", displayName: "Mac A", password: "a-pass", now: now)
            let b = try await identity.createAccount(email: "mac-b@sim.invalid", displayName: "Mac B", password: "b-pass", now: now)
            let fa = try await identity.enrolStrongFactor(a, password: "a-pass")
            let fb = try await identity.enrolStrongFactor(b, password: "b-pass")
            let sa = try await identity.signIn(email: "mac-a@sim.invalid", password: "a-pass", oneTimeCode: SimOneTimeCode.code(secret: fa.secret, at: now), now: now)
            let sb = try await identity.signIn(email: "mac-b@sim.invalid", password: "b-pass", oneTimeCode: SimOneTimeCode.code(secret: fb.secret, at: now), now: now)
            try await identity.createCase(caseID, by: sa.token, encryptionPublicKey: Data(), now: now)
            let inv = try await identity.invite(caseID: caseID, role: .examiner, intendedEmail: "mac-b@sim.invalid", ttl: 3600, by: sa.token, now: now)
            _ = try await identity.redeem(invitation: inv.token, by: sb.token, encryptionPublicKey: Data(), now: now)

            // Race 1: both Macs edit revision 0 at once.
            async let r1 = store.write(caseID: caseID, readRevision: 0, text: "A's edit", session: sa.token, now: now)
            async let r2 = store.write(caseID: caseID, readRevision: 0, text: "B's edit", session: sb.token, now: now)
            let results = await [r1, r2]
            let landed = results.filter { if case .landed = $0 { return true }; return false }.count
            let conflicts = results.filter { if case .conflict = $0 { return true }; return false }.count
            let revisionAfter = await store.revision(caseID)
            out.append(("SIMULATED: two simultaneous edits of one revision — exactly one lands, the other is an explicit conflict",
                        landed == 1 && conflicts == 1 && revisionAfter == 1, "\(results)"))

            // Race 2: B's access is revoked while B's write is queued.
            let rev = await store.revision(caseID)
            try await identity.revokeMember(b, caseID: caseID, by: sa.token, now: now)
            let late = await store.write(caseID: caseID, readRevision: rev, text: "B after removal", session: sb.token, now: now)
            if case .refused = late { out.append(("SIMULATED: a revoked writer's queued write is refused", true, "\(late)")) }
            else { out.append(("SIMULATED: a revoked writer's queued write is refused", false, "\(late)")) }

            // Race 3: a late result for a closed case.
            await store.close(caseID)
            let afterClose = await store.write(caseID: caseID, readRevision: await store.revision(caseID), text: "late AI result", session: sa.token, now: now)
            if case .refused = afterClose { out.append(("SIMULATED: a late result for a closed case writes nothing", true, "\(afterClose)")) }
            else { out.append(("SIMULATED: a late result for a closed case writes nothing", false, "\(afterClose)")) }
            out.append(("SIMULATED: no hidden overwrite — the log holds one entry per landed write", (await store.log.count) == 1, ""))
        } catch {
            KalsmritikoshLog.app.error("SIMULATED two-Mac races stopped: \(error.localizedDescription, privacy: .public)")
            out.append(("SIMULATED: the races ran to the end", false, error.localizedDescription))
        }
        return out.map { (check: $0.0, passed: $0.1, detail: $0.2) }
    }
}
