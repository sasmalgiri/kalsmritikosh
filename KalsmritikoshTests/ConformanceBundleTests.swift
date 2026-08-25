//
//  ConformanceBundleTests.swift
//  KalsmritikoshTests
//
//  Conformance roadmap 1.0.x-C — the verifiable bundle. Acceptance tests 5-7:
//  editing ANY bundle file breaks verification; editing content and recomputing
//  the public hashes still fails the signature; the (shared) verifier
//  recomputes the same status the app sealed. Three verdicts stay separated.
//

import Foundation
import Testing
import CryptoKit
@testable import Kalsmritikosh

@Suite("Conformance bundle — export + three-verdict verification")
struct ConformanceBundleTests {

    private let sutra = SutraCompiler.shared()
    private let now = Date(timeIntervalSince1970: 1_756_000_000)
    private let key = P256.Signing.PrivateKey()

    private func sealedStored() throws -> StoredConformanceAssessment {
        let attested = Set(SutraRuleCompiler.rules(for: sutra)
            .filter { $0.phaseKind == .findings || $0.phaseKind == nil }.map(\.id))
        let facts = ConformanceFacts(completedPhaseKinds: [.findings],
                                     standardOfProofDeclared: true,
                                     openItemsAcknowledged: true,
                                     humanDecisionsMade: [.findings],
                                     attestedRuleIDs: attested)
        let assessment = SutraConformance.assess(facts: facts, against: sutra, at: now)
        let sealed = try ConformanceSeal.seal(assessment: assessment, build: "1.0 (test)", key: key)
        return StoredConformanceAssessment(caseID: UUID(), runRevision: 1,
                                           assessment: assessment, seal: sealed, createdAt: now)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("A clean bundle passes all three verdicts")
    func cleanBundle() throws {
        let dir = try tempDir()
        try ConformanceBundle.write(stored: try sealedStored(), to: dir)
        let v = ConformanceBundle.verify(at: dir)
        #expect(v.integrity == .passed)
        #expect(v.authenticity == .passed)
        #expect(v.conformanceReplay == .passed)
        #expect(v.allPassed)
        // The only detail allowed on a clean unpinned verify is the honest
        // key-consistency caveat.
        #expect(v.details.allSatisfy { $0.contains("key-consistent only") })
        // The bundle carries every spec file, including the replayable facts.
        for f in ["attestation.json", "protocol.json", "rule-evaluations.json",
                  "evaluation-facts.json", "public-key.hex", "manifest.json", "README.txt"] {
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(f).path), Comment(rawValue: f))
        }
        // Identity binding: the correct trusted key ID passes; a wrong one fails.
        let embeddedKeyID = ConformanceSigningKey.keyID(for: key)
        #expect(ConformanceBundle.verify(at: dir, trustedSignerKeyID: embeddedKeyID).authenticity == .passed)
        #expect(ConformanceBundle.verify(at: dir, trustedSignerKeyID: "deadbeefdeadbeef").authenticity == .failed)
    }

    /// Audit item 5 acceptance: a wrongly COMPUTED evaluation — legitimately
    /// signed, hashes consistent — is caught only by rerunning the evaluators
    /// over the recorded facts. This is the difference between outcome
    /// consistency and true replay.
    @Test("Facts replay catches signed-but-wrong evaluations")
    func factsReplayCatchesWrongEvaluations() throws {
        let dir = try tempDir()
        // Build an assessment whose recorded evaluations DISAGREE with its
        // facts: flip one passed outcome to approvedDeviation before sealing.
        var assessment = try sealedStored().assessment
        var evaluations = assessment.evaluations
        let victim = evaluations.firstIndex { $0.outcome == .passed }!
        evaluations[victim] = RuleEvaluation(rule: evaluations[victim].rule, outcome: .approvedDeviation,
                                             evaluatorID: "forged-app", detail: "never actually evaluated")
        assessment = {
            var a = ConformanceAssessment(sutraCitation: assessment.sutraCitation,
                                          sutraSnapshotJSON: assessment.sutraSnapshotJSON,
                                          sutraSHA256: assessment.sutraSHA256,
                                          evaluations: evaluations,
                                          assessedAt: assessment.assessedAt)
            a.facts = assessment.facts   // facts unchanged — the lie is in the outcomes
            return a
        }()
        let sealed = try ConformanceSeal.seal(assessment: assessment, build: "t", key: key)
        try ConformanceBundle.write(stored: StoredConformanceAssessment(
            caseID: UUID(), runRevision: 1, assessment: assessment, seal: sealed, createdAt: now), to: dir)
        let v = ConformanceBundle.verify(at: dir)
        #expect(v.integrity == .passed)
        #expect(v.authenticity == .passed, "the forger signed correctly — hashes are consistent")
        #expect(v.conformanceReplay == .failed, "rerunning the evaluators must expose the lie")
        #expect(v.details.contains { $0.contains("does not reproduce") })
    }

    @Test("An unsealed assessment refuses to export")
    func unsealedRefuses() throws {
        var stored = try sealedStored()
        stored = StoredConformanceAssessment(caseID: stored.caseID, runRevision: 1,
                                             assessment: stored.assessment, seal: nil, createdAt: now)
        #expect(throws: ConformanceBundleError.notSealed) {
            try ConformanceBundle.write(stored: stored, to: try tempDir())
        }
    }

    /// Acceptance test 5: editing any file breaks verification (integrity layer).
    @Test("Editing any bundle file fails integrity")
    func tamperedFileFailsIntegrity() throws {
        let dir = try tempDir()
        try ConformanceBundle.write(stored: try sealedStored(), to: dir)
        let target = dir.appendingPathComponent("rule-evaluations.json")
        var bytes = try Data(contentsOf: target)
        bytes.append(Data(" ".utf8))
        try bytes.write(to: target)
        let v = ConformanceBundle.verify(at: dir)
        #expect(v.integrity == .failed)
        #expect(v.authenticity == .notChecked, "later layers must not run over a broken bundle")
        #expect(v.conformanceReplay == .notChecked)
    }

    /// Acceptance test 6: edit content AND recompute the public hashes — the
    /// manifest and envelope hashes are made internally consistent again, but
    /// the signature over the canonical envelope still fails.
    @Test("Recomputed-hash forgery passes integrity but fails authenticity")
    func recomputedForgeryFailsSignature() throws {
        let dir = try tempDir()
        let stored = try sealedStored()
        try ConformanceBundle.write(stored: stored, to: dir)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601

        // Forge: flip one outcome in the evaluations, rewrite the file...
        var evaluations = try decoder.decode([RuleEvaluation].self,
            from: try Data(contentsOf: dir.appendingPathComponent("rule-evaluations.json")))
        let victim = evaluations.firstIndex { $0.outcome == .passed }!
        evaluations[victim] = RuleEvaluation(rule: evaluations[victim].rule, outcome: .approvedDeviation,
                                             evaluatorID: "forged", detail: "forged")
        let forgedEvaluations = try ConformanceCanonical.data(of: evaluations)
        try forgedEvaluations.write(to: dir.appendingPathComponent("rule-evaluations.json"))

        // ...recompute the envelope's evaluations hash (unsigned fields kept),
        // rewrite the attestation with the ORIGINAL signature...
        var attestation = try decoder.decode(SealedConformance.self,
            from: try Data(contentsOf: dir.appendingPathComponent("attestation.json")))
        let e = attestation.envelope
        let forgedEnvelope = ConformanceSealEnvelope(
            formatVersion: e.formatVersion, sutraCitation: e.sutraCitation, sutraSHA256: e.sutraSHA256,
            ruleEvaluationsSHA256: SHA256.hash(data: forgedEvaluations).map { String(format: "%02x", $0) }.joined(),
            overallStatus: e.overallStatus, ruleCount: e.ruleCount, assessedAt: e.assessedAt,
            applicationBuild: e.applicationBuild, signerKeyID: e.signerKeyID,
            signatureAlgorithm: e.signatureAlgorithm, caseID: e.caseID, runRevision: e.runRevision,
            auditChainHead: e.auditChainHead, auditEventCount: e.auditEventCount,
            receiptSeal: e.receiptSeal, databaseSchemaVersion: e.databaseSchemaVersion,
            evidenceManifestSHA256: e.evidenceManifestSHA256, signerAssurance: e.signerAssurance,
            runID: e.runID, runStateSHA256: e.runStateSHA256,
            approvedDeviationCount: e.approvedDeviationCount)
        attestation = SealedConformance(envelope: forgedEnvelope,
                                        signatureHex: attestation.signatureHex,
                                        publicKeyHex: attestation.publicKeyHex)
        let forgedAttestation = try ConformanceCanonical.data(of: attestation)
        try forgedAttestation.write(to: dir.appendingPathComponent("attestation.json"))

        // ...and recompute the manifest so INTEGRITY passes.
        func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
        var files: [String: String] = [:]
        for name in ["attestation.json", "protocol.json", "rule-evaluations.json", "public-key.hex"] {
            files[name] = sha(try Data(contentsOf: dir.appendingPathComponent(name)))
        }
        try ConformanceCanonical.data(of: ConformanceBundle.Manifest(formatVersion: 1, files: files))
            .write(to: dir.appendingPathComponent("manifest.json"))

        let v = ConformanceBundle.verify(at: dir)
        #expect(v.integrity == .passed, "the forger made the hashes internally consistent")
        #expect(v.authenticity == .failed, "the signature over the canonical envelope must still fail")
        #expect(v.conformanceReplay == .notChecked)
    }

    /// Acceptance test 7: the verifier recomputes the same status the app sealed
    /// — and catches a sealed status that does not match the outcomes.
    @Test("Replay recomputes the sealed status from the outcomes")
    func replayMatchesStatus() throws {
        let dir = try tempDir()
        try ConformanceBundle.write(stored: try sealedStored(), to: dir)
        #expect(ConformanceBundle.verify(at: dir).conformanceReplay == .passed)

        // A truthful notConformant seal also replays cleanly.
        let rules = SutraRuleCompiler.rules(for: sutra).filter { $0.phaseKind == .findings }
        let facts = ConformanceFacts(completedPhaseKinds: [.findings],
                                     standardOfProofDeclared: false,   // gate fails
                                     openItemsAcknowledged: true,
                                     humanDecisionsMade: [.findings],
                                     attestedRuleIDs: Set(rules.map(\.id)))
        let bad = SutraConformance.assess(facts: facts, against: sutra, at: now)
        let sealedBad = try ConformanceSeal.seal(assessment: bad, build: "t", key: key)
        let dir2 = try tempDir()
        try ConformanceBundle.write(stored: StoredConformanceAssessment(
            caseID: UUID(), runRevision: 1, assessment: bad, seal: sealedBad, createdAt: now), to: dir2)
        let v2 = ConformanceBundle.verify(at: dir2)
        #expect(v2.allPassed)
        #expect(bad.status == .notConformant)
    }

    /// The standalone CLI fixture: leave a clean bundle at a stable path so the
    /// build script can smoke `swift verifier/kalverify.swift` against it.
    @Test("Writes the CLI smoke fixture")
    func cliFixture() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kalverify-fixture", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try ConformanceBundle.write(stored: try sealedStored(), to: dir)
        #expect(ConformanceBundle.verify(at: dir).allPassed)
    }
}
