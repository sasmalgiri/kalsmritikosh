//
//  SensitiveRetrievalEnforcementTests.swift
//  KalsmritikoshTests
//
//  OPS-003B — verifies SensitiveRetrievalPolicy.filter() correctly withholds
//  chunks, events, entities, relationships, summaries, GenericFacts,
//  ClaimEvaluations, and WalkSteps based on the caller's SensitiveScope.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("OPS-003B SensitiveRetrievalEnforcement")
struct SensitiveRetrievalEnforcementTests {

    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - Rig

    private func rig() async throws -> (Database, SensitiveScopeRepository, SensitiveRetrievalPolicy) {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db)
        let repo = SensitiveScopeRepository(database: db)
        let policy = SensitiveRetrievalPolicy(repository: repo)
        return (db, repo, policy)
    }

    // MARK: - Seed helpers

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

    // MARK: - In-memory model builders

    private func chunk(koID: UUID, ebID: UUID? = nil) -> RetrievedChunk {
        RetrievedChunk(
            chunk: Chunk(objectID: koID, ordinal: 0, text: "text", characterRange: 0..<4,
                         evidenceBlockID: ebID),
            score: 1.0, viaLayer: .metadata)
    }

    private func event(koID: UUID) -> Event {
        Event(kind: .emailSent, date: t0, title: "E", sourceObjectID: koID)
    }

    private func entity(koID: UUID) -> Entity {
        Entity(kind: .person, value: "Alice \(koID.uuidString.prefix(4))",
               sourceObjectID: koID)
    }

    private func relationship(koID: UUID) -> Relationship {
        Relationship(kind: .worksWith, fromEntityID: UUID(), toEntityID: UUID(),
                     sourceObjectID: koID)
    }

    private func documentSummary(koID: UUID) -> Summary {
        Summary(level: .document, length: .short, scope: .document(koID), body: "summary")
    }

    private func knowledgeBaseSummary() -> Summary {
        Summary(level: .knowledgeBase, length: .short, scope: .knowledgeBase, body: "kb")
    }

    private func scope(max: SensitivityLevel, privileged: Bool = false) -> SensitiveScope {
        SensitiveScope(workspaceID: UUID(), maximumSensitivity: max,
                       permitsPrivilegedMaterial: privileged, purpose: .retrieval)
    }

    // MARK: - Tests 1-2: default label (no SSA assignment)

    @Test("Public scope blocks items with default internal label (no SSA)")
    func publicScopeBlocksDefaultInternalLabel() async throws {
        let (_, _, policy) = try await rig()
        let koID = UUID()   // no SSA → nil resolution → default internalLevel
        let result = RetrievalResult(chunks: [chunk(koID: koID)])
        let access = SensitiveAccessContext(scope: scope(max: .publicLevel))
        let authorized = await policy.filter(result: result, access: access)
        #expect(authorized.withheldChunkCount == 1)
        #expect(authorized.result.chunks.isEmpty)
    }

    @Test("Internal scope permits items with default internal label (no SSA)")
    func internalScopePermitsDefaultInternalLabel() async throws {
        let (_, _, policy) = try await rig()
        let koID = UUID()   // nil resolution → default internalLevel
        let result = RetrievalResult(chunks: [chunk(koID: koID)])
        let access = SensitiveAccessContext(scope: scope(max: .internalLevel))
        let authorized = await policy.filter(result: result, access: access)
        #expect(authorized.withheldChunkCount == 0)
        #expect(authorized.result.chunks.count == 1)
    }

    // MARK: - Tests 3-4: sensitivity ceiling with SSA

    @Test("Restricted KO blocked by confidential ceiling scope")
    func restrictedKOBlockedByConfidentialScope() async throws {
        let (db, repo, policy) = try await rig()
        let (_, koID) = try await seedFileAndKO(db)
        _ = try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: false),
            reason: nil, at: t0)
        let result = RetrievalResult(chunks: [chunk(koID: koID)])
        let access = SensitiveAccessContext(scope: scope(max: .confidential))
        let authorized = await policy.filter(result: result, access: access)
        #expect(authorized.withheldChunkCount == 1)
        #expect(authorized.result.chunks.isEmpty)
    }

    @Test("Restricted KO permitted by restricted ceiling scope")
    func restrictedKOPermittedByRestrictedScope() async throws {
        let (db, repo, policy) = try await rig()
        let (_, koID) = try await seedFileAndKO(db)
        _ = try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: false),
            reason: nil, at: t0)
        let result = RetrievalResult(chunks: [chunk(koID: koID)])
        let access = SensitiveAccessContext(scope: scope(max: .restricted))
        let authorized = await policy.filter(result: result, access: access)
        #expect(authorized.withheldChunkCount == 0)
        #expect(authorized.result.chunks.count == 1)
    }

    // MARK: - Tests 5-6: privilege flag

    @Test("Privileged KO blocked when scope does not permit privileged material")
    func privilegedKOBlockedByNonPrivilegeScope() async throws {
        let (db, repo, policy) = try await rig()
        let (_, koID) = try await seedFileAndKO(db)
        _ = try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .internalLevel,
            authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)
        let result = RetrievalResult(chunks: [chunk(koID: koID)])
        let access = SensitiveAccessContext(scope: scope(max: .restricted, privileged: false))
        let authorized = await policy.filter(result: result, access: access)
        #expect(authorized.withheldChunkCount == 1)
        #expect(authorized.result.chunks.isEmpty)
    }

    @Test("Privileged KO permitted when scope permits privileged material")
    func privilegedKOPermittedByPrivilegeScope() async throws {
        let (db, repo, policy) = try await rig()
        let (_, koID) = try await seedFileAndKO(db)
        _ = try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .internalLevel,
            authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)
        let result = RetrievalResult(chunks: [chunk(koID: koID)])
        let access = SensitiveAccessContext(scope: scope(max: .restricted, privileged: true))
        let authorized = await policy.filter(result: result, access: access)
        #expect(authorized.withheldChunkCount == 0)
        #expect(authorized.result.chunks.count == 1)
    }

    // MARK: - Tests 7-11: per-collection filtering

    @Test("withheldChunkCount accurate with three blocked chunks from one KO")
    func withheldChunkCountAccurate() async throws {
        let (_, _, policy) = try await rig()
        let blockedKO = UUID()   // no SSA → internalLevel → blocked by publicLevel
        let result = RetrievalResult(chunks: [
            chunk(koID: blockedKO), chunk(koID: blockedKO), chunk(koID: blockedKO)
        ])
        let access = SensitiveAccessContext(scope: scope(max: .publicLevel))
        let authorized = await policy.filter(result: result, access: access)
        #expect(authorized.withheldChunkCount == 3)
        #expect(authorized.result.chunks.isEmpty)
    }

    @Test("Event withheld when its source KO is blocked")
    func eventWithheldWhenKOBlocked() async throws {
        let (db, repo, policy) = try await rig()
        let (_, koID) = try await seedFileAndKO(db)
        _ = try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: false),
            reason: nil, at: t0)
        let result = RetrievalResult(events: [event(koID: koID)])
        let access = SensitiveAccessContext(scope: scope(max: .confidential))
        let authorized = await policy.filter(result: result, access: access)
        #expect(authorized.withheldEventCount == 1)
        #expect(authorized.result.events.isEmpty)
    }

    @Test("Entity withheld when its source KO is blocked")
    func entityWithheldWhenKOBlocked() async throws {
        let (db, repo, policy) = try await rig()
        let (_, koID) = try await seedFileAndKO(db)
        _ = try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: false),
            reason: nil, at: t0)
        let result = RetrievalResult(entities: [entity(koID: koID)])
        let access = SensitiveAccessContext(scope: scope(max: .confidential))
        let authorized = await policy.filter(result: result, access: access)
        #expect(authorized.withheldEntityCount == 1)
        #expect(authorized.result.entities.isEmpty)
    }

    @Test("Relationship withheld when its source KO is blocked")
    func relationshipWithheldWhenKOBlocked() async throws {
        let (db, repo, policy) = try await rig()
        let (_, koID) = try await seedFileAndKO(db)
        _ = try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: false),
            reason: nil, at: t0)
        let result = RetrievalResult(relationships: [relationship(koID: koID)])
        let access = SensitiveAccessContext(scope: scope(max: .confidential))
        let authorized = await policy.filter(result: result, access: access)
        #expect(authorized.withheldRelationshipCount == 1)
        #expect(authorized.result.relationships.isEmpty)
    }

    @Test("Document-scope summary withheld when its KO is blocked")
    func documentSummaryWithheldWhenKOBlocked() async throws {
        let (db, repo, policy) = try await rig()
        let (_, koID) = try await seedFileAndKO(db)
        _ = try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: false),
            reason: nil, at: t0)
        let result = RetrievalResult(summaries: [documentSummary(koID: koID)])
        let access = SensitiveAccessContext(scope: scope(max: .confidential))
        let authorized = await policy.filter(result: result, access: access)
        #expect(authorized.withheldSummaryCount == 1)
        #expect(authorized.result.summaries.isEmpty)
    }

    // MARK: - Tests 12-13: non-document summary (fail-closed) + five-count accuracy

    @Test("Non-document scope summary is denied (fail-closed — no KO lineage to check)")
    func nonDocumentSummaryDenied() async throws {
        let (_, _, policy) = try await rig()
        let result = RetrievalResult(summaries: [knowledgeBaseSummary()])
        // Even a maximally permissive scope cannot admit a summary without exact KO lineage.
        let access = SensitiveAccessContext(scope: scope(max: .restricted, privileged: true))
        let authorized = await policy.filter(result: result, access: access)
        #expect(authorized.withheldSummaryCount == 1)
        #expect(authorized.result.summaries.isEmpty)
    }

    @Test("All five withheld counts accurate for mixed blocked+permitted result")
    func allFiveWithheldCountsAccurate() async throws {
        let (db, repo, policy) = try await rig()
        let (_, blockedKO) = try await seedFileAndKO(db)
        let permittedKO = UUID()   // no SSA → internalLevel → permitted by internalLevel scope
        _ = try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: blockedKO),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: false),
            reason: nil, at: t0)

        let result = RetrievalResult(
            chunks:        [chunk(koID: blockedKO),        chunk(koID: permittedKO)],
            events:        [event(koID: blockedKO),        event(koID: permittedKO)],
            entities:      [entity(koID: blockedKO),       entity(koID: permittedKO)],
            relationships: [relationship(koID: blockedKO), relationship(koID: permittedKO)],
            summaries:     [documentSummary(koID: blockedKO), documentSummary(koID: permittedKO)]
        )
        let access = SensitiveAccessContext(scope: scope(max: .internalLevel))
        let authorized = await policy.filter(result: result, access: access)

        #expect(authorized.withheldChunkCount == 1)
        #expect(authorized.withheldEventCount == 1)
        #expect(authorized.withheldEntityCount == 1)
        #expect(authorized.withheldRelationshipCount == 1)
        // Blocked document withheld; permitted document passes through.
        #expect(authorized.withheldSummaryCount == 1)
        #expect(authorized.result.chunks.count == 1)
        #expect(authorized.result.events.count == 1)
        #expect(authorized.result.entities.count == 1)
        #expect(authorized.result.relationships.count == 1)
        #expect(authorized.result.summaries.count == 1)
    }

    // MARK: - Tests 14-15: GenericFact + ClaimEvaluation pair removal

    @Test("GenericFact withheld when all its source blocks come from a blocked chunk")
    func genericFactWithheldWhenSourceBlockBlocked() async throws {
        let (_, _, policy) = try await rig()
        let blockedKO = UUID()
        let blockID = UUID()
        let fact = GenericFact(subjectLabel: "Acme", field: "employer", value: "Acme",
                               status: .sourceAsserted, confidence: 0.9,
                               sourceBlockIDs: [blockID])
        let result = RetrievalResult(
            chunks: [chunk(koID: blockedKO, ebID: blockID)],
            genericFacts: [fact]
        )
        // Public scope blocks internalLevel (default for unseeded KO)
        let access = SensitiveAccessContext(scope: scope(max: .publicLevel))
        let authorized = await policy.filter(result: result, access: access)
        #expect(authorized.result.genericFacts.isEmpty)
    }

    @Test("Legacy GenericFact with no source blocks passes through regardless of scope")
    func legacyFactWithNoSourceBlocksPassesThrough() async throws {
        let (_, _, policy) = try await rig()
        let blockedKO = UUID()
        let fact = GenericFact(subjectLabel: "Acme", field: "employer", value: "Acme",
                               status: .sourceAsserted, confidence: 0.9,
                               sourceBlockIDs: [])   // empty = legacy path
        let result = RetrievalResult(
            chunks: [chunk(koID: blockedKO)],
            genericFacts: [fact]
        )
        // Public scope blocks chunks, but legacy facts (no sourceBlockIDs) pass through.
        let access = SensitiveAccessContext(scope: scope(max: .publicLevel))
        let authorized = await policy.filter(result: result, access: access)
        #expect(authorized.result.genericFacts.count == 1)
    }

    // MARK: - Tests 16-17: WalkStep filtering

    @Test("WalkStep denied when any evidence KO is blocked")
    func walkStepDeniedWhenEvidenceKOBlocked() async throws {
        let (db, repo, policy) = try await rig()
        let (_, restrictedKO) = try await seedFileAndKO(db)
        _ = try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: restrictedKO),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: false),
            reason: nil, at: t0)

        let permittedKO = UUID()   // no SSA → internalLevel → permitted by internalLevel scope
        let step = WalkStep(
            fromFact: .person,
            bond: "knows",
            toFact: .person,
            evidenceObjectIDs: [permittedKO, restrictedKO]   // one blocked KO → whole step denied
        )
        let result = RetrievalResult(walkSteps: [step])
        let access = SensitiveAccessContext(scope: scope(max: .internalLevel))
        let authorized = await policy.filter(result: result, access: access)
        #expect(authorized.result.walkSteps.isEmpty)
    }

    @Test("WalkStep permitted when all evidence KOs are within scope")
    func walkStepPermittedWhenAllEvidenceKOsPermitted() async throws {
        let (_, _, policy) = try await rig()
        let ko1 = UUID(); let ko2 = UUID()   // no SSA → internalLevel → permitted
        let step = WalkStep(
            fromFact: .person,
            bond: "knows",
            toFact: .organization,
            evidenceObjectIDs: [ko1, ko2]
        )
        let result = RetrievalResult(walkSteps: [step])
        let access = SensitiveAccessContext(scope: scope(max: .internalLevel))
        let authorized = await policy.filter(result: result, access: access)
        #expect(authorized.result.walkSteps.count == 1)
    }

    // MARK: - Tests 19-27: workspace enforcement + memory path enforcement

    private func seedWorkspace(_ db: Database, id: UUID) async throws {
        try await db.exec("""
            INSERT INTO workspaces
                (id, title, template_type, status, default_scope_json, created_at, updated_at)
            VALUES (?, 'TestWorkspace', 'investigation', 'active', '{}', 0.0, 0.0)
            ON CONFLICT(id) DO NOTHING;
            """, [.uuid(id)])
    }

    private func seedEntity(_ db: Database, id: UUID, koID: UUID) async throws {
        try await db.exec("""
            INSERT INTO entities
                (id, kind, value, normalized, source_object_id, confidence, attributes_json)
            VALUES (?, 'person', 'TestEntity', 'testentity', ?, 0.5, '{}');
            """, [.uuid(id), .uuid(koID)])
    }

    private func workspaceRig() async throws -> (Database, SensitiveScopeRepository, WorkspaceRepository, SensitiveRetrievalPolicy) {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db)
        let sensitiveRepo = SensitiveScopeRepository(database: db)
        let workspaceRepo = WorkspaceRepository(database: db)
        let policy = SensitiveRetrievalPolicy(repository: sensitiveRepo, workspaceRepository: workspaceRepo)
        return (db, sensitiveRepo, workspaceRepo, policy)
    }

    private func workspaceScope(id: UUID, max: SensitivityLevel = .internalLevel) -> SensitiveScope {
        SensitiveScope(workspaceID: id, maximumSensitivity: max,
                       permitsPrivilegedMaterial: false, purpose: .retrieval)
    }

    @Test("Workspace B scope denies chunk whose source KO belongs to workspace A only")
    func workspaceEnforcementBlocksKOFromOtherWorkspace() async throws {
        let (db, _, workspaceRepo, policy) = try await workspaceRig()
        let wsA = UUID()
        try await seedWorkspace(db, id: wsA)
        let (fileID, koID) = try await seedFileAndKO(db)
        try await workspaceRepo.addSource(fileID, to: wsA)

        let result = RetrievalResult(chunks: [chunk(koID: koID)])
        let access = SensitiveAccessContext(scope: workspaceScope(id: UUID()))
        let authorized = await policy.filter(result: result, access: access)
        #expect(authorized.withheldChunkCount == 1)
        #expect(authorized.result.chunks.isEmpty)
    }

    @Test("Workspace A scope allows chunk whose source KO belongs to workspace A")
    func workspaceEnforcementAllowsKOInSameWorkspace() async throws {
        let (db, _, workspaceRepo, policy) = try await workspaceRig()
        let wsA = UUID()
        try await seedWorkspace(db, id: wsA)
        let (fileID, koID) = try await seedFileAndKO(db)
        try await workspaceRepo.addSource(fileID, to: wsA)

        let result = RetrievalResult(chunks: [chunk(koID: koID)])
        let access = SensitiveAccessContext(scope: workspaceScope(id: wsA))
        let authorized = await policy.filter(result: result, access: access)
        #expect(authorized.withheldChunkCount == 0)
        #expect(authorized.result.chunks.count == 1)
    }

    @Test("Event whose source KO is in workspace A is denied in workspace B scope")
    func workspaceEnforcementBlocksEventFromOtherWorkspace() async throws {
        let (db, _, workspaceRepo, policy) = try await workspaceRig()
        let wsA = UUID()
        try await seedWorkspace(db, id: wsA)
        let (fileID, koID) = try await seedFileAndKO(db)
        try await workspaceRepo.addSource(fileID, to: wsA)

        let result = RetrievalResult(events: [event(koID: koID)])
        let access = SensitiveAccessContext(scope: workspaceScope(id: UUID()))
        let authorized = await policy.filter(result: result, access: access)
        #expect(authorized.withheldEventCount == 1)
        #expect(authorized.result.events.isEmpty)
    }

    @Test("Entity not in workspace_entities is denied in workspace scope")
    func workspaceEnforcementBlocksEntityNotInWorkspace() async throws {
        let (db, _, _, policy) = try await workspaceRig()
        let wsA = UUID()
        try await seedWorkspace(db, id: wsA)
        let (_, koID) = try await seedFileAndKO(db)

        let result = RetrievalResult(entities: [entity(koID: koID)])
        let access = SensitiveAccessContext(scope: workspaceScope(id: wsA))
        let authorized = await policy.filter(result: result, access: access)
        #expect(authorized.withheldEntityCount == 1)
        #expect(authorized.result.entities.isEmpty)
    }

    @Test("Entity in workspace_entities is allowed in workspace scope")
    func workspaceEnforcementAllowsEntityInWorkspace() async throws {
        let (db, _, workspaceRepo, policy) = try await workspaceRig()
        let wsA = UUID()
        try await seedWorkspace(db, id: wsA)
        let (_, koID) = try await seedFileAndKO(db)
        let ent = entity(koID: koID)
        try await seedEntity(db, id: ent.id, koID: koID)
        try await workspaceRepo.addEntity(ent.id, to: wsA)

        let result = RetrievalResult(entities: [ent])
        let access = SensitiveAccessContext(scope: workspaceScope(id: wsA))
        let authorized = await policy.filter(result: result, access: access)
        #expect(authorized.withheldEntityCount == 0)
        #expect(authorized.result.entities.count == 1)
    }

    @Test("KO in both workspaces A and B is allowed via either workspace scope")
    func workspaceEnforcementKoInBothWorkspacesAllowedInEither() async throws {
        let (db, _, workspaceRepo, policy) = try await workspaceRig()
        let wsA = UUID(); let wsB = UUID()
        try await seedWorkspace(db, id: wsA)
        try await seedWorkspace(db, id: wsB)
        let (fileID, koID) = try await seedFileAndKO(db)
        try await workspaceRepo.addSource(fileID, to: wsA)
        try await workspaceRepo.addSource(fileID, to: wsB)

        let result = RetrievalResult(chunks: [chunk(koID: koID)])

        let authorizedA = await policy.filter(
            result: result,
            access: SensitiveAccessContext(scope: workspaceScope(id: wsA)))
        #expect(authorizedA.result.chunks.count == 1, "KO in workspace A allowed via workspace A scope")

        let authorizedB = await policy.filter(
            result: result,
            access: SensitiveAccessContext(scope: workspaceScope(id: wsB)))
        #expect(authorizedB.result.chunks.count == 1, "KO in workspace B allowed via workspace B scope")
    }

    @Test("Workspace membership query error fails closed (total denial)")
    func workspaceKoRepoErrorFailsClosed() async throws {
        // Two separate DBs: sensitiveRepo on db1 (stays open), workspaceRepo on db2 (will be closed).
        // When db2 is closed, koIDsInWorkspace throws → policy returns totalDenial.
        let db1 = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db1)
        let db2 = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db2)
        let sensitiveRepo = SensitiveScopeRepository(database: db1)
        let workspaceRepo = WorkspaceRepository(database: db2)
        let policy = SensitiveRetrievalPolicy(repository: sensitiveRepo, workspaceRepository: workspaceRepo)

        let fileID = UUID(); let koID = UUID()
        try await db1.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                           [.uuid(fileID), .text("file:///\(fileID)"), .text("text")])
        try await db1.exec("""
            INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
            VALUES (?,?,?,?,?,?);
            """, [.uuid(koID), .uuid(fileID), .text("text"), .text("body"), .real(0), .real(0)])

        let result = RetrievalResult(chunks: [chunk(koID: koID)])
        let access = SensitiveAccessContext(scope: workspaceScope(id: UUID()))

        await db2.close()

        let authorized = await policy.filter(result: result, access: access)
        #expect(authorized.result.chunks.isEmpty, "Workspace repo error must cause total denial")
        #expect(authorized.withheldChunkCount == 1)
    }

    @Test("testUnrestricted() sentinel scope skips workspace enforcement entirely")
    func testSentinelScopeSkipsWorkspaceEnforcement() async throws {
        let (db, _, _, policy) = try await workspaceRig()
        let (_, koID) = try await seedFileAndKO(db)
        // KO not in any workspace — a non-sentinel scope would deny this chunk.
        // testUnrestricted() uses the sentinel UUID → isTestSentinel == true →
        // workspace check is skipped at the "!access.scope.isTestSentinel" guard.
        let result = RetrievalResult(chunks: [chunk(koID: koID)])
        let access = SensitiveAccessContext.testUnrestricted()
        let authorized = await policy.filter(result: result, access: access)
        #expect(authorized.withheldChunkCount == 0)
        #expect(authorized.result.chunks.count == 1)
    }

    @Test("Memory enforcement: cross-workspace event blocked simulates phase1Instant withhold")
    func memoryPhase1WithheldWhenContributingEventNotInWorkspace() async throws {
        // phase1Instant (MasterBrain.swift §5) does exactly:
        //   let stub = RetrievalResult(events: hydrated, layersUsed: [])
        //   let authorized = await policy.filter(result: stub, access: access)
        //   guard authorized.result.events.count == hydrated.count else { return nil }
        // This test exercises that path end-to-end via the policy.
        let (db, _, workspaceRepo, policy) = try await workspaceRig()
        let wsA = UUID()
        try await seedWorkspace(db, id: wsA)
        let (fileID, koID) = try await seedFileAndKO(db)
        try await workspaceRepo.addSource(fileID, to: wsA)

        let keyEvent = event(koID: koID)
        let stub = RetrievalResult(events: [keyEvent], layersUsed: [])

        // Workspace A scope: event passes → count matches → memory narrative would be returned.
        let accessA = SensitiveAccessContext(scope: workspaceScope(id: wsA))
        let authorizedA = await policy.filter(result: stub, access: accessA)
        #expect(authorizedA.result.events.count == 1,
                "Key event in its source workspace passes → memory returned")

        // Different workspace scope: event blocked → count != hydrated → memory withheld.
        let accessB = SensitiveAccessContext(scope: workspaceScope(id: UUID()))
        let authorizedB = await policy.filter(result: stub, access: accessB)
        #expect(authorizedB.result.events.isEmpty,
                "Key event not in scope workspace → memory would be withheld")
    }

    // MARK: - Test 18: repo-error causes total denial

    @Test("batchResolution error causes total denial (fail-closed)")
    func repoErrorCausesTotalDenial() async throws {
        let (db, _, policy) = try await rig()
        let koID = UUID()
        let result = RetrievalResult(
            chunks: [chunk(koID: koID)],
            events: [event(koID: koID)]
        )
        let access = SensitiveAccessContext(scope: scope(max: .restricted))

        // Normal filter succeeds before closing DB.
        let before = await policy.filter(result: result, access: access)
        #expect(before.result.chunks.count == 1)

        // Close the database — batchResolution will throw.
        await db.close()

        // After close, the policy must deny everything fail-closed.
        let after = await policy.filter(result: result, access: access)
        #expect(after.result.chunks.isEmpty)
        #expect(after.result.events.isEmpty)
        #expect(after.withheldChunkCount == 1)
        #expect(after.withheldEventCount == 1)
    }
}
