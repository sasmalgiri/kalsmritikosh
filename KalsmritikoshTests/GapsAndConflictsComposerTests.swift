//
//  GapsAndConflictsComposerTests.swift
//  KalsmritikoshTests
//
//  PA-WP — the disclosure composer. Conflicts and gaps are rendered as disclosures (never
//  material assertions): both conflict sides are preserved without choosing or averaging;
//  gaps state that absence is not proof and carry no fabricated citation. Disclosures never
//  trip the fail-closed export gate and cannot satisfy a material-evidence minimum. Output is
//  two sections (conflicts first, gaps second) in deterministic order; empty input yields an
//  explicit "none found" preamble.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PA-WP — gaps & conflicts disclosure composer")
struct GapsAndConflictsComposerTests {

    private func conflict(_ a: String, _ b: String, severity: Contradiction.Severity = .medium,
                          id: UUID = UUID(), evidence: [EvidenceReference] = []) -> SelectedConflict {
        SelectedConflict(id: id, description: "d", sideA: a, sideB: b,
                         supportingClaimIDs: [UUID()], evidence: evidence, severity: severity)
    }
    private func gap(_ desc: String, kind: GapKind = .threadParent, confidence: Double = 0.3,
                     id: UUID = UUID()) -> SelectedGap {
        SelectedGap(id: id, kind: kind, description: desc, reason: "r", confidence: confidence, relatedClaimIDs: [UUID()])
    }
    private func ctx(conflicts: [SelectedConflict] = [], gaps: [SelectedGap] = []) -> WorkProductContext {
        WorkProductContext(selectedClaims: [], selectedConflicts: conflicts, selectedGaps: gaps, subjectLabel: "S")
    }

    @Test("Two sections are returned in stable order: conflicts first, gaps second")
    func twoSectionsInOrder() {
        let sections = GapsAndConflictsComposer().compose(ctx(conflicts: [conflict("A", "B")], gaps: [gap("g")]))
        #expect(sections.map(\.title) == ["Conflicts", "Gaps"])
    }

    @Test("Both conflict sides are preserved verbatim; the claim is an inference disclosure")
    func bothSidesPreservedAsDisclosure() {
        let s = GapsAndConflictsComposer().compose(ctx(conflicts: [conflict("Paid on the 3rd", "Paid on the 9th")]))[0]
        let claim = try! #require(s.claims.first)
        #expect(claim.text.contains("A: Paid on the 3rd"))
        #expect(claim.text.contains("B: Paid on the 9th"))
        #expect(claim.status == .inference)                 // never a source assertion
    }

    @Test("A conflict's two sides keep supporting and contradicting evidence separate")
    func contradictingEvidenceSeparate() {
        let ev = [EvidenceReference(objectID: UUID(), role: .supports),
                  EvidenceReference(objectID: UUID(), role: .contradicts)]
        let s = GapsAndConflictsComposer().compose(ctx(conflicts: [conflict("A", "B", evidence: ev)]))[0]
        let claim = try! #require(s.claims.first)
        #expect(claim.supporting.count == 1)
        #expect(claim.contradicting.count == 1)
    }

    @Test("Conflicts order by severity (high first), then id")
    func conflictOrdering() {
        let ids = [UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        let low = conflict("a", "b", severity: .low, id: ids[0])
        let high = conflict("c", "d", severity: .high, id: ids[1])
        let s = GapsAndConflictsComposer().compose(ctx(conflicts: [low, high]))[0]
        #expect(s.claims.first?.text.contains("A: c") == true)   // high severity leads
    }

    @Test("Gaps are inference disclosures that state absence is not proof, with no citation")
    func gapsAreCitationFreeDisclosures() {
        let s = GapsAndConflictsComposer().compose(ctx(gaps: [gap("the signed final")]))[1]
        let claim = try! #require(s.claims.first)
        #expect(claim.status == .inference)
        #expect(claim.text.contains("Missing evidence: the signed final"))
        #expect(claim.text.contains("may exist outside the indexed archive"))
        #expect(claim.supporting.isEmpty && claim.contradicting.isEmpty)   // no fabricated citation
    }

    @Test("Gaps order by kind, then confidence (higher first), then id")
    func gapOrdering() {
        let g1 = gap("x", kind: .cadenceBreak, confidence: 0.2)
        let g2 = gap("y", kind: .cadenceBreak, confidence: 0.8)
        let g3 = gap("z", kind: .threadParent, confidence: 0.5)
        let claims = GapsAndConflictsComposer().compose(ctx(gaps: [g1, g2, g3]))[1].claims
        // cadenceBreak < threadParent by rawValue; within cadenceBreak, higher confidence first.
        #expect(claims.map { String($0.text.dropFirst("Missing evidence: ".count).prefix(1)) } == ["y", "x", "z"])
    }

    @Test("Empty input yields explicit 'none found' preambles and no claims")
    func emptyInputPreamble() {
        let sections = GapsAndConflictsComposer().compose(ctx())
        #expect(sections[0].claims.isEmpty)
        #expect(sections[0].preamble.contains { $0.contains("No conflicting accounts") })
        #expect(sections[1].claims.isEmpty)
        #expect(sections[1].preamble.contains { $0.contains("No missing-evidence gaps") })
    }

    @Test("Disclosures never trip the fail-closed export gate, even with unresolved citations")
    func disclosuresDoNotBlockExport() {
        // A conflict carrying only unresolved evidence + a gap.
        let ev = [EvidenceReference(objectID: UUID(), role: .supports)]   // no sourceVersionID → unresolved
        let sections = GapsAndConflictsComposer().compose(ctx(conflicts: [conflict("A", "B", evidence: ev)], gaps: [gap("g")]))
        let wp = WorkProduct(template: .generalSummary, title: "T", sections: sections)
        #expect(WorkProductValidator().validateProductionExport(wp).isValid)   // disclosures are not material
    }

    @Test("Disclosures cannot satisfy a material-evidence minimum (all are inference-framed)")
    func disclosuresAreNeverMaterial() {
        let sections = GapsAndConflictsComposer().compose(ctx(conflicts: [conflict("A", "B")], gaps: [gap("g")]))
        let statuses = Set(sections.flatMap(\.claims).map(\.status))
        #expect(statuses == [.inference])                    // never directEvidence/sourceAssertion
    }
}
