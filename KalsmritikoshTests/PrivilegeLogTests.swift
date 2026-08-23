//
//  PrivilegeLogTests.swift
//  KalsmritikoshTests
//
//  Persona studio #2 — the FRCP 26(b)(5) privilege log must follow the real
//  steps and render the exact hardcopy table.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Privilege log studio")
struct PrivilegeLogTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Stages follow the real-life order and gate on real conditions")
    func stages() {
        var p = PrivilegeLog(title: "x", now: t0)
        #expect(PrivilegeLog.Stage.allCases.map(\.title) == ["Matter", "Withheld documents", "QC review", "Log"])
        #expect(!p.isComplete(.matter))
        p.caption = "Doe v. Acme"; p.producingParty = "Acme"
        #expect(p.isComplete(.matter))
        // Entries gate on completeness (date/type/author/description).
        var e = PLEntry(); p.entries = [e]
        #expect(!p.isComplete(.entries))
        e.date = "2026-01-01"; e.docType = "Email"; e.author = "A"; e.descriptionText = "Seeking legal advice re X."
        p.entries = [e]
        #expect(p.isComplete(.entries))
        // The log is served only after BOTH QC confirmations.
        #expect(!p.isComplete(.log))
        p.descriptionsDoNotRevealContent = true; p.everyEntryHasBasis = true
        #expect(p.isComplete(.log))
    }

    @Test("The rendered log is the exact hardcopy: rule cite, caption, table columns, legend, certification")
    func hardcopy() {
        let md = PrivilegeLogRenderer.markdown(.sample(now: t0), generatedAt: t0)
        #expect(md.hasPrefix(LegalNotice.reportDisclaimer))
        #expect(md.contains("Fed. R. Civ. P. 26(b)(5)(A)"))
        #expect(md.contains("Doe v. Acme Corp., No. 1:26-cv-0421"))
        // The table header with the standard columns, in order.
        #expect(md.contains("| No. | Date | Type | Author | Recipient(s) | CC | Privilege | Description | Bates / Control |"))
        // Privilege codes render compactly (AC / WP / AC/WP).
        #expect(md.contains("| AC |"))
        #expect(md.contains("| WP |"))
        #expect(md.contains("| AC/WP |"))
        // Legend + the 26(b)(5) description discipline stated on the document.
        #expect(md.contains("AC = attorney–client privilege"))
        #expect(md.contains("without revealing the privileged or protected information"))
        // Certification block.
        #expect(md.contains("Certified:"))
        #expect(md.contains("ACME-PRIV-000001"))
    }

    @Test("A whole log survives a JSON round-trip (persistence)")
    func codable() throws {
        let original = [PrivilegeLog.sample(now: t0)]
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode([PrivilegeLog].self, from: data) == original)
    }
}
