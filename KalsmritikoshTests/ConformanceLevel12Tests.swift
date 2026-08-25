//
//  ConformanceLevel12Tests.swift
//  KalsmritikoshTests
//
//  Conformance roadmap 1.0.x-A/B. Level 1: typed rules, one outcome per rule,
//  fail-closed (unevaluated mandatory rules block conformance — nothing passes
//  by default), Sutra frozen by canonical SHA-256. Level 2: ECDSA P-256 seal —
//  a recomputed-hash forgery still fails the signature; indeterminate
//  assessments refuse to seal. Tests use an ephemeral key (no Keychain).
//

import Foundation
import Testing
import CryptoKit
@testable import Kalsmritikosh

@Suite("Conformance Level 1 — typed rules, fail-closed")
struct ConformanceLevel1Tests {

    private let sutra = SutraCompiler.shared()
    private let now = Date(timeIntervalSince1970: 1_756_000_000)

    /// Every doctrine line of every phase becomes exactly one typed rule with a stable ID.
    @Test("Rule derivation is complete and deterministic")
    func derivation() {
        let rules = SutraRuleCompiler.rules(for: sutra)
        let expected = sutra.phases.reduce(0) {
            $0 + $1.obligations.count + $1.humanDecisions.count + $1.prohibitedConclusions.count
        }
        #expect(rules.count == expected)
        #expect(Set(rules.map(\.id)).count == rules.count, "rule IDs must be unique")
        #expect(SutraRuleCompiler.rules(for: sutra) == rules, "derivation must be deterministic")
    }

    /// The old checker's hole: prohibitions passed because callers defaulted them
    /// to empty. Now: gates satisfied but nothing attested → indeterminate, never green.
    @Test("Fail-closed: unattested rules block conformance")
    func failClosed() {
        let facts = ConformanceFacts(completedPhaseKinds: [.findings],
                                     standardOfProofDeclared: true,
                                     openItemsAcknowledged: true,
                                     humanDecisionsMade: [.findings])
        let a = SutraConformance.assess(facts: facts, against: sutra, at: now)
        #expect(a.status == .indeterminate)
        #expect(!a.unevaluated.isEmpty)
        #expect(a.evaluations.contains { $0.rule.kind == .prohibition && $0.outcome == .notEvaluated })
    }

    /// One outcome per rule; attesting the reached phase's rules makes it conformant.
    @Test("Full attestation over satisfied gates is conformant")
    func conformant() {
        let reachedIDs = Set(SutraRuleCompiler.rules(for: sutra)
            .filter { $0.phaseKind == .findings }.map(\.id))
        let facts = ConformanceFacts(completedPhaseKinds: [.findings],
                                     standardOfProofDeclared: true,
                                     openItemsAcknowledged: true,
                                     humanDecisionsMade: [.findings],
                                     attestedRuleIDs: reachedIDs)
        let a = SutraConformance.assess(facts: facts, against: sutra, at: now)
        #expect(a.status == .conformant)
        #expect(a.evaluations.count == SutraRuleCompiler.rules(for: sutra).count)
        #expect(a.evaluations.allSatisfy { $0.outcome != .notEvaluated && $0.outcome != .evaluatorError })
        // Unreached phases are N/A by the deterministic phase-reach gate, never passed silently.
        #expect(a.evaluations.contains { $0.outcome == .notApplicable && $0.evaluatorID == "gate.phaseReach.v1" })
    }

    @Test("An asserted prohibited conclusion fails the run")
    func prohibited() {
        let prohibition = SutraRuleCompiler.rules(for: sutra)
            .first { $0.phaseKind == .findings && $0.kind == .prohibition }!
        let facts = ConformanceFacts(completedPhaseKinds: [.findings],
                                     standardOfProofDeclared: true,
                                     openItemsAcknowledged: true,
                                     humanDecisionsMade: [.findings],
                                     assertedProhibited: [prohibition.text])
        let a = SutraConformance.assess(facts: facts, against: sutra, at: now)
        #expect(a.status == .notConformant)
        #expect(a.evaluations.contains { $0.rule.id == prohibition.id && $0.outcome == .failed })
    }

    @Test("A missing reserved human decision fails, not pends silently")
    func humanDecision() {
        let facts = ConformanceFacts(completedPhaseKinds: [.findings],
                                     standardOfProofDeclared: true,
                                     openItemsAcknowledged: true,
                                     humanDecisionsMade: [])
        let a = SutraConformance.assess(facts: facts, against: sutra, at: now)
        #expect(a.status == .notConformant)
        #expect(a.evaluations.contains { $0.rule.kind == .humanDecision && $0.outcome == .failed })
    }

    /// The exact constitution is frozen: same Sutra → same SHA; an amendment changes it.
    @Test("Sutra snapshot hash is stable and version-sensitive")
    func snapshotHash() {
        let facts = ConformanceFacts(completedPhaseKinds: [.findings])
        let a1 = SutraConformance.assess(facts: facts, against: sutra, at: now)
        let a2 = SutraConformance.assess(facts: facts, against: sutra, at: now)
        #expect(!a1.sutraSHA256.isEmpty)
        #expect(a1.sutraSHA256 == a2.sutraSHA256)
        #expect(!a1.sutraSnapshotJSON.isEmpty)
        let amended = sutra.amended(on: "2026-08-25", summary: "test amendment")
        let a3 = SutraConformance.assess(facts: facts, against: amended, at: now)
        #expect(a3.sutraSHA256 != a1.sutraSHA256)
        #expect(a3.sutraCitation != a1.sutraCitation)
    }

