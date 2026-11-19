//
//  CaseBriefHandoverTests.swift
//  KalsmritikoshTests
//
//  Case plan 2026-11-16 (BRIEF-09, BRIEF-10): the brief also says what rests on an assumption, what has not been checked,
//  which checks are completed and what would justify reopening each decision, and gives one honest outcome line —
//  "Inconclusive on the available evidence." when no question has a recorded decision.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Brief — assumptions, unchecked material, completed checks, reopening and the honest outcome")
struct CaseBriefHandoverTests {

    @Test("Each new section holds what it should, and the outcome follows the recorded decisions")
    func sectionsAndOutcome() {
        let c = UUID()
        let caseNode = S3Synth.node(c, .caseFile, c.uuidString, .question, "Case")
        let decidedNoSource = S3Synth.node(c, .allegation, "a1", .question, "A1 — paid twice", review: .confirmed)
        let decidedSourced = S3Synth.node(c, .allegation, "a3", .question, "A3 — invoice issued", review: .confirmed, sources: 2)
        let open = S3Synth.node(c, .allegation, "a2", .question, "A2 — refund", review: .unreviewed)
        let note = S3Synth.node(c, .journal, "e1", .event, "A note only", status: CaseMapStatus(.unsupported, "no source"))
        let unassessed = S3Synth.node(c, .journal, "e2", .event, "Bank line", status: CaseMapStatus(.unassessed, "x"))
        let done = S3Synth.node(c, .task, "t1", .action, "Get statements", workOpen: false)
        let p = S3Synth.projection(c, [caseNode, decidedNoSource, decidedSourced, open, note, unassessed, done],
                                   [S3Synth.link(c, .supports, unassessed.id, decidedSourced.id)])
        let b = CaseMapBrief.compute(p)
        #expect(Set(b.section("assumptions")?.entries.map(\.node) ?? []) == [decidedNoSource.id, note.id], "\(b.section("assumptions")?.entries.map(\.text) ?? [])")
        let unchecked = Set(b.section("unchecked")?.entries.map(\.node) ?? [])
        #expect(unchecked.contains(open.id) && unchecked.contains(unassessed.id) && !unchecked.contains(decidedSourced.id))
        #expect(b.section("completed")?.entries.map(\.node) == [done.id])
        let reopen = b.section("reopen")?.entries ?? []
        #expect(Set(reopen.map(\.node)) == [decidedNoSource.id, decidedSourced.id])
        #expect(reopen.first { $0.node == decidedSourced.id }?.why.contains("a source it cites changes") == true)
        #expect(b.outcome == "2 of 3 question(s) have a recorded decision; the others are inconclusive on the available evidence.", "\(b.outcome)")
        #expect(b.allEntries.allSatisfy { p.node($0.node) != nil && !$0.why.isEmpty })
    }

    @Test("No decision at all: 'Inconclusive on the available evidence.'; no question: nothing to conclude")
    func inconclusive() {
        let c = UUID()
        let caseNode = S3Synth.node(c, .caseFile, c.uuidString, .question, "Case")
        let q = S3Synth.node(c, .allegation, "a1", .question, "Was the batch contaminated?", review: .unreviewed)
        let b = CaseMapBrief.compute(S3Synth.projection(c, [caseNode, q], []))
        #expect(b.outcome.hasPrefix("Inconclusive on the available evidence."))
        #expect(b.section("reopen")?.entries.isEmpty == true && b.section("reopen")?.empty.isEmpty == false)
        #expect(CaseMapBrief.compute(S3Synth.projection(c, [caseNode], [])).outcome.contains("nothing to conclude"))
    }
}
