//
//  AIMethodReviewContractTests.swift
//  KalsmritikoshTests
//
//  Case plan 2026-11-16 (AI-15): what the app keeps from an AI's method review — scripted replies only, no model, no
//  network. Registered method ids only; outcomes from the vocabulary; quotes verified word for word against the documents
//  sent (an unverified check is kept labelled ungrounded); methods the reply leaves out are "not assessed"; checks join the
//  shortlist with the same merge and ranking rules.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@MainActor
@Suite("AI method review contract — checked against what was sent")
struct AIMethodReviewContractTests {
    let doc = (objectID: UUID(), text: "The HPLC-2 calibration was last recorded on 2 January 2026. Batch 42 failed the assay on 3 March 2026.")

    @Test("A valid reply is kept with its checks; an unknown method, a bad outcome and a fabricated quote are dropped with reasons; the rest are not assessed")
    func verifyReply() {
        let methods = CaseMethodReviewMethod.registered
        let reply = """
        {"methods": [
          {"method_id": "com.kalsmritikosh.method.fishbone", "outcome": "usefulNow", "reason": "Equipment has had no scrutiny",
           "checks": [{"observation": "Calibration certificate for HPLC-2", "target": "QC laboratory",
                       "predicts": {"instrument drift": "calibration overdue", "supplier variation": "calibration current"},
                       "evidence": [{"document": 1, "quote": "The HPLC-2 calibration was last recorded on 2 January 2026"}]},
                      {"observation": "Supplier's certificate of analysis", "target": "Supplier", "evidence": [{"document": 1, "quote": "the supplier admitted fault"}]}]},
          {"method_id": "com.example.method.unknown", "outcome": "usefulNow", "reason": "x"},
          {"method_id": "com.kalsmritikosh.method.capa", "outcome": "certain", "reason": "x"},
          {"method_id": "com.kalsmritikosh.method.five-whys", "outcome": "usefulLater", "reason": "After the certificate"}
        ]}
        """
        let r = AIMethodReviewContract.verify(reply: reply, methods: methods, documents: [doc])
        #expect(r.assessments.count == methods.count)
        let byID = Dictionary(uniqueKeysWithValues: r.assessments.map { ($0.methodID, $0) })
        #expect(byID["com.kalsmritikosh.method.fishbone"]?.outcome == .usefulNow && byID["com.kalsmritikosh.method.fishbone"]?.reason.hasPrefix("The AI's suggestion") == true)
        #expect(byID["com.kalsmritikosh.method.capa"]?.outcome == .notAssessed, "a bad outcome is not kept")
        #expect(r.notCovered.count == methods.count - 2)
        #expect(r.dropped.contains { $0.hasPrefix("not a registered method") } && r.dropped.contains { $0.contains("outside the vocabulary") }
                && r.dropped.contains { $0.contains("not found word for word") }, "\(r.dropped)")
        #expect(r.checks.count == 2)
        #expect(r.checks[0].ungrounded == false && r.checks[0].verifiedQuotes.first?.objectID == doc.objectID)
        #expect(r.checks[1].ungrounded, "the check whose quote did not verify is labelled ungrounded")
        let cands = AIMethodReviewContract.candidates(r)
        #expect(cands[1].title.contains("ungrounded"))
        // The AI's check and an offline proposal asking for the same thing from the same target merge into one.
        let offline = CaseCheckCandidate(id: "gap", title: "Get the certificate", observation: "calibration certificate — HPLC-2", target: "qc laboratory", origin: .gap)
        #expect(CaseCheckShortlist.rank(cands + [offline]).filter { $0.observation.lowercased().contains("calibration") }.count == 1)
    }

    @Test("An unreadable reply leaves every method not assessed and keeps nothing")
    func unreadable() {
        let methods = CaseMethodReviewMethod.registered
        let r = AIMethodReviewContract.verify(reply: "Sorry, I can't help.", methods: methods, documents: [doc])
        #expect(r.assessments.allSatisfy { $0.outcome == .notAssessed } && r.checks.isEmpty && r.notCovered.count == methods.count)
        #expect(AIMethodReviewContract.task(question: "Why did batch 42 fail?", methods: methods).contains("Quote only words that are in the documents"))
    }
}
