//
//  PhaseDTests.swift
//  KalsmritikoshTests
//
//  PHASE D — the publicly recomputable trail. Proves: the dual-hash chain
//  seals a keyless SHA-256 chain alongside the HMAC chain; the exported
//  trail folds to the signed head with the ONE shared computation; a bundle
//  whose envelope commits to a public head refuses to export without its
//  trail and refuses to verify when the trail is stripped; and a sealed
//  studio deliverable verifies (and fails on content tampering) with the
//  shared StudioDeliverableVerifier.
//

import Foundation
import Testing
import CryptoKit
@testable import Kalsmritikosh

@Suite("Phase D — public trail + studio verify", .serialized)
struct PhaseDTests {

    private let t0 = Date(timeIntervalSince1970: 1_769_300_000)
    private let key = P256.Signing.PrivateKey()

    // MARK: Public dual-hash chain

    @Test("Sealing writes the public chain; the exported trail folds to the public head")
    func publicChainSealsAndReplays() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phased-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        let repo = GovernanceEventsRepository(database: db)
        let caseID = UUID()
        _ = try await repo.record(kind: .findingsApproved, caseID: caseID, actor: "me",
                                  detail: "standard=Probable cause", at: t0)
        _ = try await repo.record(kind: .bundleExported, caseID: caseID, actor: "me",
                                  detail: "revision=1", at: t0.addingTimeInterval(10))
        let chain = AuditChainService(database: db, secret: Data("test-secret".utf8),
                                      eventProvider: { (try? await repo.auditChainEvents()) ?? [] })
        #expect(try await chain.seal(now: t0) == 2)
        let head = try await chain.publicHead()
        #expect(head != PublicAuditChain.genesis)
        let trail = try await chain.publicTrail()
        #expect(trail.count == 2)
        // The ONE shared fold reaches the head.
        #expect(PublicAuditChain.replay(trail, expectedHead: head) == nil)
        // A tampered payload breaks the replay.
        var forged = trail
        forged[1] = AuditTrailEntry(seq: forged[1].seq, source: forged[1].source,
                                    eventID: forged[1].eventID, occurredAt: forged[1].occurredAt,
                                    canonicalPayload: forged[1].canonicalPayload + "X",
                                    publicPrev: forged[1].publicPrev, publicHash: forged[1].publicHash)
        #expect(PublicAuditChain.replay(forged, expectedHead: head) != nil)
    }

    // MARK: Bundle v2 (trail-carrying)

    private func sealedWithPublicHead() throws -> (StoredConformanceAssessment, [AuditTrailEntry]) {
        // A synthetic two-entry public trail, folded with the shared rule.
        let e1Payload = "actor=me;at=1.0;caseID=C;detail=standard=x;kind=findings.approved"
        let h1 = PublicAuditChain.link(payload: e1Payload, prev: PublicAuditChain.genesis)
        let e2Payload = "actor=me;at=2.0;caseID=C;detail=revision=1;kind=bundle.exported"
        let h2 = PublicAuditChain.link(payload: e2Payload, prev: h1)
        let trail = [
            AuditTrailEntry(seq: 1, source: "governance", eventID: UUID(), occurredAt: t0,
                            canonicalPayload: e1Payload, publicPrev: PublicAuditChain.genesis, publicHash: h1),
            AuditTrailEntry(seq: 2, source: "governance", eventID: UUID(), occurredAt: t0,
                            canonicalPayload: e2Payload, publicPrev: h1, publicHash: h2),
        ]
        let sutra = SutraCompiler.shared()
        let spine: Set<PersonaJobKind> = [.caseIntake, .findings]
        let attested = Set(SutraRuleCompiler.rules(for: sutra)
            .filter { $0.phaseKind.map(spine.contains) ?? true }.map(\.id))
        var facts = ConformanceFacts(completedPhaseKinds: spine,
                                     standardOfProofDeclared: true,
                                     openItemsAcknowledged: true,
                                     humanDecisionsMade: spine,
                                     attestedRuleIDs: attested)
        let runID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEFFFF0002")!
        facts.runReceiptSeal = "receipt-seal-0002"
        facts.runCaseRevision = 2
        let binding = try ConformanceCanonical.sha256(of: ConformanceRunBinding(
            runID: runID, receiptSeal: "receipt-seal-0002", caseRevision: 2))
        let assessment = SutraConformance.assess(facts: facts, against: sutra, at: t0,
                                                 runID: runID, runStateSHA256: binding)
        let sealed = try ConformanceSeal.seal(
            assessment: assessment, build: "1.0 (test)", key: key,
            linkage: ConformanceSealLinkage(publicAuditChainHead: h2))
        let stored = StoredConformanceAssessment(caseID: UUID(), runRevision: 1,
                                                 assessment: assessment, seal: sealed, createdAt: t0)
        return (stored, trail)
    }

    @Test("A trail-carrying bundle verifies; stripping the trail (manifest recomputed) fails replay; exporting without it refuses")
    func bundleV2TrailEnforced() throws {
        let (stored, trail) = try sealedWithPublicHead()
        // Export WITHOUT the trail: refused outright.
        let dirA = FileManager.default.temporaryDirectory
            .appendingPathComponent("phased-bundle-\(UUID().uuidString)", isDirectory: true)
        #expect(throws: ConformanceBundleError.missingAuditTrail) {
            try ConformanceBundle.write(stored: stored, to: dirA)
        }
        // Export WITH the trail: all three verdicts pass.
        let dirB = FileManager.default.temporaryDirectory
            .appendingPathComponent("phased-bundle-\(UUID().uuidString)", isDirectory: true)
        try ConformanceBundle.write(stored: stored, to: dirB, auditTrail: trail)
        let clean = ConformanceBundle.verify(at: dirB)
        #expect(clean.allPassed, "\(clean.details)")
        // Strip the trail + recompute the (unsigned) manifest: replay refuses.
        try FileManager.default.removeItem(at: dirB.appendingPathComponent("audit-events.json"))
        var files: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: dirB.path)
        where name != "manifest.json" && name != "README.txt" {
            let data = try Data(contentsOf: dirB.appendingPathComponent(name))
            files[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let manifest = try JSONSerialization.data(
            withJSONObject: ["formatVersion": 1, "files": files], options: [.sortedKeys])
        try manifest.write(to: dirB.appendingPathComponent("manifest.json"))
        let stripped = ConformanceBundle.verify(at: dirB)
        #expect(stripped.conformanceReplay == .failed)
        #expect(stripped.details.contains { $0.contains("audit-events.json is missing") })
    }

    // MARK: Studio deliverable verification (shared verifier)

    @Test("A sealed studio deliverable verifies; content tampering fails; incompleteness is stated")
    func studioSealVerifies() {
        let report = "# Expert Report\n\nFindings body — cited and versioned.\n"
        let sealedMarkdown = StudioDeliverableSeal.sealedReport(
            studio: "Forensic Accountant", title: "Engagement X", report: report,
            stagesComplete: 3, stagesTotal: 5, at: t0, key: key)
        let verdict = StudioDeliverableVerifier.verify(markdown: sealedMarkdown)
        #expect(verdict.verified, "content \(verdict.contentIntact) signature \(verdict.signatureValid)")
        #expect(verdict.envelope?.allStagesComplete == false)   // 3/5 — honest incompleteness on the wire
        // Tamper with the report body above the separator: content check fails.
        let tampered = sealedMarkdown.replacingOccurrences(of: "cited and versioned", with: "REWRITTEN")
        let bad = StudioDeliverableVerifier.verify(markdown: tampered)
        #expect(!bad.contentIntact)
        #expect(!bad.verified)
    }
}
