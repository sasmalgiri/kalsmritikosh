//
//  ReportDisclaimerTests.swift
//  KalsmritikoshTests
//
//  Every exported studio report must carry the standard legal disclaimer.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Report disclaimers")
struct ReportDisclaimerTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("The ACH report leads with the standard disclaimer")
    func achDisclaimer() {
        let md = ACHReportRenderer.markdown(.sample(now: t0), generatedAt: t0)
        #expect(md.hasPrefix(LegalNotice.reportDisclaimer))
        #expect(md.lowercased().contains("not") && md.lowercased().contains("professional"))
    }

    @Test("The Reasoning-Studio (RCA) report leads with the standard disclaimer")
    func rcaDisclaimer() {
        let md = RCAReportRenderer.markdown(.sample(now: t0), generatedAt: t0)
        #expect(md.hasPrefix(LegalNotice.reportDisclaimer))
    }
}
