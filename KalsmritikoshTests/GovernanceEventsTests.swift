//
//  GovernanceEventsTests.swift
//  KalsmritikoshTests
//
//  Fifth audit — the v111 governance ledger (approval / withdrawal /
//  assessment / export acts) and its sealing as a THIRD audit-chain source.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("GOVERNANCE — v111 ledger sealed into the audit chain")
struct GovernanceEventsTests {

    private let t1 = Date(timeIntervalSince1970: 1_756_000_000)
    private let t2 = Date(timeIntervalSince1970: 1_756_000_100)

    private func makeRig() async throws -> (GovernanceEventsRepository, Database) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("govev-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        return (GovernanceEventsRepository(database: db), db)
    }

    @Test("Governance acts record append-only and surface as deterministic chain events")
    func recordAndSurface() async throws {
        let (repo, _) = try await makeRig()
        let caseID = UUID()
        _ = try await repo.record(kind: .findingsApproved, caseID: caseID, actor: "me",
                                  detail: "standard=Probable cause", at: t1)
        _ = try await repo.record(kind: .assessmentRecorded, caseID: caseID, actor: "system",
                                  detail: "revision=1;status=conformant", at: t1)
        _ = try await repo.record(kind: .bundleExported, caseID: caseID, actor: "me",
                                  detail: "revision=1", at: t2)
        let events = try await repo.auditChainEvents()
        #expect(events.count == 3)
        #expect(events.allSatisfy { $0.source == .governance })
        #expect(events.map(\.occurredAt) == events.map(\.occurredAt).sorted())
        // The canonical payload is stable and carries the act's facts.
        #expect(events.contains { $0.canonicalPayload.contains("kind=findings.approved") })
        #expect(events.contains { $0.canonicalPayload.contains("detail=revision=1;status=conformant") })
        // Re-reading produces byte-identical payloads (deterministic re-hash).
        let again = try await repo.auditChainEvents()
        #expect(again.map(\.canonicalPayload) == events.map(\.canonicalPayload))
    }

    @Test("The chain seals governance events and detects tampering with a sealed act")
    func chainCoversGovernance() async throws {
        let (repo, db) = try await makeRig()
        let caseID = UUID()
        _ = try await repo.record(kind: .findingsApproved, caseID: caseID, actor: "me",
                                  detail: "standard=Probable cause", at: t1)
        _ = try await repo.record(kind: .bundleExported, caseID: caseID, actor: "me",
                                  detail: "revision=1", at: t2)
        let chain = AuditChainService(database: db, secret: Data("test-secret".utf8),
                                      eventProvider: { (try? await repo.auditChainEvents()) ?? [] })
        #expect(try await chain.seal(now: t2) == 2)
        let intact = try await chain.verify()
        #expect(intact.isIntact)
        #expect(intact.sealedCount == 2)
        // Rewriting a sealed governance act breaks the chain (tamper-evident).
        try await db.exec("UPDATE governance_events SET detail = 'revision=999' WHERE kind = 'bundle.exported';", [])
        let broken = try await chain.verify()
        #expect(!broken.isIntact)
    }
}
