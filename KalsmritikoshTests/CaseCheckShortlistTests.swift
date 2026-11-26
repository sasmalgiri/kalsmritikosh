//
//  CaseCheckShortlistTests.swift
//  KalsmritikoshTests
//
//  Case plan 2026-11-16 (ACTION-14, ACTION-15): one check per observation (merged proposals keep every explanation), never
//  merging different targets; ranked by a sourced deadline, then the explanations it bears on, then known effort, with
//  stable ties; an override with its reason; rank is never a likelihood.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Check shortlist — merged by observation, ranked by explainable rules")
struct CaseCheckShortlistTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let h1 = UUID(), h2 = UUID(), h3 = UUID()

    @Test("Three methods proposing one certificate request give one check that serves all their explanations")
    func threeMethodsOneRequest() {
        let cands = [
            CaseCheckCandidate(id: "m:fishbone", title: "Ask for the calibration certificate", observation: "Calibration certificate for HPLC-2",
                               target: "QC laboratory", origin: .method, explanations: [h1]),
            CaseCheckCandidate(id: "m:five-whys", title: "Calibration certificate", observation: "calibration certificate — HPLC-2",
                               target: "QC Laboratory", origin: .method, explanations: [h2]),
            CaseCheckCandidate(id: "m:gap", title: "Get the certificate", observation: "Calibration Certificate for HPLC 2", target: "qc laboratory",
                               origin: .gap, explanations: [h2, h3]),
        ]
        let checks = CaseCheckShortlist.rank(cands, now: now)
        #expect(checks.count == 1)
        #expect(checks.first?.mergedFrom.sorted() == ["m:fishbone", "m:five-whys", "m:gap"])
        #expect(checks.first?.explanations == [h1, h2, h3])
    }

    @Test("Two similar payments to different people are two checks")
    func differentTargetsNeverMerge() {
        let cands = [
            CaseCheckCandidate(id: "a", title: "Trace INR 50,000", observation: "Bank record of INR 50,000 on 5 March", target: "Kestrel Supplies", origin: .method),
            CaseCheckCandidate(id: "b", title: "Trace INR 50,000", observation: "Bank record of INR 50,000 on 5 March", target: "Northwind Ltd", origin: .method),
        ]
        #expect(CaseCheckShortlist.rank(cands, now: now).count == 2)
    }

    @Test("A verified imminent expiry outranks a cheaper check that can wait; an unsourced date does not rank as a deadline")
    func deadlineFirst() {
        let soon = now.addingTimeInterval(2 * 86_400)
        let cands = [
            CaseCheckCandidate(id: "cheap", title: "Read the email", observation: "Email of 3 March", target: "case", origin: .method,
                               explanations: [h1, h2], effortHours: 0.5),
            CaseCheckCandidate(id: "log", title: "Preserve the raw instrument log", observation: "Raw log HPLC-2", target: "QC laboratory",
                               origin: .request, deadline: soon, deadlineSource: "the laboratory's 30-day retention policy, SOP-17 §4", effortHours: 4),
            CaseCheckCandidate(id: "noted", title: "Call the courier", observation: "Courier manifest", target: "courier", origin: .method,
                               deadline: now.addingTimeInterval(86_400), deadlineSource: nil),
        ]
        let checks = CaseCheckShortlist.rank(cands, now: now)
        #expect(checks.map(\.id) == ["log", "cheap", "noted"], "\(checks.map(\.id))")
        #expect(checks[0].why.contains("SOP-17") && checks[2].why.contains("its source is not"))
        #expect(checks.allSatisfy { $0.why.contains("not a measure of what is true") })
    }

    @Test("More explanations first, then known effort, unknown effort last; ties stable; an override moves a check with its reason")
    func discriminationEffortTiesOverride() {
        let cands = [
            CaseCheckCandidate(id: "c", title: "Gamma", observation: "o3", target: "t", origin: .method, explanations: [h1]),
            CaseCheckCandidate(id: "a", title: "Alpha", observation: "o1", target: "t", origin: .method, explanations: [h1, h2], effortHours: 3),
            CaseCheckCandidate(id: "b", title: "Beta", observation: "o2", target: "t", origin: .method, explanations: [h1, h2], effortHours: 1),
            CaseCheckCandidate(id: "d", title: "Delta", observation: "o4", target: "t", origin: .method, explanations: [h1]),
        ]
        #expect(CaseCheckShortlist.rank(cands, now: now).map(\.id) == ["b", "a", "d", "c"], "two explanations first, less effort first, then title")
        let moved = CaseCheckShortlist.rank(cands, overrides: [CaseCheckOverride(checkID: "d", position: 0, reason: "The witness leaves on Friday")], now: now)
        #expect(moved.map(\.id) == ["d", "b", "a", "c"])
        #expect(moved[0].overrideReason == "The witness leaves on Friday" && moved[1].overrideReason == nil)
        #expect(CaseCheckShortlist.rank(Array(cands.reversed()), now: now).map(\.id) == ["b", "a", "d", "c"], "stable whatever the input order")
    }
}
