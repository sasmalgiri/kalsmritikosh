//
//  FactCheckMemoTests.swift
//  KalsmritikoshTests
//
//  Persona studio #5 — the journalist's pre-publication memo must enforce the
//  newsroom disciplines: statuses + sources per claim, reply required for
//  anything short of verified, alleged-labelling + corrections gates.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Journalist studio")
struct FactCheckMemoTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Stage gates: reply required only when a claim is short of verified")
    func stages() {
        var m = FactCheckMemo(title: "x", now: t0)
        #expect(FactCheckMemo.Stage.allCases.map(\.title) == ["Story", "Claims", "Right of reply", "Memo"])
        // A fully-verified story needs no reply entries.
        var c = JClaim(text: "claim"); c.status = .verified; c.sources = "doc"
        m.claims = [c]
        #expect(m.isComplete(.reply))
        // A disputed claim makes the reply stage mandatory…
        c.status = .disputed; m.claims = [c]
        #expect(!m.isComplete(.reply))
        // …and satisfied by a complete entry.
        var r = ReplyEntry(); r.subject = "S"; r.claimSummary = "put in full"; r.contactedDate = "2026-05-02"
        m.replies = [r]
        #expect(m.isComplete(.reply))
        // The memo gates on both pre-publication checks.
        #expect(!m.isComplete(.memo))
        m.allegedLabellingConfirmed = true; m.correctionsPathConfirmed = true
        #expect(m.isComplete(.memo))
    }

    @Test("The memo is the newsroom hardcopy: claim table, reply log, copy flags, checks")
    func hardcopy() {
        let md = FactCheckMemoRenderer.markdown(.sample(now: t0), generatedAt: t0)
        #expect(md.hasPrefix(LegalNotice.reportDisclaimer))
        let sections = ["1. Story premise", "2. Claim-by-claim fact check", "3. Right-of-reply log",
                        "4. Copy flags", "5. Pre-publication checks"]
        var last = md.startIndex
        for s in sections {
            let r = md.range(of: s, range: last..<md.endIndex)
            #expect(r != nil, "missing or out-of-order section: \(s)")
            if let r { last = r.upperBound }
        }
        // Claim table with statuses; the single-source discipline stated.
        #expect(md.contains("| # | Claim | Status | Sources | Corroboration |"))
        #expect(md.contains("**Verified**"))
        #expect(md.contains("**Disputed**"))
        #expect(md.contains("single source is a lead"))
        // Reply log records silence too.
        #expect(md.contains("| Subject | What was put to them | Contacted | Method | Deadline | Response |"))
        #expect(md.contains("No response by deadline."))
        // The disputed claim is flagged to run as alleged.
        #expect(md.contains("Copy flags — run as alleged, not fact"))
        #expect(md.contains("[Disputed]"))
    }

    @Test("A whole memo survives a JSON round-trip")
    func codable() throws {
        let original = [FactCheckMemo.sample(now: t0)]
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode([FactCheckMemo].self, from: data) == original)
    }
}
