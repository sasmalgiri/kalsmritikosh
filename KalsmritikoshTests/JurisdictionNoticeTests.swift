//
//  JurisdictionNoticeTests.swift
//  KalsmritikoshTests
//
//  D-7 (completion instructions) — studios whose templates cite a named
//  national instrument disclose that the citation is jurisdiction-specific
//  (procedure neutral, citation not; adapt + record an authorized deviation),
//  and every studio hardcopy prints the disclosure in its appendix.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Jurisdiction disclosure (D-7)")
struct JurisdictionNoticeTests {

    private let t0 = Date(timeIntervalSince1970: 1_769_200_000)

    /// The six instruments the studio surfaces disclose (see the studio views /
    /// StudioConfig call sites — these strings must stay in step with them).
    private static let instruments = [
        "US FRCP 26(b)(5)(A)",
        "US FRCP 26(a)(2)(B) and Daubert",
        "NAIC Model #901 and NICB indicators (US)",
        "the balance-of-probabilities standard with notice and opportunity to respond (UK ACAS / US EEOC practice)",
        "the US FTC Endorsement Guides (2023)",
        "the Genealogical Proof Standard (BCG, US)"
    ]

    @Test("Every studio disclosure names its instrument and the adapt-locally duty")
    func studioLines() {
        for instrument in Self.instruments {
            let line = JurisdictionNotice.studio(instrument: instrument)
            #expect(line.contains(instrument))
            #expect(line.contains("adapt it to your jurisdiction"))
            #expect(line.contains("authorized deviation"))
            #expect(line.contains("SOP register"))
        }
    }

    @Test("The hardcopy appendix ends with the jurisdiction line when history exists")
    func appendixCarriesDisclosure() {
        var h: [StudioAuditEntry]? = nil
        StudioAudit.record(&h, "Created", at: t0)
        let appendix = StudioAudit.appendix(h)
        #expect(appendix.hasSuffix("_\(JurisdictionNotice.hardcopy)_\n"))
        // No history → no appendix, unchanged fail-safe.
        #expect(StudioAudit.appendix(nil).isEmpty)
        #expect(StudioAudit.appendix([]).isEmpty)
    }

    @Test("Served documents carry the appendix disclosure but NO app-navigation text in the header")
    func rendererDisclosures() {
        // Reviewer nit (seventeenth review): a SERVED privilege log / report
        // must not contain "Settings → Compliance Board" navigation copy in
        // its header — the restrained appendix line is the disclosure. The
        // legal citation stays.
        let privilegeLog = PrivilegeLogRenderer.markdown(.sample(now: t0), generatedAt: t0)
        let siu = SIUReportRenderer.markdown(.sample(now: t0), generatedAt: t0)
        let publish = PublishPackageRenderer.markdown(.sample(now: t0), generatedAt: t0)
        for served in [privilegeLog, siu, publish] {
            #expect(served.contains(JurisdictionNotice.hardcopy))
            #expect(!served.contains("Settings → Compliance Board"))
        }
        #expect(privilegeLog.contains("Pursuant to Fed. R. Civ. P. 26(b)(5)(A)."))
    }
}
