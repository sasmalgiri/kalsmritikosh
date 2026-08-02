//
//  ProgressiveAnswerMigrationTests.swift
//  KalsmritikoshTests
//
//  AEE-M2 — schema v89 EXTENDS the existing answer-ledger authority with the per-answer
//  revision chain (answer_revisions) + its append-only lifecycle events
//  (answer_revision_events), and a nullable revision_id on answer_claims + compat columns on
//  answers. Proves reach, v88→v89 legacy preservation WITHOUT fabricated revision history,
//  self-heal, repeat + fault rollback, and every integrity CHECK: SHA-256-shaped content_hash,
//  revision-number uniqueness, correction-needs-prior+reason, same-answer correction FK,
//  the closed 7-state event vocabulary, content-bearing-requires-revision, event sequencing,
//  and cascade. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("AEE-M2 — v89 progressive answer revision ledger migration")
struct ProgressiveAnswerMigrationTests {

    private let hex = String(repeating: "a", count: 64)

    private func seedAnswer(_ db: Database, id: UUID, state: String = "supported") async throws {
        try await db.exec("""
            INSERT INTO answers (id, question, answer_state, body, confidence, created_at)
            VALUES (?,?,?,?,?,?);
            """, [.uuid(id), .text("q?"), .text(state), .text("body"), .real(0.5), .real(100)])
    }

    private func insertRevision(_ db: Database, answer: UUID, number: Int, hash: String, id: UUID = UUID(),
                                correctionOf: UUID? = nil, reason: String? = nil, reasonKind: String? = nil) async throws {
        try await db.exec("""
            INSERT INTO answer_revisions (id, answer_id, revision_number, body, answer_state, confidence,
                content_hash, correction_of_revision_id, correction_reason, correction_reason_kind, created_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(answer), .integer(Int64(number)), .text("rbody"), .text("supported"),
                  .real(0.5), .text(hash), correctionOf.map { SQLValue.uuid($0) } ?? .null,
                  reason.map { SQLValue.text($0) } ?? .null, reasonKind.map { SQLValue.text($0) } ?? .null, .real(100)])
    }

    private func insertEvent(_ db: Database, answer: UUID, seq: Int, revision: UUID?, state: String) async throws {
        try await db.exec("""
            INSERT INTO answer_revision_events (id, answer_id, sequence, revision_id, state, created_at)
            VALUES (?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(answer), .integer(Int64(seq)), revision.map { SQLValue.uuid($0) } ?? .null,
                  .text(state), .real(100)])
    }

    // MARK: - Reach + preservation

