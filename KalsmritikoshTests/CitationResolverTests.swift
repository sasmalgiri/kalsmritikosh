//
//  CitationResolverTests.swift
//  KalsmritikoshTests
//
//  P1 citation-integrity closure (release gate F3). The canonical citation
//  resolution authority: a citation is valid iff its objectID resolves
//  through one of the APPROVED RETRIEVAL LAYERS (chunk / event /
//  relationship / deterministic evaluation / authority document) — the
//  UNION, never the chunk-score map alone — and, when the ledger probe is
//  wired, the target still exists. Wrong-workspace / SensitiveScope-denied
//  rejection composes by construction: the retrieval handed to the verifier
//  is already scope-filtered, so a real-but-denied objectID is absent from
//  the union and rejected without a ledger round-trip (encoded as a test
//  below: in-ledger but out-of-retrieval → rejected).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("CitationResolver — canonical citation authority union")
struct CitationResolverTests {

    // MARK: fixtures

    private func chunk(_ obj: UUID, score: Double = 1.0, text: String = "passage") -> RetrievedChunk {
        RetrievedChunk(
            chunk: Chunk(objectID: obj, ordinal: 0, text: text,
                         characterRange: 0..<text.count, evidenceBlockID: nil),
            score: score, viaLayer: .metadata)
    }

    private func event(_ id: UUID = UUID(), source: UUID) -> Event {
        Event(id: id, kind: .other, date: Date(timeIntervalSince1970: 1_100_000_000),
              title: "t", sourceObjectID: source)
    }

    private func citation(_ obj: UUID, eventID: UUID? = nil) -> VerifiedAnswer.Citation {
        VerifiedAnswer.Citation(objectID: obj, eventID: eventID, snippet: "s")
    }

    // MARK: valid citations per approved layer

    @Test("Valid chunk-layer citation passes")
    func chunkCitationPasses() async {
        let obj = UUID()
        let retrieval = RetrievalResult(chunks: [chunk(obj)])
        let r = await CitationResolver().resolve([citation(obj)], retrieval: retrieval)
        #expect(r.citations.map(\.objectID) == [obj])
        #expect(r.rejectedObjectIDs.isEmpty)
    }

    @Test("Valid Event-layer citation passes with NO chunk score — the previously rejected unsafe fix would have discarded it")
    func eventCitationPasses() async {
        let source = UUID()
        let ev = event(source: source)
        let retrieval = RetrievalResult(events: [ev])   // no chunks at all
        let r = await CitationResolver().resolve([citation(source, eventID: ev.id)], retrieval: retrieval)
        #expect(r.citations.map(\.objectID) == [source])
        #expect(r.citations.first?.eventID == ev.id)
        #expect(r.rejectedObjectIDs.isEmpty)
        #expect(r.scrubbedEventIDs.isEmpty)
    }

    @Test("Valid Relationship-layer citation passes")
    func relationshipCitationPasses() async {
        let source = UUID()
        let rel = Relationship(kind: .allCases.first!, fromEntityID: UUID(), toEntityID: UUID(),
                               viaEventID: nil, sourceObjectID: source, confidence: .medium)
        let retrieval = RetrievalResult(relationships: [rel])
        let r = await CitationResolver().resolve([citation(source)], retrieval: retrieval)
        #expect(r.citations.map(\.objectID) == [source])
    }

    @Test("Valid deterministic-evaluation (typed-field GenericFact) citation passes")
    func claimEvaluationCitationPasses() async {
        let obj = UUID(), blk = UUID()
        let facts = [GenericFact(subjectLabel: "r", field: "amount", value: "₹1",
                                 status: .sourceAsserted, confidence: 0.9, sourceBlockIDs: [blk])]
        // Route the evidence through the real evaluator so the evaluation's
        // evidence objectID mapping is the production one.
        let evaluations = ClaimEvaluator.evaluate(
            facts: facts,
            chunks: [RetrievedChunk(
                chunk: Chunk(objectID: obj, ordinal: 0, text: "Amount ₹1 paid.",
                             characterRange: 0..<14, evidenceBlockID: blk),
                score: 1.0, viaLayer: .metadata)])
        let retrieval = RetrievalResult(claimEvaluations: evaluations)
        let r = await CitationResolver().resolve([citation(obj)], retrieval: retrieval)
        #expect(r.citations.map(\.objectID) == [obj])
    }

