//
//  TopicConsolidatorTests.swift
//  KalsmritikoshTests
//
//  Owner rule (2026-09-19): topics must be FEW and evidence-backed. A subject
//  with too little context is not a real topic — it folds into its closest
//  substantive subject. These tests pin that behavior.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite struct TopicConsolidatorTests {

    private func fact(_ subject: String, _ field: String, _ value: String) -> GenericFact {
        GenericFact(
            subjectLabel: subject, field: field, value: value,
            assessment: EvidenceAssessment(basis: .directlyObserved, review: .unreviewed, origin: .sourceExtraction),
            confidence: 0.8, sourceBlockIDs: [UUID()])
    }

    private func subjectFacts(_ subject: String, _ pairs: [(String, String)]) -> TopicConsolidator.SubjectFacts {
        TopicConsolidator.SubjectFacts(subject: subject, facts: pairs.map { fact(subject, $0.0, $0.1) })
    }

    @Test("Thin subjects fold into the closest substantive subject — count shrinks")
    func thinFoldsIntoSubstantive() {
        // One rich subject about a patent, one thin fragment sharing its vocabulary.
        let rich = subjectFacts("Acme Patent Application", [
            ("applicant", "Acme Corporation"),
            ("application_number", "US-12345"),
            ("filing_date", "2023-04-01"),
            ("status", "granted"),
            ("examiner", "Jane Roe"),
        ])
        let thin = subjectFacts("Acme patent examiner note", [("note", "examiner queried Acme claim 3")])
        let unrelatedThin = subjectFacts("Weather log", [("temperature", "21C")])

        let out = TopicConsolidator.consolidate([rich, thin, unrelatedThin], minDistinctFacts: 4)

        // Only substantive subjects survive as topics.
        #expect(out.count == 1)
        #expect(out.first?.subject == "Acme Patent Application")
        // The thin fragment's fact was absorbed, not dropped.
        let values = out.first?.facts.map(\.value) ?? []
        #expect(values.contains("examiner queried Acme claim 3"))
        // And the unrelated thin fact is also preserved (folded into the only host).
        #expect(values.contains("21C"))
    }

    @Test("Multiple substantive subjects are all kept; thin routes to the closest by overlap")
    func routesToClosest() {
        let patent = subjectFacts("Patent Matter", [
            ("applicant", "Acme"), ("application_number", "US-1"),
            ("filing_date", "2023-01-01"), ("examiner", "Roe"),
        ])
        let lease = subjectFacts("Lease Agreement", [
            ("landlord", "Baker Estates"), ("tenant", "Acme"),
            ("rent", "5000"), ("term", "36 months"),
        ])
        // Shares vocabulary with the lease (landlord/rent), not the patent.
        let thinLease = subjectFacts("rent reminder", [("rent", "late rent notice to landlord Baker")])

        let out = TopicConsolidator.consolidate([patent, lease, thinLease], minDistinctFacts: 4)

        #expect(out.count == 2)
        let leaseTopic = out.first { $0.subject == "Lease Agreement" }
        #expect(leaseTopic?.facts.map(\.value).contains("late rent notice to landlord Baker") == true)
        let patentTopic = out.first { $0.subject == "Patent Matter" }
        #expect(patentTopic?.facts.map(\.value).contains("late rent notice to landlord Baker") == false)
    }

    @Test("All thin → the single largest becomes the sole topic and absorbs the rest")
    func allThinCollapseToOne() {
        let a = subjectFacts("A", [("x", "1"), ("y", "2")])
        let b = subjectFacts("B", [("z", "3")])
        let out = TopicConsolidator.consolidate([a, b], minDistinctFacts: 4)
        #expect(out.count == 1)
        #expect(out.first?.subject == "A")            // largest by distinct facts
        #expect(out.first?.facts.count == 3)          // absorbed B's fact
    }

    @Test("With several real topics, a thin subject sharing nothing with any of them is not dumped into the largest")
    func unrelatedThinDoesNotPolluteLargest() {
        let schedule = subjectFacts("Final shift schedule", [
            ("shift", "A"), ("shift", "B"), ("operator", "Ravi"), ("operator", "Mina"), ("line", "3"),
        ])
        let patent = subjectFacts("Patent Matter", [
            ("applicant", "Acme"), ("application_number", "US-1"),
            ("filing_date", "2023-01-01"), ("examiner", "Roe"),
        ])
        let unrelated = subjectFacts("Please call me back", [("contact", "8106524242")])
        let out = TopicConsolidator.consolidate([schedule, patent, unrelated], minDistinctFacts: 4)
        #expect(out.count == 2)
        #expect(out.allSatisfy { !$0.facts.map(\.value).contains("8106524242") },
                "no closest topic exists, so it joins none")
    }

    @Test("A single subject passes through untouched")
    func singlePassesThrough() {
        let a = subjectFacts("A", [("x", "1")])
        let out = TopicConsolidator.consolidate([a])
        #expect(out.count == 1)
        #expect(out.first?.subject == "A")
    }
}
