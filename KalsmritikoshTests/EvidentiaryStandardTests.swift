//
//  EvidentiaryStandardTests.swift
//  KalsmritikoshTests
//
//  The standard-of-proof value that INV-19 approvals must declare.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("EvidentiaryStandard")
struct EvidentiaryStandardTests {

    @Test("Every standard has a label, a gloss, and a stable rationale line")
    func shape() {
        for s in EvidentiaryStandard.allCases {
            #expect(!s.label.isEmpty)
            #expect(!s.detail.isEmpty)
            #expect(s.rationaleLine == "Standard of proof applied: \(s.label).")
        }
        // The common professional bars are present.
        #expect(EvidentiaryStandard.allCases.contains(.beyondReasonableDoubt))
        #expect(EvidentiaryStandard.allCases.contains(.balanceOfProbabilities))
    }

    @Test("Codable round-trips by raw value")
    func codable() throws {
        for s in EvidentiaryStandard.allCases {
            let data = try JSONEncoder().encode(s)
            #expect(try JSONDecoder().decode(EvidentiaryStandard.self, from: data) == s)
        }
    }
}
