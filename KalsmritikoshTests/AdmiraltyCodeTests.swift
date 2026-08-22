//
//  AdmiraltyCodeTests.swift
//  KalsmritikoshTests
//
//  The published source-evaluation rubric used by INV-08.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("AdmiraltyCode")
struct AdmiraltyCodeTests {

    @Test("Code renders as letter+number and maps reliability to the canonical rating")
    func codeAndMapping() {
        #expect(AdmiraltyCode(reliability: .b, credibility: .two).code == "B2")
        #expect(AdmiraltyCode(reliability: .a, credibility: .one).coarseRating == .high)
        #expect(AdmiraltyCode(reliability: .b, credibility: .three).coarseRating == .high)
        #expect(AdmiraltyCode(reliability: .c, credibility: .four).coarseRating == .medium)
        #expect(AdmiraltyCode(reliability: .d, credibility: .four).coarseRating == .medium)
        #expect(AdmiraltyCode(reliability: .e, credibility: .five).coarseRating == .low)
        #expect(AdmiraltyCode(reliability: .f, credibility: .six).coarseRating == .unknown)
    }

    @Test("Every grade has a non-empty label; the rationale line names the code")
    func labelsAndRationale() {
        #expect(SourceReliabilityGrade.allCases.allSatisfy { !$0.label.isEmpty })
        #expect(InformationCredibilityGrade.allCases.allSatisfy { !$0.label.isEmpty })
        let c = AdmiraltyCode(reliability: .c, credibility: .three)
        #expect(c.rationaleLine == "Admiralty rating: C3 — Fairly reliable / Possibly true.")
    }

    @Test("Codable round-trips")
    func codable() throws {
        let c = AdmiraltyCode(reliability: .d, credibility: .five)
        let data = try JSONEncoder().encode(c)
        #expect(try JSONDecoder().decode(AdmiraltyCode.self, from: data) == c)
    }
}
