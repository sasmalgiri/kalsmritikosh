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
        // RULE v2 (eighth audit): edited wrapper METADATA breaks the replay
        // too — the link binds seq/source/eventID/occurredAt, not just the
        // payload, so swapping an event ID cannot survive the fold.
        var metaForged = trail
        metaForged[1] = AuditTrailEntry(seq: metaForged[1].seq, source: metaForged[1].source,
                                        eventID: UUID(), occurredAt: metaForged[1].occurredAt,
                                        canonicalPayload: metaForged[1].canonicalPayload,
                                        publicPrev: metaForged[1].publicPrev, publicHash: metaForged[1].publicHash)
        #expect(PublicAuditChain.replay(metaForged, expectedHead: head) != nil)
        var timeForged = trail
        timeForged[0] = AuditTrailEntry(seq: timeForged[0].seq, source: timeForged[0].source,
                                        eventID: timeForged[0].eventID,
                                        occurredAt: timeForged[0].occurredAt.addingTimeInterval(3600),
                                        canonicalPayload: timeForged[0].canonicalPayload,
                                        publicPrev: timeForged[0].publicPrev, publicHash: timeForged[0].publicHash)
        #expect(PublicAuditChain.replay(timeForged, expectedHead: head) != nil)
    }

    @Test("Keyless rewrites of occurred_at or the public columns are caught by verify()")
    func publicColumnsRewriteDetected() async throws {
        // NINTH AUDIT — occurred_at and the public links are not covered by
        // the HMAC, so a database writer could rewrite them and recompute
        // the keyless public chain. verify() must RE-DERIVE both from the
        // authoritative source events and report the break BEFORE any
        // approval signs the public head.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phased-rw-\(UUID().uuidString)", isDirectory: true)
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
        _ = try await chain.seal(now: t0)
        #expect(try await chain.verify().isIntact)
        // (a) rewrite the stored timestamp only — HMAC columns untouched.
        try await db.exec("UPDATE audit_chain SET occurred_at = occurred_at + 3600 WHERE seq = 1;", [])
        #expect(try await chain.verify().firstBrokenSeq == 1)
        try await db.exec("UPDATE audit_chain SET occurred_at = occurred_at - 3600 WHERE seq = 1;", [])
        #expect(try await chain.verify().isIntact)
        // (b) forge the keyless public columns directly.
        try await db.exec("UPDATE audit_chain SET public_hash = 'ff00' WHERE seq = 2;", [])
        #expect(try await chain.verify().firstBrokenSeq == 2)
    }

    // MARK: Bundle v2 (trail-carrying)

    /// A synthetic trail entry folded with the shared RULE-V2 computation
    /// (the link binds seq/source/eventID/occurredAt/payload).
    private func trailEntry(seq: Int, payload: String, prev: String) -> AuditTrailEntry {
        let eventID = UUID()
        let hash = PublicAuditChain.link(
            entry: PublicAuditChain.canonicalEntry(seq: seq, source: "governance", eventID: eventID,
                                                   occurredAt: t0, payload: payload),
            prev: prev)
        return AuditTrailEntry(seq: seq, source: "governance", eventID: eventID, occurredAt: t0,
                               canonicalPayload: payload, publicPrev: prev, publicHash: hash)
    }

    private func sealedWithPublicHead() throws -> (StoredConformanceAssessment, [AuditTrailEntry]) {
        let e1 = trailEntry(seq: 1, payload: "actor=me;at=1.0;caseID=C;detail=standard=x;kind=findings.approved",
                            prev: PublicAuditChain.genesis)
        let e2 = trailEntry(seq: 2, payload: "actor=me;at=2.0;caseID=C;detail=revision=1;kind=bundle.exported",
                            prev: e1.publicHash)
        let trail = [e1, e2]
        let h2 = e2.publicHash
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
        // Strip the trail + recompute the (unsigned) manifest over EVERYTHING
        // else (a competent forger keeps the mandatory set + exact-contents
        // rule intact): replay still refuses on the missing trail.
        try FileManager.default.removeItem(at: dirB.appendingPathComponent("audit-events.json"))
        var files: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: dirB.path)
        where name != "manifest.json" {
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

    @Test("A trail that advanced past the SIGNED head is truncated at export and still verifies")
    func trailTruncatedToSignedHead() throws {
        // EIGHTH AUDIT — the ledger keeps sealing after the envelope signs
        // its head (the approval's own governance event, later activity).
        // Export must ship the prefix ending at the SIGNED head, not the
        // whole current trail, or replay folds past the head and fails.
        let (stored, trail) = try sealedWithPublicHead()
        let e3 = trailEntry(seq: 3, payload: "actor=me;at=3.0;caseID=C;detail=later;kind=findings.approved",
                            prev: trail[1].publicHash)
        let advanced = trail + [e3]
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phased-trunc-\(UUID().uuidString)", isDirectory: true)
        try ConformanceBundle.write(stored: stored, to: dir, auditTrail: advanced)
        let verdict = ConformanceBundle.verify(at: dir)
        #expect(verdict.allPassed, "\(verdict.details)")
        // The shipped trail carries exactly the signed prefix.
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let shipped = try decoder.decode([AuditTrailEntry].self,
            from: Data(contentsOf: dir.appendingPathComponent("audit-events.json")))
        #expect(shipped.count == 2)
        #expect(shipped.last?.publicHash == stored.seal?.envelope.publicAuditChainHead)
    }

    @Test("A fresh-ledger approval (signed head = genesis) exports and verifies without a trail")
    func genesisHeadBundleVerifies() throws {
        // EIGHTH AUDIT — on a zero-event ledger the envelope signs the chain
        // GENESIS. That bundle needs no audit-events.json and must verify.
        let sutra = SutraCompiler.shared()
        let spine: Set<PersonaJobKind> = [.caseIntake, .findings]
        let attested = Set(SutraRuleCompiler.rules(for: sutra)
            .filter { $0.phaseKind.map(spine.contains) ?? true }.map(\.id))
        var facts = ConformanceFacts(completedPhaseKinds: spine,
                                     standardOfProofDeclared: true,
                                     openItemsAcknowledged: true,
                                     humanDecisionsMade: spine,
                                     attestedRuleIDs: attested)
        let runID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEFFFF0003")!
        facts.runReceiptSeal = "receipt-seal-0003"
        facts.runCaseRevision = 1
        let binding = try ConformanceCanonical.sha256(of: ConformanceRunBinding(
            runID: runID, receiptSeal: "receipt-seal-0003", caseRevision: 1))
        let assessment = SutraConformance.assess(facts: facts, against: sutra, at: t0,
                                                 runID: runID, runStateSHA256: binding)
        let sealed = try ConformanceSeal.seal(
            assessment: assessment, build: "1.0 (test)", key: key,
            linkage: ConformanceSealLinkage(publicAuditChainHead: PublicAuditChain.genesis))
        let stored = StoredConformanceAssessment(caseID: UUID(), runRevision: 1,
                                                 assessment: assessment, seal: sealed, createdAt: t0)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phased-genesis-\(UUID().uuidString)", isDirectory: true)
        try ConformanceBundle.write(stored: stored, to: dir)   // no trail — valid
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("audit-events.json").path))
        let verdict = ConformanceBundle.verify(at: dir)
        #expect(verdict.allPassed, "\(verdict.details)")
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
