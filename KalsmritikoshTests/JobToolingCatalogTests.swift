//
//  JobToolingCatalogTests.swift
//  KalsmritikoshTests
//
//  The machine-readable job-depth map (Sūtra roadmap step 1) must cover every
//  shared job-kind and match the map's classifications.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("JobToolingCatalog — the Sūtra tooling map")
struct JobToolingCatalogTests {

    @Test("Every PersonaJobKind has exactly one profile")
    func coverage() {
        for kind in PersonaJobKind.allCases {
            #expect(JobToolingCatalog.profile(for: kind) != nil, "missing profile for \(kind)")
        }
        // No duplicates.
        #expect(JobToolingCatalog.profiles.count == PersonaJobKind.allCases.count)
    }

    @Test("The three analytic jobs are exactly the ones that warrant a studio")
    func analyticTier() {
        let analytic = Set(JobToolingCatalog.analyticKinds)
        #expect(analytic.contains(.analysis))
        #expect(analytic.contains(.causalAnalysis))
        #expect(analytic.contains(.linkage))
        // A capture/decide job must never be analyze-tier.
        #expect(!analytic.contains(.dataLab))
        #expect(!analytic.contains(.findings))
        #expect(JobToolingCatalog.profile(for: .dataLab)?.tier.warrantsStudio == false)
        #expect(JobToolingCatalog.profile(for: .causalAnalysis)?.tier.warrantsStudio == true)
    }

    @Test("The map's headline fix: analysis = ACH → the Competing Hypotheses studio")
    func analysisIsACH() {
        let p = JobToolingCatalog.profile(for: .analysis)
        #expect(p?.tier == .analyze)
        #expect(p?.method == .ach)
        #expect(p?.surface == "hypotheses")
    }

    @Test("Key surfaces line up with real destinations")
    func surfaces() {
        #expect(JobToolingCatalog.profile(for: .causalAnalysis)?.surface == "reasoning")
        #expect(JobToolingCatalog.profile(for: .dataLab)?.surface == "dataLab")
        #expect(JobToolingCatalog.profile(for: .findings)?.surface == "handoff")
        #expect(JobToolingCatalog.profile(for: .ask)?.surface == "ask")
        // Every declared surface is a real RootView Destination.
        for p in JobToolingCatalog.profiles {
            if let s = p.surface { #expect(Destination(rawValue: s) != nil, "unknown surface \(s) for \(p.kind)") }
        }
    }
}
