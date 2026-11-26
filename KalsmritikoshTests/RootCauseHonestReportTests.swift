//
//  RootCauseHonestReportTests.swift
//  KalsmritikoshTests
//
//  Case plan 2026-11-16 (REPORT-11, REASON-13): the root-cause report states what the analysis rests on and who signed
//  off from the record — never a fixed claim that causes were traced to evidence and confirmed by a human. Evidence state
//  and sign-off state are separate; an inconclusive conclusion is complete and exports honestly; ideas, causes and Why
//  answers carry optional citations and assumptions; older records decode unchanged.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Root-cause report — wording from evidence and review state")
struct RootCauseHonestReportTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// A draft with a starred cause and only typed notes: no citation anywhere.
    private func notesOnly() -> RootCauseAnalysis {
        var r = RootCauseAnalysis(title: "Batch 42 failed assay", now: t0)
        r.problemStatement = "Batch 42 failed the assay."
        r.brainstorm = [RCAIdea(text: "Supplier material variation")]
        r.fiveWhys = [RCAWhyStep(question: "Why did it fail?", answer: "The material was out of specification.", evidence: "lab book p.4")]
        r.fishbone[0].causes = [RCAFishboneCause(text: "Supplier variation", likely: true)]
        r.conclusion.rootCause = "The supplier's material varied."
        return r
    }

    @Test("A starred cause and a typed note never read as a human-confirmed, sourced root cause")
    func notesOnlyDraftIsHonest() {
        let md = RCAReportRenderer.markdown(notesOnly(), generatedAt: t0)
        #expect(!md.contains("confirmed by a human"))
        #expect(!md.contains("causes traced to evidence"))
        #expect(md.contains("No step cites a source"), "\(md)")
        #expect(md.contains("draft, not reviewed. Nothing here has been confirmed by a reviewer."))
        #expect(md.contains("marked probable by the investigator"))
        #expect(md.contains("Investigator's note on the source (as entered, not checked): lab book p.4"))
        #expect(md.contains("**Basis:** no source is cited"))
    }

    @Test("Approved with citations: the basis is named, and approval is not presented as establishing the cause")
    func approvedAndCitedNamesBasis() {
        var r = notesOnly()
        let version = UUID()
        r.fiveWhys[0].citations = [StudioEvidenceRef(sourceVersionID: version, objectID: UUID(), quote: "assay result 71% (limit 95%)")]
        r.fishbone[0].causes[0].assumption = "The supplier changed its process in March."
        r.approval.preparedBy = "A. Investigator"
        r.approval.status = .approved
        r.approval.approver = "Quality Head"
        r.approval.decidedAt = t0
        let md = RCAReportRenderer.markdown(r, generatedAt: t0)
        #expect(md.contains("1 of 1 answered Why steps cite a source passage"), "\(md)")
        #expect(md.contains("0 of 1 causes marked probable cite a source passage, 1 rest on a stated assumption"))
        #expect(md.contains("_Source: \u{201C}assay result 71% (limit 95%)\u{201D} (version \(version.uuidString.prefix(8)))_"))
        #expect(md.contains("Assumption (stated, not evidenced): The supplier changed its process in March."))
        #expect(md.contains("**Basis:** 1 cited Why step(s)."))
        #expect(md.contains("approved by Quality Head"))
        #expect(md.contains("does not by itself establish the cause"))
        #expect(!md.contains("self-approved"))
    }

    @Test("Self-approval is labelled as such")
    func selfApprovalLabelled() {
        var r = notesOnly()
        r.approval.preparedBy = "A. Investigator"; r.approval.approver = "A. Investigator"; r.approval.status = .approved
        #expect(RCAReportRenderer.markdown(r, generatedAt: t0).contains("self-approved"))
    }

    @Test("Inconclusive is a complete conclusion without a root cause, and exports honestly")
    func inconclusiveExportsHonestly() {
        var r = notesOnly()
        r.conclusion.rootCause = ""
        #expect(!r.isComplete(.conclude))
        r.conclusion.outcome = .inconclusive
        #expect(r.isComplete(.conclude))
        var md = RCAReportRenderer.markdown(r, generatedAt: t0)
        #expect(md.contains("**Outcome:** Inconclusive on the available evidence — no root cause is established."))
        #expect(!md.contains("**Root cause:**"))
        r.conclusion.rootCause = "Instrument drift"
        md = RCAReportRenderer.markdown(r, generatedAt: t0)
        #expect(md.contains("**Leading candidate (not established):** Instrument drift"))
    }

    @Test("A citation counts only once it quotes a passage; only quoted citations go to the export re-check")
    func onlyQuotedCitationsCount() {
        var r = notesOnly()
        r.fiveWhys[0].citations = [StudioEvidenceRef(sourceVersionID: UUID())]   // linked, not quoted
        #expect(r.evidenceState.citedWhys == 0)
        #expect(r.citationGate.values.isEmpty)
        r.fiveWhys[0].citations.append(StudioEvidenceRef(sourceVersionID: UUID(), objectID: UUID(), quote: "the words"))
        r.conclusion.citations = [StudioEvidenceRef(sourceVersionID: UUID(), objectID: UUID(), quote: "other words")]
        #expect(r.evidenceState.citedWhys == 1 && r.evidenceState.conclusionCitations == 1)
        let gate = r.citationGate
        #expect(gate.values.count == 2)
        #expect(Set(gate.values.values) == ["the words", "other words"])
        #expect(gate.provenance.values.allSatisfy { $0.evidence.count == 1 && !$0.investigatorEntry })
    }

    @Test("Records saved before citations, assumptions and the outcome decode unchanged")
    func olderRecordsDecode() throws {
        let id = UUID()
        let why = try JSONDecoder().decode(RCAWhyStep.self, from: Data(#"{"id":"\#(id.uuidString)","question":"Why?","answer":"Because.","evidence":"doc 7"}"#.utf8))
        #expect(why.id == id && why.evidence == "doc 7" && why.citations.isEmpty && why.assumption.isEmpty)
        let idea = try JSONDecoder().decode(RCAIdea.self, from: Data(#"{"id":"\#(UUID().uuidString)","text":"An idea","parked":true}"#.utf8))
        #expect(idea.parked && idea.citations.isEmpty)
        let cause = try JSONDecoder().decode(RCAFishboneCause.self, from: Data(#"{"id":"\#(UUID().uuidString)","text":"A cause","likely":true}"#.utf8))
        #expect(cause.likely && cause.assumption.isEmpty)
        let conclusion = try JSONDecoder().decode(RCAConclusion.self, from: Data(#"{"rootCause":"r","summary":"s"}"#.utf8))
        #expect(conclusion.outcome == .rootCauseStated && conclusion.citations.isEmpty)
        // And the new fields round-trip.
        var whole = RootCauseAnalysis.sample(now: t0)
        whole.fiveWhys[0].citations = [StudioEvidenceRef(sourceVersionID: UUID(), quote: "q")]
        whole.fiveWhys[0].assumption = "a"
        whole.conclusion.outcome = .inconclusive
        let back = try JSONDecoder().decode(RootCauseAnalysis.self, from: JSONEncoder().encode(whole))
        #expect(back == whole)
    }
}
