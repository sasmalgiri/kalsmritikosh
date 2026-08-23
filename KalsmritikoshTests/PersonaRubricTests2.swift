//
//  PersonaRubricTests2.swift
//  KalsmritikoshTests
//
//  The recognized rubrics surfaced for the Journalist and Researcher lenses.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Journalistic verification")
struct JournalisticVerificationTests {

    @Test("The checklist covers corroboration, reply, and labelling; uniquely identified")
    func steps() {
        let s = JournalisticVerification.steps
        #expect(s.count >= 5)
        #expect(Set(s.map(\.id)).count == s.count)
        #expect(s.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty })
        let ids = Set(s.map(\.id))
        for core in ["corroborate", "reply", "label"] { #expect(ids.contains(core)) }
        #expect(JournalisticVerification.disciplineNote.lowercased().contains("single source"))
    }
}

@Suite("Research appraisal (PRISMA / GRADE)")
struct ResearchAppraisalTests {

    @Test("PRISMA stages flow identification → included; GRADE has four certainty levels")
    func frameworks() {
        #expect(ResearchAppraisal.prismaStages.map(\.id) == ["identification", "screening", "eligibility", "included"])
        #expect(GRADECertainty.allCases == [.high, .moderate, .low, .veryLow])
        #expect(GRADECertainty.allCases.allSatisfy { !$0.label.isEmpty && !$0.detail.isEmpty })
        #expect(ResearchAppraisal.helpSummary.contains("PRISMA"))
        #expect(ResearchAppraisal.helpSummary.contains("GRADE"))
    }

    @Test("GRADE certainty is Codable by raw value")
    func codable() throws {
        for g in GRADECertainty.allCases {
            let data = try JSONEncoder().encode(g)
            #expect(try JSONDecoder().decode(GRADECertainty.self, from: data) == g)
        }
    }
}
