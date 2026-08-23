//
//  SIUReferralTests.swift
//  KalsmritikoshTests
//
//  Persona studio #3 — the SIU report must follow the regulatory pattern:
//  indicators never proof, external referral gated on good faith, and the file
//  showing the work even when it returns to claims.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("SIU studio")
struct SIUReferralTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Stages follow the real-life order and gate on real conditions")
    func stages() {
        var s = SIUReferral(title: "x", now: t0)
        #expect(SIUReferral.Stage.allCases.map(\.title) ==
                ["Claim", "Red flags", "Investigation", "Discrepancies", "Disposition"])
        // Red-flags stage requires flags AND the written-criteria statement.
        s.redFlags = [SIURedFlag(indicatorID: "timing.inception", note: "n")]
        #expect(!s.isComplete(.redFlags))
        s.criteriaNote = "Meets §2(b)."
        #expect(s.isComplete(.redFlags))
        // Disposition gates: rationale + indicators-not-proof acknowledgment…
        s.disposition = .returnToClaims
        s.dispositionRationale = "shows the work"
        #expect(!s.isComplete(.disposition))
        s.indicatorsNotProofAcknowledged = true
        #expect(s.isComplete(.disposition))
        // …and an EXTERNAL referral additionally requires the good-faith confirmation.
        s.disposition = .referDOI
        #expect(!s.isComplete(.disposition))
        s.goodFaithConfirmed = true
        #expect(s.isComplete(.disposition))
    }

    @Test("The report is the regulatory hardcopy: claim block, criteria, chronology, work, both-sides discrepancies, disposition")
    func hardcopy() {
        let md = SIUReportRenderer.markdown(.sample(now: t0), generatedAt: t0)
        #expect(md.hasPrefix(LegalNotice.reportDisclaimer))
        // Claim identification table.
        #expect(md.contains("| Claim no. | Insured | Policy | Loss date | Loss type | Claimed amount |"))
        #expect(md.contains("CL-2291"))
        // Referral basis names recognized indicators + the written criteria + the discipline.
        #expect(md.contains("1. Referral basis (objective criteria)"))
        #expect(md.contains("Inconsistent accounts"))
        #expect(md.contains("Meets written referral criteria"))
        #expect(md.contains("never, on their own, proof"))
        // Chronology + investigation tables (the examiner's "show the work").
        #expect(md.contains("2. Loss chronology"))
        #expect(md.contains("3. Investigation conducted"))
        #expect(md.contains("ISO ClaimSearch"))
        // Discrepancies preserve BOTH accounts.
        #expect(md.contains("**A:** Intake form: injury 2026-03-03"))
        #expect(md.contains("**B:** Physician note: injury 2026-03-10"))
        // Findings + disposition; the sample returns to claims (no good-faith line needed).
        #expect(md.contains("5. Findings of fact"))
        #expect(md.contains("Return to claims"))
        #expect(!md.contains("made in good faith"))
    }

    @Test("An external referral prints the statutory good-faith line")
    func goodFaithLine() {
        var s = SIUReferral.sample(now: t0)
        s.disposition = .referDOI; s.goodFaithConfirmed = true
        let md = SIUReportRenderer.markdown(s, generatedAt: t0)
        #expect(md.contains("Refer to the DOI fraud bureau"))
        #expect(md.contains("made in good faith"))
    }

    @Test("A whole file survives a JSON round-trip")
    func codable() throws {
        let original = [SIUReferral.sample(now: t0)]
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode([SIUReferral].self, from: data) == original)
    }
}
