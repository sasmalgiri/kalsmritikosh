//
//  SourcedSummaryComposerTests.swift
//  KalsmritikoshTests
//
//  PA-WP — the sourced-summary composer. Locks: the five assertive presentation forms sit in
//  the sourced section with distinct labels; corrected vs confirmed user-attributed claims get
//  different labels; inference and conflict live only in the disclosure sections; refused
//  claims are absent; corroboration needs independent keys; unverified deterministic stays
//  inference while verified reproducible renders as derived; citations stay separate;
//  composition is persona-invariant and stably ordered; empty input yields explicit prose.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PA-WP — sourced summary composer")
struct SourcedSummaryComposerTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func ref(_ obj: UUID = UUID(), block: UUID? = UUID(), role: EvidenceReference.Role = .supports) -> EvidenceReference {
        EvidenceReference(objectID: obj, blockID: block, sourceVersionID: UUID(), role: role)
    }
    private func selected(_ statement: String, _ assessment: EvidenceAssessment,
                          evidence: [EvidenceReference], keys: [UUID: String] = [:],
                          reproducible: Bool = false, id: UUID = UUID()) -> SelectedClaim {
        let claim = Claim(id: id, subjectID: UUID(), subjectLabel: "S", statement: statement,
                          assessment: assessment, confidence: 0.8, evidence: evidence, createdAt: t0)
        return SelectedClaim(resolved: ResolvedClaim(claim: claim, effectiveAssessment: assessment),
                             selectionReason: .explicitlyRequested, independenceKeys: keys,
                             hasReproducibleDerivation: reproducible)
    }
    private func ctx(_ claims: [SelectedClaim]) -> WorkProductContext {
        WorkProductContext(selectedClaims: claims, subjectLabel: "S")
    }

    private func fact(_ s: String = "f") -> SelectedClaim {
        selected(s, EvidenceAssessment(basis: .directlyObserved, origin: .sourceExtraction), evidence: [ref()])
    }
    private func attributed(_ s: String = "a", evidence: [EvidenceReference]? = nil) -> SelectedClaim {
        selected(s, EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction), evidence: evidence ?? [ref()])
    }
    private func corroborated(_ s: String = "c") -> SelectedClaim {
        let o1 = UUID(), o2 = UUID()
        return selected(s, EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction),
                        evidence: [ref(o1), ref(o2)], keys: [o1: "k1", o2: "k2"])
    }
    private func userConfirmed(_ s: String = "uc") -> SelectedClaim {
        selected(s, EvidenceAssessment(basis: .unknownLegacy, review: .confirmed, origin: .userCreated), evidence: [ref()])
    }
    private func userCorrected(_ s: String = "ux") -> SelectedClaim {
        selected(s, EvidenceAssessment(basis: .unknownLegacy, review: .corrected, origin: .userCreated), evidence: [ref()])
    }
    private func derived(_ s: String = "d", reproducible: Bool) -> SelectedClaim {
        selected(s, EvidenceAssessment(basis: .deterministicallyDerived, origin: .deterministicRule),
                 evidence: [ref()], reproducible: reproducible)
    }
    private func inference(_ s: String = "i") -> SelectedClaim {
        selected(s, EvidenceAssessment(basis: .inferred, origin: .modelProposed), evidence: [ref()])
    }
    private func conflict(_ s: String = "x") -> SelectedClaim {
        selected(s, EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction, conflict: .contradicted), evidence: [ref()])
    }

    private func sections(_ claims: [SelectedClaim]) -> [WorkProductSection] {
        SourcedSummaryComposer().compose(ctx(claims))
    }

    @Test("The composer returns the three sections in stable order")
    func threeSectionsInOrder() {
        #expect(sections([fact()]).map(\.title) == ["Sourced summary", "Qualified observations", "Claim-level conflicts"])
    }

    @Test("All five assertive forms sit in the sourced section with distinct labels")
    func fiveAssertiveFormsDistinct() {
        let s = sections([fact(), attributed(), corroborated(), userConfirmed(), derived(reproducible: true)])
        let sourced = s[0].claims.map(\.text)
        for label in ["Observed fact", "Source-reported", "Independently corroborated",
                      "Deterministically derived", "User-confirmed"] {
            #expect(sourced.contains { $0.hasPrefix(label + ":") }, "missing \(label)")
        }
    }

    @Test("Corrected and confirmed user-attributed claims get different labels")
    func correctedVsConfirmed() {
        let sourced = sections([userConfirmed("one"), userCorrected("two")])[0].claims.map(\.text)
        #expect(sourced.contains { $0.hasPrefix("User-confirmed:") && $0.hasSuffix("one") })
        #expect(sourced.contains { $0.hasPrefix("User-corrected:") && $0.hasSuffix("two") })
    }

    @Test("Inference and conflict appear only in disclosure sections, never among sourced facts")
    func disclosuresNotInSourced() {
        let s = sections([fact(), inference(), conflict()])
        #expect(s[0].claims.count == 1)                              // only the fact
        #expect(s[1].claims.contains { $0.text.hasPrefix("Inference:") })
        #expect(s[2].claims.contains { $0.text.hasPrefix("Conflicting accounts:") })
        #expect(!s[0].claims.contains { $0.text.hasPrefix("Inference:") || $0.text.hasPrefix("Conflicting") })
    }

    @Test("A refused (rejected-review) claim is absent from every section")
    func refusedAbsent() {
        let base = EvidenceAssessment(basis: .directlyObserved, origin: .sourceExtraction)
        let rejected = SelectedClaim(
            resolved: ResolvedClaim(claim: Claim(subjectID: UUID(), subjectLabel: "S", statement: "gone",
                                                 assessment: base, confidence: 0.9, evidence: [ref()], createdAt: t0),
                                    effectiveAssessment: base.with(review: .rejected)),
            selectionReason: .explicitlyRequested)
        let all = sections([rejected, fact("kept")]).flatMap(\.claims).map(\.text)
        #expect(all.contains { $0.hasSuffix("kept") })
        #expect(!all.contains { $0.hasSuffix("gone") })
    }

    @Test("Two reliable independent sources render as corroborated; unkeyed duplicates as source-reported")
    func corroborationVsAttribution() {
        let sourcedCorro = sections([corroborated("cc")])[0].claims.map(\.text)
        #expect(sourcedCorro.contains { $0.hasPrefix("Independently corroborated:") })
        let o1 = UUID(), o2 = UUID()
        let unkeyed = selected("dup", EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction),
                               evidence: [ref(o1), ref(o2)])       // no keys
        #expect(sections([unkeyed])[0].claims.contains { $0.text.hasPrefix("Source-reported:") })
    }

    @Test("Unverified deterministic stays inference; verified reproducible renders as derived")
    func derivationVerification() {
        #expect(sections([derived("u", reproducible: false)])[1].claims.contains { $0.text.hasPrefix("Inference:") })
        #expect(sections([derived("v", reproducible: true)])[0].claims.contains { $0.text.hasPrefix("Deterministically derived:") })
    }

    @Test("Supporting and contradicting citations stay separate on a sourced claim")
    func citationsSeparate() {
        let c = attributed("m", evidence: [ref(role: .supports), ref(role: .contradicts)])
        let claim = try! #require(sections([c])[0].claims.first)
        #expect(claim.supporting.count == 1)
        #expect(claim.contradicting.count == 1)
    }

    @Test("Composition is persona-invariant: identical context → identical content")
    func personaInvariant() {
        let claims = [fact(), corroborated(), inference(), conflict()]
        let a = sections(claims).flatMap(\.claims).map { [$0.text, $0.status.rawValue] }
        let b = sections(claims).flatMap(\.claims).map { [$0.text, $0.status.rawValue] }
        #expect(a == b)
    }

    @Test("Input order is stable within a section (no truncation)")
    func stableOrderNoTruncation() {
        let s = sections([fact("one"), fact("two"), fact("three")])[0].claims.map(\.text)
        #expect(s.map { String($0.dropFirst("Observed fact: ".count)) } == ["one", "two", "three"])
    }

    @Test("Empty context produces explicit empty-state prose in all three sections")
    func emptyContextProse() {
        let s = sections([])
        #expect(s.allSatisfy { $0.claims.isEmpty })
        #expect(s[0].preamble.contains { $0.contains("No sourced facts") })
        #expect(s[1].preamble.contains { $0.contains("No qualified observations") })
        #expect(s[2].preamble.contains { $0.contains("No claim-level conflicts") })
    }
}
