//
//  SessionFeatureTests.swift
//  KalsmritikoshTests
//
//  Unit tests for the evidence-ledger + UI-parity work: persisted EventStatus
//  (T16), the FactStatus classifier + review overlay (T14/T17), the ported
//  logistics table mapper (ocr-table-pipeline), and Guide/Home content
//  integrity. Pure logic — no database, no LLM. Verified passing via the
//  snippet runner before being committed here.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("Session features — evidence ledger + UI parity")
struct SessionFeatureTests {

    // MARK: EventStatus.derive (T16)

    @Test("derive: T1 + high confidence + trusted date → observed")
    func deriveObserved() {
        #expect(EventStatus.derive(qualityTier: .t1, dateConfidence: 0.9, contentConfidence: 0.9, kind: .emailSent) == .observed)
    }

    @Test("derive: below the trust floor → unsupported")
    func deriveUnsupported() {
        #expect(EventStatus.derive(qualityTier: .t2, dateConfidence: 0.2, contentConfidence: 0.1, kind: .other) == .unsupported)
    }

    @Test("derive: weak date but solid content → derived")
    func deriveDerived() {
        #expect(EventStatus.derive(qualityTier: .t2, dateConfidence: 0.3, contentConfidence: 0.7, kind: .meetingHeld) == .derived)
    }

    @Test("derive: otherwise → inferred")
    func deriveInferred() {
        #expect(EventStatus.derive(qualityTier: .t2, dateConfidence: 0.9, contentConfidence: 0.7, kind: .meetingHeld) == .inferred)
    }

    // MARK: FactStatusClassifier.map — §13 → UI status (T16)

    @Test("map: persisted status → UI status")
    func mapStatuses() {
        #expect(FactStatusClassifier.map(.observed, dateConfidence: 0.9).0 == .proven)
        #expect(FactStatusClassifier.map(.derived, dateConfidence: 0.3).0 == .inferred)
        #expect(FactStatusClassifier.map(.inferred, dateConfidence: 0.9).0 == .inferred)
        #expect(FactStatusClassifier.map(.asserted, dateConfidence: 0.9).0 == .inferred)
        #expect(FactStatusClassifier.map(.unsupported, dateConfidence: 0.3).0 == .unverified)
        #expect(FactStatusClassifier.map(.reviewed, dateConfidence: 0.3).0 == .proven)
        #expect(FactStatusClassifier.map(.rejected, dateConfidence: 0.3).0 == .unverified)
    }

    // MARK: Classifier + review overlay (T14/T17)

    private func observedEvent() -> Event {
        Event(kind: .emailSent, date: Date(timeIntervalSince1970: 1_700_000_000),
              title: "Test", sourceObjectID: UUID(), confidence: .high,
              dateConfidence: 0.9, qualityTier: .t1, status: .observed)
    }

    @Test("classify: an observed event surfaces as a Proven item")
    func classifyObserved() {
        let items = FactStatusClassifier().classify(events: [observedEvent()], assertions: [], contradictions: [], gaps: [])
        #expect(items.count == 1)
        #expect(items.first?.status == .proven)
    }

    @Test("review overlay: reject demotes to Unverified (kept, not deleted)")
    func reviewRejectOverlay() {
        let ev = observedEvent()
        let review = FactReview(subjectKind: .event, subjectID: ev.id, action: .reject, reason: "test")
        let items = FactStatusClassifier().classify(
            events: [ev], assertions: [], contradictions: [], gaps: [], reviews: [ev.id: review])
        #expect(items.first?.status == .unverified)
    }

    @Test("review overlay: accept confirms as Proven")
    func reviewAcceptOverlay() {
        let ev = Event(kind: .meetingHeld, date: Date(timeIntervalSince1970: 1_700_000_000),
                       title: "Meeting", sourceObjectID: UUID(), confidence: .medium,
                       dateConfidence: 0.3, qualityTier: .t2, status: .inferred)
        let review = FactReview(subjectKind: .event, subjectID: ev.id, action: .accept)
        let items = FactStatusClassifier().classify(
            events: [ev], assertions: [], contradictions: [], gaps: [], reviews: [ev.id: review])
        #expect(items.first?.status == .proven)
    }

    // MARK: Logistics table mapper (ocr-table-pipeline port)

    @Test("logistics mapper: Type-2 detection + merged-column forward-fill")
    func logisticsType2ForwardFill() {
        let grid = [
            ["Uhrzeit", "Gleis", "Anzahl", "Waggons", "Station", "Abr.", "Halle", "Datum", "Uhrzeit_DB", "Begruendung"],
            ["08:00", "3", "2", "12", "Delhi", "A", "H1", "2026-07-01", "09:00", "late"],
            ["", "4", "1", "6", "Mumbai", "B", "H2", "", "", ""]
        ]
        let mapped = LogisticsTableMapper.map(grid)
        #expect(mapped != nil)
        #expect(mapped?.kind == .type2)
        #expect(mapped?.rows.count == 2)              // header row dropped
        #expect(mapped?.rows[1][0] == "08:00")        // merged Uhrzeit forward-filled
        #expect(mapped?.rows[1][8] == "09:00")        // merged Uhrzeit_DB forward-filled
    }

    @Test("logistics mapper: unknown column count → nil (not a logistics sheet)")
    func logisticsNonMatch() {
        #expect(LogisticsTableMapper.map([["a", "b", "c"]]) == nil)
    }

    // MARK: Guide / Home content integrity (UI parity)

    @Test("guide content: exactly 5 personas, each with examples + key screens")
    func personaIntegrity() {
        #expect(GuideContent.personas.count == 5)
        for p in GuideContent.personas {
            #expect(!p.examples.isEmpty)
            #expect(!p.keyScreens.isEmpty)
        }
    }

    @Test("guide content: screen guides cover the core surfaces")
    func screenGuideCoverage() {
        let dests = Set(GuideContent.screenGuides.map(\.dest))
        #expect(dests.contains(.ask))
        #expect(dests.contains(.findings))
        #expect(dests.contains(.sources))
        #expect(GuideContent.screenGuides.count >= 10)
    }
}
