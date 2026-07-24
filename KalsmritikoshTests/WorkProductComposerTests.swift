//
//  WorkProductComposerTests.swift
//  KalsmritikoshTests
//
//  PA-002/003/004 — the ResolvedClaim-native section-composer architecture. Locks: the
//  registry rejects duplicate registrations and orders deterministically; HistoryChronology
//  Composer conforms and renders ONLY the supplied resolved claims, in order, evaluating the
//  EFFECTIVE assessment (latest review) via the canonical AssertabilityPolicy; a refused
//  claim is dropped; citations come from the claim's own evidence.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PA-002/004 — work-product section composers")
struct WorkProductComposerTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func resolved(_ statement: String,
                          basis: EvidenceBasis,
                          review: ReviewDisposition = .unreviewed,
                          origin: ProposalOrigin = .sourceExtraction,
                          evidence: [EvidenceReference]) -> ResolvedClaim {
        let assessment = EvidenceAssessment(basis: basis, review: review, origin: origin)
        let claim = Claim(subjectID: UUID(), subjectLabel: "Subject A", statement: statement,
                          assessment: assessment, confidence: 0.8, evidence: evidence, createdAt: t0)
        // effectiveAssessment is what a resolver would produce; construct it directly here.
        return ResolvedClaim(claim: claim, effectiveAssessment: assessment)
    }

    /// A minimal second composer so registry ordering / lookup can be exercised.
    private struct StubComposer: WorkProductSectionComposer {
        let id = WorkProductComposerID("aaa.stub")
        let sectionKind: BlueprintSection.Kind = .summary
        func compose(_ context: WorkProductContext) -> [WorkProductSection] { [] }
    }

    // MARK: Registry

    @Test("Registry looks composers up by id and orders them deterministically")
    func registryLookupAndOrder() throws {
        var reg = WorkProductComposerRegistry()
        try reg.register(HistoryChronologyComposer())     // id "history.chronology"
        try reg.register(StubComposer())                  // id "aaa.stub"
        #expect(reg.composer(for: WorkProductComposerID("history.chronology")) != nil)
        #expect(reg.composer(for: WorkProductComposerID("aaa.stub")) != nil)
        #expect(reg.composer(for: WorkProductComposerID("nope")) == nil)
        // Deterministic order = by id ascending.
        #expect(reg.all.map(\.id) == [WorkProductComposerID("aaa.stub"), WorkProductComposerID("history.chronology")])
    }

    @Test("Registering a duplicate composer id is rejected")
    func registryRejectsDuplicate() throws {
        var reg = WorkProductComposerRegistry()
        try reg.register(HistoryChronologyComposer())
        #expect(throws: WorkProductComposerRegistry.RegistrationError.duplicate(WorkProductComposerID("history.chronology"))) {
            try reg.register(HistoryChronologyComposer())
        }
    }

    // MARK: HistoryChronologyComposer conformance

    @Test("The composer identifies as the chronology composer")
    func composerIdentity() {
        let c = HistoryChronologyComposer()
        #expect(c.id == WorkProductComposerID("history.chronology"))
        #expect(c.sectionKind == .chronology)
    }

    @Test("Composes one section rendering the supplied claims IN ORDER")
    func rendersInOrder() {
        let a = resolved("First", basis: .directlyObserved, evidence: [EvidenceReference(objectID: UUID(), blockID: UUID(), sourceVersionID: UUID())])
        let b = resolved("Second", basis: .sourceAsserted, evidence: [EvidenceReference(objectID: UUID(), blockID: UUID(), sourceVersionID: UUID())])
        let ctx = WorkProductContext(claims: [a, b], subjectLabel: "Subject A")
        let sections = HistoryChronologyComposer().compose(ctx)
        #expect(sections.count == 1)
        #expect(sections[0].claims.map(\.text) == ["First", "Second"])   // order preserved
    }

    @Test("Status comes from the canonical policy: observed+locator → direct evidence; inferred → inference")
    func statusMapping() {
        let observed = resolved("Observed", basis: .directlyObserved,
                                evidence: [EvidenceReference(objectID: UUID(), blockID: UUID(), sourceVersionID: UUID())])
        let inferred = resolved("Inferred", basis: .inferred, origin: .modelProposed,
                                evidence: [EvidenceReference(objectID: UUID(), blockID: UUID())])
        let sections = HistoryChronologyComposer().compose(
            WorkProductContext(claims: [observed, inferred], subjectLabel: "S"))
        let byText = Dictionary(uniqueKeysWithValues: sections[0].claims.map { ($0.text, $0.status) })
        #expect(byText["Observed"] == .directEvidence)
        #expect(byText["Inferred"] == .inference)
    }

    @Test("A claim the policy refuses (rejected review) is dropped — fail closed on the effective assessment")
    func refusedClaimDropped() {
        // Stored basis would assert as fact, but the EFFECTIVE review is rejected → refuse.
        let base = EvidenceAssessment(basis: .directlyObserved, origin: .sourceExtraction)
        let claim = Claim(subjectID: UUID(), subjectLabel: "S", statement: "Rejected claim",
                          assessment: base, confidence: 0.9,
                          evidence: [EvidenceReference(objectID: UUID(), blockID: UUID(), sourceVersionID: UUID())],
                          createdAt: t0)
        let rejected = ResolvedClaim(claim: claim, effectiveAssessment: base.with(review: .rejected))
        let ok = resolved("Kept", basis: .directlyObserved,
                          evidence: [EvidenceReference(objectID: UUID(), blockID: UUID(), sourceVersionID: UUID())])
        let sections = HistoryChronologyComposer().compose(
            WorkProductContext(claims: [rejected, ok], subjectLabel: "S"))
        #expect(sections[0].claims.map(\.text) == ["Kept"])          // rejected one dropped
    }

    @Test("Citations are built from the claim's own evidence; contradicting role is kept separate")
    func citationsFromEvidence() {
        let support = EvidenceReference(objectID: UUID(), blockID: UUID(), sourceVersionID: UUID(), role: .supports)
        let against = EvidenceReference(objectID: UUID(), blockID: UUID(), sourceVersionID: UUID(), role: .contradicts)
        let c = resolved("Claim", basis: .sourceAsserted, evidence: [support, against])
        let section = HistoryChronologyComposer().compose(
            WorkProductContext(claims: [c], subjectLabel: "S"))[0]
        let rendered = try! #require(section.claims.first)
        #expect(rendered.supporting.count == 1)
        #expect(rendered.contradicting.count == 1)
        #expect(rendered.supporting.first?.isResolved == true)       // sourceVersionID present → reopenable
    }
}
