//
//  SourceScopedRetrieverTests.swift
//  KalsmritikoshTests
//
//  INV-01-B2 Gate 2 — the composition layer. Proves the SourceScopedRetriever decorator applies the case
//  scope ON TOP OF the wrapped retriever's SensitiveScope pass (both dimensions enforced, neither
//  weakened, withheld counts summed), that an inactive scope is a transparent pass-through, that the
//  boundary is fail-closed and never falls back to the workspace, and that the CaseRetrievalScopeResolver
//  maps case bindings to authorized versions with the deliberate version semantics. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("INV-01-B2 — scoped retriever + case resolver")
struct SourceScopedRetrieverTests {

    private let vA = UUID(); private let vB = UUID()
    private let intent = UserIntent(kind: .factualLookup, scope: .global, rawQuestion: "q")

    private func chunk(_ version: UUID?, block: UUID? = nil) -> RetrievedChunk {
        RetrievedChunk(chunk: Chunk(objectID: UUID(), ordinal: 0, text: "t", characterRange: 0..<1,
                                    evidenceBlockID: block, sourceVersionID: version),
                       score: 1, viaLayer: .vector)
    }

    /// A base retriever returning fixed results — stands in for the shared HybridRetriever (which would
    /// already have applied SensitiveScope, reflected here by a non-zero withheld count on the authorized
    /// overload).
    private struct StubRetriever: Retriever {
        let plain: RetrievalResult
        let authorized: AuthorizedRetrievalResult
        func retrieve(for intent: UserIntent, layers: [RetrievalLayer]) async throws -> RetrievalResult { plain }
        func retrieve(for intent: UserIntent, layers: [RetrievalLayer], access: SensitiveAccessContext) async throws -> AuthorizedRetrievalResult { authorized }
    }

