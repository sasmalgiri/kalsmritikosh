//
//  EmploymentDomainPackTests.swift
//  KalsmritikoshTests
//
//  SEM-004 — employment pack extracts employer(s) + role from résumé text as evidence-linked
//  SOURCE_ASSERTED facts; quiet on non-résumé text; multi-word org names (incl. "&") stay whole.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("SEM-004 EmploymentDomainPack")
struct EmploymentDomainPackTests {

    private let block = UUID()
    private let cv = "Present: PPIC Executive in Hospira India Pvt. Ltd. Previously worked as PPIC-Executive at Orchid Chemical & Pharmaceutical Ltd., Aurangabad since Dec 2004."

    @Test("Extracts both employers whole (including the & connector)")
    func employersWhole() {
        let employers = EmploymentDomainPack.extractFacts(fromText: cv, subjectLabel: "Sasmal", blockID: block)
            .filter { $0.field == "employer" }.map(\.value)
        #expect(employers.contains("Hospira India Pvt. Ltd"))
        #expect(employers.contains("Orchid Chemical & Pharmaceutical Ltd"))
    }

    @Test("Extracts a role and links facts to evidence")
    func roleAndEvidence() {
        let facts = EmploymentDomainPack.extractFacts(fromText: cv, subjectLabel: "Sasmal", blockID: block)
        #expect(facts.contains { $0.field == "role" && $0.value.contains("Executive") })
        for f in facts {
            #expect(f.status == .sourceAsserted)
            #expect(f.sourceBlockIDs == [block])
        }
    }

    @Test("Quiet on non-résumé text")
    func quiet() {
        #expect(EmploymentDomainPack.extractFacts(fromText: "Hi, see attached.", subjectLabel: "x", blockID: block).isEmpty)
    }

    @Test("Registers recognizers additively")
    func registers() {
        let reg = EmploymentDomainPack.registry()
        #expect(reg.tags(forText: "Worked at Orchid Chemicals Ltd").contains { $0.role == "employerLine" })
    }
}
