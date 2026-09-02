//
//  ContractDomainPackTests.swift
//  KalsmritikoshTests
//
//  SEM-006 — contract pack extracts version state (draft/final/amendment) + date.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("SEM-006 ContractDomainPack")
struct ContractDomainPackTests {
    private let block = UUID()

    @Test("Executed contract → final status + effective date (C-7: date stored as ISO atom, canon at render)")
    func executedFinal() {
        let f = ContractDomainPack.extractFacts(
            fromText: "This Agreement, executed on 12/01/2024 by and between A and B.",
            subjectLabel: "c", blockID: block)
        let byField = Dictionary(uniqueKeysWithValues: f.map { ($0.field, $0.value) })
        #expect(byField["status"] == "final")
        // V2 storage-gold (enumerated change, was raw "12/01/2024"): the ISO atom
        // via the inherited C-7 normalizer (day-before-month, as the comparator).
        #expect(byField["date"] == "2024-01-12")
        // Surface unchanged: the precision-canon inverse renders the day form.
        let dateFact = try! #require(f.first { $0.field == "date" })
        #expect(SlotAnswerComposer.renderValue(dateFact) == "12/01/2024")
        #expect(dateFact.producerVersion == DerivedProducerVersions.facts, "date stamped v1")
        #expect(dateFact.rawMatch == "12/01/2024", "rawMatch keeps the source spelling")
    }

    @Test("Draft and amendment version states are recognized")
    func versionStates() {
        #expect(ContractDomainPack.versionState(in: "DRAFT for review") == "draft")
        #expect(ContractDomainPack.versionState(in: "Amendment No. 2") == "amendment")
        #expect(ContractDomainPack.versionState(in: "hello") == nil)
    }

    @Test("Facts are evidence-linked and source-asserted")
    func evidenceLinked() {
        let f = ContractDomainPack.extractFacts(fromText: "Draft agreement dated 01/02/2023.",
                                                subjectLabel: "c", blockID: block)
        #expect(f.allSatisfy { $0.status == .sourceAsserted && $0.sourceBlockIDs == [block] })
    }
}
