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
        let facts = ConformanceFacts(completedPhaseKinds: [.caseIntake, .findings],
                                     standardOfProofDeclared: true,
                                     openItemsAcknowledged: true,
                                     humanDecisionsMade: [.caseIntake, .findings])
        let a = SutraConformance.assess(facts: facts, against: sutra, at: now)
        #expect(a.status == .indeterminate)
        #expect(!a.unevaluated.isEmpty)
        #expect(a.evaluations.contains { $0.rule.kind == .prohibition && $0.outcome == .notEvaluated })
    }

    /// One outcome per rule; attesting the reached phase's rules makes it conformant.
    @Test("Full attestation over satisfied gates is conformant")
    func conformant() {
        let spine: Set<PersonaJobKind> = [.caseIntake, .findings]
        let reachedIDs = Set(SutraRuleCompiler.rules(for: sutra)
            .filter { $0.phaseKind.map(spine.contains) ?? true }.map(\.id))
        let facts = ConformanceFacts(completedPhaseKinds: spine,
                                     standardOfProofDeclared: true,
                                     openItemsAcknowledged: true,
                                     humanDecisionsMade: spine,
                                     attestedRuleIDs: reachedIDs)
        let a = SutraConformance.assess(facts: facts, against: sutra, at: now)
        #expect(a.status == .conformant)
        #expect(a.evaluations.count == SutraRuleCompiler.rules(for: sutra).count)
        #expect(a.evaluations.allSatisfy { $0.outcome != .notEvaluated && $0.outcome != .evaluatorError })
        // Unreached phases are N/A by the deterministic applicability gate, never passed silently.
        #expect(a.evaluations.contains { $0.outcome == .notApplicable && $0.evaluatorID == "gate.applicability.v1" })
    }

    @Test("An asserted prohibited conclusion fails the run")
    func prohibited() {
        let prohibition = SutraRuleCompiler.rules(for: sutra)
            .first { $0.phaseKind == .findings && $0.kind == .prohibition }!
        let facts = ConformanceFacts(completedPhaseKinds: [.caseIntake, .findings],
                                     standardOfProofDeclared: true,
                                     openItemsAcknowledged: true,
                                     humanDecisionsMade: [.caseIntake, .findings],
                                     assertedProhibited: [prohibition.text])
        let a = SutraConformance.assess(facts: facts, against: sutra, at: now)
        #expect(a.status == .notConformant)
        #expect(a.evaluations.contains { $0.rule.id == prohibition.id && $0.outcome == .failed })
    }

    @Test("A missing reserved human decision fails, not pends silently")
    func humanDecision() {
        let facts = ConformanceFacts(completedPhaseKinds: [.caseIntake, .findings],
                                     standardOfProofDeclared: true,
                                     openItemsAcknowledged: true,
                                     humanDecisionsMade: [.caseIntake])
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

    /// The restricted applicability language: an expression nobody can parse is
    /// an evaluatorError — fail-closed, never a silent pass or skip — and even
    /// an attestation cannot rescue it.
    @Test("Unparseable applicability is an evaluatorError even when attested")
    func applicabilityFailClosed() {
        let rule = SutraRule(id: "x.obligation.0", phaseKind: .findings, kind: .obligation,
                             severity: .mandatory, text: "test", applicability: "when_convenient()")
        let facts = ConformanceFacts(completedPhaseKinds: [.findings],
                                     attestedRuleIDs: [rule.id])
        let e = SutraConformance.evaluate(rule: rule, facts: facts)
        #expect(e.outcome == .evaluatorError)
        #expect(e.evaluatorID == "gate.applicability.v1")
        // The two valid forms parse deterministically.
        let always = SutraRule(id: "g.obligation.0", phaseKind: nil, kind: .obligation,
                               severity: .mandatory, text: "t", applicability: "always")
        #expect(SutraConformance.evaluate(rule: always, facts: facts).outcome == .notEvaluated) // applicable, unattested
        let reach = SutraRule(id: "y.obligation.0", phaseKind: .closure, kind: .obligation,
                              severity: .mandatory, text: "t",
                              applicability: "phase_reached(\(PersonaJobKind.closure.rawValue))")
        #expect(SutraConformance.evaluate(rule: reach, facts: facts).outcome == .notApplicable) // closure not reached
    }

    /// Global requirements compile to mandatory global rules that always apply.
    @Test("globalRequirements become always-applicable mandatory rules")
    func globalRequirements() {
        var s = sutra
        s.globalRequirements = ["Every claim in the deliverable carries its evidence"]
        let rules = SutraRuleCompiler.rules(for: s)
        let global = rules.first { $0.id == "global.requirement.0" }
        #expect(global != nil)
        #expect(global?.phaseKind == nil)
        #expect(global?.severity == .mandatory)
        // Unattested global rule blocks conformance even with every gate satisfied.
        let spine: Set<PersonaJobKind> = [.caseIntake, .findings]
        let attestedPhaseRules = Set(rules.filter { $0.phaseKind.map(spine.contains) ?? false }.map(\.id))
        let facts = ConformanceFacts(completedPhaseKinds: spine,
                                     standardOfProofDeclared: true,
                                     openItemsAcknowledged: true,
                                     humanDecisionsMade: spine,
                                     attestedRuleIDs: attestedPhaseRules)
        let a = SutraConformance.assess(facts: facts, against: s, at: now)
        #expect(a.status == .indeterminate)
        #expect(a.evaluations.contains { $0.rule.id == "global.requirement.0" && $0.outcome == .notEvaluated })
        // Attesting it too makes the run conformant.
        let all = ConformanceFacts(completedPhaseKinds: spine,
                                   standardOfProofDeclared: true,
                                   openItemsAcknowledged: true,
                                   humanDecisionsMade: spine,
                                   attestedRuleIDs: attestedPhaseRules.union(["global.requirement.0"]))
        #expect(SutraConformance.assess(facts: all, against: s, at: now).status == .conformant)
    }

    /// Declared evidence binding: a required kind absent from the run keeps the
    /// rule notEvaluated — attestation cannot substitute for missing evidence.
    @Test("requiredEvidence gates evaluation; attestation cannot substitute")
    func evidenceBinding() {
        let rule = SutraRule(id: "x.obligation.9", phaseKind: .findings, kind: .obligation,
                             severity: .mandatory, text: "hash all evidence",
                             requiredEvidence: ["custody.hash"])
        let without = ConformanceFacts(completedPhaseKinds: [.findings],
                                       attestedRuleIDs: [rule.id])
        let blocked = SutraConformance.evaluate(rule: rule, facts: without)
        #expect(blocked.outcome == .notEvaluated)
        #expect(blocked.evaluatorID == "gate.evidenceBinding.v1")
        #expect(blocked.detail.contains("custody.hash"))
        let with = ConformanceFacts(completedPhaseKinds: [.findings],
                                    attestedRuleIDs: [rule.id],
                                    presentEvidenceKinds: ["custody.hash"])
        #expect(SutraConformance.evaluate(rule: rule, facts: with).outcome == .passed)
    }

    /// Multi-phase facts: custody + closure phases evaluate alongside findings.
    @Test("Multi-phase runs evaluate custody and closure rules")
    func multiPhase() {
        let reached: Set<PersonaJobKind> = [.caseIntake, .findings, .evidenceCustody, .closure]
        let attested = Set(SutraRuleCompiler.rules(for: sutra)
            .filter { $0.phaseKind.map(reached.contains) ?? true }.map(\.id))
        let facts = ConformanceFacts(completedPhaseKinds: reached,
                                     standardOfProofDeclared: true,
                                     openItemsAcknowledged: true,
                                     humanDecisionsMade: [.caseIntake, .findings, .closure],
                                     attestedRuleIDs: attested,
                                     presentEvidenceKinds: ["custody.record", "custody.hash"])
        let a = SutraConformance.assess(facts: facts, against: sutra, at: now)
        #expect(a.status == .conformant)
        #expect(a.evaluations.contains { $0.rule.phaseKind == .evidenceCustody && $0.outcome == .passed })
        #expect(a.evaluations.contains { $0.rule.phaseKind == .closure && $0.outcome == .passed })
        // Closure's reserved decision missing → the run fails, not pends.
        var noDecision = facts
        noDecision.humanDecisionsMade = [.caseIntake, .findings]
        #expect(SutraConformance.assess(facts: noDecision, against: sutra, at: now).status == .notConformant)
    }

    /// Audit item 3: a run that never reached a REQUIRED phase fails — its
    /// rules never soften to notApplicable.
    @Test("An unreached required phase fails the run")
    func requiredPhaseFails() {
        // The built-in doctrine defaults to requiring the findings phase.
        let facts = ConformanceFacts(completedPhaseKinds: [.caseIntake],
                                     humanDecisionsMade: [.caseIntake],
                                     attestedRuleIDs: Set(SutraRuleCompiler.rules(for: sutra).map(\.id)))
        let a = SutraConformance.assess(facts: facts, against: sutra, at: now)
        #expect(a.status == .notConformant, "attesting everything cannot rescue an unreached required phase")
        #expect(a.evaluations.contains {
            $0.outcome == .failed && $0.evaluatorID == "gate.requiredPhase.v1"
        })
    }

    /// Audit item 1: attestations are actor-bound — who, role, when, why —
    /// and the attribution travels on the evaluation detail.
    @Test("Per-rule attestations carry actor, role, timestamp and rationale")
    func attributedAttestation() {
        let rule = SutraRuleCompiler.rules(for: sutra).first { $0.phaseKind == .findings && $0.kind == .prohibition }!
        let att = RuleAttestation(actor: "A. Reviewer", role: "counsel",
                                  rationale: "checked the report against the declared standard",
                                  at: now)
        let facts = ConformanceFacts(completedPhaseKinds: [.findings],
                                     attestations: [rule.id: att])
        let e = SutraConformance.evaluate(rule: rule, facts: facts)
        #expect(e.outcome == .passed)
        #expect(e.evaluatorID == "human.attest.v2")
        #expect(e.detail.contains("A. Reviewer") && e.detail.contains("counsel")
                && e.detail.contains("checked the report"))
    }

    /// Run binding (audit item 2): the assessment and the signed envelope carry
    /// the real run ID and run-state hash.
    @Test("Assessments bind to the real run and the seal carries it")
    func runBinding() throws {
        let spine: Set<PersonaJobKind> = [.caseIntake, .findings]
        let attested = Set(SutraRuleCompiler.rules(for: sutra)
            .filter { $0.phaseKind.map(spine.contains) ?? true }.map(\.id))
        let facts = ConformanceFacts(completedPhaseKinds: spine,
                                     standardOfProofDeclared: true, openItemsAcknowledged: true,
                                     humanDecisionsMade: spine, attestedRuleIDs: attested)
        let runID = UUID()
        let a = SutraConformance.assess(facts: facts, against: sutra, at: now,
                                        runID: runID, runStateSHA256: "cafe01")
        #expect(a.runID == runID)
        #expect(a.facts != nil, "the consulted facts are embedded for replay")
        let sealed = try ConformanceSeal.seal(assessment: a, build: "t",
                                              key: CryptoKit.P256.Signing.PrivateKey())
        #expect(sealed.envelope.runID == runID.uuidString)
        #expect(sealed.envelope.runStateSHA256 == "cafe01")
        #expect(ConformanceSeal.verify(sealed))
    }

    /// A justified deviation is visible (`approvedDeviation`) and does not block conformance.
    @Test("Deviations: distinct status, typed authorization, prohibitions non-waivable")
    func deviations() {
        let spine: Set<PersonaJobKind> = [.caseIntake, .findings]
        let rules = SutraRuleCompiler.rules(for: sutra)
            .filter { $0.phaseKind.map(spine.contains) ?? true }
        // Deviate a WAIVABLE obligation: status is DISTINCT, never plain conformant.
        let deviated = rules.first { $0.kind == .obligation && $0.phaseKind == .caseIntake }!
        let attested = Set(rules.map(\.id)).subtracting([deviated.id])
        let auth = DeviationAuthorization(authorizedBy: "General Counsel", role: "counsel",
                                          justification: "authorized the exception in writing", at: now)
        let facts = ConformanceFacts(completedPhaseKinds: spine,
                                     standardOfProofDeclared: true,
                                     openItemsAcknowledged: true,
                                     humanDecisionsMade: spine,
                                     attestedRuleIDs: attested,
                                     approvedDeviations: [deviated.id: auth])
        let a = SutraConformance.assess(facts: facts, against: sutra, at: now)
        #expect(a.status == .conformantWithDeviations, "a deviated run is never plain conformant")
        let d = a.evaluations.first { $0.rule.id == deviated.id }
        #expect(d?.outcome == .approvedDeviation)
        #expect(a.certificate.contains("General Counsel") && a.certificate.contains("authorized the exception"))
        // A deviation on a PROHIBITION (non-waivable) FAILS the run.
        let prohibition = rules.first { $0.kind == .prohibition }!
        var illegal = facts
        illegal.approvedDeviations = [prohibition.id: auth]
        illegal.attestedRuleIDs = Set(rules.map(\.id)).subtracting([prohibition.id])
        let b = SutraConformance.assess(facts: illegal, against: sutra, at: now)
        #expect(b.status == .notConformant, "no free text can authorize a prohibited conclusion")
        #expect(b.evaluations.contains { $0.rule.id == prohibition.id && $0.evaluatorID == "gate.nonWaivable.v1" })
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
        let spine: Set<PersonaJobKind> = [.caseIntake, .findings]
        let attested = Set(SutraRuleCompiler.rules(for: sutra)
            .filter { $0.phaseKind.map(spine.contains) ?? true }.map(\.id))
        let facts = ConformanceFacts(completedPhaseKinds: spine,
                                     standardOfProofDeclared: true,
                                     openItemsAcknowledged: true,
                                     humanDecisionsMade: spine,
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
            signatureAlgorithm: sealed.envelope.signatureAlgorithm,
            caseID: sealed.envelope.caseID,
            runRevision: sealed.envelope.runRevision,
            auditChainHead: sealed.envelope.auditChainHead,
            auditEventCount: sealed.envelope.auditEventCount,
            receiptSeal: sealed.envelope.receiptSeal,
            databaseSchemaVersion: sealed.envelope.databaseSchemaVersion,
            evidenceManifestSHA256: sealed.envelope.evidenceManifestSHA256,
            signerAssurance: sealed.envelope.signerAssurance,
            runID: sealed.envelope.runID,
            runStateSHA256: sealed.envelope.runStateSHA256,
            approvedDeviationCount: sealed.envelope.approvedDeviationCount,
            factsSHA256: sealed.envelope.factsSHA256)
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
        let facts = ConformanceFacts(completedPhaseKinds: [.caseIntake, .findings],
                                     standardOfProofDeclared: true,
                                     openItemsAcknowledged: true,
                                     humanDecisionsMade: [.caseIntake, .findings])   // nothing attested
        let a = SutraConformance.assess(facts: facts, against: sutra, at: now)
        #expect(a.status == .indeterminate)
        #expect(throws: ConformanceSealError.indeterminateAssessment) {
            _ = try ConformanceSeal.seal(assessment: a, build: "1.0 (test)", key: key)
        }
    }

    @Test("A truthful negative attestation seals fine")
    func notConformantSeals() throws {
        let spine: Set<PersonaJobKind> = [.caseIntake, .findings]
        let facts = ConformanceFacts(completedPhaseKinds: spine,
                                     standardOfProofDeclared: false,    // gate fails
                                     openItemsAcknowledged: true,
                                     humanDecisionsMade: spine,
                                     attestedRuleIDs: Set(SutraRuleCompiler.rules(for: sutra)
                                         .filter { $0.phaseKind.map(spine.contains) ?? true }.map(\.id)))
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

    @Test("Sealing refuses when the audit chain has unsealed events")
    func unsealedAuditRefuses() {
        #expect(throws: ConformanceSealError.unsealedAuditEvents(3)) {
            _ = try ConformanceSeal.seal(assessment: conformantAssessment(), build: "t", key: key,
                                         linkage: ConformanceSealLinkage(unsealedAuditEvents: 3))
        }
    }

    @Test("Sealing refuses a stale assessment (run revision mismatch)")
    func revisionMismatchRefuses() {
        #expect(throws: ConformanceSealError.runRevisionMismatch) {
            _ = try ConformanceSeal.seal(assessment: conformantAssessment(), build: "t", key: key,
                                         linkage: ConformanceSealLinkage(runRevision: 3, assessedRunRevision: 2))
        }
    }

    @Test("Envelope v2 carries and signs the run linkage")
    func linkageSigned() throws {
        let caseID = UUID()
        let manifest = [EvidenceManifestEntry(sourceVersionID: "v1", contentHash: "aa"),
                        EvidenceManifestEntry(sourceVersionID: "v2", contentHash: nil)]
        let manifestSHA = try ConformanceCanonical.sha256(of: manifest)
        let sealed = try ConformanceSeal.seal(
            assessment: conformantAssessment(), build: "t", key: key,
            linkage: ConformanceSealLinkage(caseID: caseID, runRevision: 2, assessedRunRevision: 2,
                                            auditChainHead: "abc123", auditEventCount: 9,
                                            receiptSeal: "feed99", databaseSchemaVersion: 107,
                                            evidenceManifestSHA256: manifestSHA))
        #expect(sealed.envelope.formatVersion == 2)
        #expect(sealed.envelope.caseID == caseID.uuidString)
        #expect(sealed.envelope.auditChainHead == "abc123")
        #expect(sealed.envelope.evidenceManifestSHA256 == manifestSHA)
        #expect(sealed.envelope.signerAssurance == "external-software")   // injected key
        #expect(ConformanceSeal.verify(sealed))
        let md = ConformanceSeal.markdown(for: sealed)
        #expect(md.contains("abc123") && md.contains("feed99") && md.contains(manifestSHA))
    }
}

