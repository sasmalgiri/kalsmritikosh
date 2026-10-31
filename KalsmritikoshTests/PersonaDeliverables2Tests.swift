//
//  PersonaDeliverables2Tests.swift
//  KalsmritikoshTests
//
//  Persona studios #6–#9 (Researcher, Genealogist, Creator, Individual):
//  real-life stage gates, hardcopy-faithful section order, JSON round-trips —
//  plus the shared audit trail printed on every studio's hardcopy.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Persona studios 6–9")
struct PersonaDeliverables2Tests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func assertOrdered(_ md: String, _ sections: [String]) {
        var last = md.startIndex
        for s in sections {
            let r = md.range(of: s, range: last..<md.endIndex)
            #expect(r != nil, "missing or out-of-order section: \(s)")
            if let r { last = r.upperBound }
        }
    }

    // MARK: Researcher

    @Test("Researcher gates: PRISMA funnel must shrink; extraction rows must equal 'included'")
    func researcherGates() {
        var r = ResearchReview(title: "x", now: t0)
        r.question = "Q"
        #expect(r.isComplete(.protocolStage))
        r.identified = 10; r.screened = 20; r.eligible = 5; r.included = 2; r.exclusionReasons = "dupes"
        #expect(!r.isComplete(.screening))          // screened > identified
        r.screened = 8
        #expect(r.isComplete(.screening))
        var s = RSStudy(); s.study = "A 2020"; s.result = "+1"; s.source = "a-2020.pdf"
        r.studies = [s]
        #expect(!r.isComplete(.extraction))         // 1 row ≠ 2 included
        var s2 = RSStudy(); s2.study = "B 2021"; s2.result = "−1"
        r.studies = [s, s2]
        #expect(!r.isComplete(.extraction))         // final brief §3.6: a row without its source is not complete
        r.studies[1].source = "b-2021.pdf"
        #expect(r.isComplete(.extraction))
        #expect(!r.isComplete(.synthesis))
        r.synthesis = "conflicting"; r.certainty = .low
        #expect(r.isComplete(.synthesis))
    }

    @Test("Final brief §3.6: totals come from screening decisions; two reports of one study are one study; a negative review completes")
    func researcherDerivedFlow() {
        var r = ResearchReview(title: "x", now: t0)
        r.question = "Q"
        var q = RSSearch(); q.database = "PubMed"; q.searchString = "(remote work) AND productivity"; q.date = "2026-01-05"
        r.searches = [q]
        func rec(_ c: String, _ d: RSDecision, study: String = "", reason: String = "") -> RSRecord {
            var x = RSRecord(); x.citation = c; x.decision = d; x.studyKey = study; x.reason = reason; return x
        }
        r.records = [rec("Bloom 2015", .included, study: "bloom-trial"), rec("Bloom 2021 follow-up", .included, study: "bloom-trial"),
                     rec("Smith 2020", .excludedOnFullText, reason: ""), rec("Dup of Smith", .duplicate), rec("Off-topic", .excludedOnTitle)]
        #expect(r.flow.identified == 5 && r.flow.duplicates == 1 && r.flow.includedReports == 2 && r.flow.includedStudies == 1)
        #expect(!r.isComplete(.screening))           // a full-text exclusion without its reason
        r.records?[2].reason = "No productivity measure"
        #expect(r.isComplete(.screening))
        // One study (two reports) needs one extraction row.
        var s = RSStudy(); s.study = "Bloom"; s.result = "+13%"; s.source = "bloom-2021.pdf"
        r.studies = [s]
        #expect(r.isComplete(.extraction))
        // Certainty per outcome.
        r.synthesis = "One trial."
        var oc = RSOutcomeCertainty(); oc.outcome = "Calls handled"; oc.certainty = .moderate
        r.outcomeCertainty = [oc]
        #expect(!r.isComplete(.synthesis))           // no reason given for the rating
        r.outcomeCertainty?[0].reason = "Single trial; downgraded for imprecision"
        #expect(r.isComplete(.synthesis))
        let md = ResearchReviewRenderer.markdown(r, generatedAt: t0)
        #expect(md.contains("included 2 report(s) of 1 study(ies)") && md.contains("derived from the recorded screening decisions"))
        #expect(md.contains("`(remote work) AND productivity`"))
        // A review that includes nothing is complete without invented studies.
        var neg = ResearchReview(title: "n", now: t0)
        neg.question = "Q"; neg.searches = [q]
        neg.records = [rec("Only candidate", .excludedOnFullText, reason: "Wrong population")]
        neg.synthesis = "No study met the criteria."
        #expect(neg.isComplete(.screening) && neg.isComplete(.extraction) && neg.isComplete(.synthesis))
        #expect(ResearchReviewRenderer.markdown(neg, generatedAt: t0).contains("complete, negative review"))
    }

    @Test("Researcher hardcopy: protocol → PRISMA → extraction table → GRADE")
    func researcherHardcopy() {
        let md = ResearchReviewRenderer.markdown(.sample(now: t0), generatedAt: t0)
        #expect(md.hasPrefix(LegalNotice.reportDisclaimer))
        assertOrdered(md, ["1. Question & protocol", "2. Screening (PRISMA flow)",
                           "3. Extraction", "4. Synthesis & certainty (GRADE)"])
        #expect(md.contains("Identification **412**"))
        #expect(md.contains("| Study | Design | Sample | Outcome | Result | Source |"))
        #expect(md.contains("Certainty of evidence: Low"))
    }

    // MARK: Genealogist

    @Test("Genealogist gates: logged searches (nils count), conflicts resolved, cited written conclusion")
    func genealogistGates() {
        var p = ProofArgument(title: "x", now: t0)
        p.question = "Q"
        var s = GNSearch(); s.repository = "R"; s.source = "S"; s.result = "NIL result"
        p.searches = [s]
        #expect(p.isComplete(.research))
        #expect(!p.isComplete(.analysis))
        p.analysis = "weighed"; p.conflictResolution = "resolved"
        #expect(p.isComplete(.analysis))
        p.conclusion = "written conclusion"
        #expect(!p.isComplete(.proof))              // citations gate
        p.citationsComplete = true
        #expect(p.isComplete(.proof))
    }

    @Test("Genealogist hardcopy: the five GPS elements in order")
    func genealogistHardcopy() {
        let md = ProofArgumentRenderer.markdown(.sample(now: t0), generatedAt: t0)
        assertOrdered(md, ["1. Research question", "2. Research log", "3. Analysis & correlation",
                           "4. Resolution of conflicting evidence", "5. Conclusion"])
        #expect(md.contains("Genealogical Proof Standard"))
        #expect(md.contains("NIL result"))
    }

    // MARK: Creator

    @Test("Creator gates: every claim checked to a source, every asset cleared, disclosures + corrections")
    func creatorGates() {
        var p = PublishPackage(title: "x", now: t0)
        p.piece = "video"
        var c = CCClaim(); c.text = "claim"; c.checked = true
        p.claims = [c]
        #expect(!p.isComplete(.claims))             // no source
        c.source = "minutes"; p.claims = [c]
        #expect(p.isComplete(.claims))
        var a = CCAsset(); a.asset = "clip"
        p.assets = [a]; p.disclosureConfirmed = true
        #expect(!p.isComplete(.rights))             // no rights stated
        a.rights = "licensed"; p.assets = [a]
        #expect(p.isComplete(.rights))
        #expect(!p.isComplete(.package))
        p.correctionsPathConfirmed = true
        #expect(p.isComplete(.package))
    }

    @Test("Creator hardcopy: piece → claims table → rights → disclosures")
    func creatorHardcopy() {
        let md = PublishPackageRenderer.markdown(.sample(now: t0), generatedAt: t0)
        assertOrdered(md, ["1. The piece", "2. Claims — checked to a source",
                           "3. Rights & clearances", "4. Disclosures"])
        #expect(md.contains("| Claim | Checked | Source |"))
        #expect(md.contains("Material connections disclosed: **Yes**"))
    }

    // MARK: Individual

    @Test("Binder gates: complete people + located items + instructions + freshness review")
    func binderGates() {
        var b = EmergencyBinder(title: "x", now: t0)
        var c = BinderContact(); c.name = "N"; c.role = "GP"
        b.contacts = [c]
        #expect(b.isComplete(.people))
        var i = BinderItem(); i.item = "Will"
        b.items = [i]
        #expect(!b.isComplete(.documents))          // no location — findability is the point
        i.location = "safe"; b.items = [i]
        #expect(b.isComplete(.documents))
        b.wishes = "call the GP first"
        #expect(b.isComplete(.wishes))
        #expect(!b.isComplete(.binder))
        b.reviewedRecently = true
        #expect(b.isComplete(.binder))
    }

    @Test("Binder hardcopy: people → documents & locations → instructions")
    func binderHardcopy() {
        let md = EmergencyBinderRenderer.markdown(.sample(now: t0), generatedAt: t0)
        assertOrdered(md, ["1. Key people", "2. Documents & accounts", "3. Instructions"])
        #expect(md.contains("| Item | Where it lives | Who can access |"))
        #expect(md.contains("Reviewed within the last year: **Yes**"))
    }

    // MARK: Round-trips + audit trail

    @Test("All four survive a JSON round-trip")
    func codable() throws {
        let r = ResearchReview.sample(now: t0), p = ProofArgument.sample(now: t0)
        let c = PublishPackage.sample(now: t0), b = EmergencyBinder.sample(now: t0)
        #expect(try JSONDecoder().decode(ResearchReview.self, from: JSONEncoder().encode(r)) == r)
        #expect(try JSONDecoder().decode(ProofArgument.self, from: JSONEncoder().encode(p)) == p)
        #expect(try JSONDecoder().decode(PublishPackage.self, from: JSONEncoder().encode(c)) == c)
        #expect(try JSONDecoder().decode(EmergencyBinder.self, from: JSONEncoder().encode(b)) == b)
    }

    @Test("Audit trail: recorded events print on the hardcopy of EVERY studio deliverable")
    func auditTrail() {
        // The shared helper preserves order and prints as an appendix.
        var h: [StudioAuditEntry]? = nil
        StudioAudit.record(&h, "Created", at: t0)
        StudioAudit.record(&h, "Report exported as Markdown", at: t0.addingTimeInterval(60))
        let appendix = StudioAudit.appendix(h)
        #expect(appendix.contains("Document history (audit trail)"))
        #expect(appendix.range(of: "Created")!.lowerBound < appendix.range(of: "Report exported")!.lowerBound)

        // Every studio sample records its creation and prints the appendix.
        #expect(ResearchReviewRenderer.markdown(.sample(now: t0), generatedAt: t0).contains("Document history (audit trail)"))
        #expect(ProofArgumentRenderer.markdown(.sample(now: t0), generatedAt: t0).contains("Document history (audit trail)"))
        #expect(PublishPackageRenderer.markdown(.sample(now: t0), generatedAt: t0).contains("Document history (audit trail)"))
        #expect(EmergencyBinderRenderer.markdown(.sample(now: t0), generatedAt: t0).contains("Document history (audit trail)"))
        #expect(FactCheckMemoRenderer.markdown(.sample(now: t0), generatedAt: t0).contains("Document history (audit trail)"))
        #expect(RCAReportRenderer.markdown(.sample(now: t0), generatedAt: t0).contains("Document history (audit trail)"))
        #expect(ACHReportRenderer.markdown(.sample(now: t0), generatedAt: t0).contains("Document history (audit trail)"))
        #expect(WIReportRenderer.markdown(.sample(now: t0), generatedAt: t0).contains("Document history (audit trail)"))
        #expect(PrivilegeLogRenderer.markdown(.sample(now: t0), generatedAt: t0).contains("Document history (audit trail)"))
        #expect(SIUReportRenderer.markdown(.sample(now: t0), generatedAt: t0).contains("Document history (audit trail)"))
        #expect(FAReportRenderer.markdown(.sample(now: t0), generatedAt: t0).contains("Document history (audit trail)"))

        // Old records saved BEFORE the audit trail existed still decode (history is optional).
        let legacy = "{\"id\":\"00000000-0000-0000-0000-000000000001\",\"title\":\"t\",\"createdAt\":0,\"updatedAt\":0,\"premise\":\"\",\"reporter\":\"\",\"editor\":\"\",\"claims\":[],\"replies\":[],\"allegedLabellingConfirmed\":false,\"correctionsPathConfirmed\":false}"
        let decoded = try? JSONDecoder().decode(FactCheckMemo.self, from: Data(legacy.utf8))
        #expect(decoded != nil)
        #expect(decoded?.history == nil)
    }
}
