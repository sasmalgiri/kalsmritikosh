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

    @Test("Final brief §3.6: a reply must put each adverse claim to each subject it affects; one unrelated reply is not enough")
    func repliesPerClaimAndSubject() {
        var m = FactCheckMemo(title: "x", now: t0)
        var c1 = JClaim(text: "A took the bribe."); c1.status = .disputed; c1.sources = "one source"; c1.adverse = true; c1.affectedSubjects = ["A", "B Ltd"]
        var c2 = JClaim(text: "The contract was untendered."); c2.status = .verified; c2.sources = "minutes"; c2.adverse = false
        m.claims = [c1, c2]
        // A reply on another claim, to another subject, does not satisfy claim 1.
        var r = ReplyEntry(); r.subject = "C"; r.claimSummary = "the tender"; r.contactedDate = "2026-05-02"; r.claimIDs = [c2.id]
        m.replies = [r]
        #expect(!m.isComplete(.reply))
        #expect(m.replyGaps == ["claim 1 → A: no reply that put this claim to them", "claim 1 → B Ltd: no reply that put this claim to them"])
        var ra = ReplyEntry(); ra.subject = "A"; ra.claimSummary = "the bribe"; ra.contactedDate = "2026-05-02"; ra.claimIDs = [c1.id]
        m.replies.append(ra)
        #expect(m.replyGaps == ["claim 1 → B Ltd: no reply that put this claim to them"])
        var rb = ReplyEntry(); rb.subject = "b ltd"; rb.claimSummary = "the bribe"; rb.contactedDate = "2026-05-02"; rb.claimIDs = [c1.id]; rb.response = "No response by deadline."
        m.replies.append(rb)
        #expect(m.isComplete(.reply))
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
        #expect(md.contains("| Subject | Claims put | What was put to them | Contacted | Method | Deadline | Response | Treatment in the story |"))
        #expect(md.contains("No response is not an admission"))
        #expect(!md.contains("Right of reply not yet complete"))
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
