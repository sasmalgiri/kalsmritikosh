//
//  SourceReliabilityAssessmentRepositoryTests.swift
//  KalsmritikoshTests
//
//  OPS-006 — SourceReliabilityAssessmentRepository CRUD. Locks:
//    1. assess() creates and stores a new assessment.
//    2. A second assess() supersedes the prior row and links it forward.
//    3. effective() returns the latest non-superseded assessment.
//    4. history() returns all assessments oldest-first.
//    5. deleteAssessments() removes all rows; source_versions row survives.
//    6. assessments(forSourceVersionIDs:) returns effective assessment per version.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("OPS-006 — SourceReliabilityAssessmentRepository")
struct SourceReliabilityAssessmentRepositoryTests {

    private let t0 = Date(timeIntervalSince1970: 1_752_000_000)
    private let t1 = Date(timeIntervalSince1970: 1_752_001_000)

    // MARK: - Shared test rig

    private struct Rig {
        let db: Database
        let repo: SourceReliabilityAssessmentRepository
        let svID: UUID
    }

    private func rig() async throws -> Rig {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db)
        let svID = UUID()
        try await db.exec("""
        INSERT INTO source_versions
            (id, logical_source_id, content_hash, valid_from, created_at)
        VALUES (?, ?, ?, ?, ?);
        """, [.uuid(svID), .uuid(UUID()), .text("hash-test"),
              .real(1_752_000_000), .real(1_752_000_000)])
        return Rig(db: db, repo: SourceReliabilityAssessmentRepository(database: db), svID: svID)
    }

    // MARK: - Case 1: assess creates a new assessment

    @Test("assess() creates and stores a new assessment")
    func assessCreatesNewAssessment() async throws {
        let rig = try await rig()
        let a = try await rig.repo.assess(
            sourceVersionID: rig.svID,
            reliability: .high,
            independence: .independent,
            rationale: "Primary source, no conflict.",
            assessedBy: "user-1",
            at: t0
        )
        #expect(a.sourceVersionID == rig.svID)
        #expect(a.reliability == .high)
        #expect(a.independence == .independent)
        #expect(a.rationale == "Primary source, no conflict.")
        #expect(a.assessedBy == "user-1")
        #expect(a.supersededByID == nil)

        let count = try await rig.repo.count(forSourceVersion: rig.svID)
        #expect(count == 1)
    }

    // MARK: - Case 2: second assess supersedes the prior row

    @Test("A second assess() supersedes the prior row and links it forward via superseded_by_id")
    func assessSupersedingCreatesNewAndLinksOld() async throws {
        let rig = try await rig()
        let first = try await rig.repo.assess(
            sourceVersionID: rig.svID, reliability: .high, independence: .independent, at: t0)
        let second = try await rig.repo.assess(
            sourceVersionID: rig.svID, reliability: .medium, independence: .affiliated, at: t1)

        #expect(second.reliability == .medium)
        #expect(second.independence == .affiliated)
        #expect(second.supersededByID == nil, "The new assessment must not be superseded")

        // The first assessment's superseded_by_id must now point to the second.
        let all = try await rig.repo.history(forSourceVersion: rig.svID)
        #expect(all.count == 2)
        let oldRow = all.first { $0.id == first.id }
        #expect(oldRow?.supersededByID == second.id,
                "Prior assessment must be linked to the new one via superseded_by_id")
    }

    // MARK: - Case 3: effective returns the latest non-superseded

    @Test("effective() returns the latest non-superseded assessment")
    func effectiveReturnsLatestNonSuperseded() async throws {
        let rig = try await rig()
        _ = try await rig.repo.assess(
            sourceVersionID: rig.svID, reliability: .low, independence: .unknown, at: t0)
        let second = try await rig.repo.assess(
            sourceVersionID: rig.svID, reliability: .high, independence: .independent, at: t1)

        let eff = try await rig.repo.effective(forSourceVersion: rig.svID)
        #expect(eff?.id == second.id, "effective() must return the newest non-superseded row")
        #expect(eff?.reliability == .high)
    }

    // MARK: - Case 4: history returns all in oldest-first order

    @Test("history() returns all assessments in created_at ascending order")
    func historyReturnsAllInOrder() async throws {
        let rig = try await rig()
        let first  = try await rig.repo.assess(
            sourceVersionID: rig.svID, reliability: .unknown, independence: .unknown, at: t0)
        let second = try await rig.repo.assess(
            sourceVersionID: rig.svID, reliability: .medium, independence: .affiliated, at: t1)

        let all = try await rig.repo.history(forSourceVersion: rig.svID)
        #expect(all.count == 2)
        #expect(all[0].id == first.id,  "Oldest assessment must be first in history")
        #expect(all[1].id == second.id, "Newest assessment must be last in history")
    }

    // MARK: - Case 5: deleteAssessments removes all rows but leaves source_version

    @Test("deleteAssessments() removes all rows for the source version; source_versions row survives")
    func deleteForSourceVersionRemovesAll() async throws {
        let rig = try await rig()
        _ = try await rig.repo.assess(
            sourceVersionID: rig.svID, reliability: .high, independence: .independent, at: t0)
        _ = try await rig.repo.assess(
            sourceVersionID: rig.svID, reliability: .medium, independence: .affiliated, at: t1)
        #expect(try await rig.repo.count(forSourceVersion: rig.svID) == 2)

        try await rig.repo.deleteAssessments(forSourceVersion: rig.svID)

        #expect(try await rig.repo.count(forSourceVersion: rig.svID) == 0,
                "All assessments must be removed")
        // source_versions row must survive — deleteAssessments must not touch it.
        let svCount = try await rig.db.query(
            "SELECT COUNT(*) FROM source_versions WHERE id = ?;", [.uuid(rig.svID)])
        #expect(Int(svCount.first?.int(0) ?? 0) == 1,
                "source_versions row must not be deleted by deleteAssessments()")
    }

    // MARK: - Case 6: batch lookup returns effective per source version

    @Test("assessments(forSourceVersionIDs:) returns the effective assessment for each version")
    func batchLookupReturnsEffectivePerVersion() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db)
        let repo = SourceReliabilityAssessmentRepository(database: db)

        // Two separate source versions.
        let sv1 = UUID(), sv2 = UUID()
        for sv in [sv1, sv2] {
            try await db.exec("""
            INSERT INTO source_versions
                (id, logical_source_id, content_hash, valid_from, created_at)
            VALUES (?, ?, ?, ?, ?);
            """, [.uuid(sv), .uuid(UUID()), .text("hash-\(sv)"),
                  .real(1_752_000_000), .real(1_752_000_000)])
        }

        _ = try await repo.assess(
            sourceVersionID: sv1, reliability: .high, independence: .independent, at: t0)
        _ = try await repo.assess(
            sourceVersionID: sv2, reliability: .low, independence: .potentialConflict, at: t0)

        let batch = try await repo.assessments(forSourceVersionIDs: [sv1, sv2])
        #expect(batch.count == 2)
        #expect(batch[sv1]?.reliability == .high)
        #expect(batch[sv2]?.reliability == .low)
        #expect(batch[sv2]?.independence == .potentialConflict)

        // A version with no assessment is absent from the result.
        let sv3 = UUID()
        let partial = try await repo.assessments(forSourceVersionIDs: [sv1, sv3])
        #expect(partial.count == 1)
        #expect(partial[sv3] == nil, "Version with no assessment must be absent from batch result")
    }
}
