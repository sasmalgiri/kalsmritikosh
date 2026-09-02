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

    /// Every v1-emittable field of a pack has a shape-appropriate display contract.
    private func assertContractsCovered(_ fields: [String], pack: String) {
        for field in fields {
            switch FactSchemaRegistry.expectedShape(of: field) {
            case .identifier:
                #expect(SlotAnswerComposer.displayLabel(forFieldID: field) != nil,
                        "\(pack): v1 identifier field '\(field)' has no displayLabel constant — would surface bare or wrong")
            case .date:
                #expect(SlotAnswerComposer.renderCanonicalDate(iso: "2025-06-17") == "17/06/2025",
                        "\(pack) date '\(field)': day-precision canon is not DD/MM/YYYY (seal #3c family)")
                #expect(SlotAnswerComposer.renderCanonicalDate(iso: "2024-11") == "November 2024",
                        "\(pack) date '\(field)': month-precision canon is not 'Month YYYY'")
                #expect(SlotAnswerComposer.renderCanonicalDate(iso: "2024") == "2024",
                        "\(pack) date '\(field)': year-precision canon is not 'YYYY'")
            default:
                break   // text/word/money fields render their bare/canonical atom — identity is the contract
            }
        }
    }

    @Test("Every field each v1 pack emits has a shape-appropriate display contract")
    func everyEmittableFieldHasAContract() {
        assertContractsCovered(PatentDomainPack.emittedFields, pack: "patent")
        assertContractsCovered(ContractDomainPack.emittedFields, pack: "contract")
        assertContractsCovered(TransactionDomainPack.emittedFields, pack: "transaction")
        assertContractsCovered(EmploymentDomainPack.emittedFields, pack: "employment")
    }

    @Test("Identifier display constants equal the witnessed answer-surface prefixes")
    func constantsEqualWitnessedSurface() {
        #expect(SlotAnswerComposer.displayLabel(forFieldID: "patentNumber") == "Patent No.")
        #expect(SlotAnswerComposer.displayLabel(forFieldID: "applicationNumber") == "Application No.")
        #expect(SlotAnswerComposer.displayLabel(forFieldID: "publicationNumber") == "Publication No.")
    }
}
