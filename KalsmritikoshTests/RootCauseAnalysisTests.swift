//
//  RootCauseAnalysisTests.swift
//  KalsmritikoshTests
//
//  The Reasoning Studio's model + report are pure values, so we can lock the
//  stage-completion logic, the JSON persistence round-trip, and the rendered
//  report content without any UI.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("RootCauseAnalysis — stages, persistence, report")
struct RootCauseAnalysisTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func fullyWorked() -> RootCauseAnalysis {
        var r = RootCauseAnalysis(title: "Late shipment", now: t0)
        r.problemStatement = "The first lot shipped two weeks late."
        r.brainstorm = [RCAIdea(text: "Supplier delay"), RCAIdea(text: "Wrong address", parked: true)]
        r.fiveWhys = [
            RCAWhyStep(question: "Why late?", answer: "Parts arrived late"),
            RCAWhyStep(question: "Why did parts arrive late?", answer: "PO was issued late"),
            RCAWhyStep(question: "Why was the PO late?", answer: "No reorder trigger", evidence: "PO-1042")
        ]
        if let i = r.fishbone.firstIndex(where: { $0.name == "Process" }) {
            r.fishbone[i].causes = [RCAFishboneCause(text: "No reorder trigger", likely: true),
                                    RCAFishboneCause(text: "Manual PO entry")]
        }
        r.conclusion.rootCause = "The reorder point was never configured."
        r.conclusion.contributingFactors = ["Manual PO process"]
        r.conclusion.recommendations = [
            RCARecommendation(text: "Set an automatic reorder trigger", addresses: .rootCause),
            RCARecommendation(text: "Add a weekly stock review", addresses: .contributing)
        ]
        r.conclusion.summary = "A missing reorder trigger caused the delay."
        r.approval.preparedBy = "A. Investigator"
        r.approval.submittedTo = "Operations Director"
        return r
    }

    @Test("Stage completion follows the work done")
    func stageCompletion() {
        var r = RootCauseAnalysis(title: "x", now: t0)
        #expect(!r.isComplete(.frame))
        r.problemStatement = "Something went wrong"
        #expect(r.isComplete(.frame))

        // 5 Whys needs at least three answered rungs.
        r.fiveWhys = [RCAWhyStep(question: "a", answer: "1"), RCAWhyStep(question: "b", answer: "2")]
        #expect(!r.isComplete(.fiveWhys))
        r.fiveWhys.append(RCAWhyStep(question: "c", answer: "3"))
        #expect(r.isComplete(.fiveWhys))

        #expect(!r.isComplete(.conclude))
        r.conclusion.rootCause = "root"
        #expect(r.isComplete(.conclude))

        #expect(!r.isComplete(.report))
        r.approval.status = .approved
        #expect(r.isComplete(.report))
    }

    @Test("completionFraction reaches 1 when the five working stages are done")
    func fraction() {
        let r = fullyWorked()   // frame, brainstorm, fiveWhys, fishbone, conclude all satisfied
        #expect(r.completionFraction == 1.0)
    }

    @Test("A whole analysis survives a JSON round-trip")
    func codableRoundTrip() throws {
        let original = [fullyWorked()]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([RootCauseAnalysis].self, from: data)
        #expect(decoded == original)
    }

    @Test("The report carries every section's content")
    func reportContent() {
        var r = fullyWorked()
        r.approval.status = .approved
        r.approval.approver = "The Director"
        r.approval.decidedAt = t0
        let md = RCAReportRenderer.markdown(r, generatedAt: t0)

        #expect(md.contains("Root-Cause Analysis — Late shipment"))
        #expect(md.contains("The first lot shipped two weeks late."))
        #expect(md.contains("Supplier delay"))
        #expect(md.contains("No reorder trigger"))
        #expect(md.contains("⭐️"))                       // a probable cause is starred
        #expect(md.contains("The reorder point was never configured."))
        #expect(md.contains("1. Set an automatic reorder trigger")) // numbered recommendations
        #expect(md.contains("A. Investigator"))
        #expect(md.contains("Operations Director"))
        #expect(md.contains("Approved"))
        #expect(md.contains("The Director"))
        // Parked ideas are shown separately, not in the main list.
        #expect(md.contains("Parked"))
    }

    @Test("Default fishbone has the six Ishikawa arms")
    func defaultCategories() {
        let r = RootCauseAnalysis(title: "x", now: t0)
        #expect(r.fishbone.count == 6)
        #expect(r.fishbone.map(\.name).contains("People"))
        #expect(r.fishbone.map(\.name).contains("Information & Evidence"))
    }
}
