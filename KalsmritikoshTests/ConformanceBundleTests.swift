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

    private func sealedStored(runStateOverride: String? = nil) throws -> StoredConformanceAssessment {
        let spine: Set<PersonaJobKind> = [.caseIntake, .findings]
        let attested = Set(SutraRuleCompiler.rules(for: sutra)
            .filter { $0.phaseKind.map(spine.contains) ?? true }.map(\.id))
        var facts = ConformanceFacts(completedPhaseKinds: spine,
                                     standardOfProofDeclared: true,
                                     openItemsAcknowledged: true,
                                     humanDecisionsMade: spine,
                                     attestedRuleIDs: attested)
        // Production-shaped: bound to a run via a GENUINELY recomputable
        // binding — the components ride in the signed facts (sixth audit).
        let runID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEFFFF0001")!
        facts.runReceiptSeal = "receipt-seal-0001"
        facts.runCaseRevision = 3
        let binding = try ConformanceCanonical.sha256(of: ConformanceRunBinding(
            runID: runID, receiptSeal: "receipt-seal-0001", caseRevision: 3))
        var assessment = SutraConformance.assess(facts: facts, against: sutra, at: now,
                                                 runID: runID,
                                                 runStateSHA256: runStateOverride ?? binding)
        assessment.evidenceManifest = [
            EvidenceManifestEntry(sourceVersionID: "v-0001", contentHash: "aa11"),
            EvidenceManifestEntry(sourceVersionID: "v-0002", contentHash: nil),
        ]
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
                  "evaluation-facts.json", "evidence-manifest.json",
                  "public-key.hex", "manifest.json", "README.txt"] {
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

    /// NINTH AUDIT — README is manifest-covered, and the standalone key
    /// must be the embedded key.
    @Test("README tampering fails integrity; a swapped public-key.hex fails authenticity")
    func readmeCoveredAndKeyCrossChecked() throws {
        let dir = try tempDir()
        try ConformanceBundle.write(stored: try sealedStored(), to: dir)
        let readme = dir.appendingPathComponent("README.txt")
        try Data("edited instructions".utf8).write(to: readme)
        let v = ConformanceBundle.verify(at: dir)
        #expect(v.integrity == .failed, "README must be covered by the manifest")

        let dir2 = try tempDir()
        try ConformanceBundle.write(stored: try sealedStored(), to: dir2)
        // Swap the standalone key for a fresh one and regenerate the
        // (unsigned) manifest so integrity stays consistent.
        let otherKey = Data(P256.Signing.PrivateKey().publicKey.x963Representation
            .map { String(format: "%02x", $0) }.joined().utf8)
        try otherKey.write(to: dir2.appendingPathComponent("public-key.hex"))
        var files: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: dir2.path)
        where name != "manifest.json" {
            let data = try Data(contentsOf: dir2.appendingPathComponent(name))
            files[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "files": files],
                                   options: [.sortedKeys])
            .write(to: dir2.appendingPathComponent("manifest.json"))
        let v2 = ConformanceBundle.verify(at: dir2)
        #expect(v2.integrity == .passed)
        #expect(v2.authenticity == .failed, "the standalone key must be the embedded key")
        #expect(v2.details.contains { $0.contains("public-key.hex") })
    }

    /// TENTH AUDIT — the bundle directory must contain EXACTLY the
    /// manifest's files: deletion-with-delisting and unlisted additions
    /// both fail integrity.
    @Test("Deleting README (even delisted) and adding an unlisted file both fail integrity")
    func exactDirectoryContentsEnforced() throws {
        // Delete README AND delist it from a regenerated manifest: the
        // mandatory-set rule refuses.
        let dir = try tempDir()
        try ConformanceBundle.write(stored: try sealedStored(), to: dir)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("README.txt"))
        var files: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path)
        where name != "manifest.json" {
            let data = try Data(contentsOf: dir.appendingPathComponent(name))
            files[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "files": files],
                                   options: [.sortedKeys])
            .write(to: dir.appendingPathComponent("manifest.json"))
        let deleted = ConformanceBundle.verify(at: dir)
        #expect(deleted.integrity == .failed)
        #expect(deleted.details.contains { $0.contains("README.txt") })

        // Smuggle an unlisted file into an otherwise clean bundle: refused.
        let dir2 = try tempDir()
        try ConformanceBundle.write(stored: try sealedStored(), to: dir2)
        try Data("stowaway".utf8).write(to: dir2.appendingPathComponent("extra.json"))
        let smuggled = ConformanceBundle.verify(at: dir2)
        #expect(smuggled.integrity == .failed)
        #expect(smuggled.details.contains { $0.contains("unlisted file") })

        // ELEVENTH AUDIT — a HIDDEN smuggled file is refused too: only the
        // specific macOS artifacts (.DS_Store, ._*) are ignored.
        let dir3 = try tempDir()
        try ConformanceBundle.write(stored: try sealedStored(), to: dir3)
        try Data("hidden stowaway".utf8).write(to: dir3.appendingPathComponent(".extra.json"))
        let hidden = ConformanceBundle.verify(at: dir3)
        #expect(hidden.integrity == .failed)
        #expect(hidden.details.contains { $0.contains(".extra.json") })
        // …while a genuine .DS_Store does not break a legitimate bundle.
        let dir4 = try tempDir()
        try ConformanceBundle.write(stored: try sealedStored(), to: dir4)
        try Data([0x00, 0x01]).write(to: dir4.appendingPathComponent(".DS_Store"))
        #expect(ConformanceBundle.verify(at: dir4).allPassed)
    }

    /// ELEVENTH AUDIT — an unlistable bundle directory FAILS integrity
    /// (fail-closed): exact-contents checking must never be silently skipped.
    @Test("An unenumerable bundle directory fails integrity")
    func unenumerableDirectoryRefused() throws {
        let dir = try tempDir()
        try ConformanceBundle.write(stored: try sealedStored(), to: dir)
        // wx--x--x: files remain openable by exact name, but the directory
        // cannot be LISTED — the exact-contents check is impossible.
        try FileManager.default.setAttributes([.posixPermissions: 0o311], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        let v = ConformanceBundle.verify(at: dir)
        #expect(v.integrity == .failed)
        #expect(v.details.contains { $0.contains("could not be enumerated") })
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
            approvedDeviationCount: e.approvedDeviationCount,
            factsSHA256: e.factsSHA256,
            publicAuditChainHead: e.publicAuditChainHead)
        attestation = SealedConformance(envelope: forgedEnvelope,
                                        signatureHex: attestation.signatureHex,
                                        publicKeyHex: attestation.publicKeyHex)
        let forgedAttestation = try ConformanceCanonical.data(of: attestation)
        try forgedAttestation.write(to: dir.appendingPathComponent("attestation.json"))

        // ...and recompute the manifest so INTEGRITY passes. The modeled
        // forger keeps the FULL mandatory file set (eighth audit: a manifest
        // missing mandatory files now fails integrity outright, so the only
        // interesting forgery is a complete, internally consistent one).
        func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
        var files: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path)
        where name != "manifest.json" {
            files[name] = sha(try Data(contentsOf: dir.appendingPathComponent(name)))
        }
        try ConformanceCanonical.data(of: ConformanceBundle.Manifest(formatVersion: 1, files: files))
            .write(to: dir.appendingPathComponent("manifest.json"))

        let v = ConformanceBundle.verify(at: dir)
        #expect(v.integrity == .passed, "the forger made the hashes internally consistent")
        #expect(v.authenticity == .failed, "the signature over the canonical envelope must still fail")
        #expect(v.conformanceReplay == .notChecked)
    }

    /// EIGHTH AUDIT — an attacker-rewritten `{"files":{}}` manifest must not
    /// pass integrity vacuously, and an unknown format version is refused.
    @Test("An emptied manifest and an unknown format version both fail integrity")
    func emptiedManifestAndUnknownVersionRefused() throws {
        let dir = try tempDir()
        try ConformanceBundle.write(stored: try sealedStored(), to: dir)
        try Data(#"{"files":{},"formatVersion":1}"#.utf8)
            .write(to: dir.appendingPathComponent("manifest.json"))
        let emptied = ConformanceBundle.verify(at: dir)
        #expect(emptied.integrity == .failed)
        #expect(emptied.details.contains { $0.contains("mandatory file") })

        let dir2 = try tempDir()
        try ConformanceBundle.write(stored: try sealedStored(), to: dir2)
        let manifestData = try Data(contentsOf: dir2.appendingPathComponent("manifest.json"))
        let bumped = String(decoding: manifestData, as: UTF8.self)
            .replacingOccurrences(of: #""formatVersion":1"#, with: #""formatVersion":9"#)
        try Data(bumped.utf8).write(to: dir2.appendingPathComponent("manifest.json"))
        let unknown = ConformanceBundle.verify(at: dir2)
        #expect(unknown.integrity == .failed)
        #expect(unknown.details.contains { $0.contains("unknown format version") })
    }

    /// Acceptance test 7: the verifier recomputes the same status the app sealed
    /// — and catches a sealed status that does not match the outcomes.
    @Test("Replay recomputes the sealed status from the outcomes")
    func replayMatchesStatus() throws {
        let dir = try tempDir()
        try ConformanceBundle.write(stored: try sealedStored(), to: dir)
        #expect(ConformanceBundle.verify(at: dir).conformanceReplay == .passed)

        // A truthful notConformant seal also replays cleanly.
        let spine: Set<PersonaJobKind> = [.caseIntake, .findings]
        let rules = SutraRuleCompiler.rules(for: sutra).filter { $0.phaseKind.map(spine.contains) ?? true }
        let facts = ConformanceFacts(completedPhaseKinds: spine,
                                     standardOfProofDeclared: false,   // gate fails
                                     openItemsAcknowledged: true,
                                     humanDecisionsMade: spine,
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

    @Test("Run binding recomputes from the signed facts; a wrong signed binding fails replay")
    func runBindingRecomputes() throws {
        // Positive: the fixture's binding is genuine — recompute matches.
        let cleanDir = try tempDir()
        try ConformanceBundle.write(stored: try sealedStored(), to: cleanDir)
        let clean = ConformanceBundle.verify(at: cleanDir)
        #expect(clean.conformanceReplay == .passed)
        #expect(!clean.details.contains { $0.contains("not independently recomputable") })
        // Negative: same facts components, but the SIGNED runStateSHA256 does
        // not hash from them — the recompute refuses.
        let forgedDir = try tempDir()
        try ConformanceBundle.write(stored: try sealedStored(runStateOverride: String(repeating: "ab", count: 32)),
                                    to: forgedDir)
        let forged = ConformanceBundle.verify(at: forgedDir)
        #expect(forged.conformanceReplay == .failed)
        #expect(forged.details.contains { $0.contains("run binding") })
    }
}
