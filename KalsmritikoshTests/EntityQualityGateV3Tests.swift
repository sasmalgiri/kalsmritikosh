//
//  EntityQualityGateV3Tests.swift
//  KalsmritikoshTests
//
//  V3 3b — the gate learns to say no: the three new E-1 classes (Nil-family,
//  email-as-person, filename-shaped), the classify-reason API driving the
//  computed rejection counters, and the invariant that non-name kinds (dates,
//  money, the V3 identifierAnchor) are untouched. The gate is now the chokepoint
//  every entity-creating path gate-then-folds through (reorder in
//  IngestCoordinator + reconcile; debug assertion at insertBatch).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("V3 3b — EntityQualityGate new classes + counters")
struct EntityQualityGateV3Tests {

    private let gate = EntityQualityGate()   // empty stoplist — exercises the hardcoded classes
    private func person(_ v: String) -> Entity { Entity(kind: .person, value: v, sourceObjectID: UUID()) }

    @Test("Nil-family, email-as-person, and filename-shaped are rejected with the right class")
    func newE1Classes() {
        #expect(gate.classify(person("Nil Nil")) == "nil-family")
        #expect(gate.classify(person("Nil")) == "nil-family")
        #expect(gate.classify(person("nil, nil")) == "nil-family")
        #expect(gate.classify(person("s.khan@example.com")) == "email-as-person")
        #expect(gate.classify(person("RESPONSE_TO_HEARING_29.08.2024.pdf")) == "filename-shaped")
        #expect(gate.classify(person("routing.eml")) == "filename-shaped")
        for junk in ["Nil Nil", "s.khan@example.com", "RESPONSE_29.08.2024.pdf"] {
            #expect(!gate.shouldKeep(person(junk)), "\(junk) should be gated")
        }
    }

    @Test("Real people and orgs pass; the gate never over-rejects a genuine name")
    func genuineNamesPass() {
        #expect(gate.shouldKeep(person("Shabana Khan")))
        #expect(gate.shouldKeep(Entity(kind: .organization, value: "Orchid Chemicals Ltd", sourceObjectID: UUID())))
        #expect(gate.classify(person("Shabana Khan")) == nil)
    }

    @Test("Non-name kinds are untouched — a V3 identifier anchor is never gated")
    func nonNameKindsUntouched() {
        let anchor = IdentifierAnchor.makeAnchor(field: "patentNumber", value: "555489", sourceObjectID: UUID())
        #expect(gate.shouldKeep(anchor), "an anchor (Patent No. 555489) must pass the gate")
        #expect(gate.classify(anchor) == nil)
        // A date value that happens to look filename-ish is still not a noun kind.
        #expect(gate.shouldKeep(Entity(kind: .date, value: "2024-11-29", sourceObjectID: UUID())))
    }

    @Test("Computed rejection audit tallies by class (C-ii pattern, schema-free)")
    func rejectionAuditByClass() {
        let batch = [
            person("Nil Nil"), person("Nil"),                 // 2 nil-family
            person("a@b.com"),                                // 1 email-as-person
            person("thing.pdf"),                              // 1 filename-shaped
            person("Shabana Khan"),                           // kept
            Entity(kind: .organization, value: "Orchid Chemicals Ltd", sourceObjectID: UUID()), // kept
        ]
        let audit = gate.rejectionAudit(batch)
        #expect(audit["nil-family"] == 2)
        #expect(audit["email-as-person"] == 1)
        #expect(audit["filename-shaped"] == 1)
        // filter() keeps exactly the two genuine names.
        #expect(gate.filter(batch).count == 2)
    }

    @Test("Gate-then-fold: junk is dropped by filter so it can never reach a fold as a candidate")
    func gateDropsBeforeFold() {
        // The reorder guarantee, at the gate boundary: a name that would tie/fold
        // ("Nil Nil") is removed by filter BEFORE the linker/reconciler sees it.
        let kept = gate.filter([person("Nil Nil"), person("Shirshendu Sasmal")])
        #expect(kept.map(\.value) == ["Shirshendu Sasmal"])
    }
}
