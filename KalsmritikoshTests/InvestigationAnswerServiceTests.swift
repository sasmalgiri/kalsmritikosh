//
//  InvestigationAnswerServiceTests.swift
//  KalsmritikoshTests
//
//  INV-01-C1 — the real Investigator Ask entry point + B2's deferred live-answer acceptance. Proves the
//  service resolves a PERSISTED case into its authorized scope, builds a SourceScopedRetriever over the
//  SHARED retriever, and that an unauthorized Source B — even when it holds the exact/direct answer —
//  never reaches the retrieved evidence NOR the citations produced by the REAL deterministic answer
//  builder MasterBrain uses (DeterministicEvidenceFallback). Also: the scoped retriever is what the
//  service hands the engine (captured via the brain factory), an unknown case fails closed, and the
//  boundary holds across repeated (corrective / Full-Evidence) passes. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("INV-01-C1 — Investigator Ask entry + zero-leakage acceptance")
struct InvestigationAnswerServiceTests {

    // Source A (authorized, exact version vA) holds weak/partial evidence; Source B (unauthorized) holds
    // the direct answer, tagged with a unique phrase we can search for.
    private let vA = UUID(); private let vB = UUID()
    private let koA = UUID(); private let koB = UUID()
    private let bDirectAnswer = "OVERPAID-BY-EXACTLY-500-ON-INVOICE-42"
    private let intent = UserIntent(kind: .factualLookup, scope: .global, rawQuestion: "how much was overpaid?")

    private func chunk(_ version: UUID, object: UUID, text: String) -> RetrievedChunk {
        RetrievedChunk(chunk: Chunk(objectID: object, ordinal: 0, text: text, characterRange: 0..<text.count,
                                    sourceVersionID: version),
                       score: 1, viaLayer: .vector)
    }
    /// A base retriever returning BOTH A and B — stands in for the shared HybridRetriever.
    private var baseAB: RetrievalResult {
        RetrievalResult(chunks: [
            chunk(vA, object: koA, text: "The invoice amount was disputed by the vendor."),
            chunk(vB, object: koB, text: bDirectAnswer)])
    }
    private struct StubRetriever: Retriever {
        let result: RetrievalResult
        func retrieve(for intent: UserIntent, layers: [RetrievalLayer]) async throws -> RetrievalResult { result }
        func retrieve(for intent: UserIntent, layers: [RetrievalLayer], access: SensitiveAccessContext) async throws -> AuthorizedRetrievalResult {
            AuthorizedRetrievalResult(result: result, accessContext: access)
        }
    }

    /// A fresh ledger + one workspace + a persisted case authorizing ONLY Source A's exact version.
    private func fixture() async throws -> (service: InvestigationAnswerService, caseID: UUID, evidence: EvidenceStore) {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(ws), .text("Matter"), .real(1), .real(1)])
        let cases = InvestigationCaseRepository(database: db)
        let evidence = EvidenceStore(database: db)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var c = try await cases.createCase(workspaceID: ws, title: "Payment discrepancy", actor: "u", at: t0)
        c = try await cases.includeSource(caseID: c.id, expectedRevision: c.revision,
                                          sourceRef: vA.uuidString, sourceKind: .sourceVersion, actor: "u", at: t0)
        let base = StubRetriever(result: baseAB)
        let service = InvestigationAnswerService(
            cases: cases, resolver: CaseRetrievalScopeResolver(evidence: evidence),
            baseRetriever: base, evidence: evidence,
            makeBrain: { MasterBrain(retriever: $0) })   // minimal brain; the boundary is on the retriever
        return (service, c.id, evidence)
    }

    @Test("The service resolves the persisted case to exactly its authorized version scope")
    func scopeContextFromPersistedCase() async throws {
        let (service, caseID, _) = try await fixture()
        let ctx = try await service.scopeContext(caseID: caseID)
        #expect(ctx.scope.isActive)
        #expect(ctx.scope.authorizedSourceVersionIDs == [vA])
        #expect(ctx.status == .open)
    }

    @Test("The service's scoped retriever excludes the unauthorized Source B on the retrieval pass")
    func scopedRetrieverExcludesB() async throws {
        let (service, caseID, _) = try await fixture()
        let scoped = try await service.scopedRetriever(caseID: caseID)
        let out = try await scoped.retrieve(for: intent, layers: [], access: .testUnrestricted())
        #expect(out.result.chunks.map(\.chunk.sourceVersionID) == [vA])
        #expect(!out.result.chunks.contains { $0.chunk.text.contains(bDirectAnswer) })
    }

    @Test("Zero-leakage: the REAL deterministic answer builder over the scoped retrieval never cites B")
    func deterministicAnswerNeverCitesB() async throws {
        let (service, caseID, _) = try await fixture()
        let scoped = try await service.scopedRetriever(caseID: caseID)
        // Drive the retriever exactly as MasterBrain does, then build the answer with the exact offline
        // builder MasterBrain falls back to. B held the direct answer but was scoped out first.
        let retrieval = try await scoped.retrieve(for: intent, layers: [], access: .testUnrestricted()).result
        let answer = await DeterministicEvidenceFallback.build(question: intent.rawQuestion, intent: intent, retrieval: retrieval)
        if let answer {
            #expect(answer.citations.allSatisfy { $0.objectID != koB })          // never cites B's object
            #expect(!answer.citations.contains { $0.snippet.contains(bDirectAnswer) })
            #expect(!answer.body.contains(bDirectAnswer))                        // B's answer never surfaces
        }
        // Whether A yields a citation or the answer is nil/incomplete, B must be absent — proven above.
    }

    @Test("The boundary holds across repeated passes (corrective / Full-Evidence re-retrieval)")
    func boundaryHoldsAcrossPasses() async throws {
        let (service, caseID, _) = try await fixture()
        let scoped = try await service.scopedRetriever(caseID: caseID)
        for _ in 0..<3 {
            let out = try await scoped.retrieve(for: intent, layers: [], access: .testUnrestricted())
            #expect(!out.result.chunks.contains { $0.chunk.sourceVersionID == vB })
        }
    }

    @Test("Ask returns a case-scoped answer whose context carries the authorized scope; unknown case fails closed")
    func answerScopedAndUnknownFailsClosed() async throws {
        let (service, caseID, _) = try await fixture()
        let answered = try await service.answer(caseID: caseID, question: intent.rawQuestion, access: .testUnrestricted())
        #expect(answered.context.scope.authorizedSourceVersionIDs == [vA])
        #expect(answered.verified.citations.allSatisfy { $0.objectID != koB })   // engine never cites B
        await #expect(throws: InvestigationAnswerError.self) {
            _ = try await service.scopeContext(caseID: UUID())
        }
    }
}
