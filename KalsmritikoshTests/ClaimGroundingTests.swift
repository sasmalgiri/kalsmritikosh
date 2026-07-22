//
//  ClaimGroundingTests.swift
//  KalsmritikoshTests
//
//  CLM-001 — verifies material specifics in a claim (amounts, dates, multi-word names)
//  are checked against the cited evidence: fabricated amounts/names are flagged, grounded
//  ones pass. Bias is HIGH PRECISION — never flag a genuinely grounded claim.
//

import Testing
@testable import Kalsmritikosh

@Suite("CLM-001 ClaimGrounding")
struct ClaimGroundingTests {

    private let grounding = ClaimGrounding()

    @Test("Grounded amount + name pass (currency/format-insensitive)")
    func groundedPasses() {
        let r = grounding.check(claim: "Paid ₹3,800 to Rajesh Kumar.",
                                evidenceTexts: ["Transaction: Rs 3800 credited to Rajesh Kumar on 12 Jan."])
        #expect(r.ungroundedTokens.isEmpty)
        #expect(r.groundedFraction == 1.0)
    }

    @Test("A fabricated amount not in the evidence is flagged")
    func fabricatedAmountFlagged() {
        let r = grounding.check(claim: "The fee was ₹5,000.",
                                evidenceTexts: ["An invoice was attached regarding the service."])
        #expect(r.hasUngroundedMaterial)
        #expect(r.ungroundedTokens.contains { $0.contains("5,000") })
    }

    @Test("A multi-word employer present in the evidence is grounded")
    func employerGrounded() {
        let r = grounding.check(claim: "Shirshendu Sasmal worked at Orchid Chemicals.",
                                evidenceTexts: ["Work Experience at Orchid Chemicals, Aurangabad. Shirshendu Sasmal."])
        #expect(r.materialTokens.contains("Orchid Chemicals"))
        #expect(r.ungroundedTokens.isEmpty)
    }

    @Test("A fabricated multi-word employer is flagged")
    func fabricatedEmployerFlagged() {
        let r = grounding.check(claim: "Sasmal worked at Reliance Industries.",
                                evidenceTexts: ["Sasmal was employed at Orchid Chemicals."])
        #expect(r.ungroundedTokens.contains("Reliance Industries"))
    }

    @Test("A claim with no checkable specifics is trivially grounded (no false flags)")
    func noSpecificsNoFlags() {
        let r = grounding.check(claim: "The project was discussed at length.",
                                evidenceTexts: ["We talked about the project."])
        #expect(!r.hasUngroundedMaterial)
        #expect(r.groundedFraction == 1.0)
    }

    @Test("Year grounding: a matching year passes, a fabricated year is flagged")
    func yearGrounding() {
        #expect(grounding.check(claim: "Joined in 2004.",
                                evidenceTexts: ["since Dec 2004"]).ungroundedTokens.isEmpty)
        #expect(grounding.check(claim: "Joined in 2019.",
                                evidenceTexts: ["since Dec 2004"]).hasUngroundedMaterial)
    }
}
