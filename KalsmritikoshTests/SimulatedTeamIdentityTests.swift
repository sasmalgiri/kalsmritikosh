//
//  SimulatedTeamIdentityTests.swift
//  KalsmritikoshTests
//
//  Unified path R2-E (owner 2026-11-22 round 2) — the test-phase runner of the SIMULATED team rows: PEOPLE-05,
//  PEOPLE-10, ACCESS-01, ACCESS-07, SEC-04, QA-07, QA-09, SHIP-03, PERF-04, PERF-12. Written now, run in the test phase.
//  Every result is a simulation: real people, accounts and a server are still needed for release.
//

import Foundation
import Testing
import CryptoKit
@testable import Kalsmritikosh

@Suite("SIMULATED team identity, invitations, encryption and races (R2-E)")
struct SimulatedTeamIdentityTests {

    @Test("SIMULATED: lead / examiner / reviewer journeys all pass, and the report is labelled simulated")
    func journeys() async throws {
        let report = await SimulatedTeamJourneys.run(now: Date(timeIntervalSince1970: 1_800_000_000))
        for s in report.steps where !s.passed { Issue.record("\(s.journey) / \(s.check): \(s.detail)") }
        #expect(report.allPassed)
        #expect(report.markdown.hasPrefix("# SIMULATED"))
        #expect(report.steps.count >= 30)
        try SimulationArtifacts.write(report.markdown, name: "team-journeys.md")
    }

    @Test("SIMULATED: one-time codes follow the 30-second window and accept one window of skew")
    func oneTimeCodes() {
        let secret = Data(repeating: 7, count: 20)
        let t = Date(timeIntervalSince1970: 1_800_000_015)
        let c = SimOneTimeCode.code(secret: secret, at: t)
        #expect(c.count == 6)
        #expect(SimOneTimeCode.verify(c, secret: secret, at: t.addingTimeInterval(30)))
        #expect(!SimOneTimeCode.verify(c, secret: secret, at: t.addingTimeInterval(95)))
    }

    @Test("SIMULATED: the vault's service side never holds plaintext; a non-member has no key")
    func vaultBoundary() async throws {
        let vault = SimulatedSharedCaseVault()
        let lead = Curve25519.KeyAgreement.PrivateKey(), stranger = Curve25519.KeyAgreement.PrivateKey()
        let leadID = SimAccountID(raw: "lead"), strangerID = SimAccountID(raw: "stranger")
        let c = UUID()
        _ = try await vault.open(caseID: c, lead: leadID, members: [(leadID, lead.publicKey)])
        let item = try await vault.put(caseID: c, plaintext: Data("plain words".utf8), author: leadID, authorKey: lead)
        #expect(await vault.serverVisibleBytes(caseID: c).range(of: Data("plain words".utf8)) == nil)
        await #expect(throws: SimVaultError.noKeyForMember) { _ = try await vault.read(caseID: c, itemID: item, as: strangerID, key: stranger) }
        #expect(SimulatedEncryptionDisclosure.text.contains("would NOT be end-to-end"))
    }

    @Test("SIMULATED: two-Mac races — one edit lands, revoked and late writes are refused")
    func races() async {
        let lines = await SimulatedTwoMacRaces.run(now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(!lines.isEmpty)
        for l in lines { #expect(l.passed, "\(l.check): \(l.detail)") }
    }

    @Test("SIMULATED: the identity/revision cache invalidates only what an edit, revocation, erasure or reconnection affects")
    func identityRevisionCache() async {
        let cache = IdentityRevisionCache<String>()
        let a = UUID(), b = UUID()
        func k(_ c: UUID, _ rev: Int, _ who: String, _ perm: Int = 1) async -> IdentityRevisionKey {
            IdentityRevisionKey(caseID: c, derivedKind: "map", scopeFingerprint: "f", revision: rev, principal: who, permissionEpoch: perm,
                                connectionEpoch: await cache.connectionEpoch)
        }
        _ = await cache.value(for: await k(a, 1, "x")) { "a1" }
        _ = await cache.value(for: await k(b, 1, "x")) { "b1" }
        await cache.noteRevision(2, caseID: a)
        #expect(await cache.count == 1, "only case a's older revision went")
        await cache.dropCase(b)
        #expect(await cache.count == 0)
        _ = await cache.value(for: await k(a, 2, "y")) { "a2" }
        await cache.notePermissionChange(caseID: a, principal: "y")
        #expect(await cache.count == 0)
        _ = await cache.value(for: await k(a, 2, "z")) { "a2" }
        await cache.noteReconnected()
        #expect(await cache.count == 0)
    }

    @Test("SIMULATED: the health monitor refuses free-text keys and its snapshot is content-free")
    func contentFreeMonitor() async {
        let m = ContentFreeHealthMonitor()
        #expect(await m.record(route: "invite.redeem", outcome: .ok, latencyMs: 3))
        #expect(!(await m.record(route: "Ada Lovelace <ada@example.com>", outcome: .failed, latencyMs: 3)))
        await m.recordQueue("sync.outbox", depth: 3, oldestAgeSeconds: 12)
        let json = await m.snapshotJSON()
        #expect(ContentFreeHealthMonitor.isContentFree(json, forbidden: ["ada@example.com", "Ada Lovelace"]))
        #expect(String(decoding: json, as: UTF8.self).contains("SIMULATED"))
    }
}

/// Where the simulations write their labelled reports during the test phase (small markdown files only):
/// $KALS_SIM_OUT when set (scripts/sim/run-simulations.sh sets it), else the per-process temporary folder.
enum SimulationArtifacts {
    static func folder() -> URL {
        if let p = ProcessInfo.processInfo.environment["KALS_SIM_OUT"], !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
        return FileManager.default.temporaryDirectory.appendingPathComponent("kals-simulations", isDirectory: true)
    }
    static func write(_ text: String, name: String) throws {
        let dir = folder()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: dir.appendingPathComponent(name), options: .atomic)
    }
}
