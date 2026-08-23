//
//  PrivacyPostureTests.swift
//  KalsmritikoshTests
//
//  Fully-private-by-default is a LOCKED ship decision (owner, 2026-08-23):
//  zero downloads, zero network, no cloud, no user-facing model setup.
//  These tests pin the locked profile and the public claim so a drifted
//  build fails here before it can ship a weaker posture.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Privacy posture — fully private by default")
struct PrivacyPostureTests {

    @Test("The locked v1 profile is fully private: no cloud, no setup UI, no downloads")
    func lockedProfile() {
        let p = ReleaseCapabilityProfile.v1
        #expect(p.cloudRoutingEnabled == false)
        #expect(p.ollamaUserSetupVisible == false)
        #expect(p.byoModelUIVisible == false)
        #expect(p.optionalModelDownloadEnabled == false)
        #expect(p.bundledReasoningProviderRequired == true)
        #expect(p.silentLLMBackgroundMaintenanceEnabled == false)
    }

    @Test("The public privacy claim states the zero-network posture explicitly")
    func publicClaim() {
        let s = LegalNotice.privacyStatement
        #expect(s.contains("no network connections"))
        #expect(s.contains("nothing to download"))
        #expect(!s.contains("one-time download"))   // the pre-1.4 weaker claim must not resurface
    }
}
