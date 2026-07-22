//
//  TemporalEventProjectorTests.swift
//  Kalsmritikosh Tests
//
//  Universal History program, Phase 4 (HIST-023). Deterministic projection of
//  material into TemporalClaims + HistoryItems: idempotent (content-hash ids),
//  source references preserved, provenance carried (inferred stays non-assertable),
//  dated events → dated items, dateless facts → undated items (no guessed dates).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("HIST Phase 4 — temporal projection")
struct TemporalEventProjectorTests {

    private let clock = Date(timeIntervalSince1970: 1_700_000_000)

    private func material(subject: UUID, events: [Event] = [], assertions: [Assertion] = [],
                          facts: [GenericFact] = []) -> HistoryMaterial {
        HistoryMaterial(
            subject: ResolvedHistorySubject(subject: .person(subject), displayName: "S",
                                            canonicalEntityID: subject, resolutionConfidence: 1.0),
            events: events, assertions: assertions, genericFacts: facts,
            provenance: MaterialProvenance(canonicalEntityID: subject, eventCount: events.count,
                assertionCount: assertions.count, genericFactCount: facts.count,
                relationshipCount: 0, unscopedSubject: false))
    }

    @Test("Assertion + GenericFact for the same fact merge into one claim; evidence preserved")
    func claimsFromAssertionsAndFacts() {
        let s = UUID(), obj = UUID(), block = UUID()
        let assertion = Assertion(subjectKind: .entity, subjectID: s, predicate: "worked_for",
                                  object: .literal("Orchid Chemicals"), confidence: 0.8,
                                  evidenceObjectIDs: [obj], provenance: .sourceAsserted)
        let fact = GenericFact(subjectID: s, subjectLabel: "S", field: "employer",
                               value: "Orchid Chemicals", status: .sourceAsserted, confidence: 0.7,
                               sourceBlockIDs: [block])
        let projector = TemporalEventProjector(now: clock)
        let claims = projector.projectClaims(from: material(subject: s, assertions: [assertion], facts: [fact]))
        #expect(claims.count == 1)                       // same subject+predicate+object → one claim
        let c = claims[0]
        #expect(c.predicate == "worked_for")
        #expect(c.object == .literal("Orchid Chemicals"))
        #expect(c.status == .sourceAsserted)
        #expect(c.sourceObjectIDs == [obj])              // assertion evidence preserved
        #expect(c.assertionIDs == [assertion.id])
        #expect(c.genericFactIDs == [fact.id])           // fact evidence merged in
    }

    @Test("Projection is idempotent — re-projecting yields the identical claim ids")
    func idempotent() {
        let s = UUID()
        let a = Assertion(subjectKind: .entity, subjectID: s, predicate: "held_role",
                          object: .literal("PPIC Executive"), provenance: .inferred)
        let m = material(subject: s, assertions: [a])
        let projector = TemporalEventProjector(now: clock)
        let first = projector.projectClaims(from: m).map(\.id)
        let second = projector.projectClaims(from: m).map(\.id)
        #expect(first == second)
        #expect(first.count == 1)
        // inferred provenance → inferred status → NOT assertable (model-proposed never canonical).
        #expect(projector.projectClaims(from: m)[0].status.isAssertable == false)
    }

    @Test("A dated event projects to a dated HistoryItem; a dateless claim stays undated")
    func datedVsUndated() {
        let s = UUID(), src = UUID()
        let event = Event(kind: .contractSigned, date: Date(timeIntervalSince1970: 1_100_000_000),
                          title: "MSA signed", entityIDs: [s], sourceObjectID: src,
                          datePrecision: .day)
        let claimOnly = Assertion(subjectKind: .entity, subjectID: s, predicate: "held_role",
                                  object: .literal("Director"), provenance: .sourceAsserted)
        let m = material(subject: s, events: [event], assertions: [claimOnly])
        let projector = TemporalEventProjector(now: clock)
        let claims = projector.projectClaims(from: m)
        let items = projector.projectItems(from: m, claims: claims)

        let eventItem = try! #require(items.first { $0.derivedFrom.contains { $0.kind == .event } })
        #expect(eventItem.kind == .legalMilestone)
        #expect(eventItem.isUndated == false)                 // dated
        #expect(eventItem.evidence.first?.eventID == event.id)

        let claimItem = try! #require(items.first { $0.derivedFrom.contains { $0.kind == .temporalClaim } })
        #expect(claimItem.isUndated == true)                  // dateless → undated, NOT guessed
        #expect(claimItem.kind == .stateStart)                // held_role, no end → stateStart
    }
}