    @Test("Valid authority-document citation passes (RET-009 list, no chunk hit)")
    func authorityCitationPasses() async {
        let authority = UUID()
        let retrieval = RetrievalResult(authorityObjectIDs: [authority])
        let r = await CitationResolver().resolve([citation(authority)], retrieval: retrieval)
        #expect(r.citations.map(\.objectID) == [authority])
    }

    // MARK: rejections

    @Test("Fake/nonexistent objectID resolves through no layer and is rejected")
    func fakeObjectIDRejected() async {
        let obj = UUID(), fake = UUID()
        let retrieval = RetrievalResult(chunks: [chunk(obj)])
        let r = await CitationResolver().resolve([citation(fake)], retrieval: retrieval)
        #expect(r.citations.isEmpty)
        #expect(r.rejectedObjectIDs == [fake])
    }

    @Test("In-ledger but outside the scope-filtered retrieval → rejected (wrong-workspace / SensitiveScope-denied semantics)")
    func scopeDeniedRejectedDespiteLedgerExistence() async {
        let inScope = UUID(), deniedButReal = UUID()
        let retrieval = RetrievalResult(chunks: [chunk(inScope)])
        // Ledger says BOTH exist — the union must still reject the one the
        // scope-filtered retrieval never returned.
        let resolver = CitationResolver(ledgerObjectProbe: { ids in ids })
        let r = await resolver.resolve(
            [citation(inScope), citation(deniedButReal)], retrieval: retrieval)
        #expect(r.citations.map(\.objectID) == [inScope])
        #expect(r.rejectedObjectIDs == [deniedButReal])
    }

    @Test("Deleted/broken target rejected — in the union but gone from the ledger")
    func deletedTargetRejected() async {
        let alive = UUID(), deleted = UUID()
        let retrieval = RetrievalResult(chunks: [chunk(alive), chunk(deleted)])
        let resolver = CitationResolver(ledgerObjectProbe: { ids in
            ids.subtracting([deleted])
        })
        let r = await resolver.resolve(
            [citation(alive), citation(deleted)], retrieval: retrieval)
        #expect(r.citations.map(\.objectID) == [alive])
        #expect(r.rejectedObjectIDs == [deleted])
    }

    @Test("Mixed valid+invalid: invalid dropped, valid kept, order preserved")
    func mixedListFiltered() async {
        let a = UUID(), b = UUID(), fake1 = UUID(), fake2 = UUID()
        let retrieval = RetrievalResult(chunks: [chunk(a), chunk(b)])
        let r = await CitationResolver().resolve(
            [citation(fake1), citation(a), citation(fake2), citation(b)],
            retrieval: retrieval)
        #expect(r.citations.map(\.objectID) == [a, b])
        #expect(Set(r.rejectedObjectIDs) == [fake1, fake2])
    }

    // MARK: eventID annotation integrity

    @Test("Phantom eventID is scrubbed while the citation survives on its objectID authority")
    func phantomEventIDScrubbed() async {
        let obj = UUID(), phantomEvent = UUID()
        let retrieval = RetrievalResult(chunks: [chunk(obj)])
        let r = await CitationResolver().resolve(
            [citation(obj, eventID: phantomEvent)], retrieval: retrieval)
        #expect(r.citations.map(\.objectID) == [obj])
        #expect(r.citations.first?.eventID == nil)
        #expect(r.scrubbedEventIDs == [phantomEvent])
    }

    @Test("eventID proven by the ledger probe survives even when the event was not in this retrieval")
    func ledgerProvenEventIDSurvives() async {
        let obj = UUID(), persistedEvent = UUID()
        let retrieval = RetrievalResult(chunks: [chunk(obj)])
        let resolver = CitationResolver(ledgerEventProbe: { ids in
            ids.intersection([persistedEvent])
        })
        let r = await resolver.resolve(
            [citation(obj, eventID: persistedEvent)], retrieval: retrieval)
        #expect(r.citations.first?.eventID == persistedEvent)
        #expect(r.scrubbedEventIDs.isEmpty)
    }
}

