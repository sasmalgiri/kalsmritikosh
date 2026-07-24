//
//  ClaimMatrixComposerTests.swift
//  KalsmritikoshTests
//
//  PA-WP — the second section composer. Locks: exact presentation categories preserved (all
//  seven), corroboration only from independent keys, unkeyed duplicates do not corroborate,
//  rejected claims absent, inference/conflict visible and labelled, contradicting evidence
//  separate, stable input order, no repository access, persona-invariant, and that chronology
//  + matrix consume the same context without mutating it.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PA-WP — claim matrix composer")
struct ClaimMatrixComposerTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func selected(_ statement: String, _ assessment: EvidenceAssessment,
                          evidence: [EvidenceReference], keys: [UUID: String] = [:],
                          effective: EvidenceAssessment? = nil, reproducible: Bool = false,
                          id: UUID = UUID()) -> SelectedClaim {
        let claim = Claim(id: id, subjectID: UUID(), subjectLabel: "S", statement: statement,
                          assessment: assessment, confidence: 0.8, evidence: evidence, createdAt: t0)
        return SelectedClaim(resolved: ResolvedClaim(claim: claim, effectiveAssessment: effective ?? assessment),
                             selectionReason: .explicitlyRequested, independenceKeys: keys,
                             hasReproducibleDerivation: reproducible)
    }
    private func ref(_ obj: UUID = UUID(), block: UUID? = UUID(), role: EvidenceReference.Role = .supports) -> EvidenceReference {
        EvidenceReference(objectID: obj, blockID: block, sourceVersionID: UUID(), role: role)
    }

    // One SelectedClaim reaching each surfaced presentation category.
    private func fact() -> SelectedClaim {
        selected("f", EvidenceAssessment(basis: .directlyObserved, origin: .sourceExtraction), evidence: [ref()])
    }
    private func attributed() -> SelectedClaim {
        selected("a", EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction), evidence: [ref()])
    }
    private func corroborated() -> SelectedClaim {
        let o1 = UUID(), o2 = UUID()
        return selected("c", EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction),
                        evidence: [ref(o1), ref(o2)], keys: [o1: "k1", o2: "k2"])
    }
    private func userAttributed() -> SelectedClaim {
        selected("u", EvidenceAssessment(basis: .unknownLegacy, review: .confirmed, origin: .userCreated), evidence: [ref()])
    }
    private func inference() -> SelectedClaim {
        selected("i", EvidenceAssessment(basis: .inferred, origin: .modelProposed), evidence: [ref()])
    }
    private func conflict() -> SelectedClaim {
        selected("x", EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction, conflict: .contradicted), evidence: [ref()])
    }

    @Test("Every canonical presentation category has a distinct label (all seven preserved)")
    func categoryLabelsComplete() {
        let all: [ClaimPresentation] = [.fact, .attributed, .corroborated, .derivation, .userAttributed, .inference, .conflict]
        let labels = all.map(ClaimMatrixComposer.categoryLabel)
        #expect(Set(labels).count == 7)                    // all distinct
        #expect(ClaimMatrixComposer.categoryLabel(.corroborated) == "Independently corroborated")
        #expect(ClaimMatrixComposer.categoryLabel(.fact) == "Observed fact")
    }

    @Test("Surfaced presentation categories are rendered with their exact labels")
    func presentationsRenderedWithLabels() {
        // derivation needs a reproducible-derivation signal not yet carried on a Claim, so the
        // six render-reachable categories are exercised here; the label mapping test above
        // covers all seven.
        let ctx = WorkProductContext(selectedClaims: [fact(), attributed(), corroborated(), userAttributed(), inference(), conflict()], subjectLabel: "S")
        let texts = ClaimMatrixComposer().compose(ctx)[0].claims.map(\.text)
        for label in ["Observed fact", "Source-reported", "Independently corroborated",
                      "User-confirmed", "Inference", "Conflicting accounts"] {
            #expect(texts.contains { $0.hasPrefix(label + ":") }, "missing category: \(label)")
        }
    }

    @Test("A verified reproducible derivation renders as derived")
    func reproducibleDerivationRendersAsDerived() {
        let sel = selected("d", EvidenceAssessment(basis: .deterministicallyDerived, origin: .deterministicRule),
                           evidence: [ref()], reproducible: true)
        let r = try! #require(ResolvedClaimRenderer.render(sel))
        #expect(r.presentation == .derivation)
    }

    @Test("An unproven deterministic basis stays conservatively framed as inference")
    func unprovenDeterministicIsInference() {
        let sel = selected("d", EvidenceAssessment(basis: .deterministicallyDerived, origin: .deterministicRule),
                           evidence: [ref()], reproducible: false)     // not verified
        let r = try! #require(ResolvedClaimRenderer.render(sel))
        #expect(r.presentation == .inference)
    }

    @Test("Two reliable independence keys yield corroborated")
    func twoKeysCorroborate() {
        let r = try! #require(ResolvedClaimRenderer.render(corroborated()))
        #expect(r.presentation == .corroborated)
    }

    @Test("Unkeyed duplicate sources do NOT corroborate (they attribute)")
    func unkeyedDoesNotCorroborate() {
        let o1 = UUID(), o2 = UUID()
        let sel = selected("c", EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction),
                           evidence: [ref(o1), ref(o2)])          // no keys
        let r = try! #require(ResolvedClaimRenderer.render(sel))
        #expect(r.presentation == .attributed)
        #expect(r.presentation != .corroborated)
    }

    @Test("A rejected-review claim is absent from the matrix")
    func rejectedAbsent() {
        let base = EvidenceAssessment(basis: .directlyObserved, origin: .sourceExtraction)
        let rejected = selected("gone", base, evidence: [ref()], effective: base.with(review: .rejected))
        let ctx = WorkProductContext(selectedClaims: [rejected, fact()], subjectLabel: "S")
        let texts = ClaimMatrixComposer().compose(ctx)[0].claims.map(\.text)
        #expect(!texts.contains { $0.hasSuffix("gone") })
        #expect(texts.contains { $0.hasSuffix("f") })
    }

    @Test("Inference and conflict stay visible, labelled, and never under a fact category")
    func inferenceConflictVisibleNotFact() {
        let ctx = WorkProductContext(selectedClaims: [inference(), conflict()], subjectLabel: "S")
        let claims = ClaimMatrixComposer().compose(ctx)[0].claims
        #expect(claims.contains { $0.text.hasPrefix("Inference:") })
        #expect(claims.contains { $0.text.hasPrefix("Conflicting accounts:") })
        #expect(!claims.contains { $0.text.hasPrefix("Observed fact:") })
        // neither is mapped to the strongest EpistemicStatus
        #expect(claims.allSatisfy { $0.status != .directEvidence })
    }

    @Test("Contradicting evidence is kept separate from supporting")
    func contradictingSeparate() {
        let sel = selected("m", EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction),
                           evidence: [ref(role: .supports), ref(role: .contradicts)])
        let r = try! #require(ResolvedClaimRenderer.render(sel))
        #expect(r.workProductClaim.supporting.count == 1)
        #expect(r.workProductClaim.contradicting.count == 1)
    }

    @Test("Rows preserve deterministic input order")
    func stableInputOrder() {
        let ctx = WorkProductContext(selectedClaims: [fact(), attributed(), inference()], subjectLabel: "S")
        let texts = ClaimMatrixComposer().compose(ctx)[0].claims.map(\.text)
        #expect(texts.map { String($0.suffix(1)) } == ["f", "a", "i"])
    }

    @Test("Composition is persona-invariant: identical context → identical matrix content")
    func personaInvariant() {
        let ctx = WorkProductContext(selectedClaims: [fact(), corroborated(), conflict()], subjectLabel: "S")
        let c = ClaimMatrixComposer()
        let a = c.compose(ctx)[0].claims.map { [$0.text, $0.status.rawValue] }
        let b = c.compose(ctx)[0].claims.map { [$0.text, $0.status.rawValue] }
        #expect(a == b)          // no persona input; deterministic content (ids aside)
    }

    @Test("Registry registers both composers in deterministic id order")
    func registryOrder() throws {
        var reg = WorkProductComposerRegistry()
        try reg.register(HistoryChronologyComposer())
        try reg.register(ClaimMatrixComposer())
        #expect(reg.all.map(\.id) == [WorkProductComposerID("claims.matrix"), WorkProductComposerID("history.chronology")])
    }

    @Test("Chronology and matrix consume the same context without mutating it")
    func sharedContextUnchanged() {
        let ctx = WorkProductContext(selectedClaims: [fact(), attributed()], subjectLabel: "S")
        let snapshot = ctx.selectedClaims
        let matrix = ClaimMatrixComposer().compose(ctx)
        let chrono = HistoryChronologyComposer().compose(ctx)
        #expect(!matrix[0].claims.isEmpty)
        #expect(!chrono[0].claims.isEmpty)
        #expect(ctx.selectedClaims == snapshot)            // context is untouched
    }
}
