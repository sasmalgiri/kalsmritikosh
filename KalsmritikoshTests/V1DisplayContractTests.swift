//
//  V1DisplayContractTests.swift
//  KalsmritikoshTests
//
//  V2 (w2) PREFLIGHT — the completeness invariant (owner binding 2026-09-01,
//  #2): no field the v1 writer can emit may reach a renderer without a display
//  contract. This converts "we covered the labels we were staring at" from an
//  enumeration into a structural invariant that survives every future field
//  addition: add a field to PatentDomainPack.emittedFields and this test forces
//  its display contract before the pack can ship it.
//
//  A display contract is shape-dependent:
//   - identifier → a displayLabel CONSTANT (bare would drop "Patent No.").
//   - date       → the precision-canon renderer (bare ISO would surface wrong).
//   - text/word  → identity (status renders its bare atom "granted" correctly).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("V2 preflight — every v1-emittable field has a display contract")
struct V1DisplayContractTests {

    @Test("Every field the v1 patent writer emits has a shape-appropriate display contract")
    func everyEmittableFieldHasAContract() {
        for field in PatentDomainPack.emittedFields {
            switch FactSchemaRegistry.expectedShape(of: field) {
            case .identifier:
                #expect(SlotAnswerComposer.displayLabel(forFieldID: field) != nil,
                        "v1 identifier field '\(field)' has no displayLabel constant — it would surface bare or wrong")
            case .date:
                // The precision-canon renderer must resolve all three grains.
                #expect(SlotAnswerComposer.renderCanonicalDate(iso: "2025-06-17") == "17/06/2025",
                        "date field '\(field)': day-precision canon is not DD/MM/YYYY (seal #3c family)")
                #expect(SlotAnswerComposer.renderCanonicalDate(iso: "2024-11") == "November 2024",
                        "date field '\(field)': month-precision canon is not 'Month YYYY'")
                #expect(SlotAnswerComposer.renderCanonicalDate(iso: "2024") == "2024",
                        "date field '\(field)': year-precision canon is not 'YYYY'")
            default:
                break   // text/word fields render their bare atom — identity is the contract
            }
        }
    }

    @Test("Identifier display constants equal the witnessed answer-surface prefixes")
    func constantsEqualWitnessedSurface() {
        #expect(SlotAnswerComposer.displayLabel(forFieldID: "patentNumber") == "Patent No.")
        #expect(SlotAnswerComposer.displayLabel(forFieldID: "applicationNumber") == "Application No.")
        #expect(SlotAnswerComposer.displayLabel(forFieldID: "publicationNumber") == "Publication No.")
    }
}
