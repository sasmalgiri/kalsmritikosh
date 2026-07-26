//
//  SensitivePromptEnforcementTests.swift
//  KalsmritikoshTests
//
//  OPS-003B — verifies PromptContextAuthorizer, PromptAuthorizedRetrieval, and
//  all eight PromptTemplates overloads that accept PromptAuthorizedRetrieval
//  (the proof token that SensitiveRetrievalPolicy was applied before prompt
//  construction). Also verifies ExpertContext.access field propagation and
//  prompt-time revalidation (policy re-run at authorize() catches assignment
//  changes between retrieval and prompt construction).
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("OPS-003B SensitivePromptEnforcement")
struct SensitivePromptEnforcementTests {

    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - Helpers

    private func testScope() -> SensitiveScope {
        SensitiveScope(workspaceID: UUID(), maximumSensitivity: .internalLevel,
                       permitsPrivilegedMaterial: false, purpose: .retrieval)
    }

    private func testAccess() -> SensitiveAccessContext {
        SensitiveAccessContext(scope: testScope())
    }

    private func testAuthorized(
        chunks: [RetrievedChunk] = [],
        events: [Event] = [],
        entities: [Entity] = []
    ) -> AuthorizedRetrievalResult {
        AuthorizedRetrievalResult(
            result: RetrievalResult(chunks: chunks, events: events, entities: entities),
            accessContext: testAccess()
        )
    }

    private func testChunk(koID: UUID = UUID()) -> RetrievedChunk {
        RetrievedChunk(
            chunk: Chunk(objectID: koID, ordinal: 0, text: "chunk text", characterRange: 0..<10),
            score: 1.0, viaLayer: .metadata)
    }

    private func testEvent(koID: UUID = UUID()) -> Event {
        Event(kind: .emailSent, date: t0, title: "Meeting", sourceObjectID: koID)
    }

    private func testIntent() -> UserIntent {
        UserIntent(kind: .factualLookup, scope: .global, rawQuestion: "test question")
    }

    // MARK: - Tests 1-2: PromptContextAuthorizer (no policy — pure conversion)

    @Test("PromptContextAuthorizer converts AuthorizedRetrievalResult to PromptAuthorizedRetrieval")
    func promptContextAuthorizerConvertsResult() async {
        let authorized = testAuthorized(chunks: [testChunk()])
        let authorizer = PromptContextAuthorizer()
        let proof = await authorizer.authorize(authorized)
        #expect(proof.retrieval.chunks.count == 1)
    }

    @Test("PromptContextAuthorizer preserves the access context through conversion")
    func promptContextAuthorizerPreservesAccessContext() async {
        let access = testAccess()
        let authorized = AuthorizedRetrievalResult(
            result: RetrievalResult(),
            accessContext: access
        )
        let proof = await PromptContextAuthorizer().authorize(authorized)
        #expect(proof.accessContext.scope.workspaceID == access.scope.workspaceID)
        #expect(proof.accessContext.scope.maximumSensitivity == access.scope.maximumSensitivity)
    }

    // MARK: - Tests 3-10: all eight PromptTemplates overloads

    @Test("emailAnalysis overload accepts PromptAuthorizedRetrieval")
    func emailTemplateAcceptsAuthorizedRetrieval() async {
        let proof = await PromptContextAuthorizer().authorize(testAuthorized(chunks: [testChunk()]))
        let frame = PromptTemplates.emailAnalysis(intent: testIntent(), retrieval: proof)
        #expect(!frame.prompt.isEmpty)
    }

    @Test("financialAnalysis overload accepts PromptAuthorizedRetrieval")
    func financialTemplateAcceptsAuthorizedRetrieval() async {
        let proof = await PromptContextAuthorizer().authorize(testAuthorized(chunks: [testChunk()]))
        let frame = PromptTemplates.financialAnalysis(intent: testIntent(), retrieval: proof)
        #expect(!frame.prompt.isEmpty)
    }

    @Test("legalAnalysis overload accepts PromptAuthorizedRetrieval")
    func legalTemplateAcceptsAuthorizedRetrieval() async {
        let proof = await PromptContextAuthorizer().authorize(testAuthorized(chunks: [testChunk()]))
        let frame = PromptTemplates.legalAnalysis(intent: testIntent(), retrieval: proof)
        #expect(!frame.prompt.isEmpty)
    }

