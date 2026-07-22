//
//  PatentDomainPackTests.swift
//  KalsmritikoshTests
//
//  SEM-007 — patent pack extracts patent number + official status as evidence-linked facts;
//  quiet on non-patent text.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("SEM-007 PatentDomainPack")
struct PatentDomainPackTests {

    private let block = UUID()

    @Test("Granted patent yields number + granted status")
    func granted() {
        let f = PatentDomainPack.extractFacts(fromText: "Patent No. 402349 has been granted.",
                                              subjectLabel: "patent", blockID: block)
        let byField = Dictionary(uniqueKeysWithValues: f.map { ($0.field, $0.value) })
        #expect(byField["patentNumber"]?.contains("402349") == true)
        #expect(byField["status"] == "granted")
        #expect(f.allSatisfy { $0.status == .sourceAsserted && $0.sourceBlockIDs == [block] })
    }

    @Test("Filed application maps to filed status")
    func filed() {
        #expect(PatentDomainPack.status(in: "Application No 2024110 filed and pending") == "filed")
    }

    @Test("Terminal states take priority (granted over pending wording)")
    func terminalPriority() {
        #expect(PatentDomainPack.status(in: "grant of patent; earlier pending") == "granted")
    }

    @Test("Non-patent text extracts nothing")
    func quiet() {
        #expect(PatentDomainPack.extractFacts(fromText: "Lunch at noon?", subjectLabel: "x", blockID: block).isEmpty)
    }
}
