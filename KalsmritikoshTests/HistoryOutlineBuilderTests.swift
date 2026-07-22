//
//  HistoryOutlineBuilderTests.swift
//  Kalsmritikosh Tests
//
//  Universal History program, Phase 5 (HIST-051). The deterministic outline is
//  COMPLETE — every projected item appears and is chaptered (the Phase-5 release
//  gate) — dated items group into period chapters, undated material keeps its own
//  chapter (never a guessed position), and the build is deterministic.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("HIST Phase 5 — deterministic outline")
struct HistoryOutlineBuilderTests {

    private let clock = Date(timeIntervalSince1970: 1_700_000_000)

    private func material(subject: UUID, events: [Event], assertions: [Assertion]) -> HistoryMaterial {
        HistoryMaterial(
            subject: ResolvedHistorySubject(subject: .person(subject), displayName: "S",
                                            canonicalEntityID: subject, resolutionConfidence: 1.0),
            events: events, assertions: assertions,
            provenance: MaterialProvenance(canonicalEntityID: subject, eventCount: events.count,
                assertionCount: assertions.count, genericFactCount: 0, relationshipCount: 0,
                unscopedSubject: false))
    }

    @Test("Outline is complete + chaptered; dated years + undated chapter; deterministic")
    func completeAndChaptered() {
        let s = UUID(), src = UUID()
        let e2004 = Event(kind: .contractSigned, date: Date(timeIntervalSince1970: 1_072_915_200), // 2004
                          title: "MSA signed", entityIDs: [s], sourceObjectID: src, datePrecision: .day)
        let e2006 = Event(kind: .invoicePaid, date: Date(timeIntervalSince1970: 1_136_073_600),   // 2006
                          title: "Invoice paid", entityIDs: [s], sourceObjectID: src, datePrecision: .day)
        let undatedRole = Assertion(subjectKind: .entity, subjectID: s, predicate: "held_role",
                                    object: .literal("Director"), provenance: .sourceAsserted)
        let m = material(subject: s, events: [e2004, e2006], assertions: [undatedRole])

        let projector = TemporalEventProjector(now: clock)
        let claims = projector.projectClaims(from: m)
        let items = projector.projectItems(from: m, claims: claims)
        let builder = HistoryOutlineBuilder()
        let outline = builder.build(material: m, items: items)

        // COMPLETENESS gate: every projected item is present and chaptered exactly once.
        #expect(outline.items.count == items.count)
        #expect(outline.everyItemChaptered)

        // Two dated year chapters + one undated chapter.
        let titles = outline.chapters.map(\.title)
        #expect(titles.contains("2004"))
        #expect(titles.contains("2006"))
        #expect(titles.contains("Undated material"))
        #expect(outline.chapters.last?.title == "Undated material")   // undated is last

        // Coverage separates dated / undated (never one vague score).
        #expect(outline.coverage.datedItems == 2)
        #expect(outline.coverage.undatedItems == 1)
        #expect(outline.coverage.eventCount == 2)
        #expect(outline.coverage.earliest != nil)

        // Deterministic: rebuild yields identical chapter titles + ordering.
        let again = builder.build(material: m, items: items)
        #expect(again.chapters.map(\.title) == titles)
        #expect(again.items.map(\.id) == outline.items.map(\.id))
    }
}
