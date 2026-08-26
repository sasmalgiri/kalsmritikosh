//
//  AuditChainTests.swift
//  KalsmritikoshTests
//
//  AUD-CHAIN — the tamper-evident audit hash chain (migration v104) that seals
//  the existing append-only ledgers. Proves: v104 migration reach/preserve/
//  self-heal/rollback; seal is append-only + idempotent; verify() confirms an
//  intact chain; an edited sealed event, a deleted sealed event, and a
//  reordering are all caught; unsealed recorded events are reported (not
//  tamper); a wrong secret fails verification. Real ledger tables + a fixed
//  test secret (deterministic).
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("AUD-CHAIN — tamper-evident audit hash chain", .serialized)
struct AuditChainTests {

    private let secret = Data("test-audit-chain-secret-0123456789".utf8)
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: migration

    @Test("A fresh database reaches v104 with the audit_chain table + unique (source, event) index")
    func freshV104() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 104)
        #expect(try await db.currentUserVersion() == 104)
        #expect(try await MigrationFixtureBuilder.tableExists(db, "audit_chain"))
        #expect(try await MigrationFixtureBuilder.columns(db, "audit_chain")
            .isSuperset(of: ["seq", "source", "event_id", "payload_hash", "prev_hash", "entry_hash"]))
    }

    @Test("v103→v104 preserves data and fabricates no seals; self-heal + rollback hold")
    func migrationSafety() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 103)
        try await SchemaMigrations.migrate(db, through: 104)
        #expect(try await db.currentUserVersion() == 104)
        #expect(try await db.query("SELECT COUNT(*) FROM audit_chain;", []).first?.int(0) == 0)

        let healed = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await healed.setUserVersion(99)
        try await SchemaMigrations.migrate(healed)
        #expect(try await healed.currentUserVersion() == SchemaMigrations.latestVersion)

        let rollback = try await MigrationFixtureBuilder.database(atVersion: 103)
        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.migrate(rollback, through: 104,
                fault: MigrationFaultHarness.hook(throwingAt: .afterSQLBeforeVersionStamp(version: 104)))
        }
        #expect(try await rollback.currentUserVersion() == 103)
        #expect(try await rollback.query("SELECT name FROM sqlite_master WHERE name='audit_chain';", []).isEmpty)
    }

    // MARK: rig — a mutable in-memory event set standing in for the ledgers

    private actor Ledger {
        var events: [AuditChainEvent] = []
        func snapshot() -> [AuditChainEvent] { events }
        func set(_ e: [AuditChainEvent]) { events = e }
    }

    private func event(_ n: Int, source: AuditChainEvent.Source = .custody, payload: String? = nil) -> AuditChainEvent {
        AuditChainEvent(source: source, eventID: UUID(),
                        occurredAt: t0.addingTimeInterval(Double(n)),
                        canonicalPayload: payload ?? "k=v\(n)")
    }

    private func service(_ db: Database, _ ledger: Ledger, secret: Data? = nil) -> AuditChainService {
        AuditChainService(database: db, secret: secret ?? self.secret,
                          eventProvider: { await ledger.snapshot() })
    }

    // MARK: seal + verify

    @Test("Seal is append-only and idempotent; verify() confirms an intact chain")
    func sealIdempotentAndIntact() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let ledger = Ledger()
        await ledger.set([event(1), event(2), event(3)])
        let svc = service(db, ledger)

        #expect(try await svc.seal(now: t0) == 3)
        #expect(try await svc.seal(now: t0) == 0)   // idempotent — nothing new
        #expect(try await svc.sealedCount() == 3)

        let v = try await svc.verify()
        #expect(v.isIntact)
        #expect(v.sealedCount == 3 && v.unsealedCount == 0)
    }

    @Test("A newly recorded event seals onto the existing chain and stays intact")
    func incrementalSeal() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let ledger = Ledger()
        var events = [event(1), event(2)]
        await ledger.set(events)
        let svc = service(db, ledger)
        _ = try await svc.seal(now: t0)

        events.append(event(3, source: .review))
        await ledger.set(events)
        #expect(try await svc.seal(now: t0) == 1)
        #expect(try await svc.verify().isIntact)
        // Recorded-but-unsealed is reported as informational, not tamper.
        events.append(event(4))
        await ledger.set(events)
        let v = try await svc.verify()
        #expect(v.isIntact && v.unsealedCount == 1)
    }

    @Test("Editing a sealed event's payload breaks the chain at that seq")
    func editedEventDetected() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let ledger = Ledger()
        let e = [event(1), event(2), event(3)]
        await ledger.set(e)
        let svc = service(db, ledger)
        _ = try await svc.seal(now: t0)

        // Tamper: same id/time, different payload for the middle event.
        var edited = e
        edited[1] = AuditChainEvent(source: e[1].source, eventID: e[1].eventID,
                                    occurredAt: e[1].occurredAt, canonicalPayload: "k=TAMPERED")
        await ledger.set(edited)
        let v = try await svc.verify()
        #expect(!v.isIntact)
        #expect(v.firstBrokenSeq == 2)
    }

    @Test("Deleting a sealed event is caught as a missing-event break")
    func deletedEventDetected() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let ledger = Ledger()
        let e = [event(1), event(2), event(3)]
        await ledger.set(e)
        let svc = service(db, ledger)
        _ = try await svc.seal(now: t0)

        await ledger.set([e[0], e[2]])   // event 2 deleted from the ledger
        let v = try await svc.verify()
        #expect(!v.isIntact)
        #expect(v.missingEventSeq == 2)
    }

    @Test("A wrong secret cannot validate the chain")
    func wrongSecretFails() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let ledger = Ledger()
        await ledger.set([event(1), event(2)])
        _ = try await service(db, ledger).seal(now: t0)

        let impostor = service(db, ledger, secret: Data("a-completely-different-secret-value".utf8))
        #expect(!(try await impostor.verify().isIntact))
    }

    @Test("Canonical ordering is by (occurredAt, source, id) — same-timestamp events seal deterministically")
    func deterministicOrdering() async throws {
        let db1 = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let db2 = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        // Two events at the SAME instant, different sources.
        let a = AuditChainEvent(source: .custody, eventID: UUID(), occurredAt: t0, canonicalPayload: "a")
        let b = AuditChainEvent(source: .review, eventID: UUID(), occurredAt: t0, canonicalPayload: "b")
        let l1 = Ledger(); await l1.set([a, b])
        let l2 = Ledger(); await l2.set([b, a])   // reversed input order
        _ = try await service(db1, l1).seal(now: t0)
        _ = try await service(db2, l2).seal(now: t0)
        let h1 = try await db1.query("SELECT entry_hash FROM audit_chain ORDER BY seq DESC LIMIT 1;", []).first?.string(0)
        let h2 = try await db2.query("SELECT entry_hash FROM audit_chain ORDER BY seq DESC LIMIT 1;", []).first?.string(0)
        #expect(h1 == h2, "chain head must be independent of input order")
    }
}
