//
//  InvestigationIdentityResolutionServiceTests.swift
//  KalsmritikoshTests
//
//  INV-03 — case-scoped identity resolution over the SHARED reversible entity merge. Proves the two
//  invariants: NO AUTO-MERGE (proposing mutates nothing; confirming is the only merge site and requires an
//  open proposal) and MERGE REVERSIBLE + DECISION RECORDED (a confirmed merge can be reversed via the shared
//  unmerge, and every proposal/confirm/reject/reverse is an append-only decision row). Also: both entities
//  must be in the case scope + same kind + distinct; the decision log reopens. Uses the REAL shared
//  EntitiesRepository merge/unmerge. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("INV-03 — identity resolution (no auto-merge, reversible, recorded)")
struct InvestigationIdentityResolutionServiceTests {

    private let t0 = Date(timeIntervalSince1970: 1_767_100_000)

    private struct Rig {
        let db: Database
        let cases: InvestigationCaseRepository
        let entities: EntitiesRepository
        let service: InvestigationIdentityResolutionService
        let caseID: UUID
        let vA: UUID
    }

    /// A workspace + a case authorizing source version vA. Two same-kind person entities (winner + loser)
    /// each have an in-scope mention on vA; a third "outsider" entity's mention is on an UNauthorized version.
    private func rig(winner: UUID, loser: UUID, outsider: UUID? = nil) async throws -> Rig {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(ws), .text("Matter"), .real(1), .real(1)])
        let (vA, logicalA) = try await seedSourceVersion(db)
        let koA = try await seedKO(db, logical: logicalA)
        try await seedEntity(db, id: winner, kind: "person", value: "Jonathan Smith", ko: koA)
        try await seedMention(db, entity: winner, kind: "person", surface: "Jonathan Smith", ko: koA)
        try await seedEntity(db, id: loser, kind: "person", value: "Jon Smith", ko: koA)
        try await seedMention(db, entity: loser, kind: "person", surface: "Jon Smith", ko: koA)
        if let outsider {
            let (_, logicalB) = try await seedSourceVersion(db)      // a REAL but UNauthorized source
            let koB = try await seedKO(db, logical: logicalB)
            try await seedEntity(db, id: outsider, kind: "person", value: "J. Smith", ko: koB)
            try await seedMention(db, entity: outsider, kind: "person", surface: "J. Smith", ko: koB)
        }
        let cases = InvestigationCaseRepository(database: db)
        let evidence = EvidenceStore(database: db)
        let entities = EntitiesRepository(database: db)
        var c = try await cases.createCase(workspaceID: ws, title: "Identity ambiguity", actor: "analyst", at: t0)
        c = try await cases.includeSource(caseID: c.id, expectedRevision: c.revision,
                                          sourceRef: vA.uuidString, sourceKind: .sourceVersion, actor: "analyst", at: t0)
        let service = InvestigationIdentityResolutionService(
            cases: cases, resolver: CaseRetrievalScopeResolver(evidence: evidence),
            scopedEntities: CaseScopedEntityResolver(entities: entities, evidence: evidence),
            entities: entities, decisions: InvestigationIdentityDecisionRepository(database: db))
        return Rig(db: db, cases: cases, entities: entities, service: service, caseID: c.id, vA: vA)
    }

    private func mergedInto(_ db: Database, _ entity: UUID) async throws -> UUID? {
        try await db.query("SELECT merged_into FROM entities WHERE id = ? LIMIT 1;", [.uuid(entity)]).first?.uuid(0)
    }

    // MARK: - No auto-merge

    @Test("Proposing a merge records intent and mutates NOTHING")
    func proposeIsRecordOnly() async throws {
        let winner = UUID(), loser = UUID()
        let rig = try await rig(winner: winner, loser: loser)
        let d = try await rig.service.proposeMerge(caseID: rig.caseID, winnerEntityID: winner, loserEntityID: loser,
                                                   rationale: "same person", actor: "analyst", at: t0)
        #expect(d.kind == .mergeProposed)
        #expect(try await mergedInto(rig.db, loser) == nil)   // canonical entities untouched
    }

    @Test("Confirming without a proposal is refused and merges nothing (no auto-merge)")
    func confirmWithoutProposalRefused() async throws {
        let winner = UUID(), loser = UUID()
        let rig = try await rig(winner: winner, loser: loser)
        await #expect(throws: IdentityResolutionError.self) {
            _ = try await rig.service.confirmMerge(caseID: rig.caseID, winnerEntityID: winner, loserEntityID: loser, actor: "lead", at: t0)
        }
        #expect(try await mergedInto(rig.db, loser) == nil)
        #expect(try await rig.service.decisionLog(caseID: rig.caseID).isEmpty)
    }

    // MARK: - Confirm performs the shared merge + records

    @Test("Confirming a proposed merge performs the SHARED merge and records mergeConfirmed linked to the proposal")
    func confirmMergesAndRecords() async throws {
        let winner = UUID(), loser = UUID()
        let rig = try await rig(winner: winner, loser: loser)
        let proposal = try await rig.service.proposeMerge(caseID: rig.caseID, winnerEntityID: winner, loserEntityID: loser, rationale: nil, actor: "analyst", at: t0)
        let confirmed = try await rig.service.confirmMerge(caseID: rig.caseID, winnerEntityID: winner, loserEntityID: loser, actor: "lead", at: t0)
        #expect(confirmed.kind == .mergeConfirmed)
        #expect(confirmed.priorDecisionID == proposal.id)
        #expect(try await mergedInto(rig.db, loser) == winner)                 // loser now resolves to winner
        #expect(try await rig.entities.resolveCanonical(loser) == winner)      // via the shared engine
    }

    // MARK: - Reversible + recorded

    @Test("A confirmed merge is REVERSIBLE via the shared unmerge and the reversal is recorded")
    func reverseRestoresAndRecords() async throws {
        let winner = UUID(), loser = UUID()
        let rig = try await rig(winner: winner, loser: loser)
        _ = try await rig.service.proposeMerge(caseID: rig.caseID, winnerEntityID: winner, loserEntityID: loser, rationale: nil, actor: "analyst", at: t0)
        let confirmed = try await rig.service.confirmMerge(caseID: rig.caseID, winnerEntityID: winner, loserEntityID: loser, actor: "lead", at: t0)
        let reversed = try await rig.service.reverseMerge(caseID: rig.caseID, winnerEntityID: winner, loserEntityID: loser, rationale: "was wrong", actor: "lead", at: t0)
        #expect(reversed.kind == .mergeReversed)
        #expect(reversed.priorDecisionID == confirmed.id)
        #expect(try await mergedInto(rig.db, loser) == nil)                    // loser is its own canonical again
        // History is intact: proposal → confirm → reverse, all recorded (a reversal never erases a confirmation).
        let log = try await rig.service.decisionLog(caseID: rig.caseID).map(\.kind)
        #expect(log == [.mergeProposed, .mergeConfirmed, .mergeReversed])
    }

    @Test("Reversing a merge that was never confirmed is refused")
    func reverseWithoutConfirmRefused() async throws {
        let winner = UUID(), loser = UUID()
        let rig = try await rig(winner: winner, loser: loser)
        _ = try await rig.service.proposeMerge(caseID: rig.caseID, winnerEntityID: winner, loserEntityID: loser, rationale: nil, actor: "a", at: t0)
        await #expect(throws: IdentityResolutionError.self) {
            _ = try await rig.service.reverseMerge(caseID: rig.caseID, winnerEntityID: winner, loserEntityID: loser, rationale: nil, actor: "a", at: t0)
        }
    }

    @Test("Rejecting a proposal records a refusal and merges nothing")
    func rejectRecordsNoMerge() async throws {
        let winner = UUID(), loser = UUID()
        let rig = try await rig(winner: winner, loser: loser)
        _ = try await rig.service.proposeMerge(caseID: rig.caseID, winnerEntityID: winner, loserEntityID: loser, rationale: nil, actor: "a", at: t0)
        let rejected = try await rig.service.rejectMerge(caseID: rig.caseID, winnerEntityID: winner, loserEntityID: loser, rationale: "different people", actor: "lead", at: t0)
        #expect(rejected.kind == .mergeRejected)
        #expect(try await mergedInto(rig.db, loser) == nil)
    }

    // MARK: - Scope + kind boundaries

    @Test("An entity outside the case scope cannot be proposed for merge")
    func outOfScopeRejected() async throws {
        let winner = UUID(), loser = UUID(), outsider = UUID()
        let rig = try await rig(winner: winner, loser: loser, outsider: outsider)
        await #expect(throws: IdentityResolutionError.self) {
            _ = try await rig.service.proposeMerge(caseID: rig.caseID, winnerEntityID: winner, loserEntityID: outsider, rationale: nil, actor: "a", at: t0)
        }
    }

    @Test("Self-merge and re-proposing an already-open pair are refused")
    func sameEntityAndDoublePropose() async throws {
        let winner = UUID(), loser = UUID()
        let rig = try await rig(winner: winner, loser: loser)
        await #expect(throws: IdentityResolutionError.self) {
            _ = try await rig.service.proposeMerge(caseID: rig.caseID, winnerEntityID: winner, loserEntityID: winner, rationale: nil, actor: "a", at: t0)
        }
        _ = try await rig.service.proposeMerge(caseID: rig.caseID, winnerEntityID: winner, loserEntityID: loser, rationale: nil, actor: "a", at: t0)
        await #expect(throws: IdentityResolutionError.self) {
            _ = try await rig.service.proposeMerge(caseID: rig.caseID, winnerEntityID: winner, loserEntityID: loser, rationale: nil, actor: "a", at: t0)
        }
    }

    @Test("The decision log persists and reopens through a fresh repository")
    func decisionLogReopens() async throws {
        let winner = UUID(), loser = UUID()
        let rig = try await rig(winner: winner, loser: loser)
        _ = try await rig.service.proposeMerge(caseID: rig.caseID, winnerEntityID: winner, loserEntityID: loser, rationale: nil, actor: "a", at: t0)
        _ = try await rig.service.confirmMerge(caseID: rig.caseID, winnerEntityID: winner, loserEntityID: loser, actor: "lead", at: t0)
        let reopened = InvestigationIdentityDecisionRepository(database: rig.db)
        #expect(try await reopened.decisions(caseID: rig.caseID).count == 2)
    }

    // MARK: - Seed helpers

    private func seedSourceVersion(_ db: Database) async throws -> (version: UUID, logical: UUID) {
        let version = UUID(), logical = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                          [.uuid(logical), .text("file:///x/\(logical.uuidString)"), .text("txt"), .text("available")])
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(version), .uuid(logical), .text(String(repeating: "a", count: 64)), .real(100), .integer(1), .real(100),
                  .text("f.txt"), .text("txt"), .text("magicBytes"), .integer(1), .text("referenced"), .text("referenceRecorded"), .real(100)])
        return (version, logical)
    }
    private func seedKO(_ db: Database, logical: UUID) async throws -> UUID {
        let ko = UUID()
        try await db.exec("INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);",
                          [.uuid(ko), .uuid(logical), .text("txt"), .text("body"), .real(1), .real(1)])
        return ko
    }
    private func seedEntity(_ db: Database, id: UUID, kind: String, value: String, ko: UUID) async throws {
        try await db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);",
                          [.uuid(id), .text(kind), .text(value), .text(value.lowercased()), .uuid(ko)])
    }
    private func seedMention(_ db: Database, entity: UUID, kind: String, surface: String, ko: UUID) async throws {
        try await db.exec("INSERT INTO entity_mentions (id, entity_id, kind, surface, normalized, source_object_id) VALUES (?,?,?,?,?,?);",
                          [.uuid(UUID()), .uuid(entity), .text(kind), .text(surface), .text(surface.lowercased()), .uuid(ko)])
    }
}