    private func evidenceStore() async throws -> EvidenceStore {
        EvidenceStore(database: try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion))
    }

    // MARK: - Decorator composition

    @Test("An inactive scope is a transparent pass-through on the access-aware path")
    func inactivePassThrough() async throws {
        let base = StubRetriever(
            plain: RetrievalResult(chunks: [chunk(vA), chunk(vB)]),
            authorized: AuthorizedRetrievalResult(result: RetrievalResult(chunks: [chunk(vA), chunk(vB)]),
                                                  accessContext: .testUnrestricted(), withheldChunkCount: 2))
        let d = SourceScopedRetriever(base: base, evidence: try await evidenceStore(), scope: .unscoped)
        let out = try await d.retrieve(for: intent, layers: [], access: .testUnrestricted())
        #expect(out.result.chunks.count == 2)
        #expect(out.withheldChunkCount == 2)   // unchanged from the base
    }

    @Test("Case scope composes on top of SensitiveScope: only authorized chunks survive; withheld counts sum")
    func caseScopeOnTopOfSensitive() async throws {
        // Base already withheld 3 by sensitivity; surfaces A (authorized) + B (out of case scope).
        let base = StubRetriever(
            plain: RetrievalResult(),
            authorized: AuthorizedRetrievalResult(result: RetrievalResult(chunks: [chunk(vA), chunk(vB)]),
                                                  accessContext: .testUnrestricted(), withheldChunkCount: 3))
        let d = SourceScopedRetriever(base: base, evidence: try await evidenceStore(), scope: .authorizing([vA]))
        let out = try await d.retrieve(for: intent, layers: [], access: .testUnrestricted())
        #expect(out.result.chunks.map(\.chunk.sourceVersionID) == [vA])   // B excluded by case scope
        #expect(out.withheldChunkCount == 4)                              // 3 sensitivity + 1 case
    }

    @Test("Fail-closed: a chunk with no resolvable source version is excluded, not admitted")
    func failClosedUnresolved() async throws {
        let base = StubRetriever(
            plain: RetrievalResult(),
            authorized: AuthorizedRetrievalResult(result: RetrievalResult(chunks: [chunk(nil, block: nil)]),
                                                  accessContext: .testUnrestricted()))
        let d = SourceScopedRetriever(base: base, evidence: try await evidenceStore(), scope: .authorizing([vA]))
        let out = try await d.retrieve(for: intent, layers: [], access: .testUnrestricted())
        #expect(out.result.chunks.isEmpty)
        #expect(out.withheldChunkCount == 1)
    }

    @Test("An empty authorized set returns an honest empty result — never a widen to the workspace")
    func emptyScopeNoFallback() async throws {
        let base = StubRetriever(
            plain: RetrievalResult(),
            authorized: AuthorizedRetrievalResult(result: RetrievalResult(chunks: [chunk(vA), chunk(vB)]),
                                                  accessContext: .testUnrestricted()))
        let d = SourceScopedRetriever(base: base, evidence: try await evidenceStore(), scope: .authorizing([]))
        let out = try await d.retrieve(for: intent, layers: [], access: .testUnrestricted())
        #expect(out.result.chunks.isEmpty)
    }

    @Test("The bare (non-access) retrieve overload also enforces the case scope")
    func bareOverloadEnforcesScope() async throws {
        let base = StubRetriever(
            plain: RetrievalResult(chunks: [chunk(vA), chunk(vB)]),
            authorized: AuthorizedRetrievalResult(result: RetrievalResult(), accessContext: .testUnrestricted()))
        let d = SourceScopedRetriever(base: base, evidence: try await evidenceStore(), scope: .authorizing([vA]))
        let out = try await d.retrieve(for: intent, layers: [])
        #expect(out.chunks.map(\.chunk.sourceVersionID) == [vA])
    }

    // MARK: - Case resolver (case bindings → authorized versions)

    private func record(_ sources: [InvestigationScopeSource]) -> InvestigationCaseRecord {
        let header = InvestigationCase(id: UUID(), workspaceID: UUID(), title: "C", purpose: nil, scopeStatement: nil,
                                       outOfScopeStatement: nil, timeWindowStart: nil, timeWindowEnd: nil, status: .open,
                                       confirmedDeadlineID: nil, possibleDeadlineNote: nil, revision: 1, actor: "u",
                                       createdAt: Date(timeIntervalSinceReferenceDate: 0), updatedAt: Date(timeIntervalSinceReferenceDate: 0))
        return InvestigationCaseRecord(caseHeader: header, sources: sources, events: [])
    }
    private func binding(_ ref: String, _ kind: InvestigationSourceKind, inScope: Bool) -> InvestigationScopeSource {
        InvestigationScopeSource(id: UUID(), caseID: UUID(), sourceRef: ref, sourceKind: kind, inScope: inScope,
                                 note: nil, createdAt: Date(timeIntervalSinceReferenceDate: 0))
    }

    @Test("A .sourceVersion binding authorizes exactly that version id")
    func resolveExactVersion() async throws {
        let resolver = CaseRetrievalScopeResolver(evidence: try await evidenceStore())
        let scope = try await resolver.scope(for: record([binding(vA.uuidString, .sourceVersion, inScope: true)]))
        #expect(scope.isActive)
        #expect(scope.authorizedSourceVersionIDs == [vA])
    }

    @Test("Excluded and malformed bindings contribute nothing (fail-closed, no widen)")
    func resolveExcludedAndMalformed() async throws {
        let resolver = CaseRetrievalScopeResolver(evidence: try await evidenceStore())
        let scope = try await resolver.scope(for: record([
            binding(vA.uuidString, .sourceVersion, inScope: false),   // excluded → ignored
            binding("not-a-uuid", .sourceVersion, inScope: true),     // malformed → ignored
            binding(UUID().uuidString, .logicalSource, inScope: true) // unknown logical source, empty DB → nil
        ]))
        #expect(scope.isActive)                       // a case is still active…
        #expect(scope.authorizedSourceVersionIDs.isEmpty)   // …but authorizes nothing (honest empty)
    }
}
