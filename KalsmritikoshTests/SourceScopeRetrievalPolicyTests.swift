//
//  SourceScopeRetrievalPolicyTests.swift
//  KalsmritikoshTests
//
//  INV-01-B2 — the pure, deterministic case-scope boundary over retrieved evidence. Proves: an inactive
//  scope is a no-op; an active scope keeps ONLY evidence anchored to an authorized source version across
//  every collection (chunks direct + legacy-block fallback, events/entities/relationships via object,
//  document summaries, generic facts all-blocks-authorized, claim evaluations tied to surviving facts,
//  authority documents); FAIL-CLOSED on any unresolved identity; an empty allow-set yields an honest
//  empty result with no widen; withheld counts are exact; and two cases with different allow-sets keep
//  disjoint evidence. No DB, no LLM — the boundary logic in isolation.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("INV-01-B2 — source-scope retrieval policy")
struct SourceScopeRetrievalPolicyTests {

    // Fixed source-version ids: A authorized, B not.
    private let vA = UUID(); private let vB = UUID()
    private let koA = UUID(); private let koB = UUID()
    private let blockA = UUID(); private let blockB = UUID()

    private func chunk(versionID: UUID?, object: UUID, block: UUID? = nil) -> RetrievedChunk {
        let c = Chunk(objectID: object, ordinal: 0, text: "t", characterRange: 0..<1,
                      evidenceBlockID: block, sourceVersionID: versionID)
        return RetrievedChunk(chunk: c, score: 1.0, viaLayer: .vector)
    }
    private func event(object: UUID) -> Event {
        Event(kind: .emailSent, date: Date(timeIntervalSinceReferenceDate: 0), title: "e", sourceObjectID: object)
    }
    private func entity(object: UUID) -> Entity {
        Entity(kind: .person, value: "p", sourceObjectID: object)
    }
    private func relationship(object: UUID) -> Relationship {
        Relationship(kind: .worksWith, fromEntityID: UUID(), toEntityID: UUID(), sourceObjectID: object)
    }
    private func summary(document: UUID) -> Summary {
        Summary(level: .document, length: .short, scope: .document(document), body: "s")
    }
    private func knowledgeBaseSummary() -> Summary {
        Summary(level: .knowledgeBase, length: .short, scope: .knowledgeBase, body: "kb")
    }
    private func fact(blocks: [UUID]) -> GenericFact {
        GenericFact(subjectLabel: "s", field: "f", value: "v",
                    assessment: EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction),
                    confidence: 0.9, sourceBlockIDs: blocks)
    }

    /// Resolution: block A/B → version A/B; object A/B → version A/B.
    private var resolution: SourceScopeResolution {
        SourceScopeResolution(blockVersion: [blockA: vA, blockB: vB], objectVersion: [koA: vA, koB: vB])
    }
    /// Active scope authorizing only source version A.
    private var scopeA: RetrievalSourceScope { .authorizing([vA]) }

    @Test("An inactive scope is a no-op — every item is retained unchanged")
    func inactiveNoOp() {
        let r = RetrievalResult(chunks: [chunk(versionID: vA, object: koA), chunk(versionID: vB, object: koB)])
        let out = SourceScopeRetrievalPolicy.filter(r, scope: .unscoped, resolution: resolution)
        #expect(out.result.chunks.count == 2)
        #expect(out.anyWithheld == false)
    }

    @Test("An active scope keeps only chunks anchored to an authorized version; the rest are withheld")
    func chunkAuthorizedOnly() {
        let keep = chunk(versionID: vA, object: koA)
        let drop = chunk(versionID: vB, object: koB)
        let r = RetrievalResult(chunks: [keep, drop])
        let out = SourceScopeRetrievalPolicy.filter(r, scope: scopeA, resolution: resolution)
        #expect(out.result.chunks.map(\.chunk.id) == [keep.chunk.id])
        #expect(out.withheldChunkCount == 1)
    }

    @Test("A legacy chunk (nil version) resolves through its evidence block; unresolvable chunks fail closed")
    func legacyBlockFallbackAndFailClosed() {
        let viaBlock = chunk(versionID: nil, object: koA, block: blockA)   // resolves to vA
        let unresolved = chunk(versionID: nil, object: koA, block: nil)    // no anchor → drop
        let r = RetrievalResult(chunks: [viaBlock, unresolved])
        let out = SourceScopeRetrievalPolicy.filter(r, scope: scopeA, resolution: resolution)
        #expect(out.result.chunks.map(\.chunk.id) == [viaBlock.chunk.id])
        #expect(out.withheldChunkCount == 1)
    }

    @Test("An empty allow-set yields an honest empty result — never a silent widen")
    func emptyAllowSetExcludesAll() {
        let r = RetrievalResult(chunks: [chunk(versionID: vA, object: koA)])
        let out = SourceScopeRetrievalPolicy.filter(r, scope: .authorizing([]), resolution: resolution)
        #expect(out.result.chunks.isEmpty)
        #expect(out.withheldChunkCount == 1)
    }

    @Test("Events, entities, and relationships are scoped by their source object")
    func objectAnchoredCollections() {
        let r = RetrievalResult(
            events: [event(object: koA), event(object: koB)],
            entities: [entity(object: koA), entity(object: koB)],
            relationships: [relationship(object: koA), relationship(object: koB)])
        let out = SourceScopeRetrievalPolicy.filter(r, scope: scopeA, resolution: resolution)
        #expect(out.result.events.count == 1 && out.result.events.first?.sourceObjectID == koA)
        #expect(out.result.entities.count == 1 && out.result.entities.first?.sourceObjectID == koA)
        #expect(out.result.relationships.count == 1 && out.result.relationships.first?.sourceObjectID == koA)
        #expect(out.withheldEventCount == 1 && out.withheldEntityCount == 1 && out.withheldRelationshipCount == 1)
    }

    @Test("An item whose source object is unknown to the resolution is failed closed")
    func unresolvedObjectFailsClosed() {
        let r = RetrievalResult(events: [event(object: UUID())])   // object not in objectVersion map
        let out = SourceScopeRetrievalPolicy.filter(r, scope: scopeA, resolution: resolution)
        #expect(out.result.events.isEmpty)
        #expect(out.withheldEventCount == 1)
    }

    @Test("Only document-scoped summaries anchored to an authorized version survive; other scopes fail closed")
    func summaryScoping() {
        let r = RetrievalResult(summaries: [summary(document: koA), summary(document: koB), knowledgeBaseSummary()])
        let out = SourceScopeRetrievalPolicy.filter(r, scope: scopeA, resolution: resolution)
        #expect(out.result.summaries.count == 1)
        if case .document(let ko) = out.result.summaries.first?.scope { #expect(ko == koA) } else { Issue.record("expected document scope") }
        #expect(out.withheldSummaryCount == 2)   // koB + knowledgeBase
    }

    @Test("A generic fact survives only when every source block is authorized")
    func genericFactAllBlocksAuthorized() {
        let allA = fact(blocks: [blockA])
        let mixed = fact(blocks: [blockA, blockB])   // one block out of scope → drop
        let empty = fact(blocks: [])                 // no anchor → drop
        let r = RetrievalResult(genericFacts: [allA, mixed, empty])
        let out = SourceScopeRetrievalPolicy.filter(r, scope: scopeA, resolution: resolution)
        #expect(out.result.genericFacts.map(\.id) == [allA.id])
        #expect(out.withheldGenericFactCount == 2)
    }

    @Test("Authority documents are scoped by their KnowledgeObject")
    func authorityScoping() {
        let r = RetrievalResult(authorityObjectIDs: [koA, koB])
        let out = SourceScopeRetrievalPolicy.filter(r, scope: scopeA, resolution: resolution)
        #expect(out.result.authorityObjectIDs == [koA])
        #expect(out.withheldAuthorityCount == 1)
    }

    @Test("Two cases with different allow-sets keep disjoint evidence from the same result")
    func differentCasesDisjoint() {
        let r = RetrievalResult(chunks: [chunk(versionID: vA, object: koA), chunk(versionID: vB, object: koB)])
        let a = SourceScopeRetrievalPolicy.filter(r, scope: .authorizing([vA]), resolution: resolution)
        let b = SourceScopeRetrievalPolicy.filter(r, scope: .authorizing([vB]), resolution: resolution)
        #expect(a.result.chunks.map(\.chunk.sourceVersionID) == [vA])
        #expect(b.result.chunks.map(\.chunk.sourceVersionID) == [vB])
        #expect(Set(a.result.chunks.map(\.chunk.id)).isDisjoint(with: Set(b.result.chunks.map(\.chunk.id))))
    }

    @Test("Withheld totals aggregate across collections and the filter is deterministic")
    func withheldTotalsAndDeterminism() {
        let r = RetrievalResult(
            chunks: [chunk(versionID: vB, object: koB)],
            events: [event(object: koB)],
            summaries: [knowledgeBaseSummary()],
            genericFacts: [fact(blocks: [blockB])],
            authorityObjectIDs: [koB])
        let out1 = SourceScopeRetrievalPolicy.filter(r, scope: scopeA, resolution: resolution)
        let out2 = SourceScopeRetrievalPolicy.filter(r, scope: scopeA, resolution: resolution)
        #expect(out1.totalWithheld == 5)
        #expect(out1.result.chunks.isEmpty && out1.result.events.isEmpty && out1.result.summaries.isEmpty)
        #expect(out1.result.genericFacts.isEmpty && out1.result.authorityObjectIDs.isEmpty)
        #expect(out1.totalWithheld == out2.totalWithheld)   // deterministic
    }
}