    /// The per-rule certificate names the constitution, its hash, and every outcome.
    @Test("Certificate lists every rule with its evaluator")
    func certificate() {
        let facts = ConformanceFacts(completedPhaseKinds: [.findings],
                                     standardOfProofDeclared: true,
                                     openItemsAcknowledged: true,
                                     humanDecisionsMade: [.findings])
        let a = SutraConformance.assess(facts: facts, against: sutra, at: now)
        #expect(a.certificate.contains(a.sutraSHA256))
        #expect(a.certificate.contains(sutra.citation))
        for e in a.evaluations { #expect(a.certificate.contains(e.rule.id)) }
        #expect(a.certificate.contains("notEvaluated"), "unevaluated rules must be visible, not hidden")
    }
}

@Suite("Conformance Level 2 — signed seal")
struct ConformanceLevel2Tests {

    private let sutra = SutraCompiler.shared()
    private let now = Date(timeIntervalSince1970: 1_756_000_000)
    private let key = P256.Signing.PrivateKey()   // ephemeral — no Keychain in tests

    private func conformantAssessment() -> ConformanceAssessment {
        let attested = Set(SutraRuleCompiler.rules(for: sutra)
            .filter { $0.phaseKind == .findings }.map(\.id))
        let facts = ConformanceFacts(completedPhaseKinds: [.findings],
                                     standardOfProofDeclared: true,
                                     openItemsAcknowledged: true,
                                     humanDecisionsMade: [.findings],
                                     attestedRuleIDs: attested)
        return SutraConformance.assess(facts: facts, against: sutra, at: now)
    }

    @Test("Seal signs and verifies")
    func sealVerifies() throws {
        let sealed = try ConformanceSeal.seal(assessment: conformantAssessment(),
                                              build: "1.0 (test)", key: key)
        #expect(ConformanceSeal.verify(sealed))
        #expect(sealed.envelope.overallStatus == "conformant")
        #expect(sealed.envelope.sutraSHA256 == conformantAssessment().sutraSHA256)
        #expect(sealed.envelope.signerKeyID == ConformanceSigningKey.keyID(for: key))
    }

    /// The attack the unkeyed receipt chain cannot stop: edit a field and keep
    /// (or recompute) the hashes. The signature check must still fail.
    @Test("Edited envelope fails the signature even with consistent hashes")
    func forgeryFails() throws {
        let sealed = try ConformanceSeal.seal(assessment: conformantAssessment(),
                                              build: "1.0 (test)", key: key)
        let forgedEnvelope = ConformanceSealEnvelope(
            formatVersion: sealed.envelope.formatVersion,
            sutraCitation: sealed.envelope.sutraCitation,
            sutraSHA256: sealed.envelope.sutraSHA256,
            ruleEvaluationsSHA256: sealed.envelope.ruleEvaluationsSHA256,
            overallStatus: "conformant",
            ruleCount: sealed.envelope.ruleCount,
            assessedAt: sealed.envelope.assessedAt,
            applicationBuild: "2.0 (forged)",              // the edit
            signerKeyID: sealed.envelope.signerKeyID,
            signatureAlgorithm: sealed.envelope.signatureAlgorithm)
        let forged = SealedConformance(envelope: forgedEnvelope,
                                       signatureHex: sealed.signatureHex,
                                       publicKeyHex: sealed.publicKeyHex)
        #expect(!ConformanceSeal.verify(forged))
        // Swapping in a different public key must fail too (signature/key mismatch).
        let otherKey = P256.Signing.PrivateKey()
        let keySwapped = SealedConformance(envelope: sealed.envelope,
                                           signatureHex: sealed.signatureHex,
                                           publicKeyHex: otherKey.publicKey.x963Representation
                                               .map { String(format: "%02x", $0) }.joined())
        #expect(!ConformanceSeal.verify(keySwapped))
    }

    @Test("Indeterminate assessments refuse to seal")
    func indeterminateRefuses() {
        let facts = ConformanceFacts(completedPhaseKinds: [.findings],
                                     standardOfProofDeclared: true,
                                     openItemsAcknowledged: true,
                                     humanDecisionsMade: [.findings])   // nothing attested
        let a = SutraConformance.assess(facts: facts, against: sutra, at: now)
        #expect(a.status == .indeterminate)
        #expect(throws: ConformanceSealError.indeterminateAssessment) {
            _ = try ConformanceSeal.seal(assessment: a, build: "1.0 (test)", key: key)
        }
    }

    @Test("A truthful negative attestation seals fine")
    func notConformantSeals() throws {
        let facts = ConformanceFacts(completedPhaseKinds: [.findings],
                                     standardOfProofDeclared: false,    // gate fails
                                     openItemsAcknowledged: true,
                                     humanDecisionsMade: [.findings],
                                     attestedRuleIDs: Set(SutraRuleCompiler.rules(for: sutra)
                                         .filter { $0.phaseKind == .findings }.map(\.id)))
        let a = SutraConformance.assess(facts: facts, against: sutra, at: now)
        #expect(a.status == .notConformant)
        let sealed = try ConformanceSeal.seal(assessment: a, build: "1.0 (test)", key: key)
        #expect(ConformanceSeal.verify(sealed))
        #expect(sealed.envelope.overallStatus == "notConformant")
    }

    @Test("Seal markdown carries the verification material")
    func markdown() throws {
        let sealed = try ConformanceSeal.seal(assessment: conformantAssessment(),
                                              build: "1.0 (test)", key: key)
        let md = ConformanceSeal.markdown(for: sealed)
        #expect(md.contains(sealed.signatureHex))
        #expect(md.contains(sealed.publicKeyHex))
        #expect(md.contains(sealed.envelope.sutraSHA256))
        #expect(md.contains("not third-party certification"))
    }
}