@Suite("EvidenceVerifier + CitationResolver integration")
struct EvidenceVerifierCitationIntegrationTests {

    private func chunk(_ obj: UUID, score: Double = 1.0) -> RetrievedChunk {
        RetrievedChunk(
            chunk: Chunk(objectID: obj, ordinal: 0, text: "the passage text",
                         characterRange: 0..<16, evidenceBlockID: nil),
            score: score, viaLayer: .metadata)
    }

    private let intent = UserIntent(kind: .factualLookup, scope: .global, rawQuestion: "q")

    private func verifier() -> EvidenceVerifier {
        EvidenceVerifier(
            minimumConfidence: Confidence(0.0),
            answerabilityMinRetrievalScore: 0,
            citationResolver: CitationResolver()
        )
    }

    private func findings(citing ids: [UUID], eventIDs: [UUID] = []) -> [ExpertFindings] {
        [ExpertFindings(
            expertID: "test",
            claims: [ExpertFindings.Claim(
                statement: "claim statement",
                supportingObjectIDs: ids,
                supportingEventIDs: eventIDs,
                confidence: .high)],
            confidence: .high)]
    }

    @Test("An answer whose citations ALL fail canonical resolution refuses with the phantom reason")
    func allPhantomRefuses() async throws {
        let real = UUID(), phantom = UUID()
        // Retrieval contains a real chunk (passes answerability) but the
        // claim cites a fabricated objectID that no layer returned.
        let retrieval = RetrievalResult(chunks: [chunk(real)])
        let answer = try await verifier().verify(
            intent: intent, findings: findings(citing: [phantom]), retrieval: retrieval)
        #expect(answer.refused)
        #expect(answer.citations.isEmpty)
        #expect(answer.refusalReason?.contains("phantom") == true)
    }

    @Test("Event-layer citation ships — the verifier must NOT discard citations that merely lack a chunk score")
    func eventLayerCitationShips() async throws {
        let source = UUID()
        let ev = Event(kind: .other, date: Date(timeIntervalSince1970: 1_100_000_000),
                       title: "t", sourceObjectID: source)
        // One unrelated chunk passes the answerability floor; the claim's
        // citation resolves through the EVENT layer only.
        let unrelated = UUID()
        let retrieval = RetrievalResult(chunks: [chunk(unrelated)], events: [ev])
        let answer = try await verifier().verify(
            intent: intent,
            findings: findings(citing: [source], eventIDs: [ev.id]),
            retrieval: retrieval)
        #expect(!answer.refused)
        #expect(answer.citations.map(\.objectID) == [source])
        #expect(answer.citations.first?.eventID == ev.id)
    }

    @Test("Mixed claim: phantom citation dropped, ledger-real one ships")
    func mixedClaimShipsOnlyReal() async throws {
        let real = UUID(), phantom = UUID()
        let retrieval = RetrievalResult(chunks: [chunk(real)])
        let answer = try await verifier().verify(
            intent: intent, findings: findings(citing: [real, phantom]), retrieval: retrieval)
        #expect(!answer.refused)
        #expect(answer.citations.map(\.objectID) == [real])
    }

    @Test("Nil resolver preserves pre-P1 behavior (regression guard for legacy fixtures)")
    func nilResolverUnchanged() async throws {
        let phantom = UUID(), real = UUID()
        let legacy = EvidenceVerifier(minimumConfidence: Confidence(0.0),
                                      answerabilityMinRetrievalScore: 0)
        let retrieval = RetrievalResult(chunks: [chunk(real)])
        let answer = try await legacy.verify(
            intent: intent, findings: findings(citing: [phantom]), retrieval: retrieval)
        // Pre-P1: the phantom citation shipped (sorted last, never validated).
        #expect(answer.citations.map(\.objectID) == [phantom])
    }
}
