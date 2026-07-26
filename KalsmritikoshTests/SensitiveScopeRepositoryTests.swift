//
//  SensitiveScopeRepositoryTests.swift
//  KalsmritikoshTests
//
//  OPS-003A.1/A.2 — protection assignment CRUD, scope-decision matrix, lineage inheritance,
//  authority enforcement (userConfirmed identity + whitespace rejection), legacy KO sync
//  (file→KO propagation), 7th Claim lineage branch (EB→EBO→KO→File), batch key safety,
//  rollback atomicity, review readability, broken-lineage denial, and malformed-row rejection.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("OPS-003A SensitiveScopeRepository")
struct SensitiveScopeRepositoryTests {

    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - Rig

    private func rig() async throws -> (Database, SensitiveScopeRepository) {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db)
        return (db, SensitiveScopeRepository(database: db))
    }

    // MARK: - Seed helpers

    /// Insert a file + knowledge_object pair. Returns (fileID, koID).
    private func seedFileAndKO(_ db: Database) async throws -> (fileID: UUID, koID: UUID) {
        let fileID = UUID(); let koID = UUID()
        try await db.exec(
            "INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
            [.uuid(fileID), .text("file:///\(fileID)"), .text("text")])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?,?,?,?,?,?);
        """, [.uuid(koID), .uuid(fileID), .text("text"), .text("body"), .real(0), .real(0)])
        return (fileID, koID)
    }

    /// Insert a source_version. Returns svID.
    private func seedSourceVersion(_ db: Database) async throws -> UUID {
        let svID = UUID()
        try await db.exec("""
        INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, created_at)
        VALUES (?,?,?,?,?);
        """, [.uuid(svID), .uuid(UUID()), .text("hash-\(svID)"), .real(0), .real(0)])
        return svID
    }

    /// Insert an evidence_block, optionally linked to a source_version.
    private func seedEvidenceBlock(_ db: Database, svID: UUID?) async throws -> UUID {
        let ebID = UUID()
        let svVal: SQLValue = svID.map { .uuid($0) } ?? .null
        try await db.exec("""
        INSERT INTO evidence_blocks
            (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text,
             extraction_method, extraction_confidence)
        VALUES (?,?,?,?,?,?,?,?,?);
        """, [.uuid(ebID), .text("doc-\(ebID)"), svVal,
              .integer(0), .text("text"), .text("raw"), .text("norm"),
              .text("rule"), .real(1.0)])
        return ebID
    }

    /// Insert a chunk for a KO.
    private func seedChunk(_ db: Database, koID: UUID) async throws -> UUID {
        let chunkID = UUID()
        try await db.exec("""
        INSERT INTO chunks (id, object_id, ordinal, text, char_start, char_end, created_at)
        VALUES (?,?,?,?,?,?,?);
        """, [.uuid(chunkID), .uuid(koID), .integer(0), .text("content"),
              .integer(0), .integer(10), .real(0)])
        return chunkID
    }

    /// Insert an entity for a KO. Uses UUID in normalized to avoid UNIQUE(kind,normalized) conflicts.
    private func seedEntity(_ db: Database, koID: UUID) async throws -> UUID {
        let entityID = UUID()
        try await db.exec("""
        INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence)
        VALUES (?,?,?,?,?,?);
        """, [.uuid(entityID), .text("person"),
              .text("Entity \(entityID)"), .text("entity_\(entityID)"),
              .uuid(koID), .real(1.0)])
        return entityID
    }

    /// Insert an event for a KO.
    private func seedEvent(_ db: Database, koID: UUID) async throws -> UUID {
        let eventID = UUID()
        try await db.exec("""
        INSERT INTO events (id, kind, date, title, source_object_id, confidence)
        VALUES (?,?,?,?,?,?);
        """, [.uuid(eventID), .text("milestone"),
              .real(0), .text("Event"), .uuid(koID), .real(1.0)])
        return eventID
    }

    /// Insert a claim with no evidence refs.
    private func seedClaim(_ db: Database) async throws -> UUID {
        let claimID = UUID()
        try await db.exec("""
        INSERT INTO claims
            (id, subject_label, statement, created_at,
             evidence_basis, review_disposition, proposal_origin,
             availability_status, conflict_status)
        VALUES (?,?,?,?,?,?,?,?,?);
        """, [.uuid(claimID), .text("subject"), .text("statement"), .real(0),
              .text("direct"), .text("accepted"), .text("user"),
              .text("available"), .text("none")])
        return claimID
    }

    /// Insert a claim_evidence_ref linking claim to a KO.
    private func seedClaimRef(_ db: Database, claimID: UUID, koID: UUID, ordinal: Int) async throws {
        try await db.exec("""
        INSERT INTO claim_evidence_ref (claim_id, ordinal, knowledge_object_id, evidence_role)
        VALUES (?,?,?,?);
        """, [.uuid(claimID), .integer(Int64(ordinal)), .uuid(koID), .text("supporting")])
    }

    /// Insert an evidence_block_objects link.
    private func seedEBOLink(_ db: Database, ebID: UUID, koID: UUID) async throws {
        try await db.exec("""
        INSERT INTO evidence_block_objects (evidence_block_id, knowledge_object_id, linked_at)
        VALUES (?,?,?);
        """, [.uuid(ebID), .uuid(koID), .real(0)])
    }

    // MARK: - 1: Direct assignment blocks (updated)

    @Test("A direct restricted+privileged assignment blocks all scope surfaces")
    func assignedTargetIsBlocked() async throws {
        let (db, repo) = try await rig()
        let (_, koID) = try await seedFileAndKO(db)

        let a = try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)
        #expect(a.isActive)
        #expect(a.targetID == koID)
        #expect(a.sensitivity == .restricted)
        #expect(a.privileged)

        let resolution = try await repo.effectiveLabel(
            for: SensitiveScopeTarget(kind: .knowledgeObject, id: koID))
        let label = try #require(resolution.label, "Expected resolved label")
        #expect(label.sensitivity == .restricted)
        #expect(label.privileged)

        for purpose in SensitiveUsePurpose.allCases {
            let scope = SensitiveScope(workspaceID: UUID(),
                                       maximumSensitivity: .internalLevel,
                                       permitsPrivilegedMaterial: false,
                                       purpose: purpose)
            #expect(!SensitiveScopeRepository.scopePermits(label, scope: scope),
                    "purpose \(purpose) should block restricted+privileged")
        }
    }

    // MARK: - 2: Revocation unblocks completely (updated)

    @Test("Revoking the only assignment returns the fail-closed default")
    func revocationUnblocksCompletely() async throws {
        let (db, repo) = try await rig()
        let (_, koID) = try await seedFileAndKO(db)

        let a = try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .confidential,
            authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: false),
            reason: nil, at: t0)

        try await repo.revoke(assignmentID: a.id, revokedBy: "u", reason: "cleared",
                              at: t0.addingTimeInterval(1))

        let resolution = try await repo.effectiveLabel(
            for: SensitiveScopeTarget(kind: .knowledgeObject, id: koID))
        let label = try #require(resolution.label)
        #expect(label.sensitivity == .internalLevel)
        #expect(!label.privileged)

        let scope = SensitiveScope(workspaceID: UUID(), maximumSensitivity: .internalLevel,
                                   permitsPrivilegedMaterial: false, purpose: .retrieval)
        #expect(SensitiveScopeRepository.scopePermits(label, scope: scope))

        await #expect(throws: (any Error).self) {
            try await repo.revoke(assignmentID: a.id, revokedBy: "u", reason: nil,
                                  at: t0.addingTimeInterval(2))
        }
    }

    // MARK: - 3: Privilege sticky under high-sensitivity scope (updated)

    @Test("Privilege blocks even when sensitivity is within scope ceiling")
    func privilegeStickyUnderHighSensitivityScope() async throws {
        let (db, repo) = try await rig()
        let (_, koID) = try await seedFileAndKO(db)

        _ = try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .publicLevel,
            authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)

        let resolution = try await repo.effectiveLabel(
            for: SensitiveScopeTarget(kind: .knowledgeObject, id: koID))
        let label = try #require(resolution.label)
        #expect(label.sensitivity == .publicLevel)
        #expect(label.privileged)

        let scope = SensitiveScope(workspaceID: UUID(), maximumSensitivity: .restricted,
                                   permitsPrivilegedMaterial: false, purpose: .prompt)
        #expect(!SensitiveScopeRepository.scopePermits(label, scope: scope))

        let permissiveScope = SensitiveScope(workspaceID: UUID(),
                                             maximumSensitivity: .restricted,
                                             permitsPrivilegedMaterial: true,
                                             purpose: .prompt)
        #expect(SensitiveScopeRepository.scopePermits(label, scope: permissiveScope))
    }

    // MARK: - 4: Batch resolution (updated — SensitiveScopeTarget key + both KOs seeded)

    @Test("Batch resolution returns the correct label for each target")
    func batchResolutionReturnsBothLabels() async throws {
        let (db, repo) = try await rig()
        let (_, restrictedID) = try await seedFileAndKO(db)
        let (_, unassignedID) = try await seedFileAndKO(db)

        _ = try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: restrictedID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: false),
            reason: nil, at: t0)

        let batch = try await repo.batchResolution([
            SensitiveScopeTarget(kind: .knowledgeObject, id: restrictedID),
            SensitiveScopeTarget(kind: .knowledgeObject, id: unassignedID)
        ])

        let restrictedKey = SensitiveScopeTarget(kind: .knowledgeObject, id: restrictedID)
        let unassignedKey = SensitiveScopeTarget(kind: .knowledgeObject, id: unassignedID)
        #expect(batch[restrictedKey]?.label?.sensitivity == .restricted)
        #expect(batch[unassignedKey]?.label?.sensitivity == .internalLevel,
                "Seeded but unassigned KO must resolve to fail-closed internal, not public")
        #expect(batch[unassignedKey]?.isBroken == false)
    }

    // MARK: - 5: Unknown target returns brokenLineage (updated — was internalLevel)

    @Test("A non-existent target returns brokenLineage, never a permission grant")
    func unknownTargetReturnsBrokenLineage() async throws {
        let (_, repo) = try await rig()
        let resolution = try await repo.effectiveLabel(
            for: SensitiveScopeTarget(kind: .claim, id: UUID()))
        #expect(resolution.isBroken)
        #expect(resolution.label == nil)
    }

    // MARK: - 6: Multiple active assignments inherit highest (updated)

    @Test("Two active assignments on the same target inherit the higher sensitivity")
    func multipleActiveAssignmentsInheritHighest() async throws {
        let (db, repo) = try await rig()
        let (_, koID) = try await seedFileAndKO(db)

        _ = try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .confidential,
            authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: false),
            reason: nil, at: t0)
        _ = try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: false),
            reason: nil, at: t0.addingTimeInterval(1))

        let resolution = try await repo.effectiveLabel(
            for: SensitiveScopeTarget(kind: .knowledgeObject, id: koID))
        let label = try #require(resolution.label)
        #expect(label.sensitivity == .restricted, "inherit() should return the max sensitivity")
    }

    // MARK: - 7: Revoke one, other remains active (updated)

    @Test("Revoking one assignment leaves the other active on the same target")
    func revokeOneAssignmentLeavesOtherActive() async throws {
        let (db, repo) = try await rig()
        let (_, koID) = try await seedFileAndKO(db)
        let target = SensitiveScopeTarget(kind: .knowledgeObject, id: koID)

        let a1 = try await repo.assign(target: target, sensitivity: .confidential,
                                        authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: false),
                                        reason: nil, at: t0)
        _ = try await repo.assign(target: target, sensitivity: .restricted,
                                   authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: false),
                                   reason: nil, at: t0.addingTimeInterval(1))

        try await repo.revoke(assignmentID: a1.id, revokedBy: "u", reason: nil,
                              at: t0.addingTimeInterval(2))

        let resolution = try await repo.effectiveLabel(for: target)
        let label = try #require(resolution.label)
        #expect(label.sensitivity == .restricted)

        let all = try await repo.assignments(for: target)
        #expect(all.count == 2)
        #expect(all.filter(\.isActive).count == 1)
        #expect(all.filter { !$0.isActive }.count == 1)
    }

    // MARK: - 8: Existing target with no assignment → internalLevel (NEW)

    @Test("A seeded target with no assignment resolves to fail-closed internal, not brokenLineage")
    func existingTargetWithNoAssignmentIsInternalDefault() async throws {
        let (db, repo) = try await rig()
        let (_, koID) = try await seedFileAndKO(db)
        let resolution = try await repo.effectiveLabel(
            for: SensitiveScopeTarget(kind: .knowledgeObject, id: koID))
        #expect(!resolution.isBroken)
        let label = try #require(resolution.label)
        #expect(label.sensitivity == .internalLevel)
        #expect(!label.privileged)
        #expect(label.sensitivity != .publicLevel)
    }

    // MARK: - 9: Automated authority cannot produce a privileged assignment (NEW)

    @Test("systemRule and migration authorities are structurally non-privileged")
    func automatedPrivilegeBlocked() async throws {
        let (db, repo) = try await rig()
        let (_, koID) = try await seedFileAndKO(db)
        let target = SensitiveScopeTarget(kind: .knowledgeObject, id: koID)

        let sysRule = try await repo.assign(target: target, sensitivity: .restricted,
                                             authority: .systemRule(tag: "detector-001"),
                                             reason: nil, at: t0)
        #expect(!sysRule.privileged, "systemRule must never produce a privileged assignment")
        #expect(sysRule.origin == "system_rule:detector-001")

        let migRule = try await repo.assign(target: target, sensitivity: .confidential,
                                             authority: .migration(tag: "v71-backfill"),
                                             reason: nil, at: t0.addingTimeInterval(1))
        #expect(!migRule.privileged, "migration must never produce a privileged assignment")
        #expect(migRule.origin == "migration:v71-backfill")

        // Only userConfirmed can produce a privileged assignment.
        let userPriv = try await repo.assign(target: target, sensitivity: .restricted,
                                              authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: true),
                                              reason: nil, at: t0.addingTimeInterval(2))
        #expect(userPriv.privileged)
    }

    // MARK: - 10: Non-blank actor required (NEW)

    @Test("Assignment and revocation with blank actor strings throw nonblankActorRequired")
    func nonblankActorRequired() async throws {
        let (db, repo) = try await rig()
        let (_, koID) = try await seedFileAndKO(db)
        let target = SensitiveScopeTarget(kind: .knowledgeObject, id: koID)

        // Empty tag in migration authority → nonblankActorRequired
        await #expect(throws: (any Error).self) {
            _ = try await repo.assign(target: target, sensitivity: .restricted,
                                       authority: .migration(tag: ""),
                                       reason: nil, at: t0)
        }
        // Empty tag in systemRule authority → nonblankActorRequired
        await #expect(throws: (any Error).self) {
            _ = try await repo.assign(target: target, sensitivity: .restricted,
                                       authority: .systemRule(tag: ""),
                                       reason: nil, at: t0)
        }

        // Create a valid assignment so we can test revoke's blank-actor check.
        let a = try await repo.assign(target: target, sensitivity: .restricted,
                                       authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: false),
                                       reason: nil, at: t0)
        await #expect(throws: (any Error).self) {
            try await repo.revoke(assignmentID: a.id, revokedBy: "", reason: nil,
                                  at: t0.addingTimeInterval(1))
        }
    }

    // MARK: - 11: Unknown target throws targetNotFound inside assign (NEW)

    @Test("Assigning a target whose UUID is not in any canonical table throws targetNotFound")
    func assignUnknownTargetThrows() async throws {
        let (_, repo) = try await rig()
        let ghost = SensitiveScopeTarget(kind: .knowledgeObject, id: UUID())
        await #expect(throws: (any Error).self) {
            _ = try await repo.assign(target: ghost, sensitivity: .restricted,
                                       authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: false),
                                       reason: nil, at: t0)
        }
    }

    // MARK: - 12: Lineage — file → knowledgeObject (NEW)

    @Test("A file assignment is inherited by its child knowledge objects")
    func lineage_fileToKnowledgeObject() async throws {
        let (db, repo) = try await rig()
        let (fileID, koID) = try await seedFileAndKO(db)

        // Assign to file only — no direct KO assignment.
        _ = try await repo.assign(
            target: SensitiveScopeTarget(kind: .file, id: fileID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: false),
            reason: nil, at: t0)

        let resolution = try await repo.effectiveLabel(
            for: SensitiveScopeTarget(kind: .knowledgeObject, id: koID))
        let label = try #require(resolution.label)
        #expect(label.sensitivity == .restricted,
                "KO must inherit restricted from its parent file")
    }

    // MARK: - 13: Lineage — sourceVersion → evidenceBlock (NEW)

    @Test("A sourceVersion assignment is inherited by evidence blocks with that source_version_id")
    func lineage_sourceVersionToEvidenceBlock() async throws {
        let (db, repo) = try await rig()
        let svID = try await seedSourceVersion(db)
        let ebID = try await seedEvidenceBlock(db, svID: svID)

        _ = try await repo.assign(
            target: SensitiveScopeTarget(kind: .sourceVersion, id: svID),
            sensitivity: .confidential,
            authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: false),
            reason: nil, at: t0)

        let resolution = try await repo.effectiveLabel(
            for: SensitiveScopeTarget(kind: .evidenceBlock, id: ebID))
        let label = try #require(resolution.label)
        #expect(label.sensitivity == .confidential,
                "EB must inherit confidential from its parent sourceVersion")
    }

    // MARK: - 14: Lineage — knowledgeObject → chunk (NEW)

    @Test("A knowledgeObject assignment is inherited by its chunks")
    func lineage_knowledgeObjectToChunk() async throws {
        let (db, repo) = try await rig()
        let (_, koID) = try await seedFileAndKO(db)
        let chunkID = try await seedChunk(db, koID: koID)

        _ = try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: false),
            reason: nil, at: t0)

        let resolution = try await repo.effectiveLabel(
            for: SensitiveScopeTarget(kind: .chunk, id: chunkID))
        let label = try #require(resolution.label)
        #expect(label.sensitivity == .restricted,
                "Chunk must inherit restricted from its parent KO")
    }

    // MARK: - 15: Lineage — knowledgeObject → entity (NEW)

    @Test("A knowledgeObject assignment is inherited by its entities")
    func lineage_knowledgeObjectToEntity() async throws {
        let (db, repo) = try await rig()
        let (_, koID) = try await seedFileAndKO(db)
        let entityID = try await seedEntity(db, koID: koID)

        _ = try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .confidential,
            authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: false),
            reason: nil, at: t0)

        let resolution = try await repo.effectiveLabel(
            for: SensitiveScopeTarget(kind: .entity, id: entityID))
        let label = try #require(resolution.label)
        #expect(label.sensitivity == .confidential,
                "Entity must inherit confidential from its source KO")
    }

    // MARK: - 16: Lineage — knowledgeObject → event (NEW)

    @Test("A knowledgeObject assignment is inherited by its events")
    func lineage_knowledgeObjectToEvent() async throws {
        let (db, repo) = try await rig()
        let (_, koID) = try await seedFileAndKO(db)
        let eventID = try await seedEvent(db, koID: koID)

        _ = try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: false),
            reason: nil, at: t0)

        let resolution = try await repo.effectiveLabel(
            for: SensitiveScopeTarget(kind: .event, id: eventID))
        let label = try #require(resolution.label)
        #expect(label.sensitivity == .restricted,
                "Event must inherit restricted from its source KO")
    }

    // MARK: - 17: Lineage — claim → cited knowledgeObject (NEW)

    @Test("A claim inherits the label of a cited knowledge object via claim_evidence_ref")
    func lineage_claimToCitedKnowledgeObject() async throws {
        let (db, repo) = try await rig()
        let (_, koID) = try await seedFileAndKO(db)
        let claimID = try await seedClaim(db)
        try await seedClaimRef(db, claimID: claimID, koID: koID, ordinal: 0)

        _ = try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: false),
            reason: nil, at: t0)

        let resolution = try await repo.effectiveLabel(
            for: SensitiveScopeTarget(kind: .claim, id: claimID))
        let label = try #require(resolution.label)
        #expect(label.sensitivity == .restricted,
                "Claim must inherit restricted from its cited KO")
    }

    // MARK: - 18: Lineage — claim inherits max across two cited KOs (NEW)

    @Test("A claim citing two KOs with different labels inherits the maximum with sticky privilege")
    func lineage_mixedSourceClaim() async throws {
        let (db, repo) = try await rig()
        let (_, ko1ID) = try await seedFileAndKO(db)
        let (_, ko2ID) = try await seedFileAndKO(db)
        let claimID = try await seedClaim(db)
        try await seedClaimRef(db, claimID: claimID, koID: ko1ID, ordinal: 0)
        try await seedClaimRef(db, claimID: claimID, koID: ko2ID, ordinal: 1)

        _ = try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: ko1ID),
            sensitivity: .confidential,
            authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: false),
            reason: nil, at: t0)
        _ = try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: ko2ID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0.addingTimeInterval(1))

        let resolution = try await repo.effectiveLabel(
            for: SensitiveScopeTarget(kind: .claim, id: claimID))
        let label = try #require(resolution.label)
        #expect(label.sensitivity == .restricted,
                "Claim must inherit the max sensitivity across both cited KOs")
        #expect(label.privileged,
                "Privilege is sticky — claim must inherit it from the restricted+privileged KO")
    }

    // MARK: - 19: Lineage — revoke direct, inherited label survives (NEW)

    @Test("Revoking a direct assignment does not clear a label inherited from the parent file")
    func lineage_revokeDirectDoesntClearInherited() async throws {
        let (db, repo) = try await rig()
        let (fileID, koID) = try await seedFileAndKO(db)
        let koTarget  = SensitiveScopeTarget(kind: .knowledgeObject, id: koID)
        let fileTarget = SensitiveScopeTarget(kind: .file, id: fileID)

        _ = try await repo.assign(target: fileTarget, sensitivity: .restricted,
                                   authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: false),
                                   reason: nil, at: t0)
        let direct = try await repo.assign(target: koTarget, sensitivity: .confidential,
                                            authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: false),
                                            reason: nil, at: t0.addingTimeInterval(1))

        try await repo.revoke(assignmentID: direct.id, revokedBy: "u", reason: nil,
                              at: t0.addingTimeInterval(2))

        let resolution = try await repo.effectiveLabel(for: koTarget)
        let label = try #require(resolution.label)
        #expect(label.sensitivity == .restricted,
                "File-inherited restricted label must survive revocation of the direct KO assignment")
    }

    // MARK: - 20: Batch key — same UUID in event and claim (NEW)

    @Test("batchResolution distinguishes same UUID in two different target-kind tables")
    func batchTargetKeyNoCollision() async throws {
        let (db, repo) = try await rig()
        let (_, koID) = try await seedFileAndKO(db)
        let sameID = UUID()

        // Seed the same UUID as both an event and a claim.
        try await db.exec("""
        INSERT INTO events (id, kind, date, title, source_object_id, confidence)
        VALUES (?,?,?,?,?,?);
        """, [.uuid(sameID), .text("milestone"), .real(0), .text("Shared"), .uuid(koID), .real(1.0)])
        try await db.exec("""
        INSERT INTO claims
            (id, subject_label, statement, created_at,
             evidence_basis, review_disposition, proposal_origin,
             availability_status, conflict_status)
        VALUES (?,?,?,?,?,?,?,?,?);
        """, [.uuid(sameID), .text("sub"), .text("stmt"), .real(0),
              .text("direct"), .text("accepted"), .text("user"),
              .text("available"), .text("none")])

        let eventTarget = SensitiveScopeTarget(kind: .event,  id: sameID)
        let claimTarget = SensitiveScopeTarget(kind: .claim, id: sameID)

        _ = try await repo.assign(target: eventTarget, sensitivity: .restricted,
                                   authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: false),
                                   reason: nil, at: t0)
        _ = try await repo.assign(target: claimTarget, sensitivity: .confidential,
                                   authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: false),
                                   reason: nil, at: t0.addingTimeInterval(1))

        let batch = try await repo.batchResolution([eventTarget, claimTarget])
        #expect(batch[eventTarget]?.label?.sensitivity == .restricted,
                "Event target must return restricted, not overwritten by claim")
        #expect(batch[claimTarget]?.label?.sensitivity == .confidential,
                "Claim target must return confidential, not overwritten by event")
    }

    // MARK: - 21: Legacy KO sync on assign and revoke (NEW)

    @Test("Assigning privileged=true syncs knowledge_objects.privileged=1; revoke clears it")
    func legacySyncOnAssignAndRevoke() async throws {
        let (db, repo) = try await rig()
        let (_, koID) = try await seedFileAndKO(db)
        let target = SensitiveScopeTarget(kind: .knowledgeObject, id: koID)

        let before = try await db.query(
            "SELECT privileged FROM knowledge_objects WHERE id = ?;", [.uuid(koID)])
        #expect(before.first?.int(0) == 0, "privileged should start at 0")

        let a = try await repo.assign(target: target, sensitivity: .restricted,
                                       authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: true),
                                       reason: nil, at: t0)

        let after = try await db.query(
            "SELECT privileged FROM knowledge_objects WHERE id = ?;", [.uuid(koID)])
        #expect(after.first?.int(0) == 1, "privileged must be synced to 1 after privileged assignment")

        try await repo.revoke(assignmentID: a.id, revokedBy: "u", reason: nil,
                              at: t0.addingTimeInterval(1))

        let revoked = try await db.query(
            "SELECT privileged FROM knowledge_objects WHERE id = ?;", [.uuid(koID)])
        #expect(revoked.first?.int(0) == 0,
                "privileged must revert to 0 when the last privileged assignment is revoked")
    }

    // MARK: - 22: Review ledger is readable (NEW)

    @Test("assign() and revoke() each write a review entry; reviews(forAssignmentID:) reads both")
    func reviewsReadable() async throws {
        let (db, repo) = try await rig()
        let (_, koID) = try await seedFileAndKO(db)
        let target = SensitiveScopeTarget(kind: .knowledgeObject, id: koID)

        let a = try await repo.assign(target: target, sensitivity: .restricted,
                                       authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: false),
                                       reason: nil, at: t0)
        try await repo.revoke(assignmentID: a.id, revokedBy: "u", reason: "done",
                              at: t0.addingTimeInterval(1))

        let reviews = try await repo.reviews(forAssignmentID: a.id)
        #expect(reviews.count == 2)
        #expect(reviews[0].action == .assigned)
        #expect(reviews[1].action == .revoked)
        #expect(reviews.allSatisfy { $0.assignmentID == a.id })
    }

    // MARK: - 23: Assign rolls back atomically when review INSERT fails (NEW)

    @Test("Assignment atomically rolls back when the review INSERT fails")
    func assignRollbackIfReviewFails() async throws {
        let (db, repo) = try await rig()
        let (_, koID) = try await seedFileAndKO(db)
        let target = SensitiveScopeTarget(kind: .knowledgeObject, id: koID)

        // Sabotage the review ledger — any INSERT into it will fail.
        try await db.exec("DROP TABLE sensitive_scope_reviews;", [])

        await #expect(throws: (any Error).self) {
            _ = try await repo.assign(target: target, sensitivity: .restricted,
                                       authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: false),
                                       reason: nil, at: t0)
        }

        let rows = try await db.query("""
        SELECT COUNT(*) FROM sensitive_scope_assignments
         WHERE target_kind = ? AND target_id = ?;
        """, [.text("knowledgeObject"), .uuid(koID)])
        #expect(Int(rows.first?.int(0) ?? -1) == 0,
                "Savepoint must have rolled back the assignment INSERT")
    }

    // MARK: - 24: Revoke rolls back atomically when review INSERT fails (NEW)

    @Test("Revocation atomically rolls back when the review INSERT fails")
    func revokeRollbackIfReviewFails() async throws {
        let (db, repo) = try await rig()
        let (_, koID) = try await seedFileAndKO(db)
        let target = SensitiveScopeTarget(kind: .knowledgeObject, id: koID)

        let a = try await repo.assign(target: target, sensitivity: .restricted,
                                       authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: false),
                                       reason: nil, at: t0)

        // Sabotage the review ledger after a successful assign.
        try await db.exec("DROP TABLE sensitive_scope_reviews;", [])

        await #expect(throws: (any Error).self) {
            try await repo.revoke(assignmentID: a.id, revokedBy: "u", reason: nil,
                                  at: t0.addingTimeInterval(1))
        }

        let rows = try await db.query("""
        SELECT revoked_at FROM sensitive_scope_assignments WHERE id = ?;
        """, [.uuid(a.id)])
        #expect(rows.first?.isNull(0) == true,
                "Savepoint must have rolled back the revoke UPDATE — assignment must still be active")
    }

    // MARK: - 26: userConfirmed actor and origin stored correctly (OPS-003A.2)

    @Test("userConfirmed actorID is stored as assigned_by; origin embeds the confirmationID")
    func confirmedActorAndOriginStoredCorrectly() async throws {
        let (db, repo) = try await rig()
        let (_, koID) = try await seedFileAndKO(db)
        let target = SensitiveScopeTarget(kind: .knowledgeObject, id: koID)
        let cid = UUID()

        let a = try await repo.assign(
            target: target,
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "carol", confirmationID: cid, privileged: true),
            reason: nil, at: t0)

        #expect(a.assignedBy == "carol", "actorID must be stored verbatim as assigned_by")
        #expect(a.origin == "user_confirmed:\(cid.uuidString)",
                "origin must embed the confirmationID UUID")
        #expect(a.privileged)
    }

    // MARK: - 27: Whitespace-only actorID is rejected (OPS-003A.2)

    @Test("userConfirmed with a whitespace-only actorID throws nonblankActorRequired")
    func whitespaceOnlyActorIDRejected() async throws {
        let (db, repo) = try await rig()
        let (_, koID) = try await seedFileAndKO(db)
        let target = SensitiveScopeTarget(kind: .knowledgeObject, id: koID)

        await #expect(throws: (any Error).self,
                      "whitespace-only actorID must be refused before touching the database") {
            _ = try await repo.assign(
                target: target, sensitivity: .restricted,
                authority: .userConfirmed(actorID: "   ", confirmationID: UUID(), privileged: false),
                reason: nil, at: t0)
        }
        // No assignment must have been inserted.
        let rows = try await db.query("""
        SELECT COUNT(*) FROM sensitive_scope_assignments
         WHERE target_kind = ? AND target_id = ?;
        """, [.text("knowledgeObject"), .uuid(koID)])
        #expect(Int(rows.first?.int(0) ?? -1) == 0)
    }

    // MARK: - 28: Whitespace-only revokedBy is rejected (OPS-003A.2)

    @Test("revoke() with a whitespace-only revokedBy throws nonblankActorRequired")
    func whitespaceOnlyRevokedByRejected() async throws {
        let (db, repo) = try await rig()
        let (_, koID) = try await seedFileAndKO(db)
        let target = SensitiveScopeTarget(kind: .knowledgeObject, id: koID)

        let a = try await repo.assign(target: target, sensitivity: .restricted,
                                       authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: false),
                                       reason: nil, at: t0)
        await #expect(throws: (any Error).self,
                      "whitespace-only revokedBy must be refused") {
            try await repo.revoke(assignmentID: a.id, revokedBy: "  ", reason: nil,
                                  at: t0.addingTimeInterval(1))
        }
        // Assignment must still be active.
        let rows = try await db.query("""
        SELECT revoked_at FROM sensitive_scope_assignments WHERE id = ?;
        """, [.uuid(a.id)])
        #expect(rows.first?.isNull(0) == true, "assignment must remain active after whitespace revoke failure")
    }

    // MARK: - 29: Lineage — claim via EB→EBO→KO→File even when direct KO ref is public (OPS-003A.2 7th branch)

    @Test("A restricted File is reached via Claim→EB→EBO→KO→File even when the direct KO in the ref row is public")
    func lineage_claimViaEBThroughEBOToProtectedFile() async throws {
        let (db, repo) = try await rig()
        // koA and fileA are public (no assignment).
        let (_, koAID) = try await seedFileAndKO(db)
        // koB's file will be restricted — the EB links to koB via EBO.
        let (fileBID, koBID) = try await seedFileAndKO(db)
        let ebID = try await seedEvidenceBlock(db, svID: nil)
        // EB is linked to koBID through evidence_block_objects (NOT koA).
        try await seedEBOLink(db, ebID: ebID, koID: koBID)
        let claimID = try await seedClaim(db)
        // claim_evidence_ref: knowledge_object_id = koA (required NOT NULL, but public),
        // evidence_block_id = ebID (leads to restricted koB/fileB via 7th branch).
        try await db.exec("""
        INSERT INTO claim_evidence_ref (claim_id, ordinal, knowledge_object_id, evidence_block_id, evidence_role)
        VALUES (?,?,?,?,?);
        """, [.uuid(claimID), .integer(0), .uuid(koAID), .uuid(ebID), .text("supporting")])

        // Assign restricted only to fileB (koA/fileA carry no assignment).
        _ = try await repo.assign(
            target: SensitiveScopeTarget(kind: .file, id: fileBID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: false),
            reason: nil, at: t0)

        let resolution = try await repo.effectiveLabel(
            for: SensitiveScopeTarget(kind: .claim, id: claimID))
        let label = try #require(resolution.label)
        #expect(label.sensitivity == .restricted,
                "7th branch must propagate restricted from fileB via Claim→EB→EBO→koBID→fileBID")
    }

    // MARK: - 30: Legacy sync — file assignment propagates privileged to child KOs (OPS-003A.2)

    @Test("A privileged File assignment sets knowledge_objects.privileged = 1 on all child KOs")
    func legacySyncFilePropagatesPrivilegedToChildKOs() async throws {
        let (db, repo) = try await rig()
        let (fileID, ko1ID) = try await seedFileAndKO(db)
        // Seed a second KO under the same file.
        let ko2ID = UUID()
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?,?,?,?,?,?);
        """, [.uuid(ko2ID), .uuid(fileID), .text("text"), .text("body2"), .real(0), .real(0)])

        let before1 = try await db.query(
            "SELECT privileged FROM knowledge_objects WHERE id = ?;", [.uuid(ko1ID)])
        let before2 = try await db.query(
            "SELECT privileged FROM knowledge_objects WHERE id = ?;", [.uuid(ko2ID)])
        #expect(before1.first?.int(0) == 0)
        #expect(before2.first?.int(0) == 0)

        _ = try await repo.assign(
            target: SensitiveScopeTarget(kind: .file, id: fileID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)

        let after1 = try await db.query(
            "SELECT privileged FROM knowledge_objects WHERE id = ?;", [.uuid(ko1ID)])
        let after2 = try await db.query(
            "SELECT privileged FROM knowledge_objects WHERE id = ?;", [.uuid(ko2ID)])
        #expect(after1.first?.int(0) == 1, "child KO 1 must be set to privileged=1")
        #expect(after2.first?.int(0) == 1, "child KO 2 must be set to privileged=1")
    }

    // MARK: - 31: Legacy sync — file revoke clears child KOs when no other coverage (OPS-003A.2)

    @Test("Revoking the only privileged File assignment clears knowledge_objects.privileged on child KOs")
    func legacySyncFileRevokeRemovesKOPrivilegedWhenNoCoverage() async throws {
        let (db, repo) = try await rig()
        let (fileID, koID) = try await seedFileAndKO(db)

        let a = try await repo.assign(
            target: SensitiveScopeTarget(kind: .file, id: fileID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)

        let synced = try await db.query(
            "SELECT privileged FROM knowledge_objects WHERE id = ?;", [.uuid(koID)])
        #expect(synced.first?.int(0) == 1, "privileged must be 1 after file assignment")

        try await repo.revoke(assignmentID: a.id, revokedBy: "u", reason: nil,
                              at: t0.addingTimeInterval(1))

        let cleared = try await db.query(
            "SELECT privileged FROM knowledge_objects WHERE id = ?;", [.uuid(koID)])
        #expect(cleared.first?.int(0) == 0,
                "privileged must revert to 0 when the only covering file assignment is revoked")
    }

    // MARK: - 32: Legacy sync — file revoke preserves KO.privileged when direct KO assignment remains (OPS-003A.2)

    @Test("Revoking a File assignment does not clear privileged on a KO that still has a direct privileged assignment")
    func legacySyncFileRevokePreservesKOPrivilegedWithDirectAssignment() async throws {
        let (db, repo) = try await rig()
        let (fileID, koID) = try await seedFileAndKO(db)
        let koTarget   = SensitiveScopeTarget(kind: .knowledgeObject, id: koID)
        let fileTarget = SensitiveScopeTarget(kind: .file, id: fileID)

        let fileAssign = try await repo.assign(target: fileTarget, sensitivity: .restricted,
                                                authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: true),
                                                reason: nil, at: t0)
        // Direct KO privileged assignment — this keeps it covered after the file assign is revoked.
        _ = try await repo.assign(target: koTarget, sensitivity: .confidential,
                                   authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: true),
                                   reason: nil, at: t0.addingTimeInterval(1))

        try await repo.revoke(assignmentID: fileAssign.id, revokedBy: "u", reason: nil,
                              at: t0.addingTimeInterval(2))

        let after = try await db.query(
            "SELECT privileged FROM knowledge_objects WHERE id = ?;", [.uuid(koID)])
        #expect(after.first?.int(0) == 1,
                "privileged must stay 1: direct KO assignment still covers it even after file revoke")
    }

    // MARK: - 25: Malformed sensitivity throws (NEW)

    @Test("A row with an invalid sensitivity value causes effectiveLabel and assignments to throw")
    func malformedSensitivityThrows() async throws {
        let (db, repo) = try await rig()
        let (_, koID) = try await seedFileAndKO(db)

        // Insert a row with sensitivity = 999 (not a valid SensitivityLevel rawValue).
        try await db.exec("""
        INSERT INTO sensitive_scope_assignments
            (id, target_kind, target_id, sensitivity, privileged, origin, assigned_by, created_at)
        VALUES (?,?,?,?,?,?,?,?);
        """, [.uuid(UUID()), .text("knowledgeObject"), .uuid(koID),
              .integer(999), .integer(0), .text("test"), .text("test"), .real(0)])

        await #expect(throws: (any Error).self,
                      "effectiveLabel must throw, not silently ignore the malformed row") {
            _ = try await repo.effectiveLabel(
                for: SensitiveScopeTarget(kind: .knowledgeObject, id: koID))
        }
        await #expect(throws: (any Error).self,
                      "assignments(for:) must throw, not silently drop the malformed row") {
            _ = try await repo.assignments(
                for: SensitiveScopeTarget(kind: .knowledgeObject, id: koID))
        }
    }
}
