//
//  TemporalClaimRepositoryTests.swift
//  KalsmritikoshTests
//
//  Universal History program, Phase 3 (HIST-020/022). The v60 temporal_claims
//  migration applies, claims round-trip WITH PRECISION PRESERVED (a year stays a
//  year — never widened), and subject/predicate queries are deterministic + scoped.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("HIST Phase 3 — TemporalClaim schema + repository")
struct TemporalClaimRepositoryTests {

    private func freshDB() async throws -> Database {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("t.sqlite"))
        try await SchemaMigrations.migrate(db)
        return db
    }

    private func claim(subject: UUID, predicate: String, object: ClaimValue,
                       from: TemporalValue?, created: TimeInterval, status: EvidenceStatus = .sourceAsserted,
                       evidence: [UUID] = []) -> TemporalClaim {
        TemporalClaim(
            subjectID: subject, predicate: predicate, object: object, validFrom: from,
            status: status, confidence: 0.8, sourceObjectIDs: evidence,
            extractorID: "test", extractorVersion: "1", createdAt: Date(timeIntervalSince1970: created))
    }

    @Test("Migration reaches v60 (temporal_claims exists)")
    func migration() async throws {
        let db = try await freshDB()
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
        #expect(SchemaMigrations.latestVersion >= 60)   // v60 introduced temporal_claims
        let t = try await db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='temporal_claims';", [])
        #expect(!t.isEmpty)
    }

    @Test("Claims round-trip with precision + evidence preserved; subject-scoped, deterministic order")
    func roundTripAndScope() async throws {
        let repo = TemporalClaimRepository(database: try await freshDB())
        let subject = UUID(), other = UUID(), evid = UUID()
        let yearFrom = TemporalValue(start: Date(timeIntervalSince1970: 1_100_000_000), precision: .year,
                                     originalText: "2004", confidence: 0.7)
        try await repo.insert(claim(subject: subject, predicate: "worked_for",
                                    object: .literal("Orchid Chemicals"), from: yearFrom,
                                    created: 1_000, evidence: [evid]))
        try await repo.insert(claim(subject: subject, predicate: "held_role",
                                    object: .literal("PPIC Executive"), from: nil, created: 2_000))
        try await repo.insert(claim(subject: other, predicate: "worked_for",
                                    object: .literal("Elsewhere"), from: nil, created: 1_500))

        // Subject-scoped: only this subject's 2 claims, ordered by created_at asc.
        let all = try await repo.claims(subjectID: subject)
        #expect(all.count == 2)
        #expect(all.map(\.predicate) == ["worked_for", "held_role"])   // 1000 before 2000

        // Round-trip fidelity of the first claim.
        let worked = all[0]
        #expect(worked.object == .literal("Orchid Chemicals"))
        #expect(worked.validFrom?.precision == .year)                  // NOT widened to a day
        #expect(worked.validFrom?.originalText == "2004")
        #expect(worked.status == .sourceAsserted)
        #expect(worked.sourceObjectIDs == [evid])

        // Predicate filter.
        #expect(try await repo.claims(subjectID: subject, predicate: "worked_for").count == 1)
        #expect(try await repo.claims(subjectID: subject, predicate: "held_role").count == 1)
        #expect(try await repo.count(subjectID: subject) == 2)
        #expect(try await repo.count(subjectID: other) == 1)
    }

    @Test("The neutral predicate registry normalises free-form predicates")
    func predicateRegistry() {
        #expect(HistoryPredicate.registrySet.contains(HistoryPredicate.workedFor))
        #expect(HistoryPredicate.normalize("Worked For") == "worked_for")
        #expect(HistoryPredicate.normalize("held-role") == "held_role")
    }
}
