//
//  CausalLinkStateTests.swift
//  KalsmritikoshTests
//
//  A7.2 — CausalLink.state maps source + supersession to the evidentiary
//  vocabulary, and the rule-based composer hedges causal prose by state
//  (adjacency ≠ established causation). Add to the test target to run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct CausalLinkStateTests {

    private func link(_ source: CausalLinkSource, relation: CausalRelation = .caused,
                      superseded: UUID? = nil, s: UUID, t: UUID) -> CausalLink {
        CausalLink(sourceEventID: s, targetEventID: t, relation: relation,
                   confidence: 0.8, source: source, supersededBy: superseded)
    }

    @Test func stateMapping() {
        let s = UUID(), t = UUID()
        #expect(link(.lexicalTrigger, s: s, t: t).state == .sourceStated)
        #expect(link(.user, s: s, t: t).state == .humanConfirmed)
        #expect(link(.llm, s: s, t: t).state == .modelProposed)
        #expect(link(.heuristic, s: s, t: t).state == .ruleSupported)
        #expect(link(.ontology, s: s, t: t).state == .ruleSupported)
        #expect(link(.lexicalTrigger, superseded: UUID(), s: s, t: t).state == .rejected)
    }

    @Test func sourceStatedRendersAssertively() {
        let a = Event(kind: .deliveryDelayed, date: .init(timeIntervalSince1970: 0), title: "Delay", sourceObjectID: UUID())
        let b = Event(kind: .deliveryCompleted, date: .init(timeIntervalSince1970: 1), title: "Done", sourceObjectID: UUID())
        let l = link(.lexicalTrigger, s: a.id, t: b.id)
        let coda = RuleBasedNarrativeComposer.renderCausalCoda(chapterEvents: [a, b], links: [l], startSentenceIndex: 0)
        #expect(coda?.sentence.contains("caused") == true)
        #expect(coda?.sentence.contains("may have") == false)
    }

    @Test func ruleSupportedRendersTentatively() {
        let a = Event(kind: .deliveryDelayed, date: .init(timeIntervalSince1970: 0), title: "Delay", sourceObjectID: UUID())
        let b = Event(kind: .deliveryCompleted, date: .init(timeIntervalSince1970: 1), title: "Done", sourceObjectID: UUID())
        let l = link(.heuristic, s: a.id, t: b.id)
        let coda = RuleBasedNarrativeComposer.renderCausalCoda(chapterEvents: [a, b], links: [l], startSentenceIndex: 0)
        #expect(coda?.sentence.contains("may have caused") == true)
    }
}
