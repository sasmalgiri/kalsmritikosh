//
//  EmailParticipantRepositoryTests.swift
//  KalsmritikoshTests
//
//  OPS-005 — EmailParticipantRepository CRUD. Locks:
//    1. insertBatch persists a single occurrence and returns 1.
//    2. insertBatch is idempotent (INSERT OR IGNORE — second call returns 0).
//    3. occurrences(forSourceObject:) returns all rows for a KO in order.
//    4. occurrences(forEntity:role:) filters correctly.
//    5. deleteForSourceObject removes only the target KO's rows.
//    6. SQL CASCADE removes occurrences when a KO is hard-deleted.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("OPS-005 — EmailParticipantRepository")
struct EmailParticipantRepositoryTests {

    private let t0 = Date(timeIntervalSince1970: 1_750_600_000)

    // MARK: - Shared test rig

    private struct Rig {
        let db: Database
        let repo: EmailParticipantRepository
        let koID: UUID
        let entityID: UUID
    }

    private func rig() async throws -> Rig {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db)
        let fileID = UUID()
        try await db.exec(
            "INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
            [.uuid(fileID), .text("file://\(fileID)"), .text("eml")])
        let koID = UUID()
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?,?,?,?,?,?);
        """, [.uuid(koID), .uuid(fileID), .text("eml"), .text("test body"),
              .real(1_000_000), .real(1_000_000)])
        return Rig(db: db, repo: EmailParticipantRepository(database: db),
                   koID: koID, entityID: UUID())
    }

    private func occurrence(
        koID: UUID, entityID: UUID,
        role: EmailParticipantRole = .from,
        address: String = "sender@example.com",
        displayName: String? = nil
    ) -> EmailParticipantOccurrence {
        EmailParticipantOccurrence(
            sourceObjectID: koID,
            entityID:       entityID,
            role:           role,
            rawAddress:     address,
            displayName:    displayName,
            createdAt:      t0
        )
    }

    // MARK: - Case 1: insertBatch single

    @Test("insertBatch persists a single occurrence and returns 1")
    func insertBatchSingleOccurrence() async throws {
        let rig = try await rig()
        let occ = occurrence(koID: rig.koID, entityID: rig.entityID)
        let n = try await rig.repo.insertBatch([occ])
        #expect(n == 1)
        let rows = try await rig.repo.occurrences(forSourceObject: rig.koID)
        #expect(rows.count == 1)
        #expect(rows[0].role == .from)
        #expect(rows[0].rawAddress == "sender@example.com")
    }

    // MARK: - Case 2: idempotent re-insert

    @Test("insertBatch is idempotent: re-inserting the same row returns 0")
    func insertBatchIdempotent() async throws {
        let rig = try await rig()
        let occ = occurrence(koID: rig.koID, entityID: rig.entityID)
        _ = try await rig.repo.insertBatch([occ])
        let n2 = try await rig.repo.insertBatch([occ])
        #expect(n2 == 0, "Expected INSERT OR IGNORE to skip duplicate row")
        let count = try await rig.repo.occurrenceCount(forSourceObject: rig.koID)
        #expect(count == 1, "Row count must remain 1 after duplicate insert")
    }

    // MARK: - Case 3: occurrences(forSourceObject:)

    @Test("occurrences(forSourceObject:) returns all rows for the KO in insertion order")
    func occurrencesForSourceObject() async throws {
        let rig = try await rig()
        let e2 = UUID()
        let batch = [
            occurrence(koID: rig.koID, entityID: rig.entityID, role: .from,   address: "a@example.com"),
            occurrence(koID: rig.koID, entityID: e2,           role: .to,     address: "b@example.com"),
            occurrence(koID: rig.koID, entityID: UUID(),       role: .cc,     address: "c@example.com"),
        ]
        _ = try await rig.repo.insertBatch(batch)
        let rows = try await rig.repo.occurrences(forSourceObject: rig.koID)
        #expect(rows.count == 3)
        #expect(rows.map(\.rawAddress) == ["a@example.com", "b@example.com", "c@example.com"])
    }

    // MARK: - Case 4: occurrences(forEntity:role:)

    @Test("occurrences(forEntity:role:) filters to the requested entity+role pair")
    func occurrencesForEntityRole() async throws {
        let rig = try await rig()
        let e2 = UUID()
        let batch = [
            occurrence(koID: rig.koID, entityID: rig.entityID, role: .from, address: "from@example.com"),
            occurrence(koID: rig.koID, entityID: rig.entityID, role: .cc,   address: "from@example.com"),
            occurrence(koID: rig.koID, entityID: e2,           role: .from, address: "other@example.com"),
        ]
        _ = try await rig.repo.insertBatch(batch)
        let fromOnly = try await rig.repo.occurrences(forEntity: rig.entityID, role: .from)
        #expect(fromOnly.count == 1)
        #expect(fromOnly[0].rawAddress == "from@example.com")
        let allForEntity = try await rig.repo.occurrences(forEntity: rig.entityID)
        #expect(allForEntity.count == 2)
    }

    // MARK: - Case 5: deleteForSourceObject

    @Test("deleteForSourceObject removes only the target KO's rows, leaving others intact")
    func deleteForSourceObject() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db)
        // Two separate KOs.
        let f1 = UUID(), f2 = UUID()
        for fid in [f1, f2] {
            try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                              [.uuid(fid), .text("file://\(fid)"), .text("eml")])
        }
        let ko1 = UUID(), ko2 = UUID()
        for (kid, fid) in [(ko1, f1), (ko2, f2)] {
            try await db.exec("""
            INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
            VALUES (?,?,?,?,?,?);
            """, [.uuid(kid), .uuid(fid), .text("eml"), .text("c"), .real(0), .real(0)])
        }
        let repo = EmailParticipantRepository(database: db)
        let e = UUID()
        _ = try await repo.insertBatch([
            EmailParticipantOccurrence(sourceObjectID: ko1, entityID: e, role: .from, rawAddress: "a@x.com", displayName: nil, createdAt: t0),
            EmailParticipantOccurrence(sourceObjectID: ko2, entityID: e, role: .to,   rawAddress: "b@x.com", displayName: nil, createdAt: t0),
        ])
        try await repo.deleteForSourceObject(ko1)
        let ko1Count = try await repo.occurrenceCount(forSourceObject: ko1)
        let ko2Count = try await repo.occurrenceCount(forSourceObject: ko2)
        #expect(ko1Count == 0, "ko1 occurrences not deleted")
        #expect(ko2Count == 1, "ko2 occurrences must survive ko1 deletion")
    }

    // MARK: - Case 6: SQL CASCADE via KO delete

    @Test("Hard-deleting a knowledge_objects row removes its occurrences via SQL CASCADE")
    func cascadeDeleteViaKO() async throws {
        let rig = try await rig()
        let occ = occurrence(koID: rig.koID, entityID: rig.entityID)
        _ = try await rig.repo.insertBatch([occ])
        #expect(try await rig.repo.occurrenceCount(forSourceObject: rig.koID) == 1)

        try await rig.db.exec("DELETE FROM knowledge_objects WHERE id = ?;", [.uuid(rig.koID)])

        let count = try await rig.repo.occurrenceCount(forSourceObject: rig.koID)
        #expect(count == 0, "SQL CASCADE must remove occurrence rows when KO is deleted")
    }
}
