//
//  SutraGovernanceTests.swift
//  KalsmritikoshTests
//
//  Constitutional change-governance: amendments are the only sanctioned way to
//  alter a sutra (version bumps, history appends), and every conformance
//  certificate names the exact constitution + version it verified against.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Sūtra governance")
struct SutraGovernanceTests {

    @Test("Amending a sutra bumps the version and appends to the history — never rewrites it")
    func amendment() {
        let v1 = SutraCompiler.shared()
        #expect(v1.version == 1)
        let v2 = v1.amended(on: "2026-08-23", summary: "Tightened the findings gate.")
        #expect(v2.version == 2)
        #expect(v2.id == v1.id)
        #expect(v2.amendments?.count == 1)
        #expect(v2.amendments?.last?.summary == "Tightened the findings gate.")
        let v3 = v2.amended(on: "2026-09-01", summary: "Added a custody phase.")
        #expect(v3.version == 3)
        #expect(v3.amendments?.map(\.version) == [2, 3])   // history preserved, oldest first
        // The original is untouched — constitutions are amended, not edited.
        #expect(v1.version == 1 && v1.amendments == nil)
    }

    @Test("The conformance certificate names the constitution and version it verified against")
    func certificateCitesConstitution() {
        let sutra = SutraCompiler.shared()
        let run = RunRecord(completedPhaseKinds: [.findings],
                            standardOfProofDeclared: true, openItemsAcknowledged: true,
                            humanDecisionsMade: [.findings])
        let report = SutraConformance.verify(run: run, against: sutra)
        #expect(report.constitution == sutra.citation)
        #expect(report.certificate.contains("**Constitution:** \(sutra.citation)"))
        #expect(sutra.citation.contains("v\(sutra.version)"))
    }

    @Test("A sutra recorded before governance existed still decodes (amendments optional)")
    func legacyDecodes() throws {
        var old = SutraCompiler.shared()
        old.amendments = nil
        let data = try JSONEncoder().encode(old)
        // Strip the key entirely to simulate a pre-governance record.
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "amendments")
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(Sutra.self, from: stripped)
        #expect(decoded.amendments == nil)
        #expect(decoded.id == old.id)
    }
}
