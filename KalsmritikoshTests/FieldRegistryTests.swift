//
//  FieldRegistryTests.swift
//  KalsmritikoshTests
//
//  F8 (II.0 + NF-1..3) — the field registry assembles itself from the packs'
//  own declarations; the field-shaped fallback routes unknown-field asks onto
//  the slot path (never fact-spam); the abstention names the field, states the
//  scope, and carries its receipt; and NF-3: a KNOWN field with facts present
//  never abstains (false-not-found is Sev-1).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("F8 — FieldRegistry + field-shaped abstention")
struct FieldRegistryTests {

    @Test("The registry assembles from the packs — a new emittable field joins by existing")
    func registryAssembles() {
        for f in PatentDomainPack.emittedFields + TransactionDomainPack.emittedFields
            + ContractDomainPack.emittedFields + EmploymentDomainPack.emittedFields {
            #expect(FieldRegistry.isKnown(f), "\(f) must be known — it is emitted")
        }
        #expect(!FieldRegistry.isKnown("trademarknumber"), "no pack emits trademark numbers")
    }

    @Test("Field-shaped fallback: unknown '<word> number/id/date' resolves; noise never does")
    func fieldShapedFallback() {
        let r = SlotFieldResolver.resolve(in: "what is the trademark number")
        #expect(r.count == 1)
        #expect(r.first?.fieldID == "trademarknumber")
        #expect(r.first?.humanLabel == "Trademark number")
        // Vocabulary still wins when it matches (no double-resolution).
        let vocab = SlotFieldResolver.resolve(in: "what is the patent number")
        #expect(vocab.first?.fieldID == "patentnumber")
        // Stopword/short leading words never resolve — no false slot routing.
        #expect(SlotFieldResolver.resolve(in: "there are a number of things").isEmpty)
        #expect(SlotFieldResolver.resolve(in: "any number will do").isEmpty)
        #expect(SlotFieldResolver.resolve(in: "who is Shirshendu Sasmal").isEmpty)
        #expect(SlotFieldResolver.resolve(in: "what is the capital of France").isEmpty)
    }

    @Test("NF-2 nearest-miss: trademark number's nearest known field shares the 'number' token")
    func nearestMiss() {
        let nearest = FieldRegistry.nearestKnown(toLabel: "Trademark number")
        #expect(nearest != nil, "a number-shaped ask has number-labeled neighbors on file")
        #expect(nearest?.lowercased().contains("number") == true)
    }

    @Test("The unknown-field abstention names the field, states the scope, and carries the receipt")
    func unknownFieldAbstention() {
        let composition = SlotAnswerComposer.compose(
            slotFieldIDs: ["trademarknumber"], facts: [], evaluations: [],
            authorityObjectIDs: [], documentsSearched: 7)
        let c = try! #require(composition)
        #expect(c.isNotFound)
        let t = c.primaryText
        #expect(t.contains("trademark number"), "must name the field: \(t)")
        #expect(t.contains("not among the fields"), "must state the scope honestly: \(t)")
        #expect(t.contains("Receipt:"), "must carry the exhaustion receipt: \(t)")
        #expect(t.contains("no model was consulted"), "rung 1n is a zero-model path: \(t)")
    }

    // NF-3 (false-not-found = Sev-1) is guarded END-TO-END by the rung-1 twin
    // ("what is the granted patent number" → 700321, never an abstention) and
    // by the gold-eval floors — a present field abstaining would red both.
    // Constructing a synthetic ClaimEvaluation here would fork the
    // assertability policy; the witness-level guard is the honest one.
}