    @Test("projectAnalysis overload accepts PromptAuthorizedRetrieval")
    func projectTemplateAcceptsAuthorizedRetrieval() async {
        let proof = await PromptContextAuthorizer().authorize(testAuthorized(chunks: [testChunk()]))
        let frame = PromptTemplates.projectAnalysis(intent: testIntent(), retrieval: proof)
        #expect(!frame.prompt.isEmpty)
    }

    @Test("ocrAnalysis overload accepts PromptAuthorizedRetrieval")
    func ocrTemplateAcceptsAuthorizedRetrieval() async {
        let proof = await PromptContextAuthorizer().authorize(testAuthorized(chunks: [testChunk()]))
        let imageChunks: [RetrievedChunk] = []
        let frame = PromptTemplates.ocrAnalysis(intent: testIntent(), retrieval: proof,
                                                imageChunks: imageChunks)
        #expect(!frame.prompt.isEmpty)
    }

    @Test("timelineAnalysis overload accepts PromptAuthorizedRetrieval")
    func timelineTemplateAcceptsAuthorizedRetrieval() async {
        let proof = await PromptContextAuthorizer().authorize(
            testAuthorized(events: [testEvent()]))
        let frame = PromptTemplates.timelineAnalysis(intent: testIntent(), retrieval: proof)
        #expect(!frame.prompt.isEmpty)
    }

    @Test("researchAnalysis overload accepts PromptAuthorizedRetrieval")
    func researchTemplateAcceptsAuthorizedRetrieval() async {
        let proof = await PromptContextAuthorizer().authorize(testAuthorized(chunks: [testChunk()]))
        let frame = PromptTemplates.researchAnalysis(intent: testIntent(), retrieval: proof)
        #expect(!frame.prompt.isEmpty)
    }

    @Test("reasoningAnalysis overload accepts PromptAuthorizedRetrieval")
    func reasoningTemplateAcceptsAuthorizedRetrieval() async {
        let proof = await PromptContextAuthorizer().authorize(testAuthorized(chunks: [testChunk()]))
        let frame = PromptTemplates.reasoningAnalysis(intent: testIntent(), retrieval: proof)
        #expect(!frame.prompt.isEmpty)
    }

    // MARK: - Tests 11-13: structural properties

    @Test("PromptAuthorizedRetrieval carries the correct access context")
    func promptAuthorizedRetrievalCarriesAccessContext() async {
        let wsID = UUID()
        let scope = SensitiveScope(workspaceID: wsID, maximumSensitivity: .confidential,
                                   permitsPrivilegedMaterial: true, purpose: .retrieval)
        let access = SensitiveAccessContext(scope: scope)
        let authorized = AuthorizedRetrievalResult(result: RetrievalResult(), accessContext: access)
        let proof = await PromptContextAuthorizer().authorize(authorized)
        #expect(proof.accessContext.scope.workspaceID == wsID)
        #expect(proof.accessContext.scope.maximumSensitivity == .confidential)
        #expect(proof.accessContext.scope.permitsPrivilegedMaterial)
    }

    @Test("Empty retrieval still produces a PromptFrame with non-empty prompt")
    func emptyRetrievalPromptStillBuilds() async {
        let proof = await PromptContextAuthorizer().authorize(testAuthorized())
        let frame = PromptTemplates.reasoningAnalysis(intent: testIntent(), retrieval: proof)
        #expect(!frame.prompt.isEmpty)
    }

    @Test("Authorized overload builds a PromptFrame that contains the evidence text")
    func authorizedOverloadBuildsCorrectFrame() async {
        // Raw RetrievalResult overloads are now private (OPS-003B correction #2).
        // Only PromptAuthorizedRetrieval overloads are public. Verify the authorized
        // path produces a prompt that includes the supplied evidence.
        let ko = UUID()
        let c = RetrievedChunk(
            chunk: Chunk(objectID: ko, ordinal: 0, text: "evidence text", characterRange: 0..<13),
            score: 1.0, viaLayer: .metadata)
        let retrieval = RetrievalResult(chunks: [c])
        let authorized = AuthorizedRetrievalResult(result: retrieval, accessContext: testAccess())
        let proof = await PromptContextAuthorizer().authorize(authorized)
        let frame = PromptTemplates.reasoningAnalysis(intent: testIntent(), retrieval: proof)
        #expect(frame.prompt.contains("evidence text"))
    }

    // MARK: - Test 14: prompt-time revalidation

    @Test("Authorizer with policy re-runs filter and removes newly-blocked chunk")
    func authorizerWithPolicyRevalidatesOnAuthorize() async throws {
        // Build a real DB + policy so the re-filter is live.
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db)
        let repo = SensitiveScopeRepository(database: db)
        let policy = SensitiveRetrievalPolicy(repository: repo)

