//
//  ResearchDomainPackTests.swift
//  KalsmritikoshTests
//
//  SEM-008 — research pack extracts DOI + year from a citation.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("SEM-008 ResearchDomainPack")
struct ResearchDomainPackTests {
    private let block = UUID()

    @Test("Citation yields DOI + year")
    func citation() {
        let f = ResearchDomainPack.extractFacts(
            fromText: "Sasmal et al., J. Proc. Chem., 2011. doi:10.1021/ja012345x",
            subjectLabel: "p", blockID: block)
        let byField = Dictionary(uniqueKeysWithValues: f.map { ($0.field, $0.value) })
        #expect(byField["doi"] == "10.1021/ja012345x")
        #expect(byField["date"] == "2011")
        #expect(f.first { $0.field == "date" }?.unit == "year")
    }

    @Test("Non-publication text extracts nothing")
    func quiet() {
        #expect(ResearchDomainPack.extractFacts(fromText: "lunch tomorrow", subjectLabel: "x", blockID: block).isEmpty)
    }

    @Test("Registers a citation recognizer")
    func registers() {
        #expect(ResearchDomainPack.registry().tags(forText: "doi:10.1/x, Journal of Things").contains { $0.role == "citationLine" })
    }
}