    @Test("A fresh database reaches v89 with the revision ledger + compat columns")
    func freshV89() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 89)
        #expect(try await db.currentUserVersion() == 89)
        #expect(try await MigrationFixtureBuilder.columns(db, "answer_revisions").isSuperset(of: ["revision_number", "content_hash", "correction_of_revision_id", "correction_reason"]))
        #expect(try await MigrationFixtureBuilder.columns(db, "answer_revision_events").isSuperset(of: ["sequence", "revision_id", "state"]))
        #expect(try await MigrationFixtureBuilder.columns(db, "answer_claims").contains("revision_id"))
        #expect(try await MigrationFixtureBuilder.columns(db, "answers").isSuperset(of: ["request_id", "mission_lane", "is_terminal", "updated_at"]))
    }

    @Test("v88→v89 preserves legacy answers with NO fabricated revision history")
    func v88ToV89PreservesLegacy() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 88)
        let a = UUID(); try await seedAnswer(db, id: a)
        try await db.exec("""
            INSERT INTO answer_claims (id, answer_id, claim_text, support_status, confidence, ordinal, created_at)
            VALUES (?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(a), .text("legacy claim"), .text("supported"), .real(0.5), .integer(0), .real(100)])
        try await SchemaMigrations.migrate(db, through: 89)
        #expect(try await db.currentUserVersion() == 89)
        // The legacy answer + claim survive; the claim's revision_id is NULL (never guessed).
        #expect(try await db.query("SELECT COUNT(*) FROM answers WHERE id = ?;", [.uuid(a)]).first?.int(0) == 1)
        #expect(try await db.query("SELECT revision_id FROM answer_claims WHERE answer_id = ?;", [.uuid(a)]).first?.isNull(0) == true)
        // NO fabricated revisions/events for the legacy answer.
        #expect(try await db.query("SELECT COUNT(*) FROM answer_revisions;", []).first?.int(0) == 0)
        #expect(try await db.query("SELECT COUNT(*) FROM answer_revision_events;", []).first?.int(0) == 0)
    }

    @Test("The self-heal sentinel recognises the v89 ledger")
    func selfHealRecognizesV89() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.setUserVersion(87)
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
    }

    @Test("Re-running migrate over a v89 database is a safe no-op")
    func v89Repeatable() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 89)
        try await SchemaMigrations.migrate(db, through: 89)
        #expect(try await db.currentUserVersion() == 89)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("An injected failure inside the v89 SAVEPOINT rolls the whole migration back")
    func injectedFailureRollsBack() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 88)
        let a = UUID(); try await seedAnswer(db, id: a)
        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.migrate(db, through: 89, fault: MigrationFaultHarness.hook(throwingAt: .afterSQLBeforeVersionStamp(version: 89)))
        }
        #expect(try await db.currentUserVersion() == 88)
        #expect(try await MigrationFixtureBuilder.columns(db, "answers").contains("request_id") == false)   // old shape intact
        #expect(try await db.query("SELECT COUNT(*) FROM answers WHERE id = ?;", [.uuid(a)]).first?.int(0) == 1)  // legacy answer preserved
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("Milestone migration from version 0 reaches v89 with a clean FK graph")
    func milestoneReachesV89() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 89)
        #expect(try await db.currentUserVersion() == 89)
        #expect(try await db.query("PRAGMA foreign_key_check;", []).isEmpty)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    // MARK: - CHECKs

    @Test("A revision content_hash must be a 64-char lowercase-hex SHA-256")
    func contentHashShape() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 89)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let a = UUID(); try await seedAnswer(db, id: a)
        await #expect(throws: (any Error).self) { try await insertRevision(db, answer: a, number: 1, hash: "short") }
        await #expect(throws: (any Error).self) { try await insertRevision(db, answer: a, number: 1, hash: String(repeating: "A", count: 64)) } // uppercase
        try await insertRevision(db, answer: a, number: 1, hash: hex)   // valid
        #expect(try await db.query("SELECT COUNT(*) FROM answer_revisions WHERE answer_id = ?;", [.uuid(a)]).first?.int(0) == 1)
    }

    @Test("revision_number is >= 1 and unique per answer")
    func revisionNumberUnique() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 89)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let a = UUID(); try await seedAnswer(db, id: a)
        await #expect(throws: (any Error).self) { try await insertRevision(db, answer: a, number: 0, hash: hex) }   // < 1
        try await insertRevision(db, answer: a, number: 1, hash: hex)
        await #expect(throws: (any Error).self) { try await insertRevision(db, answer: a, number: 1, hash: hex) }   // duplicate number
    }

    @Test("A correction requires a prior revision AND a nonblank reason; a non-correction has neither")
    func correctionRequiresPriorAndReason() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 89)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let a = UUID(); try await seedAnswer(db, id: a)
        let r1 = UUID(); try await insertRevision(db, answer: a, number: 1, hash: hex, id: r1)
        // reason present but no prior revision → rejected.
        await #expect(throws: (any Error).self) { try await insertRevision(db, answer: a, number: 2, hash: hex, reason: "because") }
        // prior revision but blank reason → rejected.
        await #expect(throws: (any Error).self) { try await insertRevision(db, answer: a, number: 2, hash: hex, correctionOf: r1, reason: "   ") }
        // valid correction.
        try await insertRevision(db, answer: a, number: 2, hash: hex, correctionOf: r1, reason: "additional evidence", reasonKind: "additionalEvidence")
        #expect(try await db.query("SELECT COUNT(*) FROM answer_revisions WHERE correction_of_revision_id = ?;", [.uuid(r1)]).first?.int(0) == 1)
    }

    @Test("A correction can only reference a prior revision of the SAME answer")
    func correctionSameAnswerOnly() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 89)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let a = UUID(), b = UUID()
        try await seedAnswer(db, id: a); try await seedAnswer(db, id: b)
        let rA = UUID(); try await insertRevision(db, answer: a, number: 1, hash: hex, id: rA)
        // A revision on answer B cannot correct answer A's revision (composite FK).
        await #expect(throws: (any Error).self) {
            try await insertRevision(db, answer: b, number: 1, hash: hex, correctionOf: rA, reason: "cross-answer")
        }
    }

    @Test("A revision's answer_id must reference a real answer")
    func revisionAnswerFK() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 89)
        try await db.exec("PRAGMA foreign_keys = ON;")
        await #expect(throws: (any Error).self) { try await insertRevision(db, answer: UUID(), number: 1, hash: hex) }
    }

    @Test("Events accept only the seven lifecycle states; a content-bearing state needs a revision")
    func eventVocabularyAndRevision() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 89)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let a = UUID(); try await seedAnswer(db, id: a)
        let r1 = UUID(); try await insertRevision(db, answer: a, number: 1, hash: hex, id: r1)
        await #expect(throws: (any Error).self) { try await insertEvent(db, answer: a, seq: 1, revision: r1, state: "finalized") }   // bad state
        // A content-bearing state without a revision is rejected.
        await #expect(throws: (any Error).self) { try await insertEvent(db, answer: a, seq: 1, revision: nil, state: "groundedWorkingResult") }
        // analysisProgress may be revision-less.
        try await insertEvent(db, answer: a, seq: 1, revision: nil, state: "analysisProgress")
        // each content-bearing state with a revision is accepted.
        for (i, s) in ["immediateFinding","groundedWorkingResult","reviewReady","verifiedFinal","corrected","incomplete"].enumerated() {
            try await insertEvent(db, answer: a, seq: 2 + i, revision: r1, state: s)
        }
        #expect(try await db.query("SELECT COUNT(*) FROM answer_revision_events WHERE answer_id = ?;", [.uuid(a)]).first?.int(0) == 7)
    }

    @Test("Events enforce a unique (answer, sequence)")
    func eventSequenceUnique() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 89)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let a = UUID(); try await seedAnswer(db, id: a)
        try await insertEvent(db, answer: a, seq: 1, revision: nil, state: "analysisProgress")
        await #expect(throws: (any Error).self) { try await insertEvent(db, answer: a, seq: 1, revision: nil, state: "analysisProgress") }
    }

    @Test("Deleting an answer cascades its revisions and events")
    func cascadeOnAnswerDelete() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 89)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let a = UUID(); try await seedAnswer(db, id: a)
        let r1 = UUID(); try await insertRevision(db, answer: a, number: 1, hash: hex, id: r1)
        try await insertEvent(db, answer: a, seq: 1, revision: r1, state: "verifiedFinal")
        try await db.exec("DELETE FROM answers WHERE id = ?;", [.uuid(a)])
        #expect(try await db.query("SELECT COUNT(*) FROM answer_revisions WHERE answer_id = ?;", [.uuid(a)]).first?.int(0) == 0)
        #expect(try await db.query("SELECT COUNT(*) FROM answer_revision_events WHERE answer_id = ?;", [.uuid(a)]).first?.int(0) == 0)
    }
}