        // Seed a KO and assign it restricted sensitivity.
        let fileID = UUID(); let koID = UUID()
        try await db.exec(
            "INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
            [.uuid(fileID), .text("file:///\(fileID)"), .text("text")])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?,?,?,?,?,?);
        """, [.uuid(koID), .uuid(fileID), .text("text"), .text("body"), .real(0), .real(0)])
        _ = try await repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "alice", confirmationID: UUID(), privileged: false),
            reason: nil, at: t0)

        // First retrieval: scope allows restricted → chunk present.
        let permissiveAccess = SensitiveAccessContext(
            scope: SensitiveScope(workspaceID: UUID(), maximumSensitivity: .restricted,
                                  permitsPrivilegedMaterial: false, purpose: .retrieval))
        let chunk = RetrievedChunk(
            chunk: Chunk(objectID: koID, ordinal: 0, text: "secret", characterRange: 0..<6),
            score: 1.0, viaLayer: .metadata)
        let firstFiltered = await policy.filter(
            result: RetrievalResult(chunks: [chunk]),
            access: permissiveAccess)
        #expect(firstFiltered.result.chunks.count == 1, "Chunk should be present before scope downgrade")

        // Simulate scope downgrade: authorizer re-runs policy with a confidential ceiling
        // that no longer allows the restricted KO.
        let restrictedAccess = SensitiveAccessContext(
            scope: SensitiveScope(workspaceID: UUID(), maximumSensitivity: .confidential,
                                  permitsPrivilegedMaterial: false, purpose: .retrieval))
        let staleAuthorized = AuthorizedRetrievalResult(
            result: firstFiltered.result,
            accessContext: restrictedAccess)
        let authorizer = PromptContextAuthorizer(policy: policy)
        let proof = await authorizer.authorize(staleAuthorized)
        // Re-filter with the restricted access must have removed the chunk.
        #expect(proof.retrieval.chunks.isEmpty, "Re-filter must remove chunk blocked by downgraded scope")
    }

    // MARK: - Tests 15-16: ExpertContext.access field

    @Test("ExpertContext.access field is nil by default (backward compatibility)")
    func expertContextAccessNilByDefault() {
        let ctx = ExpertContext(
            retriever: StubRetriever(),
            capabilities: makeTestRegistry()
        )
        #expect(ctx.access == nil)
    }

    @Test("ExpertContext.access field stores the provided SensitiveAccessContext")
    func expertContextAccessFieldStored() {
        let access = testAccess()
        let ctx = ExpertContext(
            retriever: StubRetriever(),
            capabilities: makeTestRegistry(),
            access: access
        )
        #expect(ctx.access?.scope.workspaceID == access.scope.workspaceID)
        #expect(ctx.access?.scope.maximumSensitivity == access.scope.maximumSensitivity)
    }

    // MARK: - Test 17: architecture guard — unscoped retrieval fails closed

    @Test("ExpertContext.retrieveAuthorized throws unscopedRetrieval when no access context is present")
    func unscopedRetrievalThrowsWhenNoAccessContextPresent() async throws {
        // OPS-003B correction #8 — globalPermissive() is removed; retrieveAuthorized
        // must throw SensitiveRetrievalError.unscopedRetrieval rather than bypass
        // the policy when access is nil.
        let ctx = ExpertContext(
            retriever: StubRetriever(),
            capabilities: makeTestRegistry()
        )
        let intent = UserIntent(kind: .factualLookup, scope: .global, rawQuestion: "test")
        await #expect(throws: SensitiveRetrievalError.unscopedRetrieval) {
            _ = try await ctx.retrieveAuthorized(for: intent, layers: [])
        }
    }
}

// MARK: - Helpers (test-only)

private func makeTestRegistry() -> CapabilityRegistry {
    let hw = HardwareProfile(
        totalRAMBytes: 16 * 1_073_741_824,
        availableRAMBytes: 8 * 1_073_741_824,
        processorCount: 8,
        isAppleSilicon: true,
        chipName: "TestChip",
        hasNeuralEngine: true
    )
    let bench = PerformanceBenchmark(hardwareProfile: hw)
    return CapabilityRegistry(hardware: hw, benchmark: bench)
}

private struct StubRetriever: Retriever {
    func retrieve(for intent: UserIntent, layers: [RetrievalLayer]) async throws -> RetrievalResult {
        RetrievalResult()
    }
}
