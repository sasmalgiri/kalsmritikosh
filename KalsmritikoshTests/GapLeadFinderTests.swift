//
//  GapLeadFinderTests.swift
//  Kalsmritikosh Tests
//
//  P4-U2 (B-4) — gap-driven retrieval's laws: budgets hold, known evidence is
//  excluded, an unclosable gap stays honestly open (no lead), and the pass is
//  deterministic.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("P4-U2 — gap-driven leads (B-4)")
struct GapLeadFinderTests {

    private let subjectID = UUID()

    private func gap(_ kind: HistoryGapKind, targets: [String], known: [UUID] = []) -> HistoryGap {
        HistoryGap(kind: kind, subject: .person(subjectID), description: "d",
                   expectedEvidenceTypes: targets,
                   inferenceBasis: known.map { EvidenceReference(objectID: $0) }, confidence: 0.6)
    }

    @Test("Leads surface new candidates; known evidence is excluded; empty hits stay open")
    func leadLaws() async {
        let known = UUID(), fresh1 = UUID(), fresh2 = UUID()
        let gaps = [
            gap(.missingEndDate, targets: ["relieving letter"], known: [known]),
            gap(.silentPeriod, targets: ["correspondence"]),
        ]
        let result = await GapLeadFinder().findLeads(for: gaps) { query in
            query == "relieving letter" ? [known, fresh2, fresh1] : []
        }
        #expect(result.leads.count == 1, "the hitless gap stays honestly open")
        let lead = result.leads[0]
        #expect(lead.gapID == gaps[0].id)
        #expect(!lead.candidateObjectIDs.contains(known), "known evidence is never a lead")
        #expect(lead.candidateObjectIDs.sorted { $0.uuidString < $1.uuidString } == lead.candidateObjectIDs,
                "deterministic candidate order")
        #expect(Set(lead.candidateObjectIDs) == [fresh1, fresh2])
    }

    @Test("Budgets hold: gaps beyond the pass budget are deferred, queries per gap capped")
    func budgets() async {
        let gaps = (0..<12).map { _ in gap(.missingCorroboration, targets: ["a", "b", "c", "d", "e"]) }
        let counter = Counter()
        let result = await GapLeadFinder().findLeads(for: gaps) { _ in
            await counter.increment(); return []
        }
        #expect(result.gapsTried == 10)
        #expect(result.gapsDeferred == 2)
        #expect(await counter.value == 30, "10 gaps × 3 queries max — never 5")
    }

    @Test("Determinism: the same gaps and archive yield the same leads")
    func determinism() async {
        let a = UUID(), b = UUID()
        let gaps = [gap(.missingStartDate, targets: ["joining record", "opening document"])]
        let search: @Sendable (String) async -> [UUID] = { q in q == "joining record" ? [b, a] : [a] }
        let first = await GapLeadFinder().findLeads(for: gaps, search: search).leads
        let second = await GapLeadFinder().findLeads(for: gaps, search: search).leads
        #expect(first == second)
        #expect(first[0].queriesTried == ["joining record", "opening document"])
    }
}

private actor Counter {
    var value = 0
    func increment() { value += 1 }
}
