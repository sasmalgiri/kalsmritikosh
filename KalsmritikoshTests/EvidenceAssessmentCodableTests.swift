//
//  EvidenceAssessmentCodableTests.swift
//  Kalsmritikosh Tests
//
//  S0.5 item 2, Commit C (Codable compatibility). Swapping the stored property from
//  `status`/`evidenceStatus` to `assessment` changed the synthesized Codable key. These
//  tests prove pre-change JSON (which had only the legacy key) still decodes via the
//  fallback, that new JSON dual-encodes BOTH keys and reopens with the full assessment,
//  and that a payload with neither representation fails loudly.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("S0.5 item 2 C — backward-compatible Codable")
struct EvidenceAssessmentCodableTests {

    private let enc = JSONEncoder()
    private let dec = JSONDecoder()

    /// Strip the canonical `assessment` key to synthesise a genuine PRE-CHANGE payload
    /// (which had only the legacy status key) while keeping every other field validly
    /// encoded — used for the enum-bearing types (subject / object) that are impractical
    /// to hand-write.
    private func legacyShaped(_ data: Data) throws -> Data {
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        obj.removeValue(forKey: "assessment")
        return try JSONSerialization.data(withJSONObject: obj)
    }

    // MARK: GenericFact

    @Test("A hand-frozen pre-change GenericFact JSON (status only) decodes via fallback")
    func genericFactFrozenLegacyJSON() throws {
        let json = """
        {"id":"11111111-1111-1111-1111-111111111111","subjectLabel":"S","field":"employer",
         "value":"Orchid Chemicals","status":"SOURCE_ASSERTED","confidence":0.7,
         "sourceBlockIDs":["22222222-2222-2222-2222-222222222222"]}
        """.data(using: .utf8)!
        let fact = try dec.decode(GenericFact.self, from: json)
        #expect(fact.assessment.basis == .sourceAsserted)
        #expect(fact.assessment.legacyStatus == .sourceAsserted)
        #expect(fact.subjectLabel == "S")
        #expect(fact.sourceBlockIDs.count == 1)
    }

    @Test("New GenericFact JSON dual-encodes assessment + status and round-trips fully")
    func genericFactDualEncode() throws {
        let a = EvidenceAssessment(basis: .directlyObserved, review: .confirmed, origin: .sourceExtraction)
        let original = GenericFact(subjectLabel: "S", field: "employer", value: "Orchid",
                                   assessment: a, confidence: 0.9, sourceBlockIDs: [UUID()])
        let data = try enc.encode(original)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["assessment"] != nil)                        // canonical present
        #expect(obj["status"] as? String == "DIRECTLY_OBSERVED") // compatibility present
        let back = try dec.decode(GenericFact.self, from: data)
        #expect(back.assessment == a)                            // full assessment intact
    }

    // MARK: TemporalClaim

    @Test("A legacy-shaped TemporalClaim (assessment stripped) decodes via status fallback")
    func temporalClaimLegacyShaped() throws {
        let original = TemporalClaim(subjectID: UUID(), predicate: "worked_for", object: .literal("Orchid"),
                                     status: .inferred, confidence: 0.5,
                                     extractorID: "x", extractorVersion: "1", createdAt: Date(timeIntervalSince1970: 0))
        let legacy = try legacyShaped(try enc.encode(original))
        let obj = try JSONSerialization.jsonObject(with: legacy) as! [String: Any]
        #expect(obj["assessment"] == nil && obj["status"] as? String == "INFERRED")
        let back = try dec.decode(TemporalClaim.self, from: legacy)
        #expect(back.assessment.basis == .inferred)
    }

    // MARK: HistoryItem

    @Test("A legacy-shaped HistoryItem decodes via evidenceStatus and reconciles review")
    func historyItemLegacyShapedReconciles() throws {
        let original = HistoryItem(subject: .person(UUID()), kind: .event, title: "e",
                                   evidenceStatus: .sourceAsserted, confidence: 0.8,
                                   evidence: [EvidenceReference(objectID: UUID())], reviewStatus: .accepted)
        let legacy = try legacyShaped(try enc.encode(original))
        let obj = try JSONSerialization.jsonObject(with: legacy) as! [String: Any]
        #expect(obj["assessment"] == nil && obj["evidenceStatus"] as? String == "SOURCE_ASSERTED")
        let back = try dec.decode(HistoryItem.self, from: legacy)
        #expect(back.assessment.basis == .sourceAsserted)
        #expect(back.reviewStatus == .accepted)
        #expect(back.assessment.review == .confirmed)            // reconciled to reviewStatus
    }

    @Test("New HistoryItem JSON reopens with the full assessment and consistent review")
    func historyItemDualEncode() throws {
        let original = HistoryItem(subject: .person(UUID()), kind: .stateStart, title: "role",
                                   assessment: EvidenceAssessment(basis: .directlyObserved, origin: .sourceExtraction),
                                   confidence: 0.8, reviewStatus: .corrected)
        let data = try enc.encode(original)
        let back = try dec.decode(HistoryItem.self, from: data)
        #expect(back.assessment.basis == .directlyObserved)
        #expect(back.assessment.review == .corrected)            // reviewStatus corrected → review corrected
        #expect(back.reviewStatus == .corrected)
    }

    // MARK: Failure

    @Test("A payload with neither assessment nor legacy status fails loudly")
    func neitherRepresentationThrows() throws {
        let a = GenericFact(subjectLabel: "S", field: "f", value: "v",
                            assessment: LegacyEvidenceStatusAdapter.decode(.sourceAsserted),
                            confidence: 0.5, sourceBlockIDs: [])
        var obj = try JSONSerialization.jsonObject(with: try enc.encode(a)) as! [String: Any]
        obj.removeValue(forKey: "assessment")
        obj.removeValue(forKey: "status")
        let bad = try JSONSerialization.data(withJSONObject: obj)
        #expect(throws: (any Error).self) { try dec.decode(GenericFact.self, from: bad) }
    }
}