@Suite("Conformance persistence — v107, reopen against the original protocol")
struct ConformancePersistenceTests {

    private let sutra = SutraCompiler.shared()
    private let now = Date(timeIntervalSince1970: 1_756_000_000)
    private let key = P256.Signing.PrivateKey()

    private func makeRig() async throws -> (Database, ConformanceAssessmentRepository) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("conf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        return (db, ConformanceAssessmentRepository(database: db))
    }

    private func conformantAssessment(against s: Sutra) -> ConformanceAssessment {
        let spine: Set<PersonaJobKind> = [.caseIntake, .findings]
        let attested = Set(SutraRuleCompiler.rules(for: s)
            .filter { $0.phaseKind.map(spine.contains) ?? true }.map(\.id))
        let facts = ConformanceFacts(completedPhaseKinds: spine,
                                     standardOfProofDeclared: true,
                                     openItemsAcknowledged: true,
                                     humanDecisionsMade: spine,
                                     attestedRuleIDs: attested)
        return SutraConformance.assess(facts: facts, against: s, at: now)
    }

    @Test("Round-trip: record, reload, revisions append")
    func roundTrip() async throws {
        let (_, repo) = try await makeRig()
        let caseID = UUID()
        let a = conformantAssessment(against: sutra)
        let sealed = try ConformanceSeal.seal(assessment: a, build: "t", key: key)
        let first = try await repo.record(caseID: caseID, assessment: a, seal: sealed, at: now)
        #expect(first.runRevision == 1)
        let reloaded = try await repo.latest(caseID: caseID)
        #expect(reloaded != nil)
        #expect(reloaded?.assessment.sutraSHA256 == a.sutraSHA256)
        #expect(reloaded?.assessment.status == .conformant)
        #expect(reloaded?.assessment.evaluations.count == a.evaluations.count)
        #expect(reloaded?.seal?.signatureHex == sealed.signatureHex)
        // The stored seal still verifies after the DB round-trip.
        if let storedSeal = reloaded?.seal { #expect(ConformanceSeal.verify(storedSeal)) }
        // A second record appends revision 2; the first stays untouched.
        let second = try await repo.record(caseID: caseID, assessment: a, seal: nil, at: now.addingTimeInterval(60))
        #expect(second.runRevision == 2)
        #expect(try await repo.list(caseID: caseID).count == 2)
    }

    /// Acceptance test 10: an old run reopens against ITS OWN protocol. The
    /// stored snapshot decodes to the exact Sutra assessed, even after the
    /// live constitution is amended.
    @Test("Old runs reopen against their original frozen protocol")
    func reopenAgainstOriginal() async throws {
        let (_, repo) = try await makeRig()
        let caseID = UUID()
        let original = sutra
        let a = conformantAssessment(against: original)
        _ = try await repo.record(caseID: caseID, assessment: a, seal: nil, at: now)

        // The world moves on: the live constitution is amended (new version, new hash).
        let amended = original.amended(on: "2026-08-26", summary: "post-run amendment")
        let amendedAssessment = conformantAssessment(against: amended)
        #expect(amendedAssessment.sutraSHA256 != a.sutraSHA256)

        // Reopening the old run loads the ORIGINAL snapshot — decodable to the
        // exact constitution it was assessed against, not today's.
        let reloaded = try await repo.latest(caseID: caseID)
        #expect(reloaded?.assessment.sutraSHA256 == a.sutraSHA256)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let frozen = try decoder.decode(Sutra.self,
                                        from: Data((reloaded?.assessment.sutraSnapshotJSON ?? "").utf8))
        #expect(frozen.version == original.version)
        #expect(frozen.citation == original.citation)
    }
}

// MARK: - Sixth audit — discipline spines

@Suite("Discipline spines (sixth audit)")
struct DisciplineSpineTests {

    @Test("Every built-in discipline declares a mandatory phase spine that exists in its protocol")
    func disciplinesDeclareSpines() {
        for d in SutraCompiler.builtInDisciplines {
            let required = d.sutra.requiredPhaseKinds ?? []
            #expect(!required.isEmpty, Comment(rawValue: "\(d.id) declares no required phases"))
            #expect(required.contains(.findings), Comment(rawValue: "\(d.id) does not require its findings phase"))
            let phaseKinds = Set(d.sutra.phases.map(\.kind))
            #expect(Set(required).isSubset(of: phaseKinds),
                    Comment(rawValue: "\(d.id) requires phases its protocol does not contain"))
        }
    }

    @Test("The persona lens carries the shared doctrine's spine and global requirements")
    func personaLensCarriesDoctrine() {
        let base = SutraCompiler.shared()
        let lens = SutraCompiler.sutra(forPersonaLabel: "Journalist")
        #expect(lens.requiredPhaseKinds == base.requiredPhaseKinds)
        #expect(lens.globalRequirements == base.globalRequirements)
    }
}
