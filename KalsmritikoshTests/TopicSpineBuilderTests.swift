//
//  TopicSpineBuilderTests.swift
//  KalsmritikoshTests
//
//  Topic-Ledger U5 — the deterministic topic spine. One subject's leaf facts +
//  events roll up into ONE topic (MemoryObject) with a structured narrative,
//  distinct values per field, a dated timeline, and the contributing objects —
//  no model, fully deterministic.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("Topic-Ledger U5 — deterministic topic spine")
struct TopicSpineBuilderTests {

    private func fact(_ field: String, _ value: String, unit: String? = nil) -> GenericFact {
        GenericFact(subjectLabel: "Patent 202331019665", field: field, value: value, unit: unit,
                    assessment: EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction),
                    confidence: 0.8, sourceBlockIDs: [UUID()])
    }

    @Test func rollsFactsAndEventsIntoOneTopic() {
        let obj1 = UUID(), obj2 = UUID()
        let facts = [fact("applicant", "Shirshendu Sasmal"),
                     fact("applicationnumber", "202331019665"),
                     fact("applicant", "Shirshendu Sasmal")]   // duplicate value → collapses
        let events = [
            Event(kind: .contractSigned, date: Date(timeIntervalSince1970: 1_700_000_000),
                  title: "FER response filed", sourceObjectID: obj1),
            Event(kind: .contractSigned, date: Date(timeIntervalSince1970: 1_690_000_000),
                  title: "Application filed", sourceObjectID: obj2),
        ]
        let topic = TopicSpineBuilder.build(
            subjectIdentifier: "Patent 202331019665",
            facts: facts, events: events,
            now: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(topic.subjectKind == .topic)
        #expect(topic.narrative.contains("Topic: Patent 202331019665"))
        #expect(topic.narrative.contains("Applicant: Shirshendu Sasmal"))
        #expect(topic.narrative.contains("Applicationnumber: 202331019665"))
        // Duplicate applicant value appears once.
        let occurrences = topic.narrative.components(separatedBy: "Shirshendu Sasmal").count - 1
        #expect(occurrences == 1)
        // Timeline present and chronological (earlier "Application filed" before "FER response filed").
        #expect(topic.narrative.contains("Timeline:"))
        let appIdx = topic.narrative.range(of: "Application filed")!.lowerBound
        let ferIdx = topic.narrative.range(of: "FER response filed")!.lowerBound
        #expect(appIdx < ferIdx)
        // Event ids + contributing objects carried.
        #expect(topic.keyEventIDs.count == 2)
        #expect(Set(topic.sourceObjectIDs) == Set([obj1, obj2]))
    }

    @Test func factsOnlyTopicHasNoTimelineSection() {
        let topic = TopicSpineBuilder.build(
            subjectIdentifier: "X", facts: [fact("role", "Director")], events: [],
            now: Date(timeIntervalSince1970: 1))
        #expect(topic.narrative.contains("Role: Director"))
        #expect(!topic.narrative.contains("Timeline:"))
    }
}
