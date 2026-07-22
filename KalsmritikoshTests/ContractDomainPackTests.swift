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

    @Test("Executed contract → final status + effective date")
    func executedFinal() {
        let f = ContractDomainPack.extractFacts(
            fromText: "This Agreement, executed on 12/01/2024 by and between A and B.",
            subjectLabel: "c", blockID: block)
        let byField = Dictionary(uniqueKeysWithValues: f.map { ($0.field, $0.value) })
        #expect(byField["status"] == "final")
        #expect(byField["date"] == "12/01/2024")
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
